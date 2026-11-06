from typing import AsyncGenerator
from fastapi import Depends
from sqlalchemy.ext.asyncio import AsyncSession
from app.core.config import settings
from app.db.session import get_async_session
from app.integrations.ai_provider import AIProvider
from app.integrations.fake_ai_provider import FakeAIProvider
from app.queue.publisher import (
    CeleryTaskPublisher,
    FakeTaskPublisher,
    TaskPublisher,
)
from app.repositories.history_repository import HistoryRepository
from app.repositories.job_repository import JobRepository
from app.services.history_service import HistoryService
from app.services.image_service import ImageService
from app.services.job_service import JobService
from app.services.try_on_service import TryOnService
from app.services.upload_validator import UploadValidator
from app.storage.local_storage import LocalStorageAdapter

# Publisher instances (CeleryTaskPublisher for production/Compose in B04; FakeTaskPublisher when configured or in tests)
_default_fake_publisher = FakeTaskPublisher()
_default_celery_publisher = CeleryTaskPublisher()
_default_fake_ai_provider = FakeAIProvider(
    delay_seconds=settings.FAKE_AI_PROCESSING_DELAY_SECONDS
)


async def get_db() -> AsyncGenerator[AsyncSession, None]:
    """FastAPI dependency yielding a transactional async database session."""
    async for session in get_async_session():
        yield session


async def get_job_repository(
    db: AsyncSession = Depends(get_db),
) -> JobRepository:
    """FastAPI dependency injecting JobRepository."""
    return JobRepository(db)


def get_storage_adapter() -> LocalStorageAdapter:
    """FastAPI dependency providing LocalStorageAdapter."""
    return LocalStorageAdapter()


def get_upload_validator() -> UploadValidator:
    """FastAPI dependency providing UploadValidator."""
    return UploadValidator()


def get_image_service(
    storage: LocalStorageAdapter = Depends(get_storage_adapter),
    validator: UploadValidator = Depends(get_upload_validator),
) -> ImageService:
    """FastAPI dependency providing ImageService."""
    return ImageService(storage=storage, validator=validator)


def get_task_publisher() -> TaskPublisher:
    """
    FastAPI dependency providing TaskPublisher:
    Uses CeleryTaskPublisher by default in B04+, or FakeTaskPublisher if TASK_PUBLISHER_BACKEND=='fake'.
    """
    if settings.TASK_PUBLISHER_BACKEND.strip().lower() == "fake":
        return _default_fake_publisher
    return _default_celery_publisher


def get_ai_provider() -> AIProvider:
    """FastAPI/Worker dependency providing the active AIProvider (FakeAIProvider in B04)."""
    return _default_fake_ai_provider


async def get_try_on_service(
    job_repository: JobRepository = Depends(get_job_repository),
    image_service: ImageService = Depends(get_image_service),
    publisher: TaskPublisher = Depends(get_task_publisher),
) -> TryOnService:
    """FastAPI dependency providing TryOnService."""
    return TryOnService(
        job_repository=job_repository,
        image_service=image_service,
        publisher=publisher,
    )


async def get_job_service(
    job_repository: JobRepository = Depends(get_job_repository),
) -> JobService:
    """FastAPI dependency providing JobService."""
    return JobService(job_repository=job_repository)


async def get_history_repository(
    db: AsyncSession = Depends(get_db),
) -> HistoryRepository:
    """FastAPI dependency injecting HistoryRepository."""
    return HistoryRepository(db)


async def get_history_service(
    history_repository: HistoryRepository = Depends(get_history_repository),
    image_service: ImageService = Depends(get_image_service),
) -> HistoryService:
    """FastAPI dependency providing HistoryService."""
    return HistoryService(
        history_repository=history_repository,
        image_service=image_service,
    )

