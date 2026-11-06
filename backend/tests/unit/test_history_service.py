from datetime import datetime, timezone
from unittest.mock import AsyncMock, patch
import uuid
import pytest
from app.core.errors import JobNotFoundError, ResultNotReadyError
from app.models.try_on_job import JobStatus, TryOnJob
from app.services.history_service import HistoryService
from tests.conftest import InMemoryHistoryRepository, InMemoryJobRepository


@pytest.fixture
def in_memory_job_repo() -> InMemoryJobRepository:
    return InMemoryJobRepository()


@pytest.fixture
def history_repo(in_memory_job_repo: InMemoryJobRepository) -> InMemoryHistoryRepository:
    return InMemoryHistoryRepository(in_memory_job_repo)


@pytest.fixture
def mock_image_service() -> AsyncMock:
    service = AsyncMock()
    service.delete_job_images = AsyncMock(return_value=(True, True))
    return service


@pytest.fixture
def history_service(
    history_repo: InMemoryHistoryRepository,
    mock_image_service: AsyncMock,
) -> HistoryService:
    return HistoryService(
        history_repository=history_repo,
        image_service=mock_image_service,
    )


@pytest.mark.asyncio
async def test_save_job_success(
    in_memory_job_repo: InMemoryJobRepository,
    history_service: HistoryService,
):
    """Saving a succeeded job sets is_saved=True and timestamps saved_at."""
    job = await in_memory_job_repo.create_job(
        person_image_path="inputs/1/person.jpg",
        garment_image_path="inputs/1/garment.png",
    )
    await in_memory_job_repo.mark_succeeded(job.id, "outputs/1/result.jpg")

    saved_job = await history_service.save_job(job.id)
    assert saved_job.is_saved is True
    assert saved_job.saved_at is not None
    assert saved_job.status == JobStatus.SUCCEEDED


@pytest.mark.asyncio
async def test_save_job_idempotent_atomic(
    in_memory_job_repo: InMemoryJobRepository,
    history_service: HistoryService,
):
    """Calling save_job multiple times returns the same saved job and preserves initial saved_at."""
    job = await in_memory_job_repo.create_job(
        person_image_path="inputs/2/person.jpg",
        garment_image_path="inputs/2/garment.png",
    )
    await in_memory_job_repo.mark_succeeded(job.id, "outputs/2/result.jpg")

    first_save = await history_service.save_job(job.id)
    initial_saved_at = first_save.saved_at

    second_save = await history_service.save_job(job.id)
    assert second_save.is_saved is True
    assert second_save.saved_at == initial_saved_at
    assert second_save.id == job.id


@pytest.mark.asyncio
async def test_save_job_fails_when_not_succeeded(
    in_memory_job_repo: InMemoryJobRepository,
    history_service: HistoryService,
):
    """Cannot save jobs that are queued, processing, or failed (raises ResultNotReadyError 409)."""
    # Queued
    job_queued = await in_memory_job_repo.create_job(
        person_image_path="inputs/3/person.jpg",
        garment_image_path="inputs/3/garment.png",
    )
    with pytest.raises(ResultNotReadyError) as exc_info:
        await history_service.save_job(job_queued.id)
    assert exc_info.value.status_code == 409
    assert exc_info.value.details["status"] == "queued"

    # Processing
    await in_memory_job_repo.claim_job(job_queued.id)
    with pytest.raises(ResultNotReadyError) as exc_info:
        await history_service.save_job(job_queued.id)
    assert exc_info.value.status_code == 409
    assert exc_info.value.details["status"] == "processing"

    # Failed
    await in_memory_job_repo.mark_failed(
        job_queued.id, error_code="AI_ERROR", error_message="Model failure"
    )
    with pytest.raises(ResultNotReadyError) as exc_info:
        await history_service.save_job(job_queued.id)
    assert exc_info.value.status_code == 409
    assert exc_info.value.details["status"] == "failed"


@pytest.mark.asyncio
async def test_save_job_fails_when_not_found(history_service: HistoryService):
    """Saving a non-existent job ID raises JobNotFoundError (404)."""
    random_id = uuid.uuid4()
    with pytest.raises(JobNotFoundError) as exc_info:
        await history_service.save_job(random_id)
    assert exc_info.value.status_code == 404
    assert exc_info.value.details["job_id"] == str(random_id)


@pytest.mark.asyncio
async def test_list_history_pagination_and_ordering(
    in_memory_job_repo: InMemoryJobRepository,
    history_service: HistoryService,
):
    """List history returns only saved jobs ordered by saved_at desc, with correct pagination."""
    # Create 3 succeeded jobs
    saved_ids = []
    for i in range(3):
        job = await in_memory_job_repo.create_job(
            person_image_path=f"inputs/{i}/person.jpg",
            garment_image_path=f"inputs/{i}/garment.png",
        )
        await in_memory_job_repo.mark_succeeded(job.id, f"outputs/{i}/result.jpg")
        await history_service.save_job(job.id)
        saved_ids.append(job.id)

    # Create 1 unsaved succeeded job
    unsaved_job = await in_memory_job_repo.create_job(
        person_image_path="inputs/99/person.jpg",
        garment_image_path="inputs/99/garment.png",
    )
    await in_memory_job_repo.mark_succeeded(unsaved_job.id, "outputs/99/result.jpg")

    # List with limit 2, offset 0
    items, total = await history_service.list_history(limit=2, offset=0)
    assert total == 3
    assert len(items) == 2
    # Ensure all returned items are in saved_ids and unsaved_job is excluded
    assert all(item.id in saved_ids for item in items)
    assert unsaved_job.id not in [item.id for item in items]

    # List with offset 2
    items_offset, total = await history_service.list_history(limit=2, offset=2)
    assert total == 3
    assert len(items_offset) == 1


@pytest.mark.asyncio
async def test_get_history_detail(
    in_memory_job_repo: InMemoryJobRepository,
    history_service: HistoryService,
):
    """Retrieving saved job returns details; unsaved or missing job raises 404."""
    job = await in_memory_job_repo.create_job(
        person_image_path="inputs/4/person.jpg",
        garment_image_path="inputs/4/garment.png",
    )
    await in_memory_job_repo.mark_succeeded(job.id, "outputs/4/result.jpg")

    # Before saving -> raises 404
    with pytest.raises(JobNotFoundError):
        await history_service.get_history_detail(job.id)

    # After saving -> returns job
    await history_service.save_job(job.id)
    detail = await history_service.get_history_detail(job.id)
    assert detail.id == job.id
    assert detail.is_saved is True


@pytest.mark.asyncio
async def test_delete_history_success(
    in_memory_job_repo: InMemoryJobRepository,
    mock_image_service: AsyncMock,
    history_service: HistoryService,
):
    """Deleting a saved history item deletes DB record and cleans up storage files."""
    job = await in_memory_job_repo.create_job(
        person_image_path="inputs/5/person.jpg",
        garment_image_path="inputs/5/garment.png",
    )
    await in_memory_job_repo.mark_succeeded(job.id, "outputs/5/result.jpg")
    await history_service.save_job(job.id)

    await history_service.delete_history(job.id)

    # Job is removed from DB
    assert await in_memory_job_repo.get_by_id(job.id) is None
    # Filesystem delete was triggered
    mock_image_service.delete_job_images.assert_awaited_once_with(job.id)


@pytest.mark.asyncio
async def test_delete_history_orphan_logging(
    in_memory_job_repo: InMemoryJobRepository,
    mock_image_service: AsyncMock,
    history_service: HistoryService,
):
    """If file deletion raises an error, DB record is still deleted and warning is logged (T12)."""
    job = await in_memory_job_repo.create_job(
        person_image_path="inputs/6/person.jpg",
        garment_image_path="inputs/6/garment.png",
    )
    await in_memory_job_repo.mark_succeeded(job.id, "outputs/6/result.jpg")
    await history_service.save_job(job.id)

    # Simulate filesystem deletion error
    mock_image_service.delete_job_images.side_effect = OSError("Volume IO error")

    with patch("app.services.history_service.logger.warning") as mock_warn:
        await history_service.delete_history(job.id)
        # DB row was successfully deleted
        assert await in_memory_job_repo.get_by_id(job.id) is None
        # Structured orphan log was emitted
        assert mock_warn.called
        log_message = mock_warn.call_args[0][0]
        assert "ORPHAN_STORAGE_DIR_DETECTED" in log_message

