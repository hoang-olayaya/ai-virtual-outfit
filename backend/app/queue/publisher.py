import asyncio
from typing import Any, List, Optional, Protocol, runtime_checkable
import uuid
from app.core.errors import QueuePublishError
from app.core.logging import logger

TRY_ON_TASK_NAME = "worker.generate_try_on"


@runtime_checkable
class TaskPublisher(Protocol):
    """Protocol for publishing background try-on job tasks (only job_id, never image bytes)."""

    async def publish_try_on_job(self, job_id: uuid.UUID) -> None:
        """Enqueue a try-on job by its UUID."""
        ...


class FakeTaskPublisher:
    """
    In-memory fake task publisher for Phase B03 and automated tests.
    Records published job IDs in order and can simulate broker failures on demand.
    """

    def __init__(
        self,
        should_fail: bool = False,
        failure_message: str = "Simulated message broker publish failure.",
    ) -> None:
        self.published_job_ids: List[uuid.UUID] = []
        self.should_fail = should_fail
        self.failure_message = failure_message

    async def publish_try_on_job(self, job_id: uuid.UUID) -> None:
        if not isinstance(job_id, uuid.UUID):
            job_id = uuid.UUID(str(job_id))

        if self.should_fail:
            logger.error(
                "FakeTaskPublisher simulated publish error for job_id=%s: %s",
                job_id,
                self.failure_message,
            )
            raise QueuePublishError(
                message=self.failure_message,
                details={"job_id": str(job_id)},
            )

        self.published_job_ids.append(job_id)
        logger.info("FakeTaskPublisher enqueued job_id=%s", job_id)

    def reset(self) -> None:
        """Clear recorded job IDs and reset failure flags."""
        self.published_job_ids.clear()
        self.should_fail = False


class CeleryTaskPublisher:
    """
    Production task publisher sending only 'job_id' (as string) to Redis via Celery.
    Never sends binary image content over the message broker.
    """

    def __init__(
        self,
        task_name: str = TRY_ON_TASK_NAME,
        celery_client: Optional[Any] = None,
    ) -> None:
        self.task_name = task_name
        self._celery_client = celery_client

    def _get_celery_client(self) -> Any:
        if self._celery_client is not None:
            return self._celery_client
        from app.workers.celery_app import celery_app

        return celery_app

    def _send_sync(self, job_id_str: str) -> None:
        client = self._get_celery_client()
        client.send_task(self.task_name, args=[job_id_str])

    async def publish_try_on_job(self, job_id: uuid.UUID) -> None:
        job_id_str = str(job_id)
        try:
            await asyncio.to_thread(self._send_sync, job_id_str)
            logger.info(
                "CeleryTaskPublisher published task '%s' for job_id=%s",
                self.task_name,
                job_id_str,
            )
        except Exception as exc:
            logger.error(
                "CeleryTaskPublisher failed to publish job_id=%s: %s",
                job_id_str,
                exc,
            )
            raise QueuePublishError(
                message="Failed to enqueue try-on job to message broker.",
                details={"job_id": str(job_id_str)},
            ) from exc
