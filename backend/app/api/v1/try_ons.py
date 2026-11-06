from typing import Optional
from fastapi import APIRouter, Depends, File, Header, UploadFile, status
from app.api.deps import get_try_on_service
from app.schemas.common import ErrorResponse
from app.schemas.job import JobResponse
from app.services.try_on_service import TryOnService

router = APIRouter(prefix="/try-ons", tags=["try-ons"])


@router.post(
    "",
    response_model=JobResponse,
    status_code=status.HTTP_202_ACCEPTED,
    summary="Create a new virtual try-on job",
    responses={
        status.HTTP_202_ACCEPTED: {
            "description": "Try-on job accepted and queued for background processing",
            "model": JobResponse,
        },
        status.HTTP_400_BAD_REQUEST: {
            "description": "Missing input image, corrupted image, invalid dimensions, or invalid Idempotency-Key",
            "model": ErrorResponse,
        },
        413: {
            "description": "Uploaded image exceeds maximum file size limit",
            "model": ErrorResponse,
        },
        status.HTTP_415_UNSUPPORTED_MEDIA_TYPE: {
            "description": "Uploaded file is not a supported image format (JPEG, PNG, WEBP)",
            "model": ErrorResponse,
        },
        status.HTTP_503_SERVICE_UNAVAILABLE: {
            "description": "Storage, database, or message queue temporarily unavailable",
            "model": ErrorResponse,
        },
    },
)
async def create_try_on_job(
    person_image: Optional[UploadFile] = File(
        default=None,
        description="User photo (JPEG, PNG, or WEBP)",
    ),
    garment_image: Optional[UploadFile] = File(
        default=None,
        description="Garment photo (JPEG, PNG, or WEBP)",
    ),
    idempotency_key: Optional[str] = Header(
        default=None,
        alias="Idempotency-Key",
        description="Optional client-generated idempotency key (max 255 characters) to prevent duplicate jobs",
    ),
    try_on_service: TryOnService = Depends(get_try_on_service),
) -> JobResponse:
    """
    Accept two uploaded images (`person_image` and `garment_image`), validate and persist them
    to shared storage, create a `queued` job in PostgreSQL, publish `job_id` to the task queue,
    and return HTTP 202 Accepted with the job status payload.
    """
    job = await try_on_service.create_try_on_job(
        person_image=person_image,
        garment_image=garment_image,
        idempotency_key=idempotency_key,
    )
    return JobResponse.from_orm_job(job)

