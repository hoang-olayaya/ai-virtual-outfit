import uuid
from fastapi import APIRouter, Depends, Path, status
from fastapi.responses import FileResponse
from app.api.deps import get_image_service, get_job_service
from app.schemas.common import ErrorResponse
from app.services.image_service import ImageService
from app.services.job_service import JobService

router = APIRouter(prefix="/try-ons", tags=["media"])

_PRIVATE_CACHE_HEADERS = {"Cache-Control": "private, no-cache, no-store, must-revalidate"}


@router.get(
    "/{job_id}/image",
    status_code=status.HTTP_200_OK,
    response_class=FileResponse,
    summary="Download the generated virtual try-on result image",
    responses={
        status.HTTP_200_OK: {
            "description": "Binary image stream of the generated try-on result",
            "content": {
                "image/jpeg": {"schema": {"type": "string", "format": "binary"}},
                "image/png": {"schema": {"type": "string", "format": "binary"}},
                "image/webp": {"schema": {"type": "string", "format": "binary"}},
            },
        },
        status.HTTP_404_NOT_FOUND: {
            "description": "Try-on job ID or result image file does not exist",
            "model": ErrorResponse,
        },
        status.HTTP_409_CONFLICT: {
            "description": "Try-on job has not succeeded yet (still queued, processing, or failed)",
            "model": ErrorResponse,
        },
        422: {
            "description": "Invalid UUID format for job_id",
            "model": ErrorResponse,
        },
    },
)
async def get_try_on_result_image(
    job_id: uuid.UUID = Path(
        ..., description="Unique identifier (UUID) of the try-on job"
    ),
    job_service: JobService = Depends(get_job_service),
    image_service: ImageService = Depends(get_image_service),
) -> FileResponse:
    """
    Stream the binary result image for a completed (`succeeded`) try-on job.
    Uses FileResponse for chunked transfer without loading full bytes into RAM.
    """
    file_path, mime_type = await job_service.get_job_result_file_path(
        job_id=job_id,
        image_service=image_service,
    )
    return FileResponse(
        path=file_path,
        media_type=mime_type,
        headers=_PRIVATE_CACHE_HEADERS,
    )


@router.get(
    "/{job_id}/inputs/{kind}",
    status_code=status.HTTP_200_OK,
    response_class=FileResponse,
    summary="Download user or garment input photo for a try-on job",
    responses={
        status.HTTP_200_OK: {
            "description": "Binary image stream of the person or garment input photo",
            "content": {
                "image/jpeg": {"schema": {"type": "string", "format": "binary"}},
                "image/png": {"schema": {"type": "string", "format": "binary"}},
                "image/webp": {"schema": {"type": "string", "format": "binary"}},
            },
        },
        status.HTTP_400_BAD_REQUEST: {
            "description": "Invalid input kind (must be 'person' or 'garment')",
            "model": ErrorResponse,
        },
        status.HTTP_404_NOT_FOUND: {
            "description": "Try-on job ID or input image file does not exist",
            "model": ErrorResponse,
        },
        422: {
            "description": "Invalid UUID format for job_id",
            "model": ErrorResponse,
        },
    },
)
async def get_try_on_input_image(
    job_id: uuid.UUID = Path(
        ..., description="Unique identifier (UUID) of the try-on job"
    ),
    kind: str = Path(..., description="Input image kind: 'person' or 'garment'"),
    job_service: JobService = Depends(get_job_service),
    image_service: ImageService = Depends(get_image_service),
) -> FileResponse:
    """
    Stream the person or garment input photo for a try-on job.
    Enables Before/After comparison in History and Detail screens.
    """
    file_path, mime_type = await job_service.get_job_input_file_path(
        job_id=job_id,
        kind=kind,
        image_service=image_service,
    )
    return FileResponse(
        path=file_path,
        media_type=mime_type,
        headers=_PRIVATE_CACHE_HEADERS,
    )
