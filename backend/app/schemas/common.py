from typing import Any, Dict, Optional
from pydantic import BaseModel, Field


class ErrorResponse(BaseModel):
    """Standardized error payload returned by all API endpoints on failure."""

    error_code: str = Field(..., description="Machine-readable error code (e.g. MISSING_INPUT_IMAGE)")
    message: str = Field(..., description="Human-readable explanation of the error")
    details: Optional[Dict[str, Any]] = Field(
        default=None,
        description="Optional structured diagnostic details",
    )

