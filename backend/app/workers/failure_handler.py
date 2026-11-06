from dataclasses import dataclass
from typing import Optional
import uuid
from app.core.config import settings
from app.core.errors import AppError, ErrorCode, ImageNotFoundError, ImageValidationError
from app.core.logging import SecretMaskingFilter, logger
from app.integrations.ai_provider import AIProviderException
from app.models.try_on_job import TryOnJob
from app.repositories.job_repository import JobRepository


def scrub_secrets(message: str) -> str:
    """Mask any sensitive API keys or tokens from exception/error messages."""
    return SecretMaskingFilter.mask_text(message)


@dataclass(frozen=True)
class FailureDecision:
    """Result of FailureHandler error classification and DB update."""

    should_retry: bool
    error_code: str
    error_message: str
    retry_count: int
    job: Optional[TryOnJob] = None


class FailureHandler:
    """
    Classifies exceptions during worker execution into retryable vs. terminal failures,
    enforces bounded retry limits, and records failure metadata in PostgreSQL.
    """

    def __init__(
        self,
        job_repository: JobRepository,
        max_retries: Optional[int] = None,
    ) -> None:
        self.job_repository = job_repository
        self.max_retries = (
            settings.WORKER_MAX_RETRIES
            if max_retries is None
            else max(0, int(max_retries))
        )

    @staticmethod
    def classify_exception(exc: Exception) -> tuple[str, str, bool]:
        """
        Return (error_code, error_message, is_retryable) for an exception.
        """
        if isinstance(exc, AIProviderException):
            return (
                exc.error_code or ErrorCode.AI_PROVIDER_ERROR.value,
                exc.message or str(exc),
                bool(exc.retryable),
            )

        if isinstance(exc, (ImageNotFoundError, ImageValidationError)):
            return (
                exc.error_code.value,
                exc.message,
                False,
            )

        if isinstance(exc, AppError):
            retryable = exc.status_code >= 500
            return (
                exc.error_code.value,
                exc.message,
                retryable,
            )

        if isinstance(exc, (TimeoutError, ConnectionError)):
            return (
                ErrorCode.AI_PROVIDER_TIMEOUT.value,
                str(exc) or "Operation timed out during try-on execution.",
                True,
            )

        return (
            ErrorCode.WORKER_EXECUTION_ERROR.value,
            str(exc) or "Unexpected error during background try-on processing.",
            False,
        )

    async def handle_failure(
        self,
        job_id: uuid.UUID,
        exc: Exception,
        current_retry_count: Optional[int] = None,
    ) -> FailureDecision:
        """
        Evaluate whether the job should be retried or marked as terminal 'failed',
        and persist the state update in PostgreSQL.
        """
        error_code, raw_error_message, is_retryable = self.classify_exception(exc)
        error_message = scrub_secrets(raw_error_message)

        provider_name = None
        provider_request_id = None
        if isinstance(exc, AIProviderException):
            provider_name = exc.provider_name
            provider_request_id = exc.provider_request_id

        if current_retry_count is None:
            existing_job = await self.job_repository.get_by_id(job_id)
            current_retries = existing_job.retry_count if existing_job else 0
        else:
            current_retries = current_retry_count

        can_retry = is_retryable and (current_retries < self.max_retries)
        terminal = not can_retry
        increment_retry = can_retry

        updated_job = await self.job_repository.mark_failed(
            job_id=job_id,
            error_code=error_code,
            error_message=error_message,
            increment_retry=increment_retry,
            terminal=terminal,
            provider_name=provider_name,
            provider_request_id=provider_request_id,
        )
        await self.job_repository.session.commit()

        new_retry_count = (
            updated_job.retry_count
            if updated_job is not None
            else (current_retries + (1 if increment_retry else 0))
        )

        if can_retry:
            logger.warning(
                "FailureHandler scheduled retry for job_id=%s (retry=%d/%d, code=%s): %s",
                job_id,
                new_retry_count,
                self.max_retries,
                error_code,
                error_message,
            )
        else:
            logger.error(
                "FailureHandler marked job_id=%s as terminal FAILED (retries=%d/%d, code=%s): %s",
                job_id,
                new_retry_count,
                self.max_retries,
                error_code,
                error_message,
            )

        return FailureDecision(
            should_retry=can_retry,
            error_code=error_code,
            error_message=error_message,
            retry_count=new_retry_count,
            job=updated_job,
        )

