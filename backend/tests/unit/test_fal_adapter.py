import json
from typing import Any, Dict, List
import uuid
import httpx
import pytest
from app.core.errors import ErrorCode
from app.integrations.ai_provider import (
    AIProvider,
    PermanentAIProviderError,
    TransientAIProviderError,
)
from app.integrations.fal_adapter import FalAdapter
from app.services.upload_validator import UploadValidator
from tests.conftest import create_synthetic_image_bytes


def test_fal_adapter_satisfies_ai_provider_protocol():
    """Verify FalAdapter conforms to AIProvider runtime protocol."""
    adapter = FalAdapter(api_key="test-fal-key")
    assert isinstance(adapter, AIProvider)


def test_fal_adapter_missing_or_blank_api_key_raises_permanent_error():
    """Missing or whitespace-only FAL_KEY must raise non-retryable PermanentAIProviderError."""
    job_id = uuid.uuid4()
    valid_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(200, 200))

    for bad_key in ("", "   "):
        adapter = FalAdapter(api_key=bad_key)
        with pytest.raises(PermanentAIProviderError) as exc_info:
            adapter.generate_try_on(job_id, valid_bytes, valid_bytes)
        assert exc_info.value.retryable is False
        assert exc_info.value.error_code == ErrorCode.AI_PROVIDER_ERROR.value
        assert exc_info.value.provider_name == "fal"


def test_fal_adapter_rejects_corrupted_or_empty_input_images_before_network():
    """Corrupted or empty input bytes must be rejected locally with 0 HTTP requests."""
    requests_made: List[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests_made.append(request)
        return httpx.Response(200, json={})

    client = httpx.Client(transport=httpx.MockTransport(handler))
    adapter = FalAdapter(api_key="test-key", http_client=client)
    job_id = uuid.uuid4()
    valid_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(200, 200))

    with pytest.raises(PermanentAIProviderError) as exc_empty:
        adapter.generate_try_on(job_id, b"", valid_bytes)
    assert exc_empty.value.retryable is False
    assert exc_empty.value.error_code == ErrorCode.CORRUPTED_IMAGE.value

    with pytest.raises(PermanentAIProviderError) as exc_non_img:
        adapter.generate_try_on(job_id, valid_bytes, b"not-an-image")
    assert exc_non_img.value.retryable is False
    assert exc_non_img.value.error_code == ErrorCode.UNSUPPORTED_MEDIA_TYPE.value

    with pytest.raises(PermanentAIProviderError) as exc_corrupt:
        adapter.generate_try_on(
            job_id, valid_bytes, valid_bytes[: len(valid_bytes) // 2]
        )
    assert exc_corrupt.value.retryable is False
    assert exc_corrupt.value.error_code == ErrorCode.CORRUPTED_IMAGE.value
    assert len(requests_made) == 0


def test_fal_adapter_happy_path_cat_vton_upload_submit_poll_and_download():
    """
    Full happy path for default `fal-ai/cat-vton` model:
    1. Upload person (JPEG) & garment (PNG) via initiate + PUT.
    2. Submit inference payload with `human_image_url`, `garment_image_url`, `cloth_type`.
    3. Trigger `on_request_submitted` callback with `request_id`.
    4. Poll status (`IN_QUEUE` -> `IN_PROGRESS` -> `COMPLETED`).
    5. Fetch result payload (`{"image": {"url": ...}}`).
    6. Download result image bytes, validate with UploadValidator, and return AIProviderResult.
    """
    job_id = uuid.uuid4()
    person_bytes = create_synthetic_image_bytes(
        fmt="JPEG", size=(320, 480), color=(40, 80, 160)
    )
    garment_bytes = create_synthetic_image_bytes(
        fmt="PNG", size=(256, 256), color=(200, 50, 50)
    )
    synthesized_result_bytes = create_synthetic_image_bytes(
        fmt="PNG", size=(320, 480), color=(90, 140, 210)
    )

    upload_counter = 0
    poll_statuses = ["IN_QUEUE", "IN_PROGRESS", "COMPLETED"]
    poll_index = 0
    submitted_payloads: List[Dict[str, Any]] = []
    put_payloads: List[bytes] = []
    submitted_callbacks: List[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal upload_counter, poll_index
        url = str(request.url)

        if request.method == "POST" and "storage/upload/initiate" in url:
            assert request.headers.get("Authorization") == "Key secret-test-key"
            upload_counter += 1
            return httpx.Response(
                200,
                json={
                    "upload_url": f"https://storage.fal.media/put/{upload_counter}",
                    "file_url": f"https://v3.fal.media/files/input_{upload_counter}.img",
                },
            )

        if request.method == "PUT" and "storage.fal.media/put/" in url:
            put_payloads.append(request.content)
            return httpx.Response(200)

        if request.method == "POST" and url == "https://queue.fal.run/fal-ai/cat-vton":
            assert request.headers.get("Authorization") == "Key secret-test-key"
            submitted_payloads.append(json.loads(request.content.decode("utf-8")))
            return httpx.Response(
                200,
                json={
                    "request_id": "fal-req-cat-001",
                    "status_url": "https://queue.fal.run/fal-ai/cat-vton/requests/fal-req-cat-001/status",
                    "response_url": "https://queue.fal.run/fal-ai/cat-vton/requests/fal-req-cat-001",
                },
            )

        if (
            request.method == "GET"
            and url
            == "https://queue.fal.run/fal-ai/cat-vton/requests/fal-req-cat-001/status"
        ):
            status_val = poll_statuses[min(poll_index, len(poll_statuses) - 1)]
            poll_index += 1
            return httpx.Response(200, json={"status": status_val})

        if (
            request.method == "GET"
            and url
            == "https://queue.fal.run/fal-ai/cat-vton/requests/fal-req-cat-001"
        ):
            return httpx.Response(
                200,
                json={
                    "image": {
                        "url": "https://v3.fal.media/files/output/result_cat.png",
                        "content_type": "image/png",
                        "width": 320,
                        "height": 480,
                    }
                },
            )

        if (
            request.method == "GET"
            and url == "https://v3.fal.media/files/output/result_cat.png"
        ):
            return httpx.Response(
                200,
                content=synthesized_result_bytes,
                headers={"Content-Type": "image/png"},
            )

        return httpx.Response(404, json={"detail": f"Unhandled URL: {url}"})

    client = httpx.Client(transport=httpx.MockTransport(handler))
    adapter = FalAdapter(
        api_key="secret-test-key",
        model_id="fal-ai/cat-vton",
        cloth_type="upper",
        poll_interval_seconds=0.01,
        http_client=client,
        sleep_fn=lambda _: None,
    )

    result = adapter.generate_try_on(
        job_id=job_id,
        person_image_bytes=person_bytes,
        garment_image_bytes=garment_bytes,
        on_request_submitted=submitted_callbacks.append,
    )

    assert upload_counter == 2
    assert put_payloads == [person_bytes, garment_bytes]
    assert len(submitted_payloads) == 1
    assert submitted_payloads[0] == {
        "human_image_url": "https://v3.fal.media/files/input_1.img",
        "garment_image_url": "https://v3.fal.media/files/input_2.img",
        "cloth_type": "upper",
    }
    assert submitted_callbacks == ["fal-req-cat-001"]
    assert poll_index == 3

    assert result.provider_name == "fal"
    assert result.provider_request_id == "fal-req-cat-001"
    assert result.mime_type == "image/png"
    assert result.extension == ".png"
    assert result.image_bytes == synthesized_result_bytes

    validated = UploadValidator().validate_bytes_sync(result.image_bytes)
    assert validated.width == 320
    assert validated.height == 480


def test_fal_adapter_model_argument_mapping_fashn_leffa_and_idm_vton():
    """
    Verify schema builders and multi-segment `base_app_id` extraction for:
    - `fal-ai/fashn/tryon/v1.6` (`model_image`, `garment_image`, `category="auto"`, `images[0].url`)
    - `fal-ai/leffa/virtual-tryon` (`garment_type`)
    - `fal-ai/idm-vton` (`description`)
    """
    fashn_adapter = FalAdapter(
        api_key="key",
        model_id="fal-ai/fashn/tryon/v1.6",
    )
    assert fashn_adapter.base_app_id == "fal-ai/fashn"
    assert fashn_adapter.build_model_arguments("https://p.jpg", "https://g.jpg") == {
        "model_image": "https://p.jpg",
        "garment_image": "https://g.jpg",
        "category": "auto",
    }

    leffa_adapter = FalAdapter(
        api_key="key",
        model_id="fal-ai/leffa/virtual-tryon",
        cloth_type="lower",
    )
    assert leffa_adapter.base_app_id == "fal-ai/leffa"
    assert leffa_adapter.build_model_arguments("https://p.jpg", "https://g.jpg") == {
        "human_image_url": "https://p.jpg",
        "garment_image_url": "https://g.jpg",
        "garment_type": "lower_body",
    }

    idm_adapter = FalAdapter(
        api_key="key",
        model_id="fal-ai/idm-vton",
    )
    assert idm_adapter.base_app_id == "fal-ai/idm-vton"
    assert idm_adapter.build_model_arguments("https://p.jpg", "https://g.jpg") == {
        "human_image_url": "https://p.jpg",
        "garment_image_url": "https://g.jpg",
        "description": "Virtual try-on garment preview",
    }

    # Verify extract_result_image_url supports `images` list and nested `data` wrapper
    url_from_images = FalAdapter.extract_result_image_url(
        {"images": [{"url": "https://cdn.fashn.ai/out_0.jpg"}]}
    )
    assert url_from_images == "https://cdn.fashn.ai/out_0.jpg"

    url_from_nested = FalAdapter.extract_result_image_url(
        {"data": {"image": {"url": "https://v3.fal.media/nested.png"}}}
    )
    assert url_from_nested == "https://v3.fal.media/nested.png"


def test_fal_adapter_resumes_existing_request_id_without_duplicate_upload_or_submit():
    """
    Scenario T07 / T08:
    When `existing_request_id` is passed into `generate_try_on`, FalAdapter must NOT
    upload input images or submit a new paid inference request; it must directly poll
    status and download the result for `existing_request_id`.
    """
    job_id = uuid.uuid4()
    result_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 256))
    called_urls: List[tuple[str, str]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        called_urls.append((request.method, url))

        if url.endswith("/requests/existing-req-777/status"):
            return httpx.Response(200, json={"status": "COMPLETED"})
        if url.endswith("/requests/existing-req-777"):
            return httpx.Response(
                200,
                json={"image": {"url": "https://v3.fal.media/files/resumed.jpg"}},
            )
        if url == "https://v3.fal.media/files/resumed.jpg":
            return httpx.Response(200, content=result_bytes)
        return httpx.Response(500, json={"detail": f"Unexpected call: {url}"})

    client = httpx.Client(transport=httpx.MockTransport(handler))
    adapter = FalAdapter(
        api_key="secret-key",
        model_id="fal-ai/fashn/tryon/v1.6",
        http_client=client,
        sleep_fn=lambda _: None,
    )

    # Even if input bytes are empty on resume, adapter skips upload/submit
    res = adapter.generate_try_on(
        job_id=job_id,
        person_image_bytes=b"",
        garment_image_bytes=b"",
        existing_request_id="existing-req-777",
    )

    assert res.provider_request_id == "existing-req-777"
    assert res.image_bytes == result_bytes
    assert called_urls == [
        (
            "GET",
            "https://queue.fal.run/fal-ai/fashn/requests/existing-req-777/status",
        ),
        (
            "GET",
            "https://queue.fal.run/fal-ai/fashn/requests/existing-req-777",
        ),
        ("GET", "https://v3.fal.media/files/resumed.jpg"),
    ]


def test_fal_adapter_download_retries_on_transient_cdn_failure_without_rerunning_inference():
    """
    Scenario T08:
    If CDN download fails transiently (e.g. HTTP 503 then ReadTimeout) before succeeding,
    FalAdapter retries ONLY the GET download step and never re-submits inference.
    """
    job_id = uuid.uuid4()
    valid_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(200, 200))
    submit_count = 0
    download_attempts = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal submit_count, download_attempts
        url = str(request.url)

        if "storage/upload/initiate" in url:
            return httpx.Response(
                200,
                json={
                    "upload_url": "https://storage.fal.media/put/1",
                    "file_url": "https://v3.fal.media/in.jpg",
                },
            )
        if "storage.fal.media/put/" in url:
            return httpx.Response(200)
        if url == "https://queue.fal.run/fal-ai/cat-vton":
            submit_count += 1
            return httpx.Response(200, json={"request_id": "req-dl-retry"})
        if url.endswith("/requests/req-dl-retry/status"):
            return httpx.Response(200, json={"status": "COMPLETED"})
        if url.endswith("/requests/req-dl-retry"):
            return httpx.Response(
                200,
                json={"image": {"url": "https://v3.fal.media/out/flaky.jpg"}},
            )
        if url == "https://v3.fal.media/out/flaky.jpg":
            download_attempts += 1
            if download_attempts == 1:
                return httpx.Response(503, json={"detail": "CDN edge overloaded"})
            if download_attempts == 2:
                raise httpx.ReadTimeout("CDN read timed out")
            return httpx.Response(200, content=valid_bytes)

        return httpx.Response(404)

    client = httpx.Client(transport=httpx.MockTransport(handler))
    adapter = FalAdapter(
        api_key="test-key",
        download_max_retries=3,
        download_retry_backoff_seconds=0.01,
        http_client=client,
        sleep_fn=lambda _: None,
    )

    result = adapter.generate_try_on(job_id, valid_bytes, valid_bytes)
    assert submit_count == 1
    assert download_attempts == 3
    assert result.provider_request_id == "req-dl-retry"
    assert result.image_bytes == valid_bytes


def test_fal_adapter_poll_timeout_raises_transient_timeout_with_request_id():
    """
    Scenario T07:
    When polling exceeds `poll_timeout_seconds`, FalAdapter must raise TransientAIProviderError
    with `error_code=AI_PROVIDER_TIMEOUT` and `provider_request_id` populated so the worker
    can persist the request ID and resume without duplicate submission.
    """
    job_id = uuid.uuid4()
    clock_ticks = [0.0, 1.0, 2.5, 5.0]
    tick_idx = 0

    def fake_clock() -> float:
        nonlocal tick_idx
        val = clock_ticks[min(tick_idx, len(clock_ticks) - 1)]
        tick_idx += 1
        return val

    def handler(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if url.endswith("/status"):
            return httpx.Response(200, json={"status": "IN_PROGRESS"})
        return httpx.Response(500)

    client = httpx.Client(transport=httpx.MockTransport(handler))
    adapter = FalAdapter(
        api_key="test-key",
        poll_timeout_seconds=3.0,
        poll_interval_seconds=0.5,
        http_client=client,
        sleep_fn=lambda _: None,
        clock_fn=fake_clock,
    )

    with pytest.raises(TransientAIProviderError) as exc_info:
        adapter.generate_try_on(
            job_id=job_id,
            person_image_bytes=b"",
            garment_image_bytes=b"",
            existing_request_id="req-slow-999",
        )

    assert exc_info.value.retryable is True
    assert exc_info.value.error_code == ErrorCode.AI_PROVIDER_TIMEOUT.value
    assert exc_info.value.provider_name == "fal"
    assert exc_info.value.provider_request_id == "req-slow-999"


@pytest.mark.parametrize(
    "status_code,expected_exc_cls,expected_retryable,expected_code",
    [
        (429, TransientAIProviderError, True, ErrorCode.AI_PROVIDER_ERROR.value),
        (502, TransientAIProviderError, True, ErrorCode.AI_PROVIDER_ERROR.value),
        (503, TransientAIProviderError, True, ErrorCode.AI_PROVIDER_ERROR.value),
        (504, TransientAIProviderError, True, ErrorCode.AI_PROVIDER_TIMEOUT.value),
        (401, PermanentAIProviderError, False, ErrorCode.AI_PROVIDER_ERROR.value),
        (403, PermanentAIProviderError, False, ErrorCode.AI_PROVIDER_ERROR.value),
        (422, PermanentAIProviderError, False, ErrorCode.AI_PROVIDER_ERROR.value),
    ],
)
def test_fal_adapter_http_status_classification(
    status_code: int,
    expected_exc_cls: type,
    expected_retryable: bool,
    expected_code: str,
):
    """Verify HTTP error classification across transient (429/5xx) and permanent (401/403/422) codes."""
    job_id = uuid.uuid4()

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            status_code,
            json={"detail": f"Simulated HTTP {status_code}"},
        )

    client = httpx.Client(transport=httpx.MockTransport(handler))
    adapter = FalAdapter(api_key="secret-api-key-never-log", http_client=client)

    with pytest.raises(expected_exc_cls) as exc_info:
        adapter.generate_try_on(
            job_id=job_id,
            person_image_bytes=b"",
            garment_image_bytes=b"",
            existing_request_id="req-http-err",
        )

    assert exc_info.value.retryable is expected_retryable
    assert exc_info.value.error_code == expected_code
    assert exc_info.value.provider_request_id == "req-http-err"
    assert "secret-api-key-never-log" not in exc_info.value.message


def test_fal_adapter_queue_failed_and_invalid_output_handling():
    """
    Verify PermanentAIProviderError when:
    1. Queue status returns `"FAILED"`.
    2. Result payload is missing `image.url` / `images[0].url`.
    3. Downloaded image bytes from CDN are corrupted.
    """
    job_id = uuid.uuid4()

    # 1. Queue status FAILED
    client_failed = httpx.Client(
        transport=httpx.MockTransport(
            lambda req: httpx.Response(
                200,
                json={"status": "FAILED", "error": "Pose detection failed"},
            )
        )
    )
    adapter_failed = FalAdapter(api_key="key", http_client=client_failed)
    with pytest.raises(PermanentAIProviderError) as exc_failed:
        adapter_failed.generate_try_on(
            job_id, b"", b"", existing_request_id="req-fail-1"
        )
    assert exc_failed.value.retryable is False
    assert exc_failed.value.provider_request_id == "req-fail-1"
    assert "Pose detection failed" in exc_failed.value.message

    # 2. Missing URL in result payload
    def handler_bad_schema(req: httpx.Request) -> httpx.Response:
        if str(req.url).endswith("/status"):
            return httpx.Response(200, json={"status": "COMPLETED"})
        return httpx.Response(200, json={"unexpected_key": "no_url"})

    adapter_schema = FalAdapter(
        api_key="key",
        http_client=httpx.Client(transport=httpx.MockTransport(handler_bad_schema)),
    )
    with pytest.raises(PermanentAIProviderError) as exc_schema:
        adapter_schema.generate_try_on(
            job_id, b"", b"", existing_request_id="req-schema-2"
        )
    assert exc_schema.value.retryable is False
    assert exc_schema.value.provider_request_id == "req-schema-2"

    # 3. Corrupted bytes downloaded from CDN
    def handler_corrupt_cdn(req: httpx.Request) -> httpx.Response:
        url = str(req.url)
        if url.endswith("/status"):
            return httpx.Response(200, json={"status": "COMPLETED"})
        if url.endswith("/requests/req-corrupt-3"):
            return httpx.Response(
                200, json={"image": {"url": "https://v3.fal.media/bad.jpg"}}
            )
        return httpx.Response(200, content=b"not-a-valid-image-binary")

    adapter_corrupt = FalAdapter(
        api_key="key",
        http_client=httpx.Client(transport=httpx.MockTransport(handler_corrupt_cdn)),
    )
    with pytest.raises(PermanentAIProviderError) as exc_corrupt:
        adapter_corrupt.generate_try_on(
            job_id, b"", b"", existing_request_id="req-corrupt-3"
        )
    assert exc_corrupt.value.retryable is False
    assert exc_corrupt.value.provider_request_id == "req-corrupt-3"
