from dataclasses import dataclass
import io
from pathlib import Path
import tempfile
from typing import Any, Callable, Optional
import uuid
import httpx
from PIL import Image, ImageOps
from gradio_client import Client, handle_file
from gradio_client.exceptions import (
    AppError,
    AuthenticationError,
    ValidationError,
)
from app.core.config import settings
from app.core.errors import ErrorCode, ImageValidationError
from app.core.logging import logger
from app.integrations.ai_provider import (
    AIProviderResult,
    PermanentAIProviderError,
    TransientAIProviderError,
)
from app.services.upload_validator import UploadValidator, ValidatedImage


@dataclass(frozen=True)
class _AspectPadMetadata:
    orig_w: int
    orig_h: int
    canvas_w: int
    canvas_h: int
    pad_left: int
    pad_top: int

    @property
    def is_padded(self) -> bool:
        return self.canvas_w != self.orig_w or self.canvas_h != self.orig_h


class HuggingFaceAdapter:
    """
    AI Virtual Try-On adapter integrating with Hugging Face Spaces via `gradio_client`.
    Defaults to `yisol/IDM-VTON` (free ZeroGPU Space).

    Workflow:
    1. Validate `person_image_bytes` and `garment_image_bytes` locally with `UploadValidator`.
    2. Normalize EXIF orientation and pad both `person_image` and `garment_image` to IDM-VTON's
       native `3:4` aspect ratio (`768x1024`) without stretching or squashing proportions.
    3. Connect to the configured Hugging Face Space (`HF_SPACE_ID`) using `gradio_client.Client`
       (with optional `HF_TOKEN` for ZeroGPU quota priority).
    4. Invoke the `/tryon` Gradio endpoint with IDM-VTON parameters.
    5. Extract the generated output image, remove the `3:4` aspect padding, restore the exact
       original `(orig_w, orig_h)` dimensions, validate with `UploadValidator`, and return `AIProviderResult`.
    """

    PROVIDER_NAME = "huggingface"
    _TARGET_ASPECT_RATIO = 3.0 / 4.0  # IDM-VTON native 768x1024 ratio

    _TRANSIENT_KEYWORDS = (
        "timeout",
        "timed out",
        "queue",
        "rate limit",
        "quota",
        "zerogpu",
        "gpu",
        "sleeping",
        "building",
        "starting",
        "busy",
        "overload",
        "unavailable",
        "connection",
        "reset",
        "429",
        "500",
        "502",
        "503",
        "504",
    )

    _PERMANENT_KEYWORDS = (
        "401",
        "403",
        "404",
        "unauthorized",
        "forbidden",
        "not found",
        "invalid token",
    )

    def __init__(
        self,
        hf_token: Optional[str] = None,
        space_id: Optional[str] = None,
        api_name: Optional[str] = None,
        garment_description: Optional[str] = None,
        auto_mask: Optional[bool] = None,
        auto_crop: Optional[bool] = None,
        denoise_steps: Optional[int] = None,
        seed: Optional[int] = None,
        timeout_seconds: Optional[float] = None,
        preserve_aspect_ratio: bool = True,
        validator: Optional[UploadValidator] = None,
        client_factory: Optional[Callable[..., Any]] = None,
        on_request_submitted: Optional[Callable[[str], None]] = None,
    ) -> None:
        raw_token = settings.HF_TOKEN if hf_token is None else hf_token
        self.hf_token: Optional[str] = (
            raw_token.strip() if raw_token and raw_token.strip() else None
        )
        self.space_id: str = (
            settings.HF_SPACE_ID if space_id is None else space_id
        ).strip()
        if not self.space_id:
            self.space_id = "yisol/IDM-VTON"

        raw_api_name = (
            settings.HF_API_NAME if api_name is None else api_name
        ).strip()
        if not raw_api_name:
            raw_api_name = "/tryon"
        self.api_name: str = (
            raw_api_name if raw_api_name.startswith("/") else f"/{raw_api_name}"
        )

        self.garment_description: str = (
            settings.HF_GARMENT_DESCRIPTION
            if garment_description is None
            else garment_description
        ).strip() or "Upper body garment"

        self.auto_mask: bool = (
            settings.HF_AUTO_MASK if auto_mask is None else bool(auto_mask)
        )
        self.auto_crop: bool = (
            settings.HF_AUTO_CROP if auto_crop is None else bool(auto_crop)
        )
        self.denoise_steps: int = max(
            1,
            int(
                settings.HF_DENOISE_STEPS
                if denoise_steps is None
                else denoise_steps
            ),
        )
        self.seed: int = int(settings.HF_SEED if seed is None else seed)
        self.timeout_seconds: float = max(
            5.0,
            float(
                settings.HF_TIMEOUT_SECONDS
                if timeout_seconds is None
                else timeout_seconds
            ),
        )
        self.preserve_aspect_ratio: bool = preserve_aspect_ratio
        self.validator = validator or UploadValidator()
        self._client_factory = client_factory
        self._on_request_submitted = on_request_submitted

    def _validate_input_bytes(
        self,
        image_bytes: bytes,
        field_name: str,
    ) -> ValidatedImage:
        if not image_bytes:
            raise PermanentAIProviderError(
                message=f"Input '{field_name}' image bytes are empty.",
                error_code=ErrorCode.CORRUPTED_IMAGE.value,
                provider_name=self.PROVIDER_NAME,
            )
        try:
            return self.validator.validate_bytes_sync(
                image_bytes,
                field_name=field_name,
            )
        except ImageValidationError as exc:
            raise PermanentAIProviderError(
                message=(
                    f"Invalid input '{field_name}' for Hugging Face provider: "
                    f"{exc.message}"
                ),
                error_code=exc.error_code.value,
                provider_name=self.PROVIDER_NAME,
            ) from exc

    @staticmethod
    def _to_rgb_on_white(img: Image.Image) -> Image.Image:
        """Convert image to RGB, compositing transparent pixels onto a clean white background."""
        if img.mode in ("RGBA", "LA") or (
            img.mode == "P" and "transparency" in img.info
        ):
            rgba = img.convert("RGBA")
            white_bg = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
            white_bg.paste(rgba, (0, 0), rgba)
            return white_bg.convert("RGB")
        return img.convert("RGB")

    @staticmethod
    def _pad_with_edge_replication(
        rgb_img: Image.Image,
        canvas_w: int,
        canvas_h: int,
        pad_left: int,
        pad_top: int,
    ) -> Image.Image:
        """
        Place `rgb_img` onto a `(canvas_w, canvas_h)` canvas at `(pad_left, pad_top)`
        and fill any surrounding padding bands by stretching the 1px border edges.
        This avoids artificial black/white bars that could confuse pose/mask detectors.
        """
        orig_w, orig_h = rgb_img.size
        if canvas_w == orig_w and canvas_h == orig_h:
            return rgb_img

        canvas = Image.new("RGB", (canvas_w, canvas_h))
        canvas.paste(rgb_img, (pad_left, pad_top))

        pad_right = canvas_w - (pad_left + orig_w)
        pad_bottom = canvas_h - (pad_top + orig_h)

        # Fill top band
        if pad_top > 0:
            top_strip = rgb_img.crop((0, 0, orig_w, 1)).resize(
                (orig_w, pad_top), Image.Resampling.NEAREST
            )
            canvas.paste(top_strip, (pad_left, 0))

        # Fill bottom band
        if pad_bottom > 0:
            bottom_strip = rgb_img.crop((0, orig_h - 1, orig_w, orig_h)).resize(
                (orig_w, pad_bottom), Image.Resampling.NEAREST
            )
            canvas.paste(bottom_strip, (pad_left, pad_top + orig_h))

        # Fill left band (full canvas height)
        if pad_left > 0:
            left_col = canvas.crop((pad_left, 0, pad_left + 1, canvas_h)).resize(
                (pad_left, canvas_h), Image.Resampling.NEAREST
            )
            canvas.paste(left_col, (0, 0))

        # Fill right band (full canvas height)
        if pad_right > 0:
            right_col = canvas.crop(
                (pad_left + orig_w - 1, 0, pad_left + orig_w, canvas_h)
            ).resize((pad_right, canvas_h), Image.Resampling.NEAREST)
            canvas.paste(right_col, (pad_left + orig_w, 0))

        return canvas

    def _prepare_person_image_for_3_4(
        self,
        person_bytes: bytes,
    ) -> tuple[bytes, _AspectPadMetadata]:
        """
        Pad the person image to a 3:4 aspect ratio so IDM-VTON's internal `.resize((768, 1024))`
        scales X and Y uniformly without squashing the person's head, shoulders, or torso.
        - If wider than 3:4 (`orig_w / orig_h > 0.75`): pad at the top (`pad_top = canvas_h - orig_h`)
          so the bottom of the person's torso/legs remains anchored to the bottom of the frame.
        - If taller than 3:4 (`orig_w / orig_h < 0.75`): pad left and right equally.
        """
        with Image.open(io.BytesIO(person_bytes)) as raw_img:
            transposed = ImageOps.exif_transpose(raw_img)
            rgb_img = self._to_rgb_on_white(transposed)

        orig_w, orig_h = rgb_img.size
        current_ratio = orig_w / float(orig_h)

        if not self.preserve_aspect_ratio or abs(current_ratio - self._TARGET_ASPECT_RATIO) < 1e-3:
            meta = _AspectPadMetadata(
                orig_w=orig_w,
                orig_h=orig_h,
                canvas_w=orig_w,
                canvas_h=orig_h,
                pad_left=0,
                pad_top=0,
            )
            return person_bytes, meta

        if current_ratio > self._TARGET_ASPECT_RATIO:
            # Image is wider than 3:4 -> extend height (pad at top so bottom stays anchored)
            canvas_w = orig_w
            canvas_h = max(orig_h, int(round(orig_w / self._TARGET_ASPECT_RATIO)))
            pad_left = 0
            pad_top = canvas_h - orig_h
        else:
            # Image is taller than 3:4 -> extend width (pad equally on left and right)
            canvas_w = max(orig_w, int(round(orig_h * self._TARGET_ASPECT_RATIO)))
            canvas_h = orig_h
            pad_left = (canvas_w - orig_w) // 2
            pad_top = 0

        padded_img = self._pad_with_edge_replication(
            rgb_img=rgb_img,
            canvas_w=canvas_w,
            canvas_h=canvas_h,
            pad_left=pad_left,
            pad_top=pad_top,
        )

        out_buf = io.BytesIO()
        padded_img.save(out_buf, format="PNG")
        meta = _AspectPadMetadata(
            orig_w=orig_w,
            orig_h=orig_h,
            canvas_w=canvas_w,
            canvas_h=canvas_h,
            pad_left=pad_left,
            pad_top=pad_top,
        )
        return out_buf.getvalue(), meta

    def _prepare_garment_image_for_3_4(self, garment_bytes: bytes) -> bytes:
        """
        Composite transparent garment images onto white and pad to a centered 3:4 canvas
        so IDM-VTON's internal `garm_img.resize((768, 1024))` does not squash the garment horizontally.
        """
        if not self.preserve_aspect_ratio:
            return garment_bytes

        with Image.open(io.BytesIO(garment_bytes)) as raw_img:
            transposed = ImageOps.exif_transpose(raw_img)
            rgb_img = self._to_rgb_on_white(transposed)

        orig_w, orig_h = rgb_img.size
        current_ratio = orig_w / float(orig_h)

        if abs(current_ratio - self._TARGET_ASPECT_RATIO) < 1e-3:
            out_buf = io.BytesIO()
            rgb_img.save(out_buf, format="PNG")
            return out_buf.getvalue()

        if current_ratio > self._TARGET_ASPECT_RATIO:
            canvas_w = orig_w
            canvas_h = max(orig_h, int(round(orig_w / self._TARGET_ASPECT_RATIO)))
        else:
            canvas_w = max(orig_w, int(round(orig_h * self._TARGET_ASPECT_RATIO)))
            canvas_h = orig_h

        pad_left = (canvas_w - orig_w) // 2
        pad_top = (canvas_h - orig_h) // 2

        padded_img = self._pad_with_edge_replication(
            rgb_img=rgb_img,
            canvas_w=canvas_w,
            canvas_h=canvas_h,
            pad_left=pad_left,
            pad_top=pad_top,
        )

        out_buf = io.BytesIO()
        padded_img.save(out_buf, format="PNG")
        return out_buf.getvalue()

    def _restore_output_aspect_ratio(
        self,
        raw_output_bytes: bytes,
        pad_meta: _AspectPadMetadata,
    ) -> bytes:
        """
        Resize IDM-VTON's 768x1024 output back to `(canvas_w, canvas_h)` and crop out
        the temporary padding so the final image matches `(orig_w, orig_h)` exactly.
        """
        if not self.preserve_aspect_ratio:
            return raw_output_bytes

        with Image.open(io.BytesIO(raw_output_bytes)) as out_img:
            rgb_out = out_img.convert("RGB")
            out_w, out_h = rgb_out.size

            if (out_w, out_h) == (pad_meta.orig_w, pad_meta.orig_h) and not pad_meta.is_padded:
                return raw_output_bytes

            resized_canvas = rgb_out.resize(
                (pad_meta.canvas_w, pad_meta.canvas_h),
                Image.Resampling.LANCZOS,
            )
            cropped_orig = resized_canvas.crop(
                (
                    pad_meta.pad_left,
                    pad_meta.pad_top,
                    pad_meta.pad_left + pad_meta.orig_w,
                    pad_meta.pad_top + pad_meta.orig_h,
                )
            )
            out_buf = io.BytesIO()
            cropped_orig.save(out_buf, format="JPEG", quality=95)
            return out_buf.getvalue()

    def _create_client(self) -> Any:
        if self._client_factory is not None:
            return self._client_factory(
                self.space_id,
                hf_token=self.hf_token,
                httpx_kwargs={"timeout": httpx.Timeout(self.timeout_seconds)},
            )
        return Client(
            self.space_id,
            token=self.hf_token,
            httpx_kwargs={"timeout": httpx.Timeout(self.timeout_seconds)},
            verbose=False,
        )

    def _build_predict_kwargs(
        self,
        person_file_path: str,
        garment_file_path: str,
    ) -> dict[str, Any]:
        """
        Build Gradio `.predict()` keyword arguments for IDM-VTON (`yisol/IDM-VTON` and clones).
        """
        return {
            "dict": {
                "background": handle_file(person_file_path),
                "layers": [],
                "composite": None,
            },
            "garm_img": handle_file(garment_file_path),
            "garment_des": self.garment_description,
            "is_checked": self.auto_mask,
            "is_checked_crop": self.auto_crop,
            "denoise_steps": self.denoise_steps,
            "seed": self.seed,
            "api_name": self.api_name,
        }

    def _extract_result_path(
        self,
        prediction_result: Any,
        request_id: str,
    ) -> Path:
        """
        Normalize Gradio `predict()` output into a local filesystem `Path`.
        IDM-VTON returns a tuple `(output_image_path, masked_image_path)`.
        Other Gradio Spaces may return a single string path, a `Path`, or a dict with `'path'`.
        """
        candidate = prediction_result
        if isinstance(candidate, (tuple, list)):
            if not candidate:
                raise PermanentAIProviderError(
                    message=(
                        f"Hugging Face Space '{self.space_id}' returned an empty result tuple/list."
                    ),
                    error_code=ErrorCode.AI_PROVIDER_ERROR.value,
                    provider_name=self.PROVIDER_NAME,
                    provider_request_id=request_id,
                )
            candidate = candidate[0]

        if isinstance(candidate, dict):
            candidate = (
                candidate.get("path")
                or candidate.get("image")
                or candidate.get("url")
            )
            if isinstance(candidate, dict):
                candidate = candidate.get("path") or candidate.get("url")

        if isinstance(candidate, (str, Path)):
            path_obj = Path(candidate)
            if path_obj.exists() and path_obj.is_file():
                return path_obj

        raise PermanentAIProviderError(
            message=(
                f"Hugging Face Space '{self.space_id}' did not return a valid local image file. "
                f"Received: {type(prediction_result).__name__}"
            ),
            error_code=ErrorCode.AI_PROVIDER_ERROR.value,
            provider_name=self.PROVIDER_NAME,
            provider_request_id=request_id,
        )

    def _classify_and_raise(
        self,
        exc: Exception,
        stage: str,
        request_id: Optional[str] = None,
    ) -> None:
        if isinstance(exc, (PermanentAIProviderError, TransientAIProviderError)):
            raise exc

        msg = str(exc) or exc.__class__.__name__
        lowered = msg.lower()

        if isinstance(exc, (AuthenticationError, ValidationError)):
            raise PermanentAIProviderError(
                message=(
                    f"Permanent authentication/validation error from Hugging Face Space "
                    f"'{self.space_id}' during {stage}: {msg}"
                ),
                error_code=ErrorCode.AI_PROVIDER_ERROR.value,
                provider_name=self.PROVIDER_NAME,
                provider_request_id=request_id,
            ) from exc

        if isinstance(exc, (httpx.TimeoutException, TimeoutError)):
            raise TransientAIProviderError(
                message=(
                    f"Hugging Face Space '{self.space_id}' timed out during {stage}: {msg}"
                ),
                error_code=ErrorCode.AI_PROVIDER_TIMEOUT.value,
                provider_name=self.PROVIDER_NAME,
                provider_request_id=request_id,
            ) from exc

        if isinstance(exc, (httpx.RequestError, ConnectionError)):
            raise TransientAIProviderError(
                message=(
                    f"Transient network error communicating with Hugging Face Space "
                    f"'{self.space_id}' during {stage}: {msg}"
                ),
                error_code=ErrorCode.AI_PROVIDER_ERROR.value,
                provider_name=self.PROVIDER_NAME,
                provider_request_id=request_id,
            ) from exc

        if isinstance(exc, AppError):
            if any(k in lowered for k in self._TRANSIENT_KEYWORDS):
                raise TransientAIProviderError(
                    message=(
                        f"Hugging Face Space '{self.space_id}' temporary error during {stage}: {msg}"
                    ),
                    error_code=ErrorCode.AI_PROVIDER_ERROR.value,
                    provider_name=self.PROVIDER_NAME,
                    provider_request_id=request_id,
                ) from exc
            raise PermanentAIProviderError(
                message=(
                    f"Hugging Face Space '{self.space_id}' application error during {stage}: {msg}"
                ),
                error_code=ErrorCode.AI_PROVIDER_ERROR.value,
                provider_name=self.PROVIDER_NAME,
                provider_request_id=request_id,
            ) from exc

        if any(k in lowered for k in self._PERMANENT_KEYWORDS):
            raise PermanentAIProviderError(
                message=(
                    f"Permanent error from Hugging Face Space '{self.space_id}' during {stage}: {msg}"
                ),
                error_code=ErrorCode.AI_PROVIDER_ERROR.value,
                provider_name=self.PROVIDER_NAME,
                provider_request_id=request_id,
            ) from exc

        if any(k in lowered for k in self._TRANSIENT_KEYWORDS):
            err_code = (
                ErrorCode.AI_PROVIDER_TIMEOUT.value
                if "timeout" in lowered or "timed out" in lowered
                else ErrorCode.AI_PROVIDER_ERROR.value
            )
            raise TransientAIProviderError(
                message=(
                    f"Temporary error from Hugging Face Space '{self.space_id}' during {stage}: {msg}"
                ),
                error_code=err_code,
                provider_name=self.PROVIDER_NAME,
                provider_request_id=request_id,
            ) from exc

        raise TransientAIProviderError(
            message=(
                f"Error communicating with Hugging Face Space '{self.space_id}' during {stage}: {msg}"
            ),
            error_code=ErrorCode.AI_PROVIDER_ERROR.value,
            provider_name=self.PROVIDER_NAME,
            provider_request_id=request_id,
        ) from exc

    def generate_try_on(
        self,
        job_id: uuid.UUID,
        person_image_bytes: bytes,
        garment_image_bytes: bytes,
        existing_request_id: Optional[str] = None,
        on_request_submitted: Optional[Callable[[str], None]] = None,
    ) -> AIProviderResult:
        """
        Execute virtual try-on via Hugging Face Space (`gradio_client`).
        """
        validated_person = self._validate_input_bytes(
            person_image_bytes, "person_image"
        )
        validated_garment = self._validate_input_bytes(
            garment_image_bytes, "garment_image"
        )

        prepared_person_bytes, pad_meta = self._prepare_person_image_for_3_4(
            validated_person.content
        )
        prepared_garment_bytes = self._prepare_garment_image_for_3_4(
            validated_garment.content
        )

        cleaned_existing_id = (existing_request_id or "").strip()
        request_id = (
            cleaned_existing_id
            or f"hf-{job_id.hex[:12]}-{uuid.uuid4().hex[:8]}"
        )
        callback = on_request_submitted or self._on_request_submitted

        with tempfile.TemporaryDirectory(prefix=f"hf_tryon_{job_id.hex[:8]}_") as tmp_dir:
            tmp_root = Path(tmp_dir)
            person_ext = ".png" if pad_meta.is_padded else validated_person.extension
            person_path = tmp_root / f"person{person_ext}"
            garment_path = tmp_root / "garment.png"

            person_path.write_bytes(prepared_person_bytes)
            garment_path.write_bytes(prepared_garment_bytes)

            logger.info(
                "HuggingFaceAdapter connecting to Space '%s' (api_name=%s, orig=%dx%d, padded=%dx%d) for job_id=%s (request_id=%s)",
                self.space_id,
                self.api_name,
                pad_meta.orig_w,
                pad_meta.orig_h,
                pad_meta.canvas_w,
                pad_meta.canvas_h,
                job_id,
                request_id,
            )

            try:
                client = self._create_client()
            except Exception as exc:
                self._classify_and_raise(
                    exc, stage="client initialization", request_id=request_id
                )

            if callback is not None:
                callback(request_id)

            predict_kwargs = self._build_predict_kwargs(
                person_file_path=str(person_path),
                garment_file_path=str(garment_path),
            )

            try:
                prediction = client.predict(**predict_kwargs)
            except Exception as exc:
                self._classify_and_raise(
                    exc, stage="inference prediction", request_id=request_id
                )

            result_path = self._extract_result_path(
                prediction_result=prediction,
                request_id=request_id,
            )

            try:
                raw_output_bytes = result_path.read_bytes()
            except Exception as exc:
                raise TransientAIProviderError(
                    message=(
                        f"Failed to read output image returned by Hugging Face Space "
                        f"'{self.space_id}': {exc}"
                    ),
                    error_code=ErrorCode.AI_PROVIDER_ERROR.value,
                    provider_name=self.PROVIDER_NAME,
                    provider_request_id=request_id,
                ) from exc

            restored_output_bytes = self._restore_output_aspect_ratio(
                raw_output_bytes=raw_output_bytes,
                pad_meta=pad_meta,
            )

            try:
                validated_output = self.validator.validate_bytes_sync(
                    restored_output_bytes,
                    field_name="huggingface_result_image",
                )
            except ImageValidationError as exc:
                raise PermanentAIProviderError(
                    message=(
                        f"Hugging Face Space '{self.space_id}' returned an invalid output image: "
                        f"{exc.message}"
                    ),
                    error_code=exc.error_code.value,
                    provider_name=self.PROVIDER_NAME,
                    provider_request_id=request_id,
                ) from exc

            logger.info(
                "HuggingFaceAdapter completed job_id=%s (request_id=%s, space=%s, format=%s, size=%dx%d, bytes=%d)",
                job_id,
                request_id,
                self.space_id,
                validated_output.format,
                validated_output.width,
                validated_output.height,
                len(validated_output.content),
            )

            return AIProviderResult(
                image_bytes=validated_output.content,
                provider_name=self.PROVIDER_NAME,
                provider_request_id=request_id,
                mime_type=validated_output.mime_type,
                extension=validated_output.extension,
            )
