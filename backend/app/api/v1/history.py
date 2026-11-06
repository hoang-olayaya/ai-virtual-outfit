import uuid
from fastapi import APIRouter, Depends, Path, Query, status
from app.api.deps import get_history_service
from app.schemas.common import ErrorResponse
from app.schemas.history import HistoryItemResponse, HistoryListResponse
from app.schemas.job import JobResponse
from app.services.history_service import HistoryService

router = APIRouter(tags=["history"])


@router.post(
    "/try-ons/{job_id}/save",
    response_model=JobResponse,
    status_code=status.HTTP_200_OK,
    summary="Save a completed virtual try-on result to user history",
    responses={
        200: {
            "description": "Try-on result marked as saved in user history",
            "model": JobResponse,
        },
        404: {
            "description": "Try-on job ID does not exist",
            "model": ErrorResponse,
        },
        409: {
            "description": "Try-on job has not succeeded yet (cannot save failed or pending jobs)",
            "model": ErrorResponse,
        },
        422: {
            "description": "Invalid UUID format for job_id",
            "model": ErrorResponse,
        },
    },
)
async def save_try_on_job(
    job_id: uuid.UUID = Path(
        ..., description="Unique identifier (UUID) of the completed try-on job"
    ),
    history_service: HistoryService = Depends(get_history_service),
) -> JobResponse:
    """
    Mark a completed try-on job as saved in user history.
    Idempotent: calling multiple times returns the same saved job record.
    Rejects jobs with status other than 'succeeded' with HTTP 409 Conflict.
    """
    job = await history_service.save_job(job_id)
    return JobResponse.from_orm_job(job)


@router.get(
    "/history",
    response_model=HistoryListResponse,
    status_code=status.HTTP_200_OK,
    summary="List saved virtual try-on history items with pagination",
    responses={
        200: {
            "description": "Paginated list of saved try-on history items",
            "model": HistoryListResponse,
        },
        422: {
            "description": "Invalid query parameters (limit or offset)",
            "model": ErrorResponse,
        },
    },
)
async def list_history(
    limit: int = Query(
        default=20,
        ge=1,
        le=100,
        description="Number of history items to return per page (1-100)",
    ),
    offset: int = Query(
        default=0,
        ge=0,
        description="Page offset index",
    ),
    history_service: HistoryService = Depends(get_history_service),
) -> HistoryListResponse:
    """
    Retrieve saved virtual try-on items in reverse chronological order (newest saved first).
    Only includes jobs where is_saved is true.
    """
    items, total = await history_service.list_history(limit=limit, offset=offset)
    return HistoryListResponse(
        items=[HistoryItemResponse.from_orm_job(item) for item in items],
        total=total,
        limit=limit,
        offset=offset,
    )


@router.get(
    "/history/{job_id}",
    response_model=HistoryItemResponse,
    status_code=status.HTTP_200_OK,
    summary="Get saved virtual try-on history item details",
    responses={
        200: {
            "description": "Saved history item metadata and image URLs",
            "model": HistoryItemResponse,
        },
        404: {
            "description": "History item not found or has not been saved",
            "model": ErrorResponse,
        },
        422: {
            "description": "Invalid UUID format for job_id",
            "model": ErrorResponse,
        },
    },
)
async def get_history_detail(
    job_id: uuid.UUID = Path(
        ..., description="Unique identifier (UUID) of the saved try-on job"
    ),
    history_service: HistoryService = Depends(get_history_service),
) -> HistoryItemResponse:
    """
    Retrieve full details for a single saved try-on job, including URLs for
    the person input photo, garment input photo, and generated outfit result image.
    """
    job = await history_service.get_history_detail(job_id)
    return HistoryItemResponse.from_orm_job(job)


@router.delete(
    "/history/{job_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Delete a saved try-on item from history and clean up files",
    responses={
        204: {
            "description": "History item record and stored images successfully deleted",
        },
        404: {
            "description": "History item not found or has not been saved",
            "model": ErrorResponse,
        },
        422: {
            "description": "Invalid UUID format for job_id",
            "model": ErrorResponse,
        },
    },
)
async def delete_history_item(
    job_id: uuid.UUID = Path(
        ..., description="Unique identifier (UUID) of the saved try-on job to delete"
    ),
    history_service: HistoryService = Depends(get_history_service),
) -> None:
    """
    Delete a saved virtual try-on result from history and purge its associated input
    and output image files on shared volume storage.
    """
    await history_service.delete_history(job_id)

