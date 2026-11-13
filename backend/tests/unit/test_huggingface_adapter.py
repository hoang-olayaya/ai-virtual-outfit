import io
from pathlib import Path
from typing import Any, Dict, List, Optional
import uuid
import httpx
from PIL import Image
import pytest
from gradio_client.exceptions import AppError, AuthenticationError
from app.core.errors import ErrorCode
from app.integrations.ai_provider import (
    AIProvider,
    PermanentAIProviderError,
    TransientAIProviderError,
)
from app.integrations.huggingface_adapter import HuggingFaceAdapter
from app.workers.tasks import build_default_ai_provider
from tests.conftest import create_synthetic_image_bytes


class _FakeGradioClient:
    def __init__(
        self,
        return_value: Any = None,
        exception: Optional[Exception] = None,
        captured_calls: Optional[List[Dict[str, Any]]] = None,
        on_predict: Optional[ Any] = None,
    ) -> None:
        self.return_value = return_value
        self.exception = exception
        self.captured_calls = captured_calls if captured_calls is not None else []
        self.on_predict = on_predict

    def predict(self, **kwargs: Any) -> Any:
        self.captured_calls.append(kwargs)
        if self.on_predict is not None:
            self.on_predict(kwargs)
        if self.exception is not None:
            raise self.exception
        return self.return_value


def test_huggingface_adapter_satisfies_ai_provider_protocol():
    """Verify HuggingFaceAdapter conforms to AIProvider runtime protocol."""
    adapter = HuggingFaceAdapter(hf_token="hf_test_token")
    assert isinstance(adapter, AIProvider)
    assert adapter.PROVIDER_NAME == "huggingface"
    assert adapter.space_id == "yisol/IDM-VTON"
    assert adapter.api_name == "/tryon"


def test_huggingface_adapter_rejects_invalid_or_empty_inputs_before_network():
    """Corrupted or empty input bytes must be rejected locally without instantiating Gradio Client."""
    factory_called = False

    def fake_factory(*args: Any, **kwargs: Any) -> Any:
        nonlocal factory_called
        factory_called = True
        return _FakeGradioClient()

    adapter = HuggingFaceAdapter(client_factory=fake_factory)
    job_id = uuid.uuid4()
    valid_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(256, 256))

    with pytest.raises(PermanentAIProviderError) as exc_empty:
        adapter.generate_try_on(job_id, b"", valid_bytes)
    assert exc_empty.value.retryable is False
    assert exc_empty.value.error_code == ErrorCode.CORRUPTED_IMAGE.value

    with pytest.raises(PermanentAIProviderError) as exc_bad_media:
        adapter.generate_try_on(job_id, valid_bytes, b"invalid-image-content")
    assert exc_bad_media.value.retryable is False
    assert exc_bad_media.value.error_code == ErrorCode.UNSUPPORTED_MEDIA_TYPE.value
    assert factory_called is False


def test_huggingface_adapter_happy_path_idm_vton(tmp_path: Path):
    """
    Full happy path for default `yisol/IDM-VTON` Space:
    - Validates person & garment inputs
    - Calls `on_request_submitted` callback with request_id
    - Passes IDM-VTON parameters (`dict`, `garm_img`, `garment_des`, `is_checked`, `is_checked_crop`, `denoise_steps`, `seed`, `api_name`)
    - Extracts first element from `(output_image_path, masked_image_path)` tuple
    - Validates output image and returns `AIProviderResult`
    """
    job_id = uuid.uuid4()
    person_bytes = create_synthetic_image_bytes(
        fmt="JPEG", size=(300, 400), color=(100, 120, 140)
    )
    garment_bytes = create_synthetic_image_bytes(
        fmt="PNG", size=(250, 300), color=(200, 50, 50)
    )
    output_bytes = create_synthetic_image_bytes(
        fmt="PNG", size=(300, 400), color=(40, 180, 90)
    )

    output_file = tmp_path / "idm_vton_out.png"
    masked_file = tmp_path / "idm_vton_mask.png"
    output_file.write_bytes(output_bytes)
    masked_file.write_bytes(output_bytes)

    captured_calls: List[Dict[str, Any]] = []
    submitted_ids: List[str] = []

    def fake_factory(space_id: str, **kwargs: Any) -> Any:
        assert space_id == "yisol/IDM-VTON"
        assert kwargs.get("hf_token") == "hf_free_token"
        return _FakeGradioClient(
            return_value=(str(output_file), str(masked_file)),
            captured_calls=captured_calls,
        )

    adapter = HuggingFaceAdapter(
        hf_token="hf_free_token",
        space_id="yisol/IDM-VTON",
        api_name="/tryon",
        garment_description="Short sleeve T-shirt",
        auto_mask=True,
        auto_crop=False,
        denoise_steps=30,
        seed=42,
        client_factory=fake_factory,
    )

    result = adapter.generate_try_on(
        job_id=job_id,
        person_image_bytes=person_bytes,
        garment_image_bytes=garment_bytes,
        on_request_submitted=submitted_ids.append,
    )

    assert len(submitted_ids) == 1
    assert submitted_ids[0].startswith(f"hf-{job_id.hex[:12]}-")
    assert len(captured_calls) == 1
    call_kwargs = captured_calls[0]
    assert call_kwargs["api_name"] == "/tryon"
    assert call_kwargs["garment_des"] == "Short sleeve T-shirt"
    assert call_kwargs["is_checked"] is True
    assert call_kwargs["is_checked_crop"] is False
    assert call_kwargs["denoise_steps"] == 30
    assert call_kwargs["seed"] == 42
    assert "background" in call_kwargs["dict"]
    assert "garm_img" in call_kwargs

    assert result.provider_name == "huggingface"
    assert result.provider_request_id == submitted_ids[0]
    assert result.image_bytes == output_bytes
    assert result.mime_type == "image/png"
    assert result.extension == ".png"


def test_huggingface_adapter_preserves_aspect_ratio_for_non_3_4_images(tmp_path: Path):
    """
    When input person_image is not 3:4 (e.g. 360x360 square), HuggingFaceAdapter must:
    1. Pad the input image sent to IDM-VTON to 3:4 (360x480) and pad garment_image to 3:4.
    2. When IDM-VTON returns a 768x1024 output image, un-pad and restore the output
       to the exact original (360, 360) dimensions so the person is never squashed.
    """
    job_id = uuid.uuid4()
    square_person = create_synthetic_image_bytes(
        fmt="JPEG", size=(360, 360), color=(90, 90, 90)
    )
    square_garment = create_synthetic_image_bytes(
        fmt="PNG", size=(300, 300), color=(180, 40, 40)
    )
    idm_vton_768x1024_out = create_synthetic_image_bytes(
        fmt="PNG", size=(768, 1024), color=(50, 120, 200)
    )

    output_file = tmp_path / "idm_768x1024.png"
    output_file.write_bytes(idm_vton_768x1024_out)

    sent_sizes: Dict[str, tuple[int, int]] = {}

    def inspect_predict(kwargs: Dict[str, Any]) -> None:
        person_file_data = kwargs["dict"]["background"]
        garment_file_data = kwargs["garm_img"]
        person_path = person_file_data["path"] if isinstance(person_file_data, dict) else getattr(person_file_data, "path", None)
        garment_path = garment_file_data["path"] if isinstance(garment_file_data, dict) else getattr(garment_file_data, "path", None)
        with Image.open(person_path) as p_img:
            sent_sizes["person"] = p_img.size
        with Image.open(garment_path) as g_img:
            sent_sizes["garment"] = g_img.size

    adapter = HuggingFaceAdapter(
        client_factory=lambda *a, **kw: _FakeGradioClient(
            return_value=(str(output_file), str(output_file)),
            on_predict=inspect_predict,
        )
    )

    result = adapter.generate_try_on(
        job_id=job_id,
        person_image_bytes=square_person,
        garment_image_bytes=square_garment,
    )

    # Sent images to IDM-VTON must be padded to exact 3:4 aspect ratio
    assert sent_sizes["person"] == (360, 480)
    assert sent_sizes["garment"] == (300, 400)

    # Restored output image must match original 360x360 square dimensions
    with Image.open(io.BytesIO(result.image_bytes)) as final_img:
        assert final_img.size == (360, 360)


def test_huggingface_adapter_classifies_queue_and_timeout_errors_as_transient():
    """QueueError, TimeoutException, and ZeroGPU quota messages must raise retryable TransientAIProviderError."""
    job_id = uuid.uuid4()
    valid_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(200, 200))

    # 1. Queue full AppError
    adapter_queue = HuggingFaceAdapter(
        client_factory=lambda *a, **kw: _FakeGradioClient(
            exception=AppError("Queue is full, please try again")
        )
    )
    with pytest.raises(TransientAIProviderError) as exc_queue:
        adapter_queue.generate_try_on(job_id, valid_bytes, valid_bytes)
    assert exc_queue.value.retryable is True

    # 1b. AuthenticationError -> PermanentAIProviderError
    adapter_auth = HuggingFaceAdapter(
        client_factory=lambda *a, **kw: _FakeGradioClient(
            exception=AuthenticationError("Invalid Hugging Face token")
        )
    )
    with pytest.raises(PermanentAIProviderError) as exc_auth:
        adapter_auth.generate_try_on(job_id, valid_bytes, valid_bytes)
    assert exc_auth.value.retryable is False

    # 2. httpx.ReadTimeout
    adapter_timeout = HuggingFaceAdapter(
        client_factory=lambda *a, **kw: _FakeGradioClient(
            exception=httpx.ReadTimeout("Read timed out waiting for Space")
        )
    )
    with pytest.raises(TransientAIProviderError) as exc_timeout:
        adapter_timeout.generate_try_on(job_id, valid_bytes, valid_bytes)
    assert exc_timeout.value.retryable is True
    assert exc_timeout.value.error_code == ErrorCode.AI_PROVIDER_TIMEOUT.value

    # 3. ZeroGPU quota AppError
    adapter_zerogpu = HuggingFaceAdapter(
        client_factory=lambda *a, **kw: _FakeGradioClient(
            exception=AppError("You have exceeded your ZeroGPU quota")
        )
    )
    with pytest.raises(TransientAIProviderError) as exc_zerogpu:
        adapter_zerogpu.generate_try_on(job_id, valid_bytes, valid_bytes)
    assert exc_zerogpu.value.retryable is True


def test_huggingface_adapter_build_default_ai_provider(monkeypatch: pytest.MonkeyPatch):
    """Verify `build_default_ai_provider` returns HuggingFaceAdapter when AI_PROVIDER='huggingface'."""
    from app.core.config import settings

    monkeypatch.setattr(settings, "AI_PROVIDER", "huggingface")
    monkeypatch.setattr(settings, "HF_SPACE_ID", "yisol/IDM-VTON")
    provider = build_default_ai_provider()
    assert isinstance(provider, HuggingFaceAdapter)
    assert provider.space_id == "yisol/IDM-VTON"
