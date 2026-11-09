import enum
from typing import Any, Dict, Optional
from fastapi import FastAPI, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from app.core.logging import logger


class ErrorCode(str, enum.Enum):
    """Standardized application error codes for API responses and job tracking."""

    # Request & Parameter Validation Errors (4xx)
    INVALID_REQUEST = "INVALID_REQUEST"
    INVALID_IDEMPOTENCY_KEY = "INVALID_IDEMPOTENCY_KEY"

    # Input & Image Validation Errors (4xx)
    MISSING_INPUT_IMAGE = "MISSING_INPUT_IMAGE"
    FILE_TOO_LARGE = "FILE_TOO_LARGE"
    UNSUPPORTED_MEDIA_TYPE = "UNSUPPORTED_MEDIA_TYPE"
    CORRUPTED_IMAGE = "CORRUPTED_IMAGE"
    INVALID_IMAGE_DIMENSIONS = "INVALID_IMAGE_DIMENSIONS"

    # Resource Lookup & State Conflict Errors (404 / 409)
    JOB_NOT_FOUND = "JOB_NOT_FOUND"
    IMAGE_NOT_FOUND = "IMAGE_NOT_FOUND"
    RESULT_NOT_READY = "RESULT_NOT_READY"

    # Storage, Database, Queue & Worker Infrastructure Errors
    STORAGE_PATH_TRAVERSAL = "STORAGE_PATH_TRAVERSAL"
    STORAGE_UNAVAILABLE = "STORAGE_UNAVAILABLE"
    DATABASE_ERROR = "DATABASE_ERROR"
    QUEUE_PUBLISH_ERROR = "QUEUE_PUBLISH_ERROR"
    AI_PROVIDER_ERROR = "AI_PROVIDER_ERROR"
    AI_PROVIDER_TIMEOUT = "AI_PROVIDER_TIMEOUT"
    AI_PROVIDER_SUBMIT_INDETERMINATE = "AI_PROVIDER_SUBMIT_INDETERMINATE"
    WORKER_EXECUTION_ERROR = "WORKER_EXECUTION_ERROR"
    STALE_JOB_TIMEOUT = "STALE_JOB_TIMEOUT"
    RECONCILIATION_ABORTED = "RECONCILIATION_ABORTED"


class AppError(Exception):
    """Base application exception carrying structured error code and HTTP status."""

    def __init__(
        self,
        error_code: ErrorCode,
        message: str,
        status_code: int = 400,
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        super().__init__(message)
        self.error_code = error_code
        self.message = message
        self.status_code = status_code
        self.details = details or {}

    def to_dict(self) -> Dict[str, Any]:
        payload: Dict[str, Any] = {
            "error_code": self.error_code.value,
            "message": self.message,
        }
        if self.details:
            payload["details"] = self.details
        return payload


class ImageValidationError(AppError):
    """Raised when uploaded image fails validation (missing, size, MIME, decode, dimensions)."""

    def __init__(
        self,
        error_code: ErrorCode,
        message: str,
        status_code: int = 400,
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        super().__init__(
            error_code=error_code,
            message=message,
            status_code=status_code,
            details=details,
        )


class InvalidIdempotencyKeyError(AppError):
    """Raised when the provided Idempotency-Key header is invalid (e.g. exceeds length limit)."""

    def __init__(
        self,
        message: str = "Idempotency-Key header must not exceed 255 characters.",
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        super().__init__(
            error_code=ErrorCode.INVALID_IDEMPOTENCY_KEY,
            message=message,
            status_code=status.HTTP_400_BAD_REQUEST,
            details=details,
        )


class JobNotFoundError(AppError):
    """Raised when a requested TryOnJob ID does not exist in PostgreSQL."""

    def __init__(
        self,
        message: str = "Requested try-on job was not found.",
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        super().__init__(
            error_code=ErrorCode.JOB_NOT_FOUND,
            message=message,
            status_code=status.HTTP_404_NOT_FOUND,
            details=details,
        )


class ResultNotReadyError(AppError):
    """Raised when requesting the result image of a try-on job that has not succeeded yet."""

    def __init__(
        self,
        message: str = "Result image is not available because the try-on job has not succeeded.",
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        super().__init__(
            error_code=ErrorCode.RESULT_NOT_READY,
            message=message,
            status_code=status.HTTP_409_CONFLICT,
            details=details,
        )


class AIProviderError(AppError):
    """Raised when an AI provider fails to generate a try-on result."""

    def __init__(
        self,
        error_code: ErrorCode = ErrorCode.AI_PROVIDER_ERROR,
        message: str = "AI provider failed to generate virtual try-on image.",
        status_code: int = status.HTTP_502_BAD_GATEWAY,
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        super().__init__(
            error_code=error_code,
            message=message,
            status_code=status_code,
            details=details,
        )


class StorageError(AppError):
    """Raised when file storage operations fail."""

    def __init__(
        self,
        error_code: ErrorCode = ErrorCode.STORAGE_UNAVAILABLE,
        message: str = "Storage service is unavailable or encountered an I/O error.",
        status_code: int = 503,
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        super().__init__(
            error_code=error_code,
            message=message,
            status_code=status_code,
            details=details,
        )


class PathTraversalError(StorageError):
    """Raised when a relative path attempts to escape the storage root directory."""

    def __init__(
        self,
        message: str = "Invalid or unsafe storage path.",
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        super().__init__(
            error_code=ErrorCode.STORAGE_PATH_TRAVERSAL,
            message=message,
            status_code=400,
            details=details,
        )


class ImageNotFoundError(StorageError):
    """Raised when a requested image file does not exist in storage."""

    def __init__(
        self,
        message: str = "Requested image file was not found.",
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        super().__init__(
            error_code=ErrorCode.IMAGE_NOT_FOUND,
            message=message,
            status_code=404,
            details=details,
        )


class DatabaseOperationError(AppError):
    """Raised when a database persistence operation fails unexpectedly."""

    def __init__(
        self,
        message: str = "Database operation failed while processing the request.",
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        super().__init__(
            error_code=ErrorCode.DATABASE_ERROR,
            message=message,
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            details=details,
        )


class QueuePublishError(AppError):
    """Raised when publishing a try-on job task to the message broker fails."""

    def __init__(
        self,
        message: str = "Failed to enqueue try-on job for background processing.",
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        super().__init__(
            error_code=ErrorCode.QUEUE_PUBLISH_ERROR,
            message=message,
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            details=details,
        )


def register_exception_handlers(app: FastAPI) -> None:
    """Register global exception handlers so all API errors follow the standard contract."""

    @app.exception_handler(AppError)
    async def handle_app_error(request: Request, exc: AppError) -> JSONResponse:
        if exc.status_code >= 500:
            logger.error(
                "AppError [%s] on %s %s: %s (details=%s)",
                exc.error_code.value,
                request.method,
                request.url.path,
                exc.message,
                exc.details,
            )
        else:
            logger.warning(
                "Client AppError [%s] on %s %s: %s",
                exc.error_code.value,
                request.method,
                request.url.path,
                exc.message,
            )
        return JSONResponse(
            status_code=exc.status_code,
            content=exc.to_dict(),
        )

    @app.exception_handler(RequestValidationError)
    async def handle_request_validation_error(
        request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        sanitized_errors = []
        for err in exc.errors():
            sanitized_errors.append(
                {
                    "loc": [str(item) for item in err.get("loc", [])],
                    "msg": err.get("msg", "Invalid value"),
                    "type": err.get("type", "value_error"),
                }
            )
        return JSONResponse(
            status_code=422,
            content={
                "error_code": ErrorCode.INVALID_REQUEST.value,
                "message": "Request parameters failed validation.",
                "details": {"errors": sanitized_errors},
            },
        )
