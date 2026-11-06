from datetime import datetime
from typing import List, Optional
import uuid
from pydantic import BaseModel, ConfigDict, Field
from app.core.config import settings
from app.models.try_on_job import JobStatus, TryOnJob


class HistoryItemResponse(BaseModel):
    """DTO representing a single saved virtual try-on result in user history."""

    model_config = ConfigDict(from_attributes=True)

    job_id: uuid.UUID = Field(..., description="Unique identifier of the try-on job")
    status: JobStatus = Field(
        ...,
        description="Job execution status (always succeeded for saved history)",
    )
    person_image_url: str = Field(
        ..., description="Endpoint URL to fetch the user input photo"
    )
    garment_image_url: str = Field(
        ..., description="Endpoint URL to fetch the garment input photo"
    )
    result_image_url: str = Field(
        ..., description="Endpoint URL to fetch the generated outfit result image"
    )
    is_saved: bool = Field(default=True, description="Whether the job is saved in history")
    saved_at: Optional[datetime] = Field(
        default=None, description="Timestamp when the result was saved"
    )
    created_at: datetime = Field(..., description="Timestamp when the job was created")
    completed_at: Optional[datetime] = Field(
        default=None, description="Timestamp when the job completed"
    )

    @classmethod
    def from_orm_job(
        cls,
        job: TryOnJob,
        api_v1_prefix: Optional[str] = None,
    ) -> "HistoryItemResponse":
        prefix = (
            api_v1_prefix if api_v1_prefix is not None else settings.API_V1_STR
        ).rstrip("/")
        return cls(
            job_id=job.id,
            status=job.status,
            person_image_url=f"{prefix}/try-ons/{job.id}/inputs/person",
            garment_image_url=f"{prefix}/try-ons/{job.id}/inputs/garment",
            result_image_url=f"{prefix}/try-ons/{job.id}/image",
            is_saved=bool(job.is_saved),
            saved_at=job.saved_at,
            created_at=job.created_at,
            completed_at=job.completed_at,
        )


class HistoryListResponse(BaseModel):
    """Paginated collection of saved history items."""

    items: List[HistoryItemResponse] = Field(
        ..., description="List of saved try-on jobs in current page"
    )
    total: int = Field(..., description="Total count of saved jobs across all pages")
    limit: int = Field(..., description="Page limit applied")
    offset: int = Field(..., description="Page offset applied")

