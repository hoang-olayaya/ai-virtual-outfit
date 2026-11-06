import io
import time
from typing import Callable, Optional
import uuid
from PIL import Image, ImageOps, UnidentifiedImageError
from app.core.config import settings
from app.core.errors import ErrorCode
from app.core.logging import logger
from app.integrations.ai_provider import (
    AIProviderResult,
    PermanentAIProviderError,
    TransientAIProviderError,
)


class FakeAIProvider:
    """
    Deterministic fake AI provider for Phase B04 and automated tests.
    Validates both input images with Pillow and synthesizes a deterministic composite
    JPEG result image (person base with overlaid garment preview badge) without calling
    paid external fal.ai endpoints.
    """

    PROVIDER_NAME = "fake"

    def __init__(
        self,
        delay_seconds: Optional[float] = None,
        should_fail: bool = False,
        retryable_failure: bool = False,
        failure_error_code: str = ErrorCode.AI_PROVIDER_ERROR.value,
        failure_message: str = "Simulated FakeAIProvider inference failure.",
    ) -> None:
        self.delay_seconds = (
            settings.FAKE_AI_PROCESSING_DELAY_SECONDS
            if delay_seconds is None
            else max(0.0, float(delay_seconds))
        )
        self.should_fail = should_fail
        self.retryable_failure = retryable_failure
        self.failure_error_code = failure_error_code
        self.failure_message = failure_message
        self.call_count: int = 0

    @staticmethod
    def _decode_rgb_image(image_bytes: bytes, label: str) -> Image.Image:
        if not image_bytes:
            raise PermanentAIProviderError(
                message=f"Input '{label}' image bytes are empty.",
                error_code=ErrorCode.CORRUPTED_IMAGE.value,
                provider_name=FakeAIProvider.PROVIDER_NAME,
            )
        try:
            with Image.open(io.BytesIO(image_bytes)) as img:
                img.load()
                return ImageOps.exif_transpose(img).convert("RGB")
        except (UnidentifiedImageError, OSError, ValueError) as exc:
            raise PermanentAIProviderError(
                message=f"Failed to decode '{label}' image in FakeAIProvider: {exc}",
                error_code=ErrorCode.CORRUPTED_IMAGE.value,
                provider_name=FakeAIProvider.PROVIDER_NAME,
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
        Synthesize a deterministic composite try-on image from person and garment inputs.
        """
        self.call_count += 1
        request_id = existing_request_id or f"fake-req-{job_id}"
        if on_request_submitted is not None and not existing_request_id:
            on_request_submitted(request_id)

        if self.delay_seconds > 0:
            time.sleep(self.delay_seconds)

        if self.should_fail:
            logger.warning(
                "FakeAIProvider simulating failure (retryable=%s) for job_id=%s: %s",
                self.retryable_failure,
                job_id,
                self.failure_message,
            )
            if self.retryable_failure:
                raise TransientAIProviderError(
                    message=self.failure_message,
                    error_code=self.failure_error_code,
                    provider_name=self.PROVIDER_NAME,
                    provider_request_id=request_id,
                )
            raise PermanentAIProviderError(
                message=self.failure_message,
                error_code=self.failure_error_code,
                provider_name=self.PROVIDER_NAME,
                provider_request_id=request_id,
            )

        person_img = self._decode_rgb_image(person_image_bytes, "person_image")
        garment_img = self._decode_rgb_image(garment_image_bytes, "garment_image")

        # Create a deterministic composite output preserving person_img dimensions
        canvas = person_img.copy()
        base_w, base_h = canvas.size

        # Resize garment overlay to 40% of person image dimensions (min 32px)
        overlay_w = max(32, min(base_w, int(base_w * 0.4)))
        overlay_h = max(32, min(base_h, int(base_h * 0.4)))
        garment_resized = garment_img.resize(
            (overlay_w, overlay_h), Image.Resampling.BILINEAR
        )

        # Paste garment overlay centered horizontally in the torso area
        pos_x = max(0, (base_w - overlay_w) // 2)
        pos_y = max(0, (base_h - overlay_h) // 2)
        canvas.paste(garment_resized, (pos_x, pos_y))

        output_buffer = io.BytesIO()
        canvas.save(output_buffer, format="JPEG", quality=92)
        result_bytes = output_buffer.getvalue()

        logger.info(
            "FakeAIProvider generated result for job_id=%s (request_id=%s, size=%dx%d, bytes=%d)",
            job_id,
            request_id,
            base_w,
            base_h,
            len(result_bytes),
        )

        return AIProviderResult(
            image_bytes=result_bytes,
            provider_name=self.PROVIDER_NAME,
            provider_request_id=request_id,
            mime_type="image/jpeg",
            extension=".jpg",
        )

