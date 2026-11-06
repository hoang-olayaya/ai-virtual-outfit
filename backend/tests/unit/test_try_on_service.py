from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch
import uuid
import pytest
from sqlalchemy.exc import IntegrityError, SQLAlchemyError

from app.core.errors import (
    DatabaseOperationError,
    ErrorCode,
    ImageValidationError,
    InvalidIdempotencyKeyError,
    JobNotFoundError,
    QueuePublishError,
)
from app.models.try_on_job import JobStatus, TryOnJob
from app.queue.publisher import CeleryTaskPublisher, FakeTaskPublisher
from app.schemas.job import JobResponse
from app.services.image_service import ImageService
from app.services.job_service import JobService
from app.services.try_on_service import TryOnService
from tests.conftest import create_synthetic_image_bytes, make_upload_file


def _make_fake_job(
    job_id: uuid.UUID | None = None,
    status: JobStatus = JobStatus.QUEUED,
    idempotency_key: str | None = None,
    result_image_path: str | None = None,
    error_code: str | None = None,
    error_message: str | None = None,
) -> TryOnJob:
    now = datetime.now(timezone.utc)
    return TryOnJob(
        id=job_id or uuid.uuid4(),
        idempotency_key=idempotency_key,
        status=status,
        person_image_path="inputs/person.jpg",
        garment_image_path="inputs/garment.png",
        result_image_path=result_image_path,
        error_code=error_code,
        error_message=error_message,
        created_at=now,
        updated_at=now,
        completed_at=now if status in (JobStatus.SUCCEEDED, JobStatus.FAILED) else None,
    )


def _make_mock_job_repository() -> MagicMock:
    repo = MagicMock()
    repo.session = MagicMock()
    repo.session.commit = AsyncMock()
    repo.session.rollback = AsyncMock()
    repo.session.refresh = AsyncMock()
    repo.get_by_idempotency_key = AsyncMock(return_value=None)
    repo.get_by_id = AsyncMock(return_value=None)
    repo.create_job = AsyncMock()
    repo.mark_failed = AsyncMock()
    return repo


@pytest.mark.asyncio
async def test_try_on_service_happy_path(
    image_service: ImageService,
    temp_storage_dir: Path,
    fake_publisher: FakeTaskPublisher,
):
    repo = _make_mock_job_repository()

    async def _create_job_side_effect(
        person_image_path: str,
        garment_image_path: str,
        idempotency_key: str | None = None,
        job_id: uuid.UUID | None = None,
    ) -> TryOnJob:
        return _make_fake_job(
            job_id=job_id,
            status=JobStatus.QUEUED,
            idempotency_key=idempotency_key,
        )

    repo.create_job.side_effect = _create_job_side_effect
    service = TryOnService(
        job_repository=repo,
        image_service=image_service,
        publisher=fake_publisher,
    )

    person_file = make_upload_file(create_synthetic_image_bytes("JPEG"), "person.jpg")
    garment_file = make_upload_file(create_synthetic_image_bytes("PNG"), "garment.png")

    job = await service.create_try_on_job(
        person_image=person_file,
        garment_image=garment_file,
        idempotency_key="  key-123  ",
    )

    assert job.status == JobStatus.QUEUED
    assert job.idempotency_key == "key-123"
    assert (temp_storage_dir / "inputs" / str(job.id) / "person.jpg").is_file()
    assert (temp_storage_dir / "inputs" / str(job.id) / "garment.png").is_file()
    assert fake_publisher.published_job_ids == [job.id]
    repo.session.commit.assert_awaited_once()


@pytest.mark.asyncio
async def test_try_on_service_invalid_image_does_not_touch_db_or_publisher(
    image_service: ImageService,
    temp_storage_dir: Path,
    fake_publisher: FakeTaskPublisher,
):
    repo = _make_mock_job_repository()
    service = TryOnService(
        job_repository=repo,
        image_service=image_service,
        publisher=fake_publisher,
    )

    person_file = make_upload_file(create_synthetic_image_bytes("JPEG"), "person.jpg")

    with pytest.raises(ImageValidationError) as exc_info:
        await service.create_try_on_job(person_image=person_file, garment_image=None)

    assert exc_info.value.error_code == ErrorCode.MISSING_INPUT_IMAGE
    repo.create_job.assert_not_awaited()
    assert fake_publisher.published_job_ids == []
    assert list((temp_storage_dir / "inputs").iterdir()) == []


@pytest.mark.asyncio
async def test_try_on_service_idempotency_precheck_returns_existing_job(
    image_service: ImageService,
    temp_storage_dir: Path,
    fake_publisher: FakeTaskPublisher,
):
    repo = _make_mock_job_repository()
    existing_job = _make_fake_job(idempotency_key="dup-key-01")
    repo.get_by_idempotency_key.return_value = existing_job

    service = TryOnService(
        job_repository=repo,
        image_service=image_service,
        publisher=fake_publisher,
    )

    person_file = make_upload_file(create_synthetic_image_bytes("JPEG"), "person.jpg")
    garment_file = make_upload_file(create_synthetic_image_bytes("PNG"), "garment.png")

    result = await service.create_try_on_job(
        person_image=person_file,
        garment_image=garment_file,
        idempotency_key="dup-key-01",
    )

    assert result.id == existing_job.id
    repo.create_job.assert_not_awaited()
    assert fake_publisher.published_job_ids == []
    assert list((temp_storage_dir / "inputs").iterdir()) == []


@pytest.mark.asyncio
async def test_try_on_service_rejects_overlong_idempotency_key(
    image_service: ImageService,
    fake_publisher: FakeTaskPublisher,
):
    repo = _make_mock_job_repository()
    service = TryOnService(
        job_repository=repo,
        image_service=image_service,
        publisher=fake_publisher,
    )

    person_file = make_upload_file(create_synthetic_image_bytes("JPEG"), "person.jpg")
    garment_file = make_upload_file(create_synthetic_image_bytes("PNG"), "garment.png")

    with pytest.raises(InvalidIdempotencyKeyError) as exc_info:
        await service.create_try_on_job(
            person_image=person_file,
            garment_image=garment_file,
            idempotency_key="k" * 256,
        )

    assert exc_info.value.error_code == ErrorCode.INVALID_IDEMPOTENCY_KEY
    assert exc_info.value.status_code == 400


@pytest.mark.asyncio
async def test_try_on_service_db_failure_cleans_up_stored_input_files(
    image_service: ImageService,
    temp_storage_dir: Path,
    fake_publisher: FakeTaskPublisher,
):
    repo = _make_mock_job_repository()
    repo.create_job.side_effect = SQLAlchemyError("Simulated DB connection lost")

    service = TryOnService(
        job_repository=repo,
        image_service=image_service,
        publisher=fake_publisher,
    )

    person_file = make_upload_file(create_synthetic_image_bytes("JPEG"), "person.jpg")
    garment_file = make_upload_file(create_synthetic_image_bytes("PNG"), "garment.png")

    with pytest.raises(DatabaseOperationError) as exc_info:
        await service.create_try_on_job(person_image=person_file, garment_image=garment_file)

    assert exc_info.value.error_code == ErrorCode.DATABASE_ERROR
    assert exc_info.value.status_code == 503
    repo.session.rollback.assert_awaited_once()
    assert fake_publisher.published_job_ids == []
    # Compensating action must remove inputs/{job_id}
    assert list((temp_storage_dir / "inputs").iterdir()) == []


@pytest.mark.asyncio
async def test_try_on_service_concurrent_idempotency_integrity_error_returns_winner(
    image_service: ImageService,
    temp_storage_dir: Path,
    fake_publisher: FakeTaskPublisher,
):
    repo = _make_mock_job_repository()
    winner_job = _make_fake_job(idempotency_key="race-key")
    # First call (precheck) returns None; second call (after IntegrityError) returns winner_job
    repo.get_by_idempotency_key.side_effect = [None, winner_job]
    repo.create_job.side_effect = IntegrityError("INSERT", {}, Exception("duplicate key"))

    service = TryOnService(
        job_repository=repo,
        image_service=image_service,
        publisher=fake_publisher,
    )

    person_file = make_upload_file(create_synthetic_image_bytes("JPEG"), "person.jpg")
    garment_file = make_upload_file(create_synthetic_image_bytes("PNG"), "garment.png")

    result = await service.create_try_on_job(
        person_image=person_file,
        garment_image=garment_file,
        idempotency_key="race-key",
    )

    assert result.id == winner_job.id
    repo.session.rollback.assert_awaited_once()
    assert fake_publisher.published_job_ids == []
    assert list((temp_storage_dir / "inputs").iterdir()) == []


@pytest.mark.asyncio
async def test_try_on_service_publish_failure_marks_job_failed(
    image_service: ImageService,
    fake_publisher: FakeTaskPublisher,
):
    repo = _make_mock_job_repository()
    created_job = _make_fake_job(status=JobStatus.QUEUED)
    repo.create_job.return_value = created_job

    fake_publisher.should_fail = True
    fake_publisher.failure_message = "Redis broker unreachable"

    service = TryOnService(
        job_repository=repo,
        image_service=image_service,
        publisher=fake_publisher,
    )

    person_file = make_upload_file(create_synthetic_image_bytes("JPEG"), "person.jpg")
    garment_file = make_upload_file(create_synthetic_image_bytes("PNG"), "garment.png")

    with pytest.raises(QueuePublishError) as exc_info:
        await service.create_try_on_job(person_image=person_file, garment_image=garment_file)

    assert exc_info.value.error_code == ErrorCode.QUEUE_PUBLISH_ERROR
    assert exc_info.value.status_code == 503
    repo.mark_failed.assert_awaited_once_with(
        job_id=created_job.id,
        error_code=ErrorCode.QUEUE_PUBLISH_ERROR.value,
        error_message="Redis broker unreachable",
        increment_retry=False,
        terminal=True,
    )


@pytest.mark.asyncio
async def test_job_service_get_job_found_and_not_found():
    repo = _make_mock_job_repository()
    service = JobService(job_repository=repo)

    target_id = uuid.uuid4()
    expected_job = _make_fake_job(job_id=target_id)
    repo.get_by_id.return_value = expected_job

    found = await service.get_job(target_id)
    assert found.id == target_id

    repo.get_by_id.return_value = None
    missing_id = uuid.uuid4()
    with pytest.raises(JobNotFoundError) as exc_info:
        await service.get_job(missing_id)

    assert exc_info.value.error_code == ErrorCode.JOB_NOT_FOUND
    assert exc_info.value.status_code == 404
    assert exc_info.value.details == {"job_id": str(missing_id)}


@pytest.mark.asyncio
async def test_celery_task_publisher_success_and_error():
    mock_celery_client = MagicMock()
    publisher = CeleryTaskPublisher(
        task_name="worker.generate_try_on",
        celery_client=mock_celery_client,
    )
    job_id = uuid.uuid4()

    await publisher.publish_try_on_job(job_id)
    mock_celery_client.send_task.assert_called_once_with(
        "worker.generate_try_on",
        args=[str(job_id)],
    )

    mock_celery_client.send_task.side_effect = RuntimeError("Broker connection refused")
    with pytest.raises(QueuePublishError) as exc_info:
        await publisher.publish_try_on_job(job_id)
    assert exc_info.value.error_code == ErrorCode.QUEUE_PUBLISH_ERROR
    assert exc_info.value.details == {"job_id": str(job_id)}


def test_job_response_from_orm_job_mapping():
    job_id = uuid.uuid4()
    succeeded_job = _make_fake_job(
        job_id=job_id,
        status=JobStatus.SUCCEEDED,
        result_image_path=f"outputs/{job_id}/result.jpg",
    )
    dto = JobResponse.from_orm_job(succeeded_job)
    assert dto.job_id == job_id
    assert dto.status == JobStatus.SUCCEEDED
    assert dto.result_image_url == f"/api/v1/try-ons/{job_id}/image"
    assert dto.error is None

    failed_job = _make_fake_job(
        job_id=job_id,
        status=JobStatus.FAILED,
        error_code="QUEUE_PUBLISH_ERROR",
        error_message="Redis timeout",
    )
    failed_dto = JobResponse.from_orm_job(failed_job)
    assert failed_dto.status == JobStatus.FAILED
    assert failed_dto.result_image_url is None
    assert failed_dto.error is not None
    assert failed_dto.error.error_code == "QUEUE_PUBLISH_ERROR"
    assert failed_dto.error.message == "Redis timeout"
