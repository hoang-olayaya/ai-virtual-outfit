from pathlib import Path
from typing import Tuple
import uuid
from app.core.errors import (
    AppError,
    ErrorCode,
    ImageNotFoundError,
    JobNotFoundError,
    ResultNotReadyError,
)
from app.models.try_on_job import JobStatus, TryOnJob
from app.repositories.job_repository import JobRepository
from app.services.image_service import ImageService


class JobService:
    """Application service for querying try-on job status, metadata, and result media."""

    def __init__(self, job_repository: JobRepository) -> None:
        self.job_repository = job_repository

    async def get_job(self, job_id: uuid.UUID) -> TryOnJob:
        """Retrieve a TryOnJob by UUID or raise JobNotFoundError (404)."""
        job = await self.job_repository.get_by_id(job_id)
        if job is None:
            raise JobNotFoundError(
                message=f"Try-on job '{job_id}' was not found.",
                details={"job_id": str(job_id)},
            )
        return job

    async def get_job_result_image(
        self,
        job_id: uuid.UUID,
        image_service: ImageService,
    ) -> Tuple[bytes, str]:
        """
        Retrieve the generated result image bytes and MIME type for a succeeded job.
        - Raises JobNotFoundError (404) if job does not exist.
        - Raises ResultNotReadyError (409) if job status is not 'succeeded'.
        - Raises ImageNotFoundError (404) if result_image_path is missing or file is absent on disk.
        """
        job = await self.get_job(job_id)

        if job.status != JobStatus.SUCCEEDED:
            raise ResultNotReadyError(
                message=(
                    f"Result image for job '{job_id}' is not available "
                    f"(current status: '{job.status.value}')."
                ),
                details={
                    "job_id": str(job_id),
                    "status": job.status.value,
                },
            )

        if not job.result_image_path:
            raise ImageNotFoundError(
                message=f"Result image path is not recorded for job '{job_id}'.",
                details={"job_id": str(job_id)},
            )

        return await image_service.read_image(job.result_image_path)

    async def get_job_result_file_path(
        self,
        job_id: uuid.UUID,
        image_service: ImageService,
    ) -> Tuple[Path, str]:
        """
        Resolve safe filesystem Path and MIME type for a succeeded job's result image.
        Enables streaming via FileResponse without reading entire file into RAM.
        """
        job = await self.get_job(job_id)

        if job.status != JobStatus.SUCCEEDED:
            raise ResultNotReadyError(
                message=(
                    f"Result image for job '{job_id}' is not available "
                    f"(current status: '{job.status.value}')."
                ),
                details={
                    "job_id": str(job_id),
                    "status": job.status.value,
                },
            )

        if not job.result_image_path:
            raise ImageNotFoundError(
                message=f"Result image path is not recorded for job '{job_id}'.",
                details={"job_id": str(job_id)},
            )

        safe_path = image_service.resolve_image_path(job.result_image_path)
        mime_type = image_service.detect_mime_type(job.result_image_path)
        return safe_path, mime_type

    async def get_job_input_file_path(
        self,
        job_id: uuid.UUID,
        kind: str,
        image_service: ImageService,
    ) -> Tuple[Path, str]:
        """
        Resolve safe filesystem Path and MIME type for an input image (person or garment).
        Enables streaming via FileResponse without reading entire file into RAM.
        """
        normalized_kind = kind.strip().lower()
        if normalized_kind not in ("person", "garment"):
            raise AppError(
                error_code=ErrorCode.INVALID_REQUEST,
                message=f"Invalid input kind '{kind}'. Must be 'person' or 'garment'.",
                status_code=400,
                details={"kind": kind, "allowed": ["person", "garment"]},
            )

        job = await self.get_job(job_id)
        rel_path = (
            job.person_image_path
            if normalized_kind == "person"
            else job.garment_image_path
        )
        if not rel_path:
            raise ImageNotFoundError(
                message=f"Input image path for '{kind}' is missing in job record.",
                details={"job_id": str(job_id), "kind": kind},
            )

        safe_path = image_service.resolve_image_path(rel_path)
        mime_type = image_service.detect_mime_type(rel_path)
        return safe_path, mime_type


