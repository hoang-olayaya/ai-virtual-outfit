from datetime import datetime, timezone
import io
from pathlib import Path
from typing import AsyncGenerator, Dict, Generator, Optional, Tuple
import uuid
import httpx
import pytest
import pytest_asyncio
from fastapi import UploadFile
from fastapi.testclient import TestClient
from PIL import Image
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.pool import NullPool
from starlette.datastructures import Headers
from app.api.deps import (
    get_history_repository,
    get_image_service,
    get_job_repository,
    get_task_publisher,
)
from app.core.config import settings
from app.db.session import ping_database
from app.integrations.fake_ai_provider import FakeAIProvider
from app.main import app
from app.models.try_on_job import JobStatus, TryOnJob
from app.queue.publisher import FakeTaskPublisher
from app.repositories.history_repository import HistoryRepository
from app.repositories.job_repository import JobRepository
from app.services.image_service import ImageService
from app.services.upload_validator import UploadValidator
from app.storage.local_storage import LocalStorageAdapter


def create_synthetic_image_bytes(
    fmt: str = "JPEG",
    size: Tuple[int, int] = (256, 256),
    color: Tuple[int, int, int] = (70, 130, 180),
) -> bytes:
    """Create valid in-memory image bytes using Pillow."""
    buf = io.BytesIO()
    mode = "RGBA" if fmt.upper() in ("PNG", "WEBP") else "RGB"
    img = Image.new(mode, size, color=color)
    img.save(buf, format=fmt)
    return buf.getvalue()


def make_upload_file(
    content: bytes,
    filename: str = "sample.jpg",
    content_type: str = "image/jpeg",
) -> UploadFile:
    """Helper to wrap bytes into a FastAPI UploadFile instance."""
    return UploadFile(
        file=io.BytesIO(content),
        filename=filename,
        headers=Headers({"content-type": content_type}),
    )


def _clone_job(job: TryOnJob) -> TryOnJob:
    """Clone a TryOnJob entity cleanly without copying SQLAlchemy internal instance state."""
    return TryOnJob(
        id=job.id,
        idempotency_key=job.idempotency_key,
        status=job.status,
        person_image_path=job.person_image_path,
        garment_image_path=job.garment_image_path,
        result_image_path=job.result_image_path,
        provider_name=job.provider_name,
        provider_request_id=job.provider_request_id,
        error_code=job.error_code,
        error_message=job.error_message,
        retry_count=job.retry_count,
        is_saved=job.is_saved,
        saved_at=job.saved_at,
        created_at=job.created_at,
        updated_at=job.updated_at,
        completed_at=job.completed_at,
    )


class _InMemorySession:
    """Transactional session simulator supporting commit/rollback/refresh for local API integration tests."""

    def __init__(self, repo: "InMemoryJobRepository") -> None:
        self._repo = repo

    async def commit(self) -> None:
        self._repo._committed = {
            jid: _clone_job(job) for jid, job in self._repo._working.items()
        }

    async def rollback(self) -> None:
        self._repo._working = {
            jid: _clone_job(job) for jid, job in self._repo._committed.items()
        }

    async def refresh(self, job: TryOnJob) -> None:
        return None


class InMemoryJobRepository(JobRepository):
    """
    Transactional in-memory implementation of JobRepository used when PostgreSQL
    is not running locally, while preserving exact constraint and state semantics.
    """

    def __init__(self) -> None:
        self._committed: Dict[uuid.UUID, TryOnJob] = {}
        self._working: Dict[uuid.UUID, TryOnJob] = {}
        self.session = _InMemorySession(self)  # type: ignore[assignment]

    async def create_job(
        self,
        person_image_path: str,
        garment_image_path: str,
        idempotency_key: Optional[str] = None,
        job_id: Optional[uuid.UUID] = None,
    ) -> TryOnJob:
        if idempotency_key is not None:
            for existing in self._working.values():
                if existing.idempotency_key == idempotency_key:
                    raise IntegrityError(
                        "INSERT INTO try_on_jobs",
                        {"idempotency_key": idempotency_key},
                        Exception("duplicate key value violates unique constraint"),
                    )
        now = datetime.now(timezone.utc)
        job = TryOnJob(
            id=job_id or uuid.uuid4(),
            idempotency_key=idempotency_key,
            status=JobStatus.QUEUED,
            person_image_path=person_image_path,
            garment_image_path=garment_image_path,
            created_at=now,
            updated_at=now,
        )
        self._working[job.id] = job
        return job

    async def get_by_id(self, job_id: uuid.UUID) -> Optional[TryOnJob]:
        return self._working.get(job_id)

    async def get_by_idempotency_key(self, idempotency_key: str) -> Optional[TryOnJob]:
        for job in self._working.values():
            if job.idempotency_key == idempotency_key:
                return job
        return None

    async def claim_job(self, job_id: uuid.UUID) -> Optional[TryOnJob]:
        job = self._working.get(job_id)
        if job is None or job.status != JobStatus.QUEUED:
            return None
        job.status = JobStatus.PROCESSING
        job.updated_at = datetime.now(timezone.utc)
        return job

    async def claim_resume_job(self, job_id: uuid.UUID) -> Optional[TryOnJob]:
        job = self._working.get(job_id)
        if job is None or job.status != JobStatus.PROCESSING:
            return None
        job.updated_at = datetime.now(timezone.utc)
        return job

    async def update_provider_tracking(
        self,
        job_id: uuid.UUID,
        provider_name: str,
        provider_request_id: str,
    ) -> Optional[TryOnJob]:
        job = self._working.get(job_id)
        if job is None:
            return None
        job.provider_name = provider_name
        job.provider_request_id = provider_request_id
        job.updated_at = datetime.now(timezone.utc)
        return job

    async def mark_succeeded(
        self,
        job_id: uuid.UUID,
        result_image_path: str,
    ) -> Optional[TryOnJob]:
        job = self._working.get(job_id)
        if job is None:
            return None
        now = datetime.now(timezone.utc)
        job.status = JobStatus.SUCCEEDED
        job.result_image_path = result_image_path
        job.completed_at = now
        job.updated_at = now
        return job

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
        job = self._working.get(job_id)
        if job is None:
            return None
        now = datetime.now(timezone.utc)
        job.error_code = error_code
        job.error_message = error_message
        job.updated_at = now
        if increment_retry:
            job.retry_count = (job.retry_count or 0) + 1
        if terminal:
            job.status = JobStatus.FAILED
            job.completed_at = now
        if provider_name is not None:
            job.provider_name = provider_name
        if provider_request_id is not None:
            job.provider_request_id = provider_request_id
        return job

    async def count_jobs(self) -> int:
        return len(self._working)

    async def mark_saved_atomic(self, job_id: uuid.UUID) -> Optional[TryOnJob]:
        job = self._working.get(job_id)
        if job is None or job.status != JobStatus.SUCCEEDED:
            return None
        now = datetime.now(timezone.utc)
        if not job.is_saved:
            job.is_saved = True
            job.saved_at = now
        job.updated_at = now
        return job

    async def mark_saved(self, job_id: uuid.UUID, is_saved: bool = True) -> Optional[TryOnJob]:
        job = self._working.get(job_id)
        if job is None:
            return None
        if is_saved and job.status != JobStatus.SUCCEEDED:
            raise ValueError(f"Cannot save job with status '{job.status}'. Only succeeded jobs can be saved.")
        now = datetime.now(timezone.utc)
        job.is_saved = is_saved
        job.saved_at = now if is_saved else None
        job.updated_at = now
        return job

    async def list_saved_jobs(self, limit: int = 20, offset: int = 0) -> Sequence[TryOnJob]:
        saved = [j for j in self._working.values() if j.is_saved]
        saved.sort(
            key=lambda x: (
                x.saved_at or datetime.min.replace(tzinfo=timezone.utc),
                x.created_at,
            ),
            reverse=True,
        )
        return saved[offset : offset + limit]

    async def count_saved_jobs(self) -> int:
        return len([j for j in self._working.values() if j.is_saved])

    async def get_saved_by_id(self, job_id: uuid.UUID) -> Optional[TryOnJob]:
        job = self._working.get(job_id)
        if job is not None and job.is_saved:
            return job
        return None

    async def delete_job(self, job_id: uuid.UUID) -> bool:
        if job_id in self._working:
            del self._working[job_id]
            self._committed.pop(job_id, None)
            return True
        return False


class InMemoryHistoryRepository(HistoryRepository):
    """
    Transactional in-memory implementation of HistoryRepository wrapping the
    same in-memory storage dictionary as InMemoryJobRepository.
    """

    def __init__(self, job_repo: InMemoryJobRepository) -> None:
        self._job_repo = job_repo
        self.session = job_repo.session  # type: ignore[assignment]

    async def get_by_id(self, job_id: uuid.UUID) -> Optional[TryOnJob]:
        return await self._job_repo.get_by_id(job_id)

    async def get_saved_by_id(self, job_id: uuid.UUID) -> Optional[TryOnJob]:
        return await self._job_repo.get_saved_by_id(job_id)

    async def mark_saved_atomic(self, job_id: uuid.UUID) -> Optional[TryOnJob]:
        return await self._job_repo.mark_saved_atomic(job_id)

    async def list_saved_jobs(self, limit: int = 20, offset: int = 0) -> Sequence[TryOnJob]:
        return await self._job_repo.list_saved_jobs(limit=limit, offset=offset)

    async def count_saved_jobs(self) -> int:
        return await self._job_repo.count_saved_jobs()

    async def delete_job(self, job_id: uuid.UUID) -> bool:
        return await self._job_repo.delete_job(job_id)



@pytest.fixture
def temp_storage_dir(tmp_path: Path) -> Path:
    """Isolated temporary directory for file storage tests."""
    storage_root = tmp_path / "test_storage"
    storage_root.mkdir(parents=True, exist_ok=True)
    return storage_root


@pytest.fixture
def storage_adapter(temp_storage_dir: Path) -> LocalStorageAdapter:
    """Fixture providing a LocalStorageAdapter backed by an isolated tmp_path."""
    adapter = LocalStorageAdapter(base_path=temp_storage_dir)
    adapter.ensure_base_dirs()
    return adapter


@pytest.fixture
def upload_validator() -> UploadValidator:
    """Fixture providing default UploadValidator."""
    return UploadValidator()


@pytest.fixture
def image_service(
    storage_adapter: LocalStorageAdapter,
    upload_validator: UploadValidator,
) -> ImageService:
    """Fixture providing ImageService wired to isolated temporary storage."""
    return ImageService(storage=storage_adapter, validator=upload_validator)


@pytest.fixture
def fake_publisher() -> FakeTaskPublisher:
    """Fixture providing a clean in-memory FakeTaskPublisher per test."""
    return FakeTaskPublisher()


@pytest.fixture
def fake_ai_provider() -> FakeAIProvider:
    """Fixture providing a deterministic FakeAIProvider with zero delay per test."""
    return FakeAIProvider(delay_seconds=0.0)


@pytest.fixture(scope="session")
def client() -> Generator[TestClient, None, None]:
    """Fixture providing a synchronized TestClient for FastAPI."""
    with TestClient(app) as test_client:
        yield test_client


_pg_available: Optional[bool] = None


async def is_postgres_available() -> bool:
    """Check once per test session whether the PostgreSQL test database is reachable."""
    global _pg_available
    if _pg_available is None:
        _pg_available = await ping_database()
    return _pg_available


@pytest_asyncio.fixture
async def test_engine():
    """Create test engine with NullPool and ensure tables exist."""
    if not await is_postgres_available():
        pytest.skip("PostgreSQL database is not reachable; skipping raw PostgreSQL test.")
    engine = create_async_engine(
        settings.DATABASE_URL,
        poolclass=NullPool,
    )
    yield engine
    await engine.dispose()


@pytest_asyncio.fixture
async def db_session(test_engine) -> AsyncGenerator[AsyncSession, None]:
    """Fixture providing an isolated AsyncSession per test."""
    session_factory = async_sessionmaker(
        bind=test_engine,
        class_=AsyncSession,
        expire_on_commit=False,
    )
    async with session_factory() as session:
        yield session
        await session.rollback()
        # Cleanup rows after each test to maintain full isolation
        try:
            await session.execute(text("TRUNCATE TABLE try_on_jobs RESTART IDENTITY CASCADE;"))
            await session.commit()
        except Exception:
            await session.rollback()


@pytest_asyncio.fixture
async def api_job_repository() -> AsyncGenerator[JobRepository, None]:
    """
    Provides a real PostgreSQL-backed JobRepository when PostgreSQL is reachable
    (e.g. inside Docker Compose), or falls back to InMemoryJobRepository when running
    locally without Docker Desktop active.
    """
    if await is_postgres_available():
        engine = create_async_engine(settings.DATABASE_URL, poolclass=NullPool)
        session_factory = async_sessionmaker(
            bind=engine,
            class_=AsyncSession,
            expire_on_commit=False,
        )
        async with session_factory() as session:
            yield JobRepository(session)
            await session.rollback()
            try:
                await session.execute(text("TRUNCATE TABLE try_on_jobs RESTART IDENTITY CASCADE;"))
                await session.commit()
            except Exception:
                await session.rollback()
        await engine.dispose()
    else:
        yield InMemoryJobRepository()


@pytest_asyncio.fixture
async def api_history_repository(
    api_job_repository: JobRepository,
) -> AsyncGenerator[HistoryRepository, None]:
    """
    Provides a HistoryRepository wired to the same backing store as api_job_repository.
    """
    if isinstance(api_job_repository, InMemoryJobRepository):
        yield InMemoryHistoryRepository(api_job_repository)
    else:
        yield HistoryRepository(api_job_repository.session)


@pytest_asyncio.fixture
async def async_api_client(
    api_job_repository: JobRepository,
    api_history_repository: HistoryRepository,
    image_service: ImageService,
    fake_publisher: FakeTaskPublisher,
) -> AsyncGenerator[httpx.AsyncClient, None]:
    """
    Async HTTP client bound to FastAPI app with dependency overrides for:
    - JobRepository (`api_job_repository` - real Postgres when up, or transactional in-memory fallback)
    - HistoryRepository (`api_history_repository`)
    - Isolated temporary file storage (`image_service`)
    - In-memory task publisher (`fake_publisher`)
    """
    app.dependency_overrides[get_job_repository] = lambda: api_job_repository
    app.dependency_overrides[get_history_repository] = lambda: api_history_repository
    app.dependency_overrides[get_image_service] = lambda: image_service
    app.dependency_overrides[get_task_publisher] = lambda: fake_publisher

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://testserver") as ac:
        yield ac

    app.dependency_overrides.clear()
