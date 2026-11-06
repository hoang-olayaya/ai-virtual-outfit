from datetime import datetime
from typing import Optional
import uuid
from pydantic import BaseModel, ConfigDict, Field
from app.core.config import settings
from app.models.try_on_job import JobStatus, TryOnJob


class JobErrorDetail(BaseModel):
    """Structured error information attached to a failed or retried job."""

    error_code: str = Field(..., description="Error code recorded during job execution or enqueue")
    message: str = Field(..., description="Human-readable failure description")


class JobResponse(BaseModel):
    """
    Unified DTO returned by both POST /api/v1/try-ons (202 Accepted)
    and GET /api/v1/try-ons/{job_id} (200 OK).
    """

    model_config = ConfigDict(from_attributes=True)

    job_id: uuid.UUID = Field(..., description="Unique identifier of the try-on job")
    status: JobStatus = Field(..., description="Current lifecycle status (queued, processing, succeeded, failed)")
    result_image_url: Optional[str] = Field(
        default=None,
        description="Relative API endpoint to fetch the generated outfit image when status is 'succeeded'",
    )
    person_image_url: Optional[str] = Field(
        default=None,
        description="Relative API endpoint to fetch the person photo input image",
    )
    garment_image_url: Optional[str] = Field(
        default=None,
        description="Relative API endpoint to fetch the garment photo input image",
    )
    error: Optional[JobErrorDetail] = Field(
        default=None,
        description="Error details if the job encountered an error or failed",
    )
    is_saved: bool = Field(default=False, description="Whether the job is saved to user history")
    saved_at: Optional[datetime] = Field(default=None, description="Timestamp when the job was saved")
    created_at: datetime = Field(..., description="Timestamp when the job was created")
    updated_at: datetime = Field(..., description="Timestamp when the job was last updated")
    completed_at: Optional[datetime] = Field(
        default=None,
        description="Timestamp when the job reached a terminal state (succeeded or failed)",
    )

    @classmethod
    def from_orm_job(
        cls,
        job: TryOnJob,
        api_v1_prefix: Optional[str] = None,
    ) -> "JobResponse":
        prefix = (api_v1_prefix if api_v1_prefix is not None else settings.API_V1_STR).rstrip("/")
        result_url: Optional[str] = None
        if job.status == JobStatus.SUCCEEDED and job.result_image_path:
            result_url = f"{prefix}/try-ons/{job.id}/image"

        person_url: Optional[str] = (
            f"{prefix}/try-ons/{job.id}/inputs/person" if job.person_image_path else None
        )
        garment_url: Optional[str] = (
            f"{prefix}/try-ons/{job.id}/inputs/garment" if job.garment_image_path else None
        )

        error_detail: Optional[JobErrorDetail] = None
        if job.error_code:
            error_detail = JobErrorDetail(
                error_code=job.error_code,
                message=job.error_message or "Job failed with an unspecified error.",
            )

        return cls(
            job_id=job.id,
            status=job.status,
            result_image_url=result_url,
            person_image_url=person_url,
            garment_image_url=garment_url,
            error=error_detail,
            is_saved=bool(job.is_saved),
            saved_at=job.saved_at,
            created_at=job.created_at,
            updated_at=job.updated_at,
            completed_at=job.completed_at,
        )

