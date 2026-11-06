from typing import Sequence, Tuple
import uuid
from app.core.errors import JobNotFoundError, ResultNotReadyError
from app.core.logging import logger
from app.models.try_on_job import JobStatus, TryOnJob
from app.repositories.history_repository import HistoryRepository
from app.services.image_service import ImageService


class HistoryService:
    """Application service for managing saved try-on results, history queries, and safe deletion."""

    def __init__(
        self,
        history_repository: HistoryRepository,
        image_service: ImageService,
    ) -> None:
        self.history_repository = history_repository
        self.image_service = image_service

    async def save_job(self, job_id: uuid.UUID) -> TryOnJob:
        """
        Mark a completed try-on job as saved using an atomic database update.
        - Guarantees race-condition-free idempotency.
        - Raises JobNotFoundError (404) if job does not exist.
        - Raises ResultNotReadyError (409) if job status is not 'succeeded'.
        """
        updated_job = await self.history_repository.mark_saved_atomic(job_id)
        if updated_job is not None:
            await self.history_repository.session.commit()
            await self.history_repository.session.refresh(updated_job)
            logger.info("Successfully marked job %s as saved in history.", job_id)
            return updated_job

        # Atomic update returned None -> inspect reason (not found vs invalid status)
        job = await self.history_repository.get_by_id(job_id)
        if job is None:
            raise JobNotFoundError(details={"job_id": str(job_id)})

        raise ResultNotReadyError(
            message=(
                f"Only completed (succeeded) try-on jobs can be saved. "
                f"Current status: '{job.status.value}'."
            ),
            details={"job_id": str(job_id), "status": job.status.value},
        )

    async def list_history(
        self,
        limit: int = 20,
        offset: int = 0,
    ) -> Tuple[Sequence[TryOnJob], int]:
        """Return paginated saved jobs and total count, ordered newest saved first."""
        items = await self.history_repository.list_saved_jobs(
            limit=limit, offset=offset
        )
        total = await self.history_repository.count_saved_jobs()
        return items, total

    async def get_history_detail(self, job_id: uuid.UUID) -> TryOnJob:
        """Retrieve a specific saved job from history or raise 404."""
        job = await self.history_repository.get_saved_by_id(job_id)
        if job is None:
            raise JobNotFoundError(
                message=f"History item '{job_id}' was not found in saved history.",
                details={"job_id": str(job_id)},
            )
        return job

    async def delete_history(self, job_id: uuid.UUID) -> None:
        """
        Delete a saved job from database and purge associated files on storage volume.
        If file deletion experiences partial issues, logs structured warning with job_id
        under event 'ORPHAN_STORAGE_DIR_DETECTED' for background reconciliation.
        """
        job = await self.history_repository.get_saved_by_id(job_id)
        if job is None:
            raise JobNotFoundError(
                message=f"Cannot delete: History item '{job_id}' was not found.",
                details={"job_id": str(job_id)},
            )

        # 1. Delete DB record first to prevent stale references
        await self.history_repository.delete_job(job_id)
        await self.history_repository.session.commit()

        # 2. Purge files on volume safely
        try:
            await self.image_service.delete_job_images(job_id)
        except Exception as exc:
            logger.warning(
                "ORPHAN_STORAGE_DIR_DETECTED: Database record for job_id=%s was deleted, "
                "but storage cleanup failed: %s. Volume Sweeper will reclaim this directory.",
                job_id,
                exc,
            )

