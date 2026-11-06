from celery import Celery
from app.core.config import settings

celery_app = Celery(
    "virtual_outfit_worker",
    broker=settings.REDIS_URL,
    backend=settings.REDIS_URL,
    include=["app.workers.tasks"],
)

celery_app.conf.update(
    task_serializer="json",
    accept_content=["json"],
    result_serializer="json",
    timezone="UTC",
    enable_utc=True,
    broker_connection_retry_on_startup=True,
    task_acks_late=True,
    worker_prefetch_multiplier=1,
)


@celery_app.task(name="worker.ping")
def ping() -> str:
    """Simple ping task to verify worker execution and broker round-trip."""
    return "pong"
