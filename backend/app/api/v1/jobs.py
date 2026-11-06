import uuid
from fastapi import APIRouter, Depends, Path, status
from app.api.deps import get_job_service
from app.schemas.common import ErrorResponse
from app.schemas.job import JobResponse
from app.services.job_service import JobService

router = APIRouter(prefix="/try-ons", tags=["jobs"])


@router.get(
    "/{job_id}",
    response_model=JobResponse,
    status_code=status.HTTP_200_OK,
    summary="Get virtual try-on job status and metadata",
    responses={
        status.HTTP_200_OK: {
            "description": "Current status and metadata of the try-on job",
            "model": JobResponse,
        },
        status.HTTP_404_NOT_FOUND: {
            "description": "Try-on job ID does not exist",
            "model": ErrorResponse,
        },
        422: {
            "description": "Invalid UUID format for job_id",
            "model": ErrorResponse,
        },
    },
)
async def get_try_on_job_status(
    job_id: uuid.UUID = Path(..., description="Unique identifier (UUID) of the try-on job"),
    job_service: JobService = Depends(get_job_service),
) -> JobResponse:
    """
    Retrieve the current status (`queued`, `processing`, `succeeded`, or `failed`),
    timestamps, error details, and result image URL (when succeeded) for a try-on job.
    """
    job = await job_service.get_job(job_id)
    return JobResponse.from_orm_job(job)

