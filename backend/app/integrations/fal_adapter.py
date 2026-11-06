from contextlib import contextmanager
import time
from typing import Any, Callable, Dict, Iterator, Optional
import uuid
import httpx
from app.core.config import settings
from app.core.errors import ErrorCode, ImageValidationError
from app.core.logging import logger
from app.integrations.ai_provider import (
    AIProviderResult,
    PermanentAIProviderError,
    TransientAIProviderError,
)
from app.services.upload_validator import UploadValidator, ValidatedImage


class FalAdapter:
    """
    Production AI Virtual Try-On adapter integrating with fal.ai Storage CDN and Queue API.

    Workflow:
    1. If `existing_request_id` is None:
       - Validate `person_image_bytes` and `garment_image_bytes` locally with `UploadValidator`.
       - Upload both images to fal.ai Storage CDN (`initiate` -> `PUT upload_url` -> `file_url`).
       - Build model-specific inference arguments (`cat-vton`, `fashn`, `idm-vton`, `leffa`).
       - Submit inference job to `POST https://queue.fal.run/{model_id}` and record `request_id`.
    2. If `existing_request_id` is provided (Scenario T07 / T08 retry resume):
       - Skip image uploads and queue submission to prevent duplicate paid AI requests.
       - Reconstruct `status_url` and `response_url` from `existing_request_id`.
    3. Poll `status_url` (`IN_QUEUE` / `IN_PROGRESS` -> `COMPLETED`) with bounded timeout.
    4. Fetch output JSON from `response_url` and extract the generated image URL (`image.url` or `images[0].url`).
    5. Download result image bytes from CDN with independent bounded retries (Scenario T08).
    6. Validate downloaded result image bytes with `UploadValidator` before returning `AIProviderResult`.
    """

    PROVIDER_NAME = "fal"
    _TRANSIENT_HTTP_STATUS_CODES = {408, 429, 500, 502, 503, 504}
    _ACTIVE_QUEUE_STATUSES = {"IN_QUEUE", "IN_PROGRESS", "QUEUED", "PENDING"}
    _COMPLETED_QUEUE_STATUSES = {"COMPLETED", "SUCCEEDED", "OK"}
    _FAILED_QUEUE_STATUSES = {"FAILED", "ERROR", "CANCELLED", "CANCELED"}

    def __init__(
        self,
        api_key: Optional[str] = None,
        model_id: Optional[str] = None,
        cloth_type: Optional[str] = None,
        queue_base_url: Optional[str] = None,
        storage_upload_url: Optional[str] = None,
        http_timeout_seconds: Optional[float] = None,
        poll_interval_seconds: Optional[float] = None,
        poll_timeout_seconds: Optional[float] = None,
        download_max_retries: Optional[int] = None,
        download_retry_backoff_seconds: Optional[float] = None,
        validator: Optional[UploadValidator] = None,
        http_client: Optional[httpx.Client] = None,
        sleep_fn: Callable[[float], None] = time.sleep,
        clock_fn: Callable[[], float] = time.monotonic,
        on_request_submitted: Optional[Callable[[str], None]] = None,
    ) -> None:
        self.api_key = (
            settings.FAL_KEY if api_key is None else api_key
        )
        self.model_id = (
            (settings.FAL_MODEL_ID if model_id is None else model_id).strip().strip("/")
        )
        self.cloth_type = (
            settings.FAL_CLOTH_TYPE if cloth_type is None else cloth_type
        ).strip()
        self.queue_base_url = (
            settings.FAL_QUEUE_BASE_URL if queue_base_url is None else queue_base_url
        ).rstrip("/")
        self.storage_upload_url = (
            settings.FAL_STORAGE_UPLOAD_URL
            if storage_upload_url is None
            else storage_upload_url
        ).strip()
        self.http_timeout_seconds = max(
            1.0,
            float(
                settings.FAL_HTTP_TIMEOUT_SECONDS
                if http_timeout_seconds is None
                else http_timeout_seconds
            ),
        )
        self.poll_interval_seconds = max(
            0.0,
            float(
                settings.FAL_POLL_INTERVAL_SECONDS
                if poll_interval_seconds is None
                else poll_interval_seconds
            ),
        )
        self.poll_timeout_seconds = max(
            0.1,
            float(
                settings.FAL_POLL_TIMEOUT_SECONDS
                if poll_timeout_seconds is None
                else poll_timeout_seconds
            ),
        )
        self.download_max_retries = max(
            0,
            int(
                settings.FAL_DOWNLOAD_MAX_RETRIES
                if download_max_retries is None
                else download_max_retries
            ),
        )
        self.download_retry_backoff_seconds = max(
            0.0,
            float(
                settings.FAL_DOWNLOAD_RETRY_BACKOFF_SECONDS
                if download_retry_backoff_seconds is None
                else download_retry_backoff_seconds
            ),
        )
        self.validator = validator or UploadValidator()
        self._http_client = http_client
        self._sleep = sleep_fn
        self._clock = clock_fn
        self._on_request_submitted = on_request_submitted

    @property
    def base_app_id(self) -> str:
        """
        Return the `{owner}/{app}` prefix used by fal.ai Queue API for status/result URLs.
        For example:
        - `fal-ai/cat-vton` -> `fal-ai/cat-vton`
        - `fal-ai/fashn/tryon/v1.6` -> `fal-ai/fashn`
        """
        segments = [seg for seg in self.model_id.split("/") if seg]
        if len(segments) >= 2:
            return f"{segments[0]}/{segments[1]}"
        return self.model_id

    def _require_api_key(self) -> str:
        cleaned = (self.api_key or "").strip()
        if not cleaned:
            raise PermanentAIProviderError(
                message="FAL_KEY is not configured. Cannot execute fal.ai virtual try-on request.",
                error_code=ErrorCode.AI_PROVIDER_ERROR.value,
                provider_name=self.PROVIDER_NAME,
            )
        return cleaned

    def _auth_headers(self) -> Dict[str, str]:
        key = self._require_api_key()
        return {
            "Authorization": f"Key {key}",
            "Accept": "application/json",
        }

    @contextmanager
    def _client_context(self) -> Iterator[httpx.Client]:
        if self._http_client is not None:
            yield self._http_client
            return

        with httpx.Client(
            timeout=httpx.Timeout(self.http_timeout_seconds),
            follow_redirects=True,
        ) as client:
            yield client

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
                message=f"Invalid input '{field_name}' for fal.ai provider: {exc.message}",
                error_code=exc.error_code.value,
                provider_name=self.PROVIDER_NAME,
            ) from exc

    def _raise_for_http_error(
        self,
        response: httpx.Response,
        stage: str,
        request_id: Optional[str] = None,
    ) -> None:
        if response.status_code < 400:
            return

        status_code = response.status_code
        detail_snippet = ""
        try:
            body_json = response.json()
            if isinstance(body_json, dict):
                detail_snippet = str(
                    body_json.get("detail")
                    or body_json.get("message")
                    or body_json.get("error")
                    or ""
                ).strip()
        except Exception:
            detail_snippet = (response.text or "").strip()[:200]

        suffix = f" ({detail_snippet})" if detail_snippet else ""
        msg = f"fal.ai {stage} failed with HTTP {status_code}{suffix}."

        if status_code in self._TRANSIENT_HTTP_STATUS_CODES:
            if stage == "queue submit" and request_id is None:
                err_code = ErrorCode.AI_PROVIDER_SUBMIT_INDETERMINATE.value
            elif status_code in (408, 504):
                err_code = ErrorCode.AI_PROVIDER_TIMEOUT.value
            else:
                err_code = ErrorCode.AI_PROVIDER_ERROR.value

            raise TransientAIProviderError(
                message=msg,
                error_code=err_code,
                provider_name=self.PROVIDER_NAME,
                provider_request_id=request_id,
            )

        raise PermanentAIProviderError(
            message=msg,
            error_code=ErrorCode.AI_PROVIDER_ERROR.value,
            provider_name=self.PROVIDER_NAME,
            provider_request_id=request_id,
        )

    def _request_with_error_handling(
        self,
        client: httpx.Client,
        method: str,
        url: str,
        stage: str,
        request_id: Optional[str] = None,
        **kwargs: Any,
    ) -> httpx.Response:
        try:
            response = client.request(method, url, **kwargs)
        except httpx.TimeoutException as exc:
            err_code = (
                ErrorCode.AI_PROVIDER_SUBMIT_INDETERMINATE.value
                if stage == "queue submit" and request_id is None
                else ErrorCode.AI_PROVIDER_TIMEOUT.value
            )
            raise TransientAIProviderError(
                message=f"fal.ai {stage} timed out: {exc}",
                error_code=err_code,
                provider_name=self.PROVIDER_NAME,
                provider_request_id=request_id,
            ) from exc
        except httpx.HTTPError as exc:
            err_code = (
                ErrorCode.AI_PROVIDER_SUBMIT_INDETERMINATE.value
                if stage == "queue submit" and request_id is None
                else ErrorCode.AI_PROVIDER_ERROR.value
            )
            raise TransientAIProviderError(
                message=f"fal.ai {stage} encountered network transport error: {exc}",
                error_code=err_code,
                provider_name=self.PROVIDER_NAME,
                provider_request_id=request_id,
            ) from exc

        self._raise_for_http_error(response, stage=stage, request_id=request_id)
        return response

    @staticmethod
    def _parse_json_object(
        response: httpx.Response,
        stage: str,
        request_id: Optional[str] = None,
    ) -> Dict[str, Any]:
        try:
            payload = response.json()
        except Exception as exc:
            raise PermanentAIProviderError(
                message=f"fal.ai {stage} returned non-JSON response.",
                error_code=ErrorCode.AI_PROVIDER_ERROR.value,
                provider_name=FalAdapter.PROVIDER_NAME,
                provider_request_id=request_id,
            ) from exc

        if not isinstance(payload, dict):
            raise PermanentAIProviderError(
                message=f"fal.ai {stage} returned unexpected JSON structure (expected object).",
                error_code=ErrorCode.AI_PROVIDER_ERROR.value,
                provider_name=FalAdapter.PROVIDER_NAME,
                provider_request_id=request_id,
            )
        return payload

    def _upload_single_image(
        self,
        client: httpx.Client,
        job_id: uuid.UUID,
        role: str,
        validated: ValidatedImage,
    ) -> str:
        """
        Upload a validated input image to fal.ai Storage CDN:
        1. POST initiate upload -> `{upload_url, file_url}`
        2. PUT binary content to `upload_url`
        3. Return `file_url`
        """
        file_name = f"{job_id}-{role}{validated.extension}"
        init_response = self._request_with_error_handling(
            client,
            "POST",
            self.storage_upload_url,
            stage=f"storage upload initiate ({role})",
            headers={
                **self._auth_headers(),
                "Content-Type": "application/json",
            },
            json={
                "content_type": validated.mime_type,
                "file_name": file_name,
            },
        )
        init_data = self._parse_json_object(
            init_response,
            stage=f"storage upload initiate ({role})",
        )
        upload_url = str(init_data.get("upload_url") or "").strip()
        file_url = str(init_data.get("file_url") or "").strip()

        if not upload_url.startswith(("http://", "https://")) or not file_url.startswith(
            ("http://", "https://")
        ):
            raise PermanentAIProviderError(
                message=(
                    f"fal.ai storage upload initiate ({role}) response is missing valid "
                    "'upload_url' or 'file_url'."
                ),
                error_code=ErrorCode.AI_PROVIDER_ERROR.value,
                provider_name=self.PROVIDER_NAME,
            )

        self._request_with_error_handling(
            client,
            "PUT",
            upload_url,
            stage=f"storage binary PUT ({role})",
            headers={"Content-Type": validated.mime_type},
            content=validated.content,
        )

        logger.info(
            "FalAdapter uploaded %s image for job_id=%s (mime=%s, bytes=%d)",
            role,
            job_id,
            validated.mime_type,
            len(validated.content),
        )
        return file_url

    def build_model_arguments(
        self,
        person_image_url: str,
        garment_image_url: str,
    ) -> Dict[str, Any]:
        """
        Map uploaded person and garment CDN URLs to the input schema expected by `self.model_id`.
        """
        model_lower = self.model_id.lower()

        if "fashn" in model_lower:
            return {
                "model_image": person_image_url,
                "garment_image": garment_image_url,
                "category": "auto",
            }

        if "cat-vton" in model_lower:
            return {
                "human_image_url": person_image_url,
                "garment_image_url": garment_image_url,
                "cloth_type": self.cloth_type or "upper",
            }

        if "leffa" in model_lower:
            garment_type_map = {
                "upper": "upper_body",
                "lower": "lower_body",
                "overall": "dresses",
            }
            return {
                "human_image_url": person_image_url,
                "garment_image_url": garment_image_url,
                "garment_type": garment_type_map.get(
                    self.cloth_type.lower(), "upper_body"
                ),
            }

        # Default / idm-vton schema
        return {
            "human_image_url": person_image_url,
            "garment_image_url": garment_image_url,
            "description": "Virtual try-on garment preview",
        }

    def _build_queue_urls_for_request(
        self,
        request_id: str,
    ) -> tuple[str, str]:
        clean_id = request_id.strip()
        base = f"{self.queue_base_url}/{self.base_app_id}/requests/{clean_id}"
        return f"{base}/status", base

    def _submit_inference(
        self,
        client: httpx.Client,
        job_id: uuid.UUID,
        arguments: Dict[str, Any],
    ) -> tuple[str, str, str]:
        submit_url = f"{self.queue_base_url}/{self.model_id}"
        response = self._request_with_error_handling(
            client,
            "POST",
            submit_url,
            stage="queue submit",
            headers={
                **self._auth_headers(),
                "Content-Type": "application/json",
            },
            json=arguments,
        )
        data = self._parse_json_object(response, stage="queue submit")
        request_id = str(data.get("request_id") or "").strip()
        if not request_id:
            raise PermanentAIProviderError(
                message="fal.ai queue submit response did not include a valid 'request_id'.",
                error_code=ErrorCode.AI_PROVIDER_ERROR.value,
                provider_name=self.PROVIDER_NAME,
            )

        default_status_url, default_response_url = self._build_queue_urls_for_request(
            request_id
        )
        status_url = str(data.get("status_url") or default_status_url).strip()
        response_url = str(data.get("response_url") or default_response_url).strip()

        logger.info(
            "FalAdapter submitted inference for job_id=%s (model=%s, request_id=%s)",
            job_id,
            self.model_id,
            request_id,
        )
        return request_id, status_url, response_url

    def _poll_until_completed(
        self,
        client: httpx.Client,
        job_id: uuid.UUID,
        request_id: str,
        status_url: str,
        response_url: str,
    ) -> str:
        deadline = self._clock() + self.poll_timeout_seconds
        current_response_url = response_url

        while True:
            status_resp = self._request_with_error_handling(
                client,
                "GET",
                status_url,
                stage="queue status poll",
                request_id=request_id,
                headers=self._auth_headers(),
            )
            status_data = self._parse_json_object(
                status_resp,
                stage="queue status poll",
                request_id=request_id,
            )
            raw_status = str(status_data.get("status") or "").strip().upper()
            if status_data.get("response_url"):
                current_response_url = str(status_data["response_url"]).strip()

            if raw_status in self._COMPLETED_QUEUE_STATUSES:
                logger.info(
                    "FalAdapter queue request completed for job_id=%s (request_id=%s)",
                    job_id,
                    request_id,
                )
                return current_response_url

            if raw_status in self._FAILED_QUEUE_STATUSES:
                err_detail = self._parse_queue_failure_detail(status_data, raw_status)
                raise PermanentAIProviderError(
                    message=f"fal.ai inference failed for request '{request_id}': {err_detail}",
                    error_code=ErrorCode.AI_PROVIDER_ERROR.value,
                    provider_name=self.PROVIDER_NAME,
                    provider_request_id=request_id,
                )

            if raw_status not in self._ACTIVE_QUEUE_STATUSES:
                raise PermanentAIProviderError(
                    message=(
                        f"fal.ai queue status returned unrecognized state "
                        f"'{raw_status or '<empty>'}' for request '{request_id}'."
                    ),
                    error_code=ErrorCode.AI_PROVIDER_ERROR.value,
                    provider_name=self.PROVIDER_NAME,
                    provider_request_id=request_id,
                )

            if self._clock() >= deadline:
                raise TransientAIProviderError(
                    message=(
                        f"fal.ai inference polling timed out after {self.poll_timeout_seconds}s "
                        f"(last status: '{raw_status}', request_id='{request_id}')."
                    ),
                    error_code=ErrorCode.AI_PROVIDER_TIMEOUT.value,
                    provider_name=self.PROVIDER_NAME,
                    provider_request_id=request_id,
                )

            if self.poll_interval_seconds > 0:
                self._sleep(self.poll_interval_seconds)

    @staticmethod
    def _parse_queue_failure_detail(status_data: Dict[str, Any], raw_status: str) -> str:
        """Extract sanitized failure description from fal.ai queue response payload."""
        err = status_data.get("error")
        if isinstance(err, dict):
            detail = err.get("message") or err.get("detail") or str(err)
            return str(detail).strip()
        if isinstance(err, str) and err.strip():
            return err.strip()

        detail_field = status_data.get("detail") or status_data.get("message")
        if detail_field:
            return str(detail_field).strip()

        logs = status_data.get("logs")
        if isinstance(logs, list) and logs:
            log_messages = []
            for item in logs:
                if isinstance(item, dict) and "message" in item:
                    log_messages.append(str(item["message"]))
                elif isinstance(item, str):
                    log_messages.append(item)
            if log_messages:
                return " | ".join(log_messages[-3:])

        return f"Queue status reported '{raw_status}'"

    @classmethod
    def extract_result_image_url(
        cls,
        payload: Dict[str, Any],
        request_id: Optional[str] = None,
    ) -> str:
        """
        Extract the generated image CDN URL from fal.ai result payload.
        Supports:
        - `{"image": {"url": "https://..."}}` (e.g., `fal-ai/cat-vton`, `fal-ai/idm-vton`)
        - `{"images": [{"url": "https://..."}]}` (e.g., `fal-ai/fashn/tryon/v1.6`)
        - Nested `{"data": {"image": ...}}` or `{"output": {"image": ...}}` envelopes
        """
        candidates: list[Dict[str, Any]] = [payload]
        for wrapper_key in ("data", "output", "result"):
            nested = payload.get(wrapper_key)
            if isinstance(nested, dict):
                candidates.append(nested)

        for container in candidates:
            image_field = container.get("image")
            if isinstance(image_field, dict):
                url = str(image_field.get("url") or "").strip()
                if url.startswith(("http://", "https://")):
                    return url
            elif isinstance(image_field, str) and image_field.strip().startswith(
                ("http://", "https://")
            ):
                return image_field.strip()

            images_field = container.get("images")
            if isinstance(images_field, list) and len(images_field) > 0:
                first_item = images_field[0]
                if isinstance(first_item, dict):
                    url = str(first_item.get("url") or "").strip()
                    if url.startswith(("http://", "https://")):
                        return url
                elif isinstance(first_item, str) and first_item.strip().startswith(
                    ("http://", "https://")
                ):
                    return first_item.strip()

        raise PermanentAIProviderError(
            message=(
                "fal.ai result payload does not contain a valid image URL "
                "in 'image.url' or 'images[0].url'."
            ),
            error_code=ErrorCode.AI_PROVIDER_ERROR.value,
            provider_name=cls.PROVIDER_NAME,
            provider_request_id=request_id,
        )

    def _fetch_result_image_url(
        self,
        client: httpx.Client,
        request_id: str,
        response_url: str,
    ) -> str:
        result_resp = self._request_with_error_handling(
            client,
            "GET",
            response_url,
            stage="queue result fetch",
            request_id=request_id,
            headers=self._auth_headers(),
        )
        result_payload = self._parse_json_object(
            result_resp,
            stage="queue result fetch",
            request_id=request_id,
        )
        return self.extract_result_image_url(result_payload, request_id=request_id)

    def _download_result_image(
        self,
        client: httpx.Client,
        job_id: uuid.UUID,
        request_id: str,
        result_url: str,
    ) -> ValidatedImage:
        """
        Download generated image bytes from `result_url` with bounded local retries
        so transient CDN glitches never trigger a duplicate paid AI inference (Scenario T08).
        """
        attempt = 0
        max_attempts = 1 + self.download_max_retries
        last_transient_error: Optional[TransientAIProviderError] = None

        while attempt < max_attempts:
            attempt += 1
            try:
                response = self._request_with_error_handling(
                    client,
                    "GET",
                    result_url,
                    stage="result image download",
                    request_id=request_id,
                )
                raw_bytes = response.content
                if not raw_bytes:
                    raise PermanentAIProviderError(
                        message="fal.ai result image download returned empty body.",
                        error_code=ErrorCode.AI_PROVIDER_ERROR.value,
                        provider_name=self.PROVIDER_NAME,
                        provider_request_id=request_id,
                    )

                try:
                    validated = self.validator.validate_bytes_sync(
                        raw_bytes,
                        field_name="fal_result_image",
                    )
                except ImageValidationError as exc:
                    raise PermanentAIProviderError(
                        message=f"Downloaded fal.ai result image failed validation: {exc.message}",
                        error_code=ErrorCode.AI_PROVIDER_ERROR.value,
                        provider_name=self.PROVIDER_NAME,
                        provider_request_id=request_id,
                    ) from exc

                logger.info(
                    "FalAdapter downloaded and validated result image for job_id=%s "
                    "(request_id=%s, format=%s, size=%dx%d, bytes=%d, attempt=%d/%d)",
                    job_id,
                    request_id,
                    validated.format,
                    validated.width,
                    validated.height,
                    len(validated.content),
                    attempt,
                    max_attempts,
                )
                return validated

            except TransientAIProviderError as exc:
                last_transient_error = exc
                if attempt < max_attempts:
                    backoff = self.download_retry_backoff_seconds * attempt
                    logger.warning(
                        "FalAdapter result download transient failure for job_id=%s "
                        "(request_id=%s, attempt=%d/%d): %s. Retrying download in %.1fs...",
                        job_id,
                        request_id,
                        attempt,
                        max_attempts,
                        exc.message,
                        backoff,
                    )
                    if backoff > 0:
                        self._sleep(backoff)
                    continue
                raise

        assert last_transient_error is not None
        raise last_transient_error

    def generate_try_on(
        self,
        job_id: uuid.UUID,
        person_image_bytes: bytes,
        garment_image_bytes: bytes,
        existing_request_id: Optional[str] = None,
        on_request_submitted: Optional[Callable[[str], None]] = None,
    ) -> AIProviderResult:
        """
        Execute virtual try-on via fal.ai or resume an existing fal.ai request ID.
        """
        self._require_api_key()
        callback = on_request_submitted or self._on_request_submitted
        cleaned_existing_id = (existing_request_id or "").strip()

        with self._client_context() as client:
            if cleaned_existing_id:
                request_id = cleaned_existing_id
                status_url, response_url = self._build_queue_urls_for_request(
                    request_id
                )
                logger.info(
                    "FalAdapter resuming existing request_id=%s for job_id=%s "
                    "(skipping upload and duplicate inference submission)",
                    request_id,
                    job_id,
                )
            else:
                validated_person = self._validate_input_bytes(
                    person_image_bytes, "person_image"
                )
                validated_garment = self._validate_input_bytes(
                    garment_image_bytes, "garment_image"
                )

                person_url = self._upload_single_image(
                    client, job_id, "person", validated_person
                )
                garment_url = self._upload_single_image(
                    client, job_id, "garment", validated_garment
                )

                arguments = self.build_model_arguments(
                    person_image_url=person_url,
                    garment_image_url=garment_url,
                )
                request_id, status_url, response_url = self._submit_inference(
                    client,
                    job_id=job_id,
                    arguments=arguments,
                )
                if callback is not None:
                    callback(request_id)

            final_response_url = self._poll_until_completed(
                client,
                job_id=job_id,
                request_id=request_id,
                status_url=status_url,
                response_url=response_url,
            )

            result_image_url = self._fetch_result_image_url(
                client,
                request_id=request_id,
                response_url=final_response_url,
            )

            validated_result = self._download_result_image(
                client,
                job_id=job_id,
                request_id=request_id,
                result_url=result_image_url,
            )

            return AIProviderResult(
                image_bytes=validated_result.content,
                provider_name=self.PROVIDER_NAME,
                provider_request_id=request_id,
                mime_type=validated_result.mime_type,
                extension=validated_result.extension,
            )

