import uuid
import pytest
from app.core.errors import ErrorCode
from app.integrations.ai_provider import (
    AIProvider,
    PermanentAIProviderError,
    TransientAIProviderError,
)
from app.integrations.fake_ai_provider import FakeAIProvider
from app.services.upload_validator import UploadValidator
from tests.conftest import create_synthetic_image_bytes


def test_fake_ai_provider_satisfies_protocol():
    """Verify FakeAIProvider conforms to AIProvider runtime protocol."""
    provider = FakeAIProvider(delay_seconds=0.0)
    assert isinstance(provider, AIProvider)


def test_fake_ai_provider_generates_valid_deterministic_image():
    """
    FakeAIProvider must accept valid person + garment bytes (JPEG/PNG/WEBP),
    return a valid JPEG result image that passes UploadValidator, and preserve
    person image dimensions.
    """
    provider = FakeAIProvider(delay_seconds=0.0)
    validator = UploadValidator()
    job_id = uuid.uuid4()

    person_bytes = create_synthetic_image_bytes(
        fmt="JPEG", size=(320, 480), color=(40, 80, 160)
    )
    garment_bytes = create_synthetic_image_bytes(
        fmt="PNG", size=(200, 200), color=(220, 60, 60)
    )

    result1 = provider.generate_try_on(
        job_id=job_id,
        person_image_bytes=person_bytes,
        garment_image_bytes=garment_bytes,
    )
    assert result1.provider_name == "fake"
    assert result1.provider_request_id == f"fake-req-{job_id}"
    assert result1.mime_type == "image/jpeg"
    assert result1.extension == ".jpg"
    assert provider.call_count == 1

    # Validate output image bytes with strict UploadValidator
    validated = validator.validate_bytes_sync(result1.image_bytes, field_name="result")
    assert validated.format == "JPEG"
    assert validated.width == 320
    assert validated.height == 480

    # Deterministic check: calling again with same inputs produces identical bytes
    result2 = provider.generate_try_on(
        job_id=job_id,
        person_image_bytes=person_bytes,
        garment_image_bytes=garment_bytes,
        existing_request_id="custom-req-123",
    )
    assert result2.image_bytes == result1.image_bytes
    assert result2.provider_request_id == "custom-req-123"
    assert provider.call_count == 2


def test_fake_ai_provider_rejects_corrupted_or_empty_inputs():
    """Corrupted or empty input bytes must raise PermanentAIProviderError (non-retryable)."""
    provider = FakeAIProvider(delay_seconds=0.0)
    job_id = uuid.uuid4()
    valid_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(200, 200))

    with pytest.raises(PermanentAIProviderError) as exc_empty:
        provider.generate_try_on(
            job_id=job_id,
            person_image_bytes=b"",
            garment_image_bytes=valid_bytes,
        )
    assert exc_empty.value.retryable is False
    assert exc_empty.value.error_code == ErrorCode.CORRUPTED_IMAGE.value

    with pytest.raises(PermanentAIProviderError) as exc_corrupt:
        provider.generate_try_on(
            job_id=job_id,
            person_image_bytes=valid_bytes,
            garment_image_bytes=b"not-an-image-stream",
        )
    assert exc_corrupt.value.retryable is False
    assert exc_corrupt.value.error_code == ErrorCode.CORRUPTED_IMAGE.value


def test_fake_ai_provider_simulated_transient_and_permanent_failures():
    """Verify FakeAIProvider can simulate both transient (retryable) and permanent errors."""
    job_id = uuid.uuid4()
    valid_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(200, 200))

    transient_provider = FakeAIProvider(
        should_fail=True,
        retryable_failure=True,
        failure_error_code=ErrorCode.AI_PROVIDER_TIMEOUT.value,
        failure_message="Simulated rate limit / timeout",
    )
    with pytest.raises(TransientAIProviderError) as exc_trans:
        transient_provider.generate_try_on(job_id, valid_bytes, valid_bytes)
    assert exc_trans.value.retryable is True
    assert exc_trans.value.error_code == ErrorCode.AI_PROVIDER_TIMEOUT.value
    assert exc_trans.value.provider_request_id == f"fake-req-{job_id}"

    permanent_provider = FakeAIProvider(
        should_fail=True,
        retryable_failure=False,
        failure_error_code=ErrorCode.AI_PROVIDER_ERROR.value,
        failure_message="Simulated permanent model rejection",
    )
    with pytest.raises(PermanentAIProviderError) as exc_perm:
        permanent_provider.generate_try_on(job_id, valid_bytes, valid_bytes)
    assert exc_perm.value.retryable is False
    assert exc_perm.value.error_code == ErrorCode.AI_PROVIDER_ERROR.value

