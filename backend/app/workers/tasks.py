import asyncio
from dataclasses import dataclass
from typing import Any, Dict, Optional, Union
import uuid
from app.core.config import settings
from app.core.logging import logger
from app.db.session import create_worker_session
from app.integrations.ai_provider import AIProvider
from app.integrations.fake_ai_provider import FakeAIProvider
from app.models.try_on_job import JobStatus
from app.queue.publisher import TRY_ON_TASK_NAME
from app.repositories.job_repository import JobRepository
from app.services.image_service import ImageService
from app.workers.celery_app import celery_app
from app.workers.failure_handler import FailureHandler
from app.workers.job_guard import ClaimDecision, JobGuard


@dataclass(frozen=True)
class WorkerExecutionOutcome:
    """Structured result of executing a try-on job in the worker pipeline."""

    job_id: uuid.UUID
    status: str
    decision: str
    result_image_path: Optional[str] = None
    provider_name: Optional[str] = None
    provider_request_id: Optional[str] = None
    should_retry: bool = False
    error_code: Optional[str] = None
    error_message: Optional[str] = None
    retry_count: int = 0

    def to_dict(self) -> Dict[str, Any]:
        return {
            "job_id": str(self.job_id),
            "status": self.status,
            "decision": self.decision,
            "result_image_path": self.result_image_path,
            "provider_name": self.provider_name,
            "provider_request_id": self.provider_request_id,
            "should_retry": self.should_retry,
            "error_code": self.error_code,
            "error_message": self.error_message,
            "retry_count": self.retry_count,
        }


def build_default_ai_provider() -> AIProvider:
    """Create the configured AI provider instance (FalAdapter in B05/B06, FakeAIProvider in B04/dev)."""
    provider_name = (settings.AI_PROVIDER or "fake").strip().lower()
    if provider_name == "fal":
        from app.integrations.fal_adapter import FalAdapter

        return FalAdapter(
            api_key=settings.FAL_KEY,
            model_id=settings.FAL_MODEL_ID,
            cloth_type=settings.FAL_CLOTH_TYPE,
            queue_base_url=settings.FAL_QUEUE_BASE_URL,
            storage_upload_url=settings.FAL_STORAGE_UPLOAD_URL,
            http_timeout_seconds=settings.FAL_HTTP_TIMEOUT_SECONDS,
            poll_interval_seconds=settings.FAL_POLL_INTERVAL_SECONDS,
            poll_timeout_seconds=settings.FAL_POLL_TIMEOUT_SECONDS,
            download_max_retries=settings.FAL_DOWNLOAD_MAX_RETRIES,
            download_retry_backoff_seconds=settings.FAL_DOWNLOAD_RETRY_BACKOFF_SECONDS,
        )
    if provider_name == "fake":
        return FakeAIProvider(delay_seconds=settings.FAKE_AI_PROCESSING_DELAY_SECONDS)
    raise ValueError(f"Unsupported AI_PROVIDER '{settings.AI_PROVIDER}'. Expected 'fal' or 'fake'.")


async def _run_pipeline_with_dependencies(
    job_uuid: uuid.UUID,
    job_repository: JobRepository,
    image_service: ImageService,
    ai_provider: AIProvider,
    max_retries: Optional[int] = None,
    allow_processing_resume: bool = False,
) -> WorkerExecutionOutcome:
    """
    Core async pipeline executing a single try-on job:
    1. Claim or inspect job via JobGuard (idempotent duplicate protection).
    2. Load person and garment input image bytes from shared volume.
    3. Execute AI provider inference (`generate_try_on`).
    4. Record provider tracking (`provider_name`, `provider_request_id`) in PostgreSQL.
    5. Atomically persist result image file to `outputs/{job_id}/result.{ext}`.
    6. Mark job status as `succeeded` in PostgreSQL.
    7. On any exception, delegate to FailureHandler to record error and classify retry.
    """
    guard = JobGuard(job_repository)
    failure_handler = FailureHandler(job_repository, max_retries=max_retries)

    claim_result = await guard.claim_or_inspect(
        job_uuid,
        allow_processing_resume=allow_processing_resume,
    )
    if not claim_result.should_proceed or claim_result.job is None:
        current_status = (
            claim_result.job.status.value
            if claim_result.job is not None
            else "not_found"
        )
        return WorkerExecutionOutcome(
            job_id=job_uuid,
            status=current_status,
            decision=claim_result.decision.value,
            result_image_path=(
                claim_result.job.result_image_path if claim_result.job else None
            ),
            provider_name=(
                claim_result.job.provider_name if claim_result.job else None
            ),
            provider_request_id=(
                claim_result.job.provider_request_id if claim_result.job else None
            ),
            retry_count=(claim_result.job.retry_count if claim_result.job else 0),
        )

    job = claim_result.job
    loop = asyncio.get_running_loop()

    def _sync_on_request_submitted(req_id: str) -> None:
        async def _update_early() -> None:
            try:
                await job_repository.update_provider_tracking(
                    job_id=job_uuid,
                    provider_name=getattr(ai_provider, "PROVIDER_NAME", "fal"),
                    provider_request_id=req_id,
                )
                await job_repository.session.commit()
                logger.info(
                    "Early provider tracking saved for job_id=%s (request_id=%s)",
                    job_uuid,
                    req_id,
                )
            except Exception as early_err:
                logger.warning(
                    "Failed early tracking commit for job_id=%s (request_id=%s): %s",
                    job_uuid,
                    req_id,
                    early_err,
                )

        future = asyncio.run_coroutine_threadsafe(_update_early(), loop)
        try:
            future.result(timeout=5.0)
        except Exception as wait_err:
            logger.warning(
                "Early tracking future timed out for job_id=%s: %s", job_uuid, wait_err
            )

    try:
        # 1. Load person and garment input images from shared volume
        person_bytes, _ = await image_service.read_image(job.person_image_path)
        garment_bytes, _ = await image_service.read_image(job.garment_image_path)

        # 2. Invoke AI provider in a worker thread to avoid blocking the event loop
        provider_result = await asyncio.to_thread(
            ai_provider.generate_try_on,
            job_uuid,
            person_bytes,
            garment_bytes,
            job.provider_request_id,
            _sync_on_request_submitted,
        )

        # 3. Record provider tracking info in PostgreSQL before writing output
        await job_repository.update_provider_tracking(
            job_id=job_uuid,
            provider_name=provider_result.provider_name,
            provider_request_id=provider_result.provider_request_id,
        )
        await job_repository.session.commit()

        # 4. Persist result image to shared volume first (atomic write + validation)
        saved_result_path = await image_service.store_result_image(
            job_id=job_uuid,
            image_bytes=provider_result.image_bytes,
            validate=True,
            default_extension=provider_result.extension,
        )

        # 5. Transition job status to 'succeeded' only after output file is safely on disk
        succeeded_job = await job_repository.mark_succeeded(
            job_id=job_uuid,
            result_image_path=saved_result_path,
        )
        await job_repository.session.commit()

        logger.info(
            "Worker completed try-on job_id=%s -> status=succeeded (result=%s)",
            job_uuid,
            saved_result_path,
        )
        return WorkerExecutionOutcome(
            job_id=job_uuid,
            status=JobStatus.SUCCEEDED.value,
            decision=claim_result.decision.value,
            result_image_path=saved_result_path,
            provider_name=provider_result.provider_name,
            provider_request_id=provider_result.provider_request_id,
            retry_count=succeeded_job.retry_count if succeeded_job else job.retry_count,
        )

    except Exception as exc:
        await job_repository.session.rollback()
        try:
            await image_service.cleanup_output_images(job_uuid)
        except Exception as cleanup_exc:
            logger.warning(
                "Safe cleanup of output directory failed for job_id=%s (ignoring to preserve root error): %s",
                job_uuid,
                cleanup_exc,
            )
        failure_decision = await failure_handler.handle_failure(
            job_id=job_uuid,
            exc=exc,
            current_retry_count=job.retry_count,
        )
        final_status = (
            failure_decision.job.status.value
            if failure_decision.job is not None
            else (
                JobStatus.PROCESSING.value
                if failure_decision.should_retry
                else JobStatus.FAILED.value
            )
        )
        return WorkerExecutionOutcome(
            job_id=job_uuid,
            status=final_status,
            decision=ClaimDecision.CLAIMED.value,
            should_retry=failure_decision.should_retry,
            error_code=failure_decision.error_code,
            error_message=failure_decision.error_message,
            retry_count=failure_decision.retry_count,
        )


async def execute_try_on_job(
    job_id: Union[uuid.UUID, str],
    *,
    job_repository: Optional[JobRepository] = None,
    image_service: Optional[ImageService] = None,
    ai_provider: Optional[AIProvider] = None,
    max_retries: Optional[int] = None,
    allow_processing_resume: bool = False,
) -> WorkerExecutionOutcome:
    """
    Execute the try-on worker pipeline for `job_id`.
    Accepts optional injected dependencies for unit/integration testing;
    creates an isolated NullPool worker DB session when `job_repository` is not supplied.
    """
    job_uuid = job_id if isinstance(job_id, uuid.UUID) else uuid.UUID(str(job_id))
    resolved_image_service = image_service or ImageService()
    resolved_ai_provider = ai_provider or build_default_ai_provider()

    if job_repository is not None:
        return await _run_pipeline_with_dependencies(
            job_uuid=job_uuid,
            job_repository=job_repository,
            image_service=resolved_image_service,
            ai_provider=resolved_ai_provider,
            max_retries=max_retries,
            allow_processing_resume=allow_processing_resume,
        )

    async with create_worker_session() as session:
        repo = JobRepository(session)
        return await _run_pipeline_with_dependencies(
            job_uuid=job_uuid,
            job_repository=repo,
            image_service=resolved_image_service,
            ai_provider=resolved_ai_provider,
            max_retries=max_retries,
            allow_processing_resume=allow_processing_resume,
        )


@celery_app.task(bind=True, name=TRY_ON_TASK_NAME, max_retries=settings.WORKER_MAX_RETRIES)
def generate_try_on(self, job_id: str) -> Dict[str, Any]:
    """
    Celery entrypoint task consuming `job_id` (UUID string) from Redis,
    running the try-on pipeline, and scheduling bounded Celery retries on transient errors.
    """
    celery_retries = int(getattr(self.request, "retries", 0) or 0)
    allow_resume = celery_retries > 0

    logger.info(
        "Celery worker received task '%s' for job_id=%s (celery_retry=%d)",
        TRY_ON_TASK_NAME,
        job_id,
        celery_retries,
    )

    outcome = asyncio.run(
        execute_try_on_job(
            job_id=job_id,
            allow_processing_resume=allow_resume,
        )
    )

    if outcome.should_retry:
        backoff = settings.WORKER_RETRY_BACKOFF_SECONDS * max(1, outcome.retry_count)
        logger.warning(
            "Celery task '%s' retrying job_id=%s in %ds (error_code=%s)",
            TRY_ON_TASK_NAME,
            job_id,
            backoff,
            outcome.error_code,
        )
        raise self.retry(
            exc=RuntimeError(outcome.error_message or "Transient worker error"),
            countdown=backoff,
            max_retries=settings.WORKER_MAX_RETRIES,
        )

    return outcome.to_dict()

