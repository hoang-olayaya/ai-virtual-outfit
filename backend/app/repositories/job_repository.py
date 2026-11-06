from datetime import datetime, timezone
from typing import List, Optional, Sequence
import uuid
from sqlalchemy import delete, func, select, update
from sqlalchemy.ext.asyncio import AsyncSession
from app.models.try_on_job import JobStatus, TryOnJob


class JobRepository:
    """Repository handling all database operations for TryOnJob."""

    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def create_job(
        self,
        person_image_path: str,
        garment_image_path: str,
        idempotency_key: Optional[str] = None,
        job_id: Optional[uuid.UUID] = None,
    ) -> TryOnJob:
        """Create and persist a new TryOnJob in queued state."""
        job = TryOnJob(
            id=job_id or uuid.uuid4(),
            idempotency_key=idempotency_key,
            status=JobStatus.QUEUED,
            person_image_path=person_image_path,
            garment_image_path=garment_image_path,
        )
        self.session.add(job)
        await self.session.flush()
        return job

    async def get_by_id(self, job_id: uuid.UUID) -> Optional[TryOnJob]:
        """Find a job by its unique identifier."""
        stmt = select(TryOnJob).where(TryOnJob.id == job_id)
        result = await self.session.execute(stmt)
        return result.scalar_one_or_none()

    async def get_by_idempotency_key(self, idempotency_key: str) -> Optional[TryOnJob]:
        """Find a job by its idempotency key."""
        stmt = select(TryOnJob).where(TryOnJob.idempotency_key == idempotency_key)
        result = await self.session.execute(stmt)
        return result.scalar_one_or_none()

    async def claim_job(self, job_id: uuid.UUID) -> Optional[TryOnJob]:
        """
        Atomically transition job from 'queued' to 'processing'.
        Returns the claimed TryOnJob, or None if the job was not in 'queued' state
        (e.g., already claimed by another worker or completed).
        """
        stmt = (
            update(TryOnJob)
            .where(TryOnJob.id == job_id, TryOnJob.status == JobStatus.QUEUED)
            .values(status=JobStatus.PROCESSING, updated_at=func.now())
            .returning(TryOnJob)
        )
        result = await self.session.execute(stmt)
        claimed_job = result.scalar_one_or_none()
        return claimed_job

    async def claim_resume_job(self, job_id: uuid.UUID) -> Optional[TryOnJob]:
        """
        Atomically acquire execution lease on an in-progress job for controlled retry.
        Guarantees only one worker process can resume execution of a job in 'processing' status.
        """
        stmt = (
            update(TryOnJob)
            .where(TryOnJob.id == job_id, TryOnJob.status == JobStatus.PROCESSING)
            .values(updated_at=func.now())
            .returning(TryOnJob)
        )
        result = await self.session.execute(stmt)
        return result.scalar_one_or_none()

    async def update_provider_tracking(
        self,
        job_id: uuid.UUID,
        provider_name: str,
        provider_request_id: str,
    ) -> Optional[TryOnJob]:
        """Record external AI provider name and request identifier for recovery tracking."""
        stmt = (
            update(TryOnJob)
            .where(TryOnJob.id == job_id)
            .values(
                provider_name=provider_name,
                provider_request_id=provider_request_id,
                updated_at=func.now(),
            )
            .returning(TryOnJob)
        )
        result = await self.session.execute(stmt)
        return result.scalar_one_or_none()

    async def mark_succeeded(
        self,
        job_id: uuid.UUID,
        result_image_path: str,
    ) -> Optional[TryOnJob]:
        """Transition job to 'succeeded' and record the output image path."""
        stmt = (
            update(TryOnJob)
            .where(TryOnJob.id == job_id)
            .values(
                status=JobStatus.SUCCEEDED,
                result_image_path=result_image_path,
                completed_at=func.now(),
                updated_at=func.now(),
            )
            .returning(TryOnJob)
        )
        result = await self.session.execute(stmt)
        return result.scalar_one_or_none()

    async def mark_failed(
        self,
        job_id: uuid.UUID,
        error_code: str,
        error_message: str,
        increment_retry: bool = False,
        terminal: bool = True,
        provider_name: Optional[str] = None,
        provider_request_id: Optional[str] = None,
    ) -> Optional[TryOnJob]:
        """Record failure details, optionally incrementing retry count or marking status as terminal failed."""
        values = {
            "error_code": error_code,
            "error_message": error_message,
            "updated_at": func.now(),
        }
        if terminal:
            values["status"] = JobStatus.FAILED
            values["completed_at"] = func.now()

        if increment_retry:
            values["retry_count"] = TryOnJob.retry_count + 1

        if provider_name is not None:
            values["provider_name"] = provider_name
        if provider_request_id is not None:
            values["provider_request_id"] = provider_request_id

        stmt = update(TryOnJob).where(TryOnJob.id == job_id).values(**values).returning(TryOnJob)
        result = await self.session.execute(stmt)
        return result.scalar_one_or_none()

    async def mark_saved_atomic(
        self,
        job_id: uuid.UUID,
    ) -> Optional[TryOnJob]:
        """
        Atomically flag a succeeded job as saved without race conditions.
        Preserves existing saved_at via COALESCE.
        """
        stmt = (
            update(TryOnJob)
            .where(TryOnJob.id == job_id, TryOnJob.status == JobStatus.SUCCEEDED)
            .values(
                is_saved=True,
                saved_at=func.coalesce(TryOnJob.saved_at, func.now()),
                updated_at=func.now(),
            )
            .returning(TryOnJob)
        )
        result = await self.session.execute(stmt)
        return result.scalar_one_or_none()

    async def mark_saved(
        self,
        job_id: uuid.UUID,
        is_saved: bool = True,
    ) -> Optional[TryOnJob]:
        """
        Flag a succeeded job as saved in user history.
        Only jobs with status 'succeeded' can be marked as saved.
        """
        job = await self.get_by_id(job_id)
        if not job:
            return None

        if is_saved and job.status != JobStatus.SUCCEEDED:
            raise ValueError(f"Cannot save job with status '{job.status}'. Only succeeded jobs can be saved.")

        stmt = (
            update(TryOnJob)
            .where(TryOnJob.id == job_id)
            .values(
                is_saved=is_saved,
                saved_at=func.now() if is_saved else None,
                updated_at=func.now(),
            )
            .returning(TryOnJob)
        )
        result = await self.session.execute(stmt)
        return result.scalar_one_or_none()

    async def list_saved_jobs(
        self,
        limit: int = 20,
        offset: int = 0,
    ) -> Sequence[TryOnJob]:
        """Query saved jobs for user history display, ordered latest first."""
        stmt = (
            select(TryOnJob)
            .where(TryOnJob.is_saved.is_(True))
            .order_by(TryOnJob.saved_at.desc(), TryOnJob.created_at.desc())
            .limit(limit)
            .offset(offset)
        )
        result = await self.session.execute(stmt)
        return result.scalars().all()

    async def count_saved_jobs(self) -> int:
        """Count total number of saved jobs in database."""
        stmt = select(func.count(TryOnJob.id)).where(TryOnJob.is_saved.is_(True))
        result = await self.session.execute(stmt)
        return int(result.scalar_one() or 0)

    async def delete_job(self, job_id: uuid.UUID) -> bool:
        """Delete a job record from database."""
        stmt = delete(TryOnJob).where(TryOnJob.id == job_id)
        result = await self.session.execute(stmt)
        rowcount = getattr(result, "rowcount", 0)
        return int(rowcount or 0) > 0
