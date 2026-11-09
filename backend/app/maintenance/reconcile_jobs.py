import asyncio
from dataclasses import dataclass, field
import sys
from typing import List, Optional
import uuid

from app.core.config import settings
from app.core.errors import ErrorCode
from app.core.logging import logger, setup_logging
from app.db.session import create_worker_session
from app.models.try_on_job import TryOnJob
from app.queue.publisher import CeleryTaskPublisher, TaskPublisher
from app.repositories.job_repository import JobRepository


@dataclass
class ReconcileReport:
    """Structured summary of job reconciliation run."""

    stale_jobs_found: int = 0
    stale_jobs_requeued: int = 0
    stale_jobs_failed: int = 0
    stuck_queued_found: int = 0
    stuck_queued_republished: int = 0
    errors: List[str] = field(default_factory=list)

    @property
    def total_reconciled(self) -> int:
        return self.stale_jobs_requeued + self.stale_jobs_failed + self.stuck_queued_republished


async def reconcile_stale_jobs(
    job_repository: JobRepository,
    publisher: TaskPublisher,
    stale_threshold_seconds: Optional[int] = None,
    queued_timeout_seconds: Optional[int] = None,
    max_retries: Optional[int] = None,
    batch_size: int = 100,
) -> ReconcileReport:
    """
    Scan and reconcile stale or orphaned jobs in PostgreSQL:
    1. Stale 'processing' jobs:
       - If retry_count < max_retries: atomically transition back to 'queued' and re-enqueue to broker.
       - If retry_count >= max_retries: mark terminal 'failed' with STALE_JOB_TIMEOUT.
    2. Stuck 'queued' jobs:
       - If created_at is older than queued_timeout_seconds, re-publish to message broker.
    """
    stale_threshold = (
        stale_threshold_seconds
        if stale_threshold_seconds is not None
        else settings.STALE_JOB_THRESHOLD_SECONDS
    )
    queued_timeout = (
        queued_timeout_seconds
        if queued_timeout_seconds is not None
        else settings.QUEUED_JOB_TIMEOUT_SECONDS
    )
    retries_limit = (
        max_retries if max_retries is not None else settings.WORKER_MAX_RETRIES
    )

    report = ReconcileReport()

    # 1. Reconcile stale 'processing' jobs
    try:
        stale_jobs = await job_repository.find_stale_processing_jobs(
            stale_threshold_seconds=stale_threshold,
            limit=batch_size,
        )
    except Exception as exc:
        err_msg = f"Failed to query stale processing jobs: {exc}"
        logger.error(err_msg)
        report.errors.append(err_msg)
        stale_jobs = []

    for job in stale_jobs:
        report.stale_jobs_found += 1
        job_id = job.id
        try:
            if job.retry_count < retries_limit:
                requeued = await job_repository.requeue_stale_job(job_id, increment_retry=True)
                if requeued is not None:
                    await job_repository.session.commit()
                    await publisher.publish_try_on_job(job_id)
                    report.stale_jobs_requeued += 1
                    logger.warning(
                        "Reconciler recovered and requeued stale job_id=%s (retry_count=%d/%d)",
                        job_id,
                        requeued.retry_count,
                        retries_limit,
                    )
            else:
                fail_msg = (
                    f"Job exceeded stale processing threshold of {stale_threshold}s "
                    f"and exhausted maximum retry attempts ({job.retry_count}/{retries_limit})."
                )
                await job_repository.mark_failed(
                    job_id=job_id,
                    error_code=ErrorCode.STALE_JOB_TIMEOUT.value,
                    error_message=fail_msg,
                    increment_retry=False,
                    terminal=True,
                )
                await job_repository.session.commit()
                report.stale_jobs_failed += 1
                logger.error(
                    "Reconciler marked stale job_id=%s as terminal FAILED (STALE_JOB_TIMEOUT)",
                    job_id,
                )
        except Exception as job_err:
            await job_repository.session.rollback()
            err_str = f"Error reconciling processing job_id={job_id}: {job_err}"
            logger.error(err_str)
            report.errors.append(err_str)

    # 2. Reconcile stuck 'queued' jobs
    try:
        stuck_queued_jobs = await job_repository.find_stuck_queued_jobs(
            queued_timeout_seconds=queued_timeout,
            limit=batch_size,
        )
    except Exception as exc:
        err_msg = f"Failed to query stuck queued jobs: {exc}"
        logger.error(err_msg)
        report.errors.append(err_msg)
        stuck_queued_jobs = []

    for job in stuck_queued_jobs:
        report.stuck_queued_found += 1
        job_id = job.id
        try:
            await publisher.publish_try_on_job(job_id)
            report.stuck_queued_republished += 1
            logger.info("Reconciler republished stuck queued job_id=%s to broker", job_id)
        except Exception as pub_err:
            err_str = f"Error republishing stuck queued job_id={job_id}: {pub_err}"
            logger.warning(err_str)
            report.errors.append(err_str)

    logger.info(
        "Job reconciliation completed: found_stale=%d, requeued=%d, failed=%d, "
        "stuck_queued=%d, republished=%d, errors=%d",
        report.stale_jobs_found,
        report.stale_jobs_requeued,
        report.stale_jobs_failed,
        report.stuck_queued_found,
        report.stuck_queued_republished,
        len(report.errors),
    )
    return report


async def _run_cli() -> int:
    setup_logging()
    logger.info("Starting manual job reconciliation CLI...")
    publisher = CeleryTaskPublisher()
    async with create_worker_session() as session:
        repo = JobRepository(session)
        report = await reconcile_stale_jobs(repo, publisher)
        logger.info("Reconciliation CLI finished: %s", report)
        return 1 if report.errors else 0


def main() -> None:
    code = asyncio.run(_run_cli())
    sys.exit(code)


if __name__ == "__main__":
    main()

