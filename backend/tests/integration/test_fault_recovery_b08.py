import io
import os
from pathlib import Path
import time
import uuid
import pytest
from app.core.config import settings
from app.core.errors import ErrorCode
from app.core.logging import SecretMaskingFilter
from app.maintenance.cleanup_files import cleanup_storage_files
from app.maintenance.reconcile_jobs import reconcile_stale_jobs
from app.models.try_on_job import JobStatus
from app.workers.failure_handler import FailureHandler
from app.workers.tasks import execute_try_on_job


@pytest.mark.asyncio
async def test_t05_redis_publish_failure_recovers_cleanly(
    async_api_client, fake_publisher, job_repository
):
    """
    Scenario T05: Redis broker fails during task enqueue.
    API must return HTTP 503 and record QUEUE_PUBLISH_ERROR, never hanging in 'queued'.
    """
    fake_publisher.should_fail = True

    files = {
        "person_image": ("person.jpg", io.BytesIO(b"\xff\xd8\xff\xe0" + b"\x00" * 500), "image/jpeg"),
        "garment_image": ("garment.jpg", io.BytesIO(b"\xff\xd8\xff\xe0" + b"\x00" * 500), "image/jpeg"),
    }
    # Using synthetic valid images from helper
    from tests.conftest import create_synthetic_image_bytes

    valid_person = create_synthetic_image_bytes("JPEG")
    valid_garment = create_synthetic_image_bytes("JPEG")
    files = {
        "person_image": ("person.jpg", io.BytesIO(valid_person), "image/jpeg"),
        "garment_image": ("garment.jpg", io.BytesIO(valid_garment), "image/jpeg"),
    }

    response = await async_api_client.post("/api/v1/try-ons", files=files)
    assert response.status_code == 503
    payload = response.json()
    assert payload["error_code"] == ErrorCode.QUEUE_PUBLISH_ERROR.value

    # Verify that if any job was recorded, it is marked 'failed', not 'queued'
    job_id_str = payload.get("details", {}).get("job_id")
    if job_id_str:
        job = await job_repository.get_by_id(uuid.UUID(job_id_str))
        assert job is not None
        assert job.status == JobStatus.FAILED
        assert job.error_code == ErrorCode.QUEUE_PUBLISH_ERROR.value


@pytest.mark.asyncio
async def test_t06_worker_interrupted_reconciled_and_resumed(
    job_repository, image_service, fake_ai_provider, fake_publisher
):
    """
    Scenario T06: Worker process interrupted while job was in 'processing' state.
    Reconciler detects stale job, resets to 'queued', and a subsequent worker run resumes it.
    """
    from tests.conftest import create_synthetic_image_bytes
    from app.services.upload_validator import ValidatedImage

    # 1. Store initial inputs and create job in 'processing' state
    job_id = uuid.uuid4()
    p_bytes = create_synthetic_image_bytes("JPEG")
    g_bytes = create_synthetic_image_bytes("JPEG")
    val_p = await image_service.validator.validate_bytes(p_bytes, field_name="person_image")
    val_g = await image_service.validator.validate_bytes(g_bytes, field_name="garment_image")
    stored = await image_service.store_input_images(job_id=job_id, person_image=val_p, garment_image=val_g)

    job = await job_repository.create_job(
        person_image_path=stored.person_image_path,
        garment_image_path=stored.garment_image_path,
        job_id=job_id,
    )
    # Simulate worker claiming job then crashing
    await job_repository.claim_job(job_id)
    # Backdate updated_at so it qualifies as stale
    from datetime import datetime, timedelta, timezone
    job.updated_at = datetime.now(timezone.utc) - timedelta(seconds=400)

    # 2. Run reconciliation
    report = await reconcile_stale_jobs(
        job_repository=job_repository,
        publisher=fake_publisher,
        stale_threshold_seconds=300,
    )
    assert report.stale_jobs_requeued == 1

    # 3. New worker executes resumed job
    outcome = await execute_try_on_job(
        job_id=job_id,
        job_repository=job_repository,
        image_service=image_service,
        ai_provider=fake_ai_provider,
        allow_processing_resume=True,
    )
    assert outcome.status == JobStatus.SUCCEEDED.value
    rechecked = await job_repository.get_by_id(job_id)
    assert rechecked.status == JobStatus.SUCCEEDED


@pytest.mark.asyncio
async def test_t10_duplicate_try_on_requests_same_idempotency_key(
    async_api_client, fake_publisher
):
    """
    Scenario T10: User submits duplicate Try On requests with identical Idempotency-Key.
    Must return 202 with identical job_id and create only one job.
    """
    from tests.conftest import create_synthetic_image_bytes

    valid_person = create_synthetic_image_bytes("JPEG")
    valid_garment = create_synthetic_image_bytes("JPEG")
    files1 = {
        "person_image": ("person.jpg", io.BytesIO(valid_person), "image/jpeg"),
        "garment_image": ("garment.jpg", io.BytesIO(valid_garment), "image/jpeg"),
    }
    files2 = {
        "person_image": ("person.jpg", io.BytesIO(valid_person), "image/jpeg"),
        "garment_image": ("garment.jpg", io.BytesIO(valid_garment), "image/jpeg"),
    }
    headers = {"Idempotency-Key": "req-idem-unique-12345"}

    res1 = await async_api_client.post("/api/v1/try-ons", files=files1, headers=headers)
    assert res1.status_code == 202
    job_id_1 = res1.json()["job_id"]

    res2 = await async_api_client.post("/api/v1/try-ons", files=files2, headers=headers)
    assert res2.status_code == 202
    job_id_2 = res2.json()["job_id"]

    assert job_id_1 == job_id_2, "Duplicate request with same idempotency key must return same job_id"


@pytest.mark.asyncio
async def test_t10_invalid_idempotency_key_rejected(async_api_client):
    """Scenario T10: Idempotency-Key containing control characters or exceeding 255 chars is rejected."""
    from tests.conftest import create_synthetic_image_bytes

    valid_person = create_synthetic_image_bytes("JPEG")
    valid_garment = create_synthetic_image_bytes("JPEG")
    files = {
        "person_image": ("person.jpg", io.BytesIO(valid_person), "image/jpeg"),
        "garment_image": ("garment.jpg", io.BytesIO(valid_garment), "image/jpeg"),
    }

    # Control char \x00
    res_ctrl = await async_api_client.post(
        "/api/v1/try-ons",
        files=files,
        headers={"Idempotency-Key": "bad\x00key"},
    )
    assert res_ctrl.status_code == 400
    assert res_ctrl.json()["error_code"] == ErrorCode.INVALID_IDEMPOTENCY_KEY.value

    # Over 255 chars
    res_long = await async_api_client.post(
        "/api/v1/try-ons",
        files=files,
        headers={"Idempotency-Key": "k" * 256},
    )
    assert res_long.status_code == 400
    assert res_long.json()["error_code"] == ErrorCode.INVALID_IDEMPOTENCY_KEY.value


@pytest.mark.asyncio
async def test_t12_orphan_storage_dir_reclaimed_after_delete_failure(
    storage_adapter, job_repository, temp_storage_dir
):
    """
    Scenario T12: A saved job is deleted from database, but disk removal encountered an error
    leaving an orphan folder. The Volume Sweeper detects and safely purges it.
    """
    orphan_id = uuid.uuid4()
    orphan_input_dir = temp_storage_dir / "inputs" / str(orphan_id)
    orphan_input_dir.mkdir(parents=True, exist_ok=True)
    (orphan_input_dir / "person.jpg").write_bytes(b"image bytes")

    orphan_output_dir = temp_storage_dir / "outputs" / str(orphan_id)
    orphan_output_dir.mkdir(parents=True, exist_ok=True)
    (orphan_output_dir / "result.jpg").write_bytes(b"result bytes")

    # Backdate mtime beyond grace period (e.g. 20 minutes ago)
    twenty_mins_ago = time.time() - 1200
    os.utime(orphan_input_dir, (twenty_mins_ago, twenty_mins_ago))
    os.utime(orphan_output_dir, (twenty_mins_ago, twenty_mins_ago))

    report = await cleanup_storage_files(
        storage=storage_adapter,
        job_repository=job_repository,
        grace_period_seconds=900,
    )

    assert report.orphan_dirs_deleted == 2
    assert not orphan_input_dir.exists()
    assert not orphan_output_dir.exists()


@pytest.mark.asyncio
async def test_privacy_headers_on_media_endpoints(
    async_api_client, job_repository, temp_storage_dir
):
    """
    NFR-07: Media endpoints must serve Cache-Control: private, no-cache, no-store, must-revalidate.
    """
    from tests.conftest import create_synthetic_image_bytes

    job_id = uuid.uuid4()
    # Create input and output files on disk
    inputs_dir = temp_storage_dir / "inputs" / str(job_id)
    inputs_dir.mkdir(parents=True, exist_ok=True)
    person_file = inputs_dir / "person.jpg"
    person_file.write_bytes(create_synthetic_image_bytes("JPEG"))

    outputs_dir = temp_storage_dir / "outputs" / str(job_id)
    outputs_dir.mkdir(parents=True, exist_ok=True)
    result_file = outputs_dir / "result.jpg"
    result_file.write_bytes(create_synthetic_image_bytes("JPEG"))

    # Create succeeded job in repository
    job = await job_repository.create_job(
        person_image_path=f"inputs/{job_id}/person.jpg",
        garment_image_path=f"inputs/{job_id}/person.jpg",
        job_id=job_id,
    )
    job.status = JobStatus.SUCCEEDED
    job.result_image_path = f"outputs/{job_id}/result.jpg"

    # Test GET result image
    res_img = await async_api_client.get(f"/api/v1/try-ons/{job_id}/image")
    assert res_img.status_code == 200
    cc = res_img.headers.get("Cache-Control", "")
    assert "private" in cc
    assert "no-cache" in cc
    assert "no-store" in cc
    assert "must-revalidate" in cc

    # Test GET input image
    res_input = await async_api_client.get(f"/api/v1/try-ons/{job_id}/inputs/person")
    assert res_input.status_code == 200
    cc_input = res_input.headers.get("Cache-Control", "")
    assert "private" in cc_input
    assert "no-cache" in cc_input
    assert "no-store" in cc_input
    assert "must-revalidate" in cc_input


@pytest.mark.asyncio
async def test_secret_scrubbing_in_failure_handler(job_repository, monkeypatch):
    """
    Security check: Ensure sensitive API keys (e.g. FAL_KEY) are NEVER stored in error_message.
    """
    fake_secret_key = "fal_secret_key_1234567890abcdef"
    monkeypatch.setattr(settings, "FAL_KEY", fake_secret_key)

    job = await job_repository.create_job(
        person_image_path="inputs/p.jpg",
        garment_image_path="inputs/g.jpg",
    )
    failure_handler = FailureHandler(job_repository, max_retries=1)

    # Simulate exception containing the raw secret key
    leaky_error = RuntimeError(f"Connection failed to fal.ai using authorization: Key {fake_secret_key}")
    decision = await failure_handler.handle_failure(job.id, leaky_error)

    assert fake_secret_key not in decision.error_message
    assert "******" in decision.error_message

    rechecked = await job_repository.get_by_id(job.id)
    assert fake_secret_key not in rechecked.error_message
    assert "******" in rechecked.error_message
