import io
import json
from pathlib import Path
from typing import Any, Dict, List
from unittest.mock import AsyncMock, patch
import uuid
import httpx
from PIL import Image
import pytest

from app.core.config import settings
from app.core.errors import ErrorCode
from app.integrations.fal_adapter import FalAdapter
from app.models.try_on_job import JobStatus
from app.queue.publisher import FakeTaskPublisher
from app.repositories.job_repository import JobRepository
from app.services.image_service import ImageService
from app.workers.tasks import execute_try_on_job
from tests.conftest import create_synthetic_image_bytes


def _make_mock_fal_transport(
    expected_job_id: uuid.UUID,
    result_jpeg_bytes: bytes,
    fail_submit_network: bool = False,
    fail_polling_timeout: bool = False,
    fail_queue_status: bool = False,
    download_flaky_attempts: int = 0,
):
    upload_initiate_calls: List[httpx.Request] = []
    upload_put_calls: List[httpx.Request] = []
    submit_calls: List[httpx.Request] = []
    poll_calls: List[httpx.Request] = []
    download_calls: List[httpx.Request] = []
    download_attempt_counter = [0]

    req_id = f"mock-fal-{expected_job_id}"

    def handler(request: httpx.Request) -> httpx.Response:
        url_str = str(request.url)

        # 1. Upload initiate
        if "storage/upload/initiate" in url_str:
            upload_initiate_calls.append(request)
            data = json.loads(request.content.decode("utf-8"))
            fname = data.get("file_name", "file.jpg")
            return httpx.Response(
                200,
                json={
                    "upload_url": f"https://mock.storage.fal.run/upload/{fname}",
                    "file_url": f"https://cdn.fal.media/files/{fname}",
                },
            )

        # 2. Binary upload PUT
        if "mock.storage.fal.run/upload/" in url_str:
            upload_put_calls.append(request)
            return httpx.Response(200, text="OK")

        # 3. Queue submit
        if url_str.endswith(settings.FAL_MODEL_ID) and request.method == "POST":
            submit_calls.append(request)
            if fail_submit_network:
                raise httpx.ConnectTimeout("Network dropped before response from queue submit")
            return httpx.Response(
                200,
                json={
                    "request_id": req_id,
                    "status_url": f"https://queue.fal.run/{settings.FAL_MODEL_ID}/requests/{req_id}/status",
                    "response_url": f"https://queue.fal.run/{settings.FAL_MODEL_ID}/requests/{req_id}",
                },
            )

        # 4. Status poll
        if f"/requests/{req_id}/status" in url_str:
            poll_calls.append(request)
            if fail_polling_timeout:
                raise httpx.ReadTimeout("Polling connection timed out")
            if fail_queue_status:
                return httpx.Response(
                    200,
                    json={
                        "status": "FAILED",
                        "error": {"message": "Human silhouette was not detected in person image"},
                    },
                )
            # Normal completion
            return httpx.Response(
                200,
                json={
                    "status": "COMPLETED",
                    "response_url": f"https://queue.fal.run/{settings.FAL_MODEL_ID}/requests/{req_id}",
                },
            )

        # 5. Result payload fetch
        if url_str.endswith(f"/requests/{req_id}") and request.method == "GET":
            return httpx.Response(
                200,
                json={
                    "image": {
                        "url": f"https://cdn.fal.media/results/{req_id}.jpg",
                        "content_type": "image/jpeg",
                    }
                },
            )

        # 6. Result image download
        if f"/results/{req_id}.jpg" in url_str:
            download_calls.append(request)
            download_attempt_counter[0] += 1
            if download_attempt_counter[0] <= download_flaky_attempts:
                return httpx.Response(502, text="Bad Gateway (CDN edge glitch)")
            return httpx.Response(
                200,
                content=result_jpeg_bytes,
                headers={"Content-Type": "image/jpeg"},
            )

        return httpx.Response(404, text=f"Unhandled mock endpoint: {url_str}")

    tracking = {
        "upload_initiate_calls": upload_initiate_calls,
        "upload_put_calls": upload_put_calls,
        "submit_calls": submit_calls,
        "poll_calls": poll_calls,
        "download_calls": download_calls,
    }
    return httpx.MockTransport(handler), tracking


@pytest.mark.asyncio
async def test_real_worker_pipeline_happy_path_with_fal_adapter(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    image_service: ImageService,
    temp_storage_dir: Path,
):
    """
    Phase B06 Full Happy Path with FalAdapter:
    1. POST /api/v1/try-ons with 2 valid images -> 202 Accepted.
    2. Worker pipeline runs with FalAdapter (using httpx.MockTransport):
       - Uploads person & garment to CDN
       - Submits model inference
       - Early tracking callback persists request_id in PostgreSQL
       - Polls status -> COMPLETED
       - Downloads result image bytes
       - Validates and stores to 'outputs/{job_id}/result.jpg'
       - Transitions DB status to 'succeeded'
    3. GET /api/v1/try-ons/{job_id} -> status='succeeded', result_image_url set.
    4. GET /api/v1/try-ons/{job_id}/image -> returns valid JPEG bytes without re-running inference.
    """
    person_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(320, 480), color=(60, 120, 180))
    garment_bytes = create_synthetic_image_bytes(fmt="PNG", size=(200, 200), color=(180, 50, 70))
    expected_result_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(320, 480), color=(100, 200, 100))

    # 1. Create job via API
    resp = await async_api_client.post(
        "/api/v1/try-ons",
        files={
            "person_image": ("person.jpg", person_bytes, "image/jpeg"),
            "garment_image": ("garment.png", garment_bytes, "image/png"),
        },
    )
    assert resp.status_code == 202
    job_id = uuid.UUID(resp.json()["job_id"])

    # 2. Setup FalAdapter with MockTransport
    transport, tracking = _make_mock_fal_transport(job_id, expected_result_bytes)
    mock_client = httpx.Client(transport=transport)
    adapter = FalAdapter(
        api_key="test-mock-fal-key",
        http_client=mock_client,
        poll_interval_seconds=0.0,
    )

    # 3. Execute Worker Pipeline
    outcome = await execute_try_on_job(
        job_id=job_id,
        job_repository=api_job_repository,
        image_service=image_service,
        ai_provider=adapter,
    )

    assert outcome.status == JobStatus.SUCCEEDED.value
    assert outcome.provider_name == "fal"
    assert outcome.provider_request_id == f"mock-fal-{job_id}"
    assert outcome.result_image_path == f"outputs/{job_id}/result.jpg"
    assert (temp_storage_dir / "outputs" / str(job_id) / "result.jpg").is_file()

    # Verify HTTP calls made by FalAdapter
    assert len(tracking["upload_initiate_calls"]) == 2  # person + garment
    assert len(tracking["upload_put_calls"]) == 2
    assert len(tracking["submit_calls"]) == 1
    assert len(tracking["poll_calls"]) == 1
    assert len(tracking["download_calls"]) == 1

    # 4. Status API polling reflects succeeded
    status_resp = await async_api_client.get(f"/api/v1/try-ons/{job_id}")
    assert status_resp.status_code == 200
    status_data = status_resp.json()
    assert status_data["status"] == "succeeded"
    assert status_data["result_image_url"] == f"/api/v1/try-ons/{job_id}/image"

    # 5. Media API returns the saved result image without extra provider calls
    media_resp = await async_api_client.get(f"/api/v1/try-ons/{job_id}/image")
    assert media_resp.status_code == 200
    assert media_resp.headers["content-type"] == "image/jpeg"
    assert len(tracking["submit_calls"]) == 1  # No duplicate inference!


@pytest.mark.asyncio
async def test_real_worker_pipeline_timeout_and_idempotent_resume_scenario_t07(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    image_service: ImageService,
):
    """
    Scenario T07 Verification (fal.ai timeout & Idempotent Resume):
    - Attempt 1: Uploads & submits successfully, gets request_id='mock-fal-{job_id}',
      then polling times out with ReadTimeout -> TransientAIProviderError.
      Job records provider_request_id and remains status='processing', retry_count=1.
    - Attempt 2: Worker resumes on retry (allow_processing_resume=True).
      Inspects job.provider_request_id, passes existing_request_id into FalAdapter.
      FalAdapter SKIPS uploads and SKIPS submit -> Only polls and downloads!
      Zero duplicate inference calls!
    """
    person_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 256))
    garment_bytes = create_synthetic_image_bytes(fmt="PNG", size=(256, 256))
    result_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 256))

    post_resp = await async_api_client.post(
        "/api/v1/try-ons",
        files={
            "person_image": ("person.jpg", person_bytes, "image/jpeg"),
            "garment_image": ("garment.png", garment_bytes, "image/png"),
        },
    )
    job_id = uuid.UUID(post_resp.json()["job_id"])

    # Attempt 1: Transport configured to fail during polling
    transport_1, tracking_1 = _make_mock_fal_transport(
        job_id, result_bytes, fail_polling_timeout=True
    )
    client_1 = httpx.Client(transport=transport_1)
    adapter_1 = FalAdapter(api_key="test-key", http_client=client_1, poll_interval_seconds=0.0)

    outcome_1 = await execute_try_on_job(
        job_id=job_id,
        job_repository=api_job_repository,
        image_service=image_service,
        ai_provider=adapter_1,
        max_retries=2,
    )

    assert outcome_1.should_retry is True
    assert outcome_1.status == JobStatus.PROCESSING.value
    assert outcome_1.retry_count == 1
    assert outcome_1.error_code == ErrorCode.AI_PROVIDER_TIMEOUT.value

    # Verify provider tracking info was safely persisted to PostgreSQL on failure
    db_job = await api_job_repository.get_by_id(job_id)
    assert db_job is not None
    assert db_job.provider_request_id == f"mock-fal-{job_id}"
    assert len(tracking_1["submit_calls"]) == 1

    # Attempt 2: Transport configured to succeed on poll
    transport_2, tracking_2 = _make_mock_fal_transport(
        job_id, result_bytes, fail_polling_timeout=False
    )
    client_2 = httpx.Client(transport=transport_2)
    adapter_2 = FalAdapter(api_key="test-key", http_client=client_2, poll_interval_seconds=0.0)

    outcome_2 = await execute_try_on_job(
        job_id=job_id,
        job_repository=api_job_repository,
        image_service=image_service,
        ai_provider=adapter_2,
        max_retries=2,
        allow_processing_resume=True,
    )

    assert outcome_2.status == JobStatus.SUCCEEDED.value
    assert outcome_2.retry_count == 1

    # Crucial Verification of Zero Duplicate Submission:
    # Attempt 2 must have made 0 upload initiate calls and 0 queue submit calls!
    assert len(tracking_2["upload_initiate_calls"]) == 0
    assert len(tracking_2["upload_put_calls"]) == 0
    assert len(tracking_2["submit_calls"]) == 0
    assert len(tracking_2["poll_calls"]) == 1
    assert len(tracking_2["download_calls"]) == 1


@pytest.mark.asyncio
async def test_real_worker_pipeline_submit_indeterminate_network_drop(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    image_service: ImageService,
):
    """
    Verify handling of indeterminate network failure at queue submit:
    When network fails before response is received, error is classified as
    AI_PROVIDER_SUBMIT_INDETERMINATE without a provider_request_id.
    """
    person_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 256))
    garment_bytes = create_synthetic_image_bytes(fmt="PNG", size=(256, 256))
    result_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 256))

    post_resp = await async_api_client.post(
        "/api/v1/try-ons",
        files={
            "person_image": ("person.jpg", person_bytes, "image/jpeg"),
            "garment_image": ("garment.png", garment_bytes, "image/png"),
        },
    )
    job_id = uuid.UUID(post_resp.json()["job_id"])

    transport, tracking = _make_mock_fal_transport(
        job_id, result_bytes, fail_submit_network=True
    )
    client = httpx.Client(transport=transport)
    adapter = FalAdapter(api_key="test-key", http_client=client)

    outcome = await execute_try_on_job(
        job_id=job_id,
        job_repository=api_job_repository,
        image_service=image_service,
        ai_provider=adapter,
        max_retries=2,
    )

    assert outcome.should_retry is True
    assert outcome.status == JobStatus.PROCESSING.value
    assert outcome.error_code == ErrorCode.AI_PROVIDER_SUBMIT_INDETERMINATE.value

    db_job = await api_job_repository.get_by_id(job_id)
    assert db_job is not None
    assert db_job.provider_request_id is None


@pytest.mark.asyncio
async def test_real_worker_pipeline_download_retry_scenario_t08(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    image_service: ImageService,
):
    """
    Scenario T08 Verification (Decoupled CDN Download Retry):
    Model inference succeeds, but CDN result image download gets HTTP 502 on attempt 1.
    FalAdapter retries locally on attempt 2 and succeeds.
    Verify inference submit was called exactly ONCE throughout the job.
    """
    person_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 256))
    garment_bytes = create_synthetic_image_bytes(fmt="PNG", size=(256, 256))
    result_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 256))

    post_resp = await async_api_client.post(
        "/api/v1/try-ons",
        files={
            "person_image": ("person.jpg", person_bytes, "image/jpeg"),
            "garment_image": ("garment.png", garment_bytes, "image/png"),
        },
    )
    job_id = uuid.UUID(post_resp.json()["job_id"])

    # First download attempt fails with 502, second succeeds
    transport, tracking = _make_mock_fal_transport(
        job_id, result_bytes, download_flaky_attempts=1
    )
    client = httpx.Client(transport=transport)
    adapter = FalAdapter(
        api_key="test-key",
        http_client=client,
        download_max_retries=2,
        download_retry_backoff_seconds=0.0,
        poll_interval_seconds=0.0,
    )

    outcome = await execute_try_on_job(
        job_id=job_id,
        job_repository=api_job_repository,
        image_service=image_service,
        ai_provider=adapter,
    )

    assert outcome.status == JobStatus.SUCCEEDED.value
    assert len(tracking["submit_calls"]) == 1
    assert len(tracking["download_calls"]) == 2


@pytest.mark.asyncio
async def test_real_worker_pipeline_permanent_error_handling(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    image_service: ImageService,
):
    """
    When fal.ai queue status returns FAILED:
    - Worker marks job as terminal 'failed' with error_code='AI_PROVIDER_ERROR'.
    - should_retry=False.
    - provider_request_id is preserved in DB for auditing.
    - GET /image returns 409 RESULT_NOT_READY.
    """
    person_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 256))
    garment_bytes = create_synthetic_image_bytes(fmt="PNG", size=(256, 256))
    result_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 256))

    post_resp = await async_api_client.post(
        "/api/v1/try-ons",
        files={
            "person_image": ("person.jpg", person_bytes, "image/jpeg"),
            "garment_image": ("garment.png", garment_bytes, "image/png"),
        },
    )
    job_id = uuid.UUID(post_resp.json()["job_id"])

    transport, tracking = _make_mock_fal_transport(
        job_id, result_bytes, fail_queue_status=True
    )
    client = httpx.Client(transport=transport)
    adapter = FalAdapter(api_key="test-key", http_client=client, poll_interval_seconds=0.0)

    outcome = await execute_try_on_job(
        job_id=job_id,
        job_repository=api_job_repository,
        image_service=image_service,
        ai_provider=adapter,
    )

    assert outcome.should_retry is False
    assert outcome.status == JobStatus.FAILED.value
    assert outcome.error_code == ErrorCode.AI_PROVIDER_ERROR.value
    assert "silhouette was not detected" in (outcome.error_message or "")

    # Media endpoint rejects failed job
    media_resp = await async_api_client.get(f"/api/v1/try-ons/{job_id}/image")
    assert media_resp.status_code == 409


@pytest.mark.asyncio
async def test_real_worker_pipeline_storage_failure_safe_cleanup(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    image_service: ImageService,
):
    """
    When DB commit fails after storing result image:
    - Worker rolls back DB transaction.
    - Invokes cleanup_output_images safely without masking the original exception.
    - Records error in PostgreSQL.
    """
    person_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 256))
    garment_bytes = create_synthetic_image_bytes(fmt="PNG", size=(256, 256))
    result_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 256))

    post_resp = await async_api_client.post(
        "/api/v1/try-ons",
        files={
            "person_image": ("person.jpg", person_bytes, "image/jpeg"),
            "garment_image": ("garment.png", garment_bytes, "image/png"),
        },
    )
    job_id = uuid.UUID(post_resp.json()["job_id"])

    transport, _ = _make_mock_fal_transport(job_id, result_bytes)
    client = httpx.Client(transport=transport)
    adapter = FalAdapter(api_key="test-key", http_client=client, poll_interval_seconds=0.0)

    # Patch mark_succeeded to fail, simulating database crash at commit
    with patch.object(
        api_job_repository,
        "mark_succeeded",
        side_effect=RuntimeError("Simulated DB commit crash"),
    ):
        outcome = await execute_try_on_job(
            job_id=job_id,
            job_repository=api_job_repository,
            image_service=image_service,
            ai_provider=adapter,
        )

        assert outcome.status == JobStatus.FAILED.value
        assert "Simulated DB commit crash" in (outcome.error_message or "")

        # Verify output directory was cleaned up safely
        output_file = image_service.storage.resolve_safe_path(f"outputs/{job_id}/result.jpg")
        assert not output_file.exists()
