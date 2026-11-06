from dataclasses import dataclass
from typing import Callable, Optional, Protocol, runtime_checkable
import uuid
from app.core.errors import ErrorCode


@dataclass(frozen=True)
class AIProviderResult:
    """
    Immutable value object encapsulating the output of an AI Virtual Try-On provider.
    """

    image_bytes: bytes
    provider_name: str
    provider_request_id: str
    mime_type: str = "image/jpeg"
    extension: str = ".jpg"


class AIProviderException(Exception):
    """
    Base exception raised by AI provider adapters.
    Carries retryable classification so Worker FailureHandler can decide
    whether to schedule a bounded retry or transition the job to terminal failed.
    """

    def __init__(
        self,
        message: str,
        error_code: str = ErrorCode.AI_PROVIDER_ERROR.value,
        retryable: bool = False,
        provider_name: Optional[str] = None,
        provider_request_id: Optional[str] = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.error_code = error_code
        self.retryable = retryable
        self.provider_name = provider_name
        self.provider_request_id = provider_request_id


class TransientAIProviderError(AIProviderException):
    """
    Retryable error from an AI provider (e.g., network timeout, HTTP 429/502/503).
    """

    def __init__(
        self,
        message: str = "Temporary error communicating with AI provider.",
        error_code: str = ErrorCode.AI_PROVIDER_ERROR.value,
        provider_name: Optional[str] = None,
        provider_request_id: Optional[str] = None,
    ) -> None:
        super().__init__(
            message=message,
            error_code=error_code,
            retryable=True,
            provider_name=provider_name,
            provider_request_id=provider_request_id,
        )


class PermanentAIProviderError(AIProviderException):
    """
    Non-retryable error from an AI provider (e.g., invalid input image, rejected payload, auth failure).
    """

    def __init__(
        self,
        message: str = "Permanent AI provider error while generating try-on result.",
        error_code: str = ErrorCode.AI_PROVIDER_ERROR.value,
        provider_name: Optional[str] = None,
        provider_request_id: Optional[str] = None,
    ) -> None:
        super().__init__(
            message=message,
            error_code=error_code,
            retryable=False,
            provider_name=provider_name,
            provider_request_id=provider_request_id,
        )


@runtime_checkable
class AIProvider(Protocol):
    """
    Protocol for AI Virtual Try-On inference providers (FakeAIProvider in B04, FalAdapter in B05/B06).
    """

    def generate_try_on(
        self,
        job_id: uuid.UUID,
        person_image_bytes: bytes,
        garment_image_bytes: bytes,
        existing_request_id: Optional[str] = None,
        on_request_submitted: Optional[Callable[[str], None]] = None,
    ) -> AIProviderResult:
        """
        Execute virtual try-on inference using person and garment input image bytes,
        returning the generated result image bytes and provider tracking metadata.
        """
        ...

