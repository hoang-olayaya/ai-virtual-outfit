from pathlib import Path
from unittest.mock import patch
import uuid
import httpx
import pytest
from sqlalchemy import func, select
from sqlalchemy.exc import SQLAlchemyError

from app.core.errors import ErrorCode
from app.models.try_on_job import JobStatus, TryOnJob
from app.queue.publisher import FakeTaskPublisher
from app.repositories.job_repository import JobRepository
from tests.conftest import InMemoryJobRepository, create_synthetic_image_bytes


async def _count_jobs(repo: JobRepository) -> int:
    if isinstance(repo, InMemoryJobRepository):
        return await repo.count_jobs()
    stmt = select(func.count()).select_from(TryOnJob)
    result = await repo.session.execute(stmt)
    return int(result.scalar_one())


@pytest.mark.asyncio
async def test_post_create_try_on_and_get_status_happy_path(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    temp_storage_dir: Path,
    fake_publisher: FakeTaskPublisher,
):
    """
    T01 / B03 core integration flow:
    1. POST /api/v1/try-ons with 2 valid images -> 202 Accepted + job_id.
    2. Input files saved under inputs/{job_id}/person.jpg and garment.png.
    3. Database row created with status='queued'.
    4. FakeTaskPublisher recorded [job_id].
    5. GET /api/v1/try-ons/{job_id} -> 200 OK with status='queued'.
    """
    person_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(300, 400))
    garment_bytes = create_synthetic_image_bytes(fmt="PNG", size=(256, 256))

    response = await async_api_client.post(
        "/api/v1/try-ons",
        files={
            "person_image": ("person.jpg", person_bytes, "image/jpeg"),
            "garment_image": ("garment.png", garment_bytes, "image/png"),
        },
    )

    assert response.status_code == 202
    data = response.json()
    job_id = uuid.UUID(data["job_id"])
    assert data["status"] == "queued"
    assert data["result_image_url"] is None
    assert data["error"] is None
    assert data["is_saved"] is False
    assert data["created_at"] is not None

    # Verify stored files on shared volume
    assert (temp_storage_dir / "inputs" / str(job_id) / "person.jpg").read_bytes() == person_bytes
    assert (temp_storage_dir / "inputs" / str(job_id) / "garment.png").read_bytes() == garment_bytes

    # Verify task published to queue
    assert fake_publisher.published_job_ids == [job_id]

    # Poll GET /api/v1/try-ons/{job_id}
    get_resp = await async_api_client.get(f"/api/v1/try-ons/{job_id}")
    assert get_resp.status_code == 200
    status_data = get_resp.json()
    assert status_data["job_id"] == str(job_id)
    assert status_data["status"] == "queued"

    # Simulate worker completing the job -> GET status should include result_image_url
    await api_job_repository.claim_job(job_id)
    await api_job_repository.mark_succeeded(
        job_id, result_image_path=f"outputs/{job_id}/result.jpg"
    )
    await api_job_repository.session.commit()

    succeeded_resp = await async_api_client.get(f"/api/v1/try-ons/{job_id}")
    assert succeeded_resp.status_code == 200
    succeeded_data = succeeded_resp.json()
    assert succeeded_data["status"] == "succeeded"
    assert succeeded_data["result_image_url"] == f"/api/v1/try-ons/{job_id}/image"
    assert succeeded_data["completed_at"] is not None


@pytest.mark.asyncio
async def test_post_missing_person_or_garment_image_rejects_cleanly(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    temp_storage_dir: Path,
    fake_publisher: FakeTaskPublisher,
):
    """
    T02: Missing person_image or garment_image -> 400 MISSING_INPUT_IMAGE,
    no DB job created, no orphan files on disk, no queue task published.
    """
    valid_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(200, 200))

    # Missing garment_image
    resp1 = await async_api_client.post(
        "/api/v1/try-ons",
        files={"person_image": ("person.jpg", valid_bytes, "image/jpeg")},
    )
    assert resp1.status_code == 400
    body1 = resp1.json()
    assert body1["error_code"] == ErrorCode.MISSING_INPUT_IMAGE.value
    assert body1["details"]["field"] == "garment_image"

    # Missing person_image
    resp2 = await async_api_client.post(
        "/api/v1/try-ons",
        files={"garment_image": ("garment.jpg", valid_bytes, "image/jpeg")},
    )
    assert resp2.status_code == 400
    body2 = resp2.json()
    assert body2["error_code"] == ErrorCode.MISSING_INPUT_IMAGE.value
    assert body2["details"]["field"] == "person_image"

    assert await _count_jobs(api_job_repository) == 0
    assert fake_publisher.published_job_ids == []
    assert list((temp_storage_dir / "inputs").iterdir()) == []


@pytest.mark.asyncio
async def test_post_spoofed_non_image_file_rejected(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    temp_storage_dir: Path,
    fake_publisher: FakeTaskPublisher,
):
    """
    T03: Non-image file disguised with .jpg extension -> 415 UNSUPPORTED_MEDIA_TYPE,
    no job created, no files written.
    """
    valid_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(200, 200))
    fake_bytes = b"This is plain text pretending to be a JPEG image"

    resp = await async_api_client.post(
        "/api/v1/try-ons",
        files={
            "person_image": ("person.jpg", valid_bytes, "image/jpeg"),
            "garment_image": ("spoofed.jpg", fake_bytes, "image/jpeg"),
        },
    )

    assert resp.status_code == 415
    body = resp.json()
    assert body["error_code"] == ErrorCode.UNSUPPORTED_MEDIA_TYPE.value
    assert body["details"]["field"] == "garment_image"
    assert await _count_jobs(api_job_repository) == 0
    assert fake_publisher.published_job_ids == []
    assert list((temp_storage_dir / "inputs").iterdir()) == []


@pytest.mark.asyncio
async def test_post_duplicate_idempotency_key_returns_same_job_without_duplicate_enqueue(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    fake_publisher: FakeTaskPublisher,
):
    """
    T10: Sending two POST requests with the same Idempotency-Key returns the same job_id,
    creates only 1 row in database, and publishes to queue only once.
    """
    person_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 256))
    garment_bytes = create_synthetic_image_bytes(fmt="PNG", size=(256, 256))
    headers = {"Idempotency-Key": "client-req-idemp-999"}

    resp1 = await async_api_client.post(
        "/api/v1/try-ons",
        headers=headers,
        files={
            "person_image": ("person.jpg", person_bytes, "image/jpeg"),
            "garment_image": ("garment.png", garment_bytes, "image/png"),
        },
    )
    assert resp1.status_code == 202
    job_id_1 = resp1.json()["job_id"]

    resp2 = await async_api_client.post(
        "/api/v1/try-ons",
        headers=headers,
        files={
            "person_image": ("person.jpg", person_bytes, "image/jpeg"),
            "garment_image": ("garment.png", garment_bytes, "image/png"),
        },
    )
    assert resp2.status_code == 202
    job_id_2 = resp2.json()["job_id"]

    assert job_id_1 == job_id_2
    assert await _count_jobs(api_job_repository) == 1
    assert len(fake_publisher.published_job_ids) == 1


@pytest.mark.asyncio
async def test_post_db_insert_failure_cleans_up_files_and_does_not_publish(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    temp_storage_dir: Path,
    fake_publisher: FakeTaskPublisher,
):
    """
    When database insert fails after input files were written to disk,
    TryOnService must remove 'inputs/{job_id}' and return 503 DATABASE_ERROR.
    """
    person_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 256))
    garment_bytes = create_synthetic_image_bytes(fmt="PNG", size=(256, 256))

    with patch.object(
        api_job_repository,
        "create_job",
        side_effect=SQLAlchemyError("Simulated PostgreSQL write failure"),
    ):
        resp = await async_api_client.post(
            "/api/v1/try-ons",
            files={
                "person_image": ("person.jpg", person_bytes, "image/jpeg"),
                "garment_image": ("garment.png", garment_bytes, "image/png"),
            },
        )

    assert resp.status_code == 503
    body = resp.json()
    assert body["error_code"] == ErrorCode.DATABASE_ERROR.value
    assert fake_publisher.published_job_ids == []
    assert list((temp_storage_dir / "inputs").iterdir()) == []


@pytest.mark.asyncio
async def test_post_fake_publisher_failure_marks_job_failed_in_db(
    async_api_client: httpx.AsyncClient,
    fake_publisher: FakeTaskPublisher,
):
    """
    T05: When queue publishing fails, POST returns 503 QUEUE_PUBLISH_ERROR (with job_id in details),
    and the job in database is transitioned to 'failed' so it never stays stuck in 'queued'.
    """
    person_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 256))
    garment_bytes = create_synthetic_image_bytes(fmt="PNG", size=(256, 256))

    fake_publisher.should_fail = True
    fake_publisher.failure_message = "Simulated Redis connection timeout"

    resp = await async_api_client.post(
        "/api/v1/try-ons",
        files={
            "person_image": ("person.jpg", person_bytes, "image/jpeg"),
            "garment_image": ("garment.png", garment_bytes, "image/png"),
        },
    )

    assert resp.status_code == 503
    body = resp.json()
    assert body["error_code"] == ErrorCode.QUEUE_PUBLISH_ERROR.value
    failed_job_id = body["details"]["job_id"]

    # Subsequent GET /api/v1/try-ons/{job_id} confirms job is in 'failed' state with error details
    status_resp = await async_api_client.get(f"/api/v1/try-ons/{failed_job_id}")
    assert status_resp.status_code == 200
    status_body = status_resp.json()
    assert status_body["status"] == JobStatus.FAILED.value
    assert status_body["error"]["error_code"] == ErrorCode.QUEUE_PUBLISH_ERROR.value
    assert "Simulated Redis connection timeout" in status_body["error"]["message"]
    assert status_body["completed_at"] is not None


@pytest.mark.asyncio
async def test_get_job_not_found_and_invalid_uuid(
    async_api_client: httpx.AsyncClient,
):
    unknown_id = uuid.uuid4()
    resp_404 = await async_api_client.get(f"/api/v1/try-ons/{unknown_id}")
    assert resp_404.status_code == 404
    body_404 = resp_404.json()
    assert body_404["error_code"] == ErrorCode.JOB_NOT_FOUND.value
    assert body_404["details"]["job_id"] == str(unknown_id)

    resp_422 = await async_api_client.get("/api/v1/try-ons/not-a-valid-uuid")
    assert resp_422.status_code == 422
    body_422 = resp_422.json()
    assert body_422["error_code"] == ErrorCode.INVALID_REQUEST.value
    assert "errors" in body_422["details"]
