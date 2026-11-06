import io
from pathlib import Path
import uuid
import httpx
from PIL import Image
import pytest

from app.core.errors import ErrorCode
from app.integrations.fake_ai_provider import FakeAIProvider
from app.models.try_on_job import JobStatus
from app.queue.publisher import FakeTaskPublisher
from app.repositories.job_repository import JobRepository
from app.services.image_service import ImageService
from app.workers.tasks import execute_try_on_job
from tests.conftest import create_synthetic_image_bytes


@pytest.mark.asyncio
async def test_end_to_end_b04_pipeline_post_to_worker_to_result_media(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    image_service: ImageService,
    temp_storage_dir: Path,
    fake_publisher: FakeTaskPublisher,
    fake_ai_provider: FakeAIProvider,
):
    """
    Full B04 End-to-End Integration Flow:
    1. POST /api/v1/try-ons with 2 valid images -> 202 Accepted (status='queued').
    2. GET /api/v1/try-ons/{job_id}/image while 'queued' -> 409 RESULT_NOT_READY.
    3. Worker consumes job_id from queue, claims job ('processing'), reads inputs from
       shared volume, runs FakeAIProvider, writes 'outputs/{job_id}/result.jpg',
       and marks job 'succeeded' in DB.
    4. GET /api/v1/try-ons/{job_id} -> 200 OK (status='succeeded', result_image_url set).
    5. GET /api/v1/try-ons/{job_id}/image -> 200 OK with valid JPEG bytes and Content-Type.
    """
    person_bytes = create_synthetic_image_bytes(
        fmt="JPEG", size=(360, 480), color=(50, 100, 150)
    )
    garment_bytes = create_synthetic_image_bytes(
        fmt="PNG", size=(240, 240), color=(200, 50, 80)
    )

    # 1. Create try-on job via POST API
    post_resp = await async_api_client.post(
        "/api/v1/try-ons",
        files={
            "person_image": ("person.jpg", person_bytes, "image/jpeg"),
            "garment_image": ("garment.png", garment_bytes, "image/png"),
        },
    )
    assert post_resp.status_code == 202
    job_id = uuid.UUID(post_resp.json()["job_id"])
    assert fake_publisher.published_job_ids == [job_id]

    # 2. Requesting result media before worker finishes must return 409 RESULT_NOT_READY
    early_media_resp = await async_api_client.get(f"/api/v1/try-ons/{job_id}/image")
    assert early_media_resp.status_code == 409
    early_err = early_media_resp.json()
    assert early_err["error_code"] == ErrorCode.RESULT_NOT_READY.value
    assert early_err["details"]["status"] == JobStatus.QUEUED.value

    # 3. Execute worker task for the published job_id
    outcome = await execute_try_on_job(
        job_id=job_id,
        job_repository=api_job_repository,
        image_service=image_service,
        ai_provider=fake_ai_provider,
    )
    assert outcome.status == JobStatus.SUCCEEDED.value
    assert outcome.result_image_path == f"outputs/{job_id}/result.jpg"
    assert outcome.provider_name == "fake"
    assert outcome.provider_request_id == f"fake-req-{job_id}"
    assert (temp_storage_dir / "outputs" / str(job_id) / "result.jpg").is_file()

    # 4. Poll GET /api/v1/try-ons/{job_id} -> status='succeeded' + result_image_url
    status_resp = await async_api_client.get(f"/api/v1/try-ons/{job_id}")
    assert status_resp.status_code == 200
    status_json = status_resp.json()
    assert status_json["status"] == "succeeded"
    assert status_json["result_image_url"] == f"/api/v1/try-ons/{job_id}/image"
    assert status_json["completed_at"] is not None
    assert status_json["error"] is None

    # 5. Fetch result image via GET /api/v1/try-ons/{job_id}/image
    media_resp = await async_api_client.get(f"/api/v1/try-ons/{job_id}/image")
    assert media_resp.status_code == 200
    assert media_resp.headers["content-type"] == "image/jpeg"
    assert len(media_resp.content) > 0

    with Image.open(io.BytesIO(media_resp.content)) as out_img:
        assert out_img.format == "JPEG"
        assert out_img.size == (360, 480)

    # Ensure GET /image does not trigger additional AI inference calls
    assert fake_ai_provider.call_count == 1


@pytest.mark.asyncio
async def test_worker_duplicate_delivery_is_idempotent(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    image_service: ImageService,
    fake_ai_provider: FakeAIProvider,
):
    """
    If Redis/Celery delivers the same job_id twice after completion,
    JobGuard must skip the duplicate delivery without invoking the AI provider again.
    """
    person_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 256))
    garment_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 256))

    post_resp = await async_api_client.post(
        "/api/v1/try-ons",
        files={
            "person_image": ("person.jpg", person_bytes, "image/jpeg"),
            "garment_image": ("garment.jpg", garment_bytes, "image/jpeg"),
        },
    )
    job_id = uuid.UUID(post_resp.json()["job_id"])

    first_outcome = await execute_try_on_job(
        job_id=job_id,
        job_repository=api_job_repository,
        image_service=image_service,
        ai_provider=fake_ai_provider,
    )
    assert first_outcome.status == JobStatus.SUCCEEDED.value
    assert fake_ai_provider.call_count == 1

    # Second execution of the same job_id
    second_outcome = await execute_try_on_job(
        job_id=job_id,
        job_repository=api_job_repository,
        image_service=image_service,
        ai_provider=fake_ai_provider,
    )
    assert second_outcome.decision == "already_completed"
    assert second_outcome.status == JobStatus.SUCCEEDED.value
    assert fake_ai_provider.call_count == 1


@pytest.mark.asyncio
async def test_worker_transient_failure_then_retry_succeeds(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    image_service: ImageService,
):
    """
    Simulate a transient provider failure on attempt 1 followed by recovery on retry:
    - Attempt 1 fails with retryable=True -> status stays 'processing', retry_count=1, should_retry=True.
    - Attempt 2 (with allow_processing_resume=True) succeeds -> status='succeeded', result image downloadable.
    """
    person_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 256))
    garment_bytes = create_synthetic_image_bytes(fmt="PNG", size=(256, 256))

    post_resp = await async_api_client.post(
        "/api/v1/try-ons",
        files={
            "person_image": ("person.jpg", person_bytes, "image/jpeg"),
            "garment_image": ("garment.png", garment_bytes, "image/png"),
        },
    )
    job_id = uuid.UUID(post_resp.json()["job_id"])

    flaky_provider = FakeAIProvider(
        should_fail=True,
        retryable_failure=True,
        failure_error_code=ErrorCode.AI_PROVIDER_TIMEOUT.value,
        failure_message="Temporary provider timeout",
    )

    # Attempt 1 -> fails transiently
    outcome_1 = await execute_try_on_job(
        job_id=job_id,
        job_repository=api_job_repository,
        image_service=image_service,
        ai_provider=flaky_provider,
        max_retries=2,
    )
    assert outcome_1.should_retry is True
    assert outcome_1.status == JobStatus.PROCESSING.value
    assert outcome_1.retry_count == 1

    # Recovery on Attempt 2
    flaky_provider.should_fail = False
    outcome_2 = await execute_try_on_job(
        job_id=job_id,
        job_repository=api_job_repository,
        image_service=image_service,
        ai_provider=flaky_provider,
        max_retries=2,
        allow_processing_resume=True,
    )
    assert outcome_2.should_retry is False
    assert outcome_2.status == JobStatus.SUCCEEDED.value
    assert outcome_2.retry_count == 1

    media_resp = await async_api_client.get(f"/api/v1/try-ons/{job_id}/image")
    assert media_resp.status_code == 200
    assert media_resp.headers["content-type"] == "image/jpeg"


@pytest.mark.asyncio
async def test_worker_permanent_provider_failure_marks_job_failed_and_blocks_media(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    image_service: ImageService,
):
    """
    When FakeAIProvider fails with a permanent error:
    - Worker marks job status='failed' with error details.
    - GET /api/v1/try-ons/{job_id} returns status='failed' and error object.
    - GET /api/v1/try-ons/{job_id}/image returns 409 RESULT_NOT_READY.
    """
    person_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 256))
    garment_bytes = create_synthetic_image_bytes(fmt="PNG", size=(256, 256))

    post_resp = await async_api_client.post(
        "/api/v1/try-ons",
        files={
            "person_image": ("person.jpg", person_bytes, "image/jpeg"),
            "garment_image": ("garment.png", garment_bytes, "image/png"),
        },
    )
    job_id = uuid.UUID(post_resp.json()["job_id"])

    failing_provider = FakeAIProvider(
        should_fail=True,
        retryable_failure=False,
        failure_error_code=ErrorCode.AI_PROVIDER_ERROR.value,
        failure_message="Unable to detect person silhouette",
    )

    outcome = await execute_try_on_job(
        job_id=job_id,
        job_repository=api_job_repository,
        image_service=image_service,
        ai_provider=failing_provider,
    )
    assert outcome.should_retry is False
    assert outcome.status == JobStatus.FAILED.value
    assert outcome.error_code == ErrorCode.AI_PROVIDER_ERROR.value

    # Status API reflects terminal failure
    status_resp = await async_api_client.get(f"/api/v1/try-ons/{job_id}")
    assert status_resp.status_code == 200
    status_data = status_resp.json()
    assert status_data["status"] == "failed"
    assert status_data["result_image_url"] is None
    assert status_data["error"]["error_code"] == ErrorCode.AI_PROVIDER_ERROR.value
    assert "Unable to detect person silhouette" in status_data["error"]["message"]

    # Media endpoint rejects failed job with 409 RESULT_NOT_READY
    media_resp = await async_api_client.get(f"/api/v1/try-ons/{job_id}/image")
    assert media_resp.status_code == 409
    assert media_resp.json()["error_code"] == ErrorCode.RESULT_NOT_READY.value


@pytest.mark.asyncio
async def test_media_endpoint_returns_404_for_unknown_job_or_deleted_output_file(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    image_service: ImageService,
    fake_ai_provider: FakeAIProvider,
):
    """
    Verify 404 responses on GET /api/v1/try-ons/{job_id}/image:
    - Unknown job_id -> 404 JOB_NOT_FOUND.
    - Succeeded job whose output file was deleted from disk -> 404 IMAGE_NOT_FOUND.
    """
    missing_job_id = uuid.uuid4()
    resp_missing_job = await async_api_client.get(
        f"/api/v1/try-ons/{missing_job_id}/image"
    )
    assert resp_missing_job.status_code == 404
    assert resp_missing_job.json()["error_code"] == ErrorCode.JOB_NOT_FOUND.value

    # Create and complete a job, then remove its output file from storage
    person_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(200, 200))
    garment_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(200, 200))
    post_resp = await async_api_client.post(
        "/api/v1/try-ons",
        files={
            "person_image": ("person.jpg", person_bytes, "image/jpeg"),
            "garment_image": ("garment.jpg", garment_bytes, "image/jpeg"),
        },
    )
    job_id = uuid.UUID(post_resp.json()["job_id"])

    await execute_try_on_job(
        job_id=job_id,
        job_repository=api_job_repository,
        image_service=image_service,
        ai_provider=fake_ai_provider,
    )

    # Delete output directory to simulate missing file on disk
    await image_service.cleanup_output_images(job_id)

    resp_missing_file = await async_api_client.get(f"/api/v1/try-ons/{job_id}/image")
    assert resp_missing_file.status_code == 404
    assert resp_missing_file.json()["error_code"] == ErrorCode.IMAGE_NOT_FOUND.value

