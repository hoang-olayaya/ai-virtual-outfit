from dataclasses import dataclass
import enum
from typing import Optional
import uuid
from app.core.logging import logger
from app.models.try_on_job import JobStatus, TryOnJob
from app.repositories.job_repository import JobRepository


class ClaimDecision(str, enum.Enum):
    """Decision returned when a Celery Worker attempts to claim a TryOnJob."""

    CLAIMED = "claimed"
    RESUMED = "resumed"
    ALREADY_COMPLETED = "already_completed"
    ALREADY_PROCESSING = "already_processing"
    NOT_FOUND = "not_found"


@dataclass(frozen=True)
class ClaimResult:
    """Outcome of JobGuard.claim_or_inspect."""

    decision: ClaimDecision
    job: Optional[TryOnJob] = None

    @property
    def should_proceed(self) -> bool:
        return self.decision in (ClaimDecision.CLAIMED, ClaimDecision.RESUMED)


class JobGuard:
    """
    Worker guard ensuring atomic job claiming (`queued` -> `processing`) and
    safe handling of duplicate task deliveries or controlled retry attempts.
    """

    def __init__(self, job_repository: JobRepository) -> None:
        self.job_repository = job_repository

    async def claim_or_inspect(
        self,
        job_id: uuid.UUID,
        allow_processing_resume: bool = False,
    ) -> ClaimResult:
        """
        Attempt to atomically transition `job_id` from 'queued' to 'processing'.
        If the job is not in 'queued' state, inspect its current state in PostgreSQL:
        - If missing -> NOT_FOUND
        - If 'succeeded' or 'failed' -> ALREADY_COMPLETED (skip duplicate delivery)
        - If 'processing' -> RESUMED when allow_processing_resume=True (controlled retry),
          otherwise ALREADY_PROCESSING (skip concurrent worker collision).
        """
        claimed_job = await self.job_repository.claim_job(job_id)
        if claimed_job is not None:
            await self.job_repository.session.commit()
            logger.info("JobGuard claimed job_id=%s (queued -> processing)", job_id)
            return ClaimResult(decision=ClaimDecision.CLAIMED, job=claimed_job)

        existing_job = await self.job_repository.get_by_id(job_id)
        if existing_job is None:
            logger.warning("JobGuard could not find job_id=%s in database", job_id)
            return ClaimResult(decision=ClaimDecision.NOT_FOUND, job=None)

        if existing_job.status in (JobStatus.SUCCEEDED, JobStatus.FAILED):
            logger.info(
                "JobGuard skipping already completed job_id=%s (status=%s)",
                job_id,
                existing_job.status.value,
            )
            return ClaimResult(
                decision=ClaimDecision.ALREADY_COMPLETED,
                job=existing_job,
            )

        if existing_job.status == JobStatus.PROCESSING:
            if allow_processing_resume:
                resumed_job = await self.job_repository.claim_resume_job(job_id)
                if resumed_job is not None:
                    await self.job_repository.session.commit()
                    logger.info(
                        "JobGuard atomically acquired resume lease for job_id=%s on retry (retry_count=%s)",
                        job_id,
                        resumed_job.retry_count,
                    )
                    return ClaimResult(
                        decision=ClaimDecision.RESUMED,
                        job=resumed_job,
                    )
                logger.warning(
                    "JobGuard failed to acquire resume lease for job_id=%s (already claimed by another worker)",
                    job_id,
                )
                return ClaimResult(
                    decision=ClaimDecision.ALREADY_PROCESSING,
                    job=existing_job,
                )
            logger.info(
                "JobGuard skipping job_id=%s because it is already being processed by another worker",
                job_id,
            )
            return ClaimResult(
                decision=ClaimDecision.ALREADY_PROCESSING,
                job=existing_job,
            )

        return ClaimResult(decision=ClaimDecision.NOT_FOUND, job=existing_job)

