from typing import Optional, Sequence
import uuid
from sqlalchemy import delete, func, select, update
from sqlalchemy.ext.asyncio import AsyncSession
from app.models.try_on_job import JobStatus, TryOnJob


class HistoryRepository:
    """Repository handling all history queries and atomic state persistence for TryOnJob."""

    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def get_by_id(self, job_id: uuid.UUID) -> Optional[TryOnJob]:
        """Find a job by its UUID, regardless of saved status."""
        stmt = select(TryOnJob).where(TryOnJob.id == job_id)
        result = await self.session.execute(stmt)
        return result.scalar_one_or_none()

    async def get_saved_by_id(self, job_id: uuid.UUID) -> Optional[TryOnJob]:
        """Find a job only if it is marked as saved."""
        stmt = select(TryOnJob).where(
            TryOnJob.id == job_id, TryOnJob.is_saved.is_(True)
        )
        result = await self.session.execute(stmt)
        return result.scalar_one_or_none()

    async def mark_saved_atomic(self, job_id: uuid.UUID) -> Optional[TryOnJob]:
        """
        Atomically mark a succeeded job as saved without race conditions.
        - Preserves initial saved_at timestamp via COALESCE(saved_at, func.now()).
        - Only matches jobs where status == 'succeeded'.
        Returns updated TryOnJob or None if not found or status != succeeded.
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

    async def list_saved_jobs(
        self, limit: int = 20, offset: int = 0
    ) -> Sequence[TryOnJob]:
        """Query saved jobs ordered newest saved first."""
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
        """Count total number of saved jobs in history."""
        stmt = select(func.count(TryOnJob.id)).where(TryOnJob.is_saved.is_(True))
        result = await self.session.execute(stmt)
        return int(result.scalar_one() or 0)

    async def delete_job(self, job_id: uuid.UUID) -> bool:
        """Delete a job record from the database."""
        stmt = delete(TryOnJob).where(TryOnJob.id == job_id)
        result = await self.session.execute(stmt)
        rowcount = getattr(result, "rowcount", 0)
        return int(rowcount or 0) > 0

