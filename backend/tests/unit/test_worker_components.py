from unittest.mock import AsyncMock, MagicMock, patch
import uuid
import pytest
from app.core.errors import ErrorCode, ImageNotFoundError, QueuePublishError
from app.integrations.ai_provider import (
    PermanentAIProviderError,
    TransientAIProviderError,
)
from app.models.try_on_job import JobStatus
from app.queue.publisher import TRY_ON_TASK_NAME, CeleryTaskPublisher
from app.workers.celery_app import celery_app, ping
from app.workers.failure_handler import FailureHandler
from app.workers.job_guard import ClaimDecision, JobGuard
from app.workers.tasks import WorkerExecutionOutcome, generate_try_on
from tests.conftest import InMemoryJobRepository


@pytest.mark.asyncio
async def test_celery_task_publisher_sends_only_job_id_string():
    """
    CeleryTaskPublisher must call celery_client.send_task with task_name and args=[str(job_id)],
    never sending binary image payloads.
    """
    mock_celery = MagicMock()
    publisher = CeleryTaskPublisher(celery_client=mock_celery)
    job_id = uuid.uuid4()

    await publisher.publish_try_on_job(job_id)

    mock_celery.send_task.assert_called_once_with(
        TRY_ON_TASK_NAME,
        args=[str(job_id)],
    )


@pytest.mark.asyncio
async def test_celery_task_publisher_wraps_broker_exception_into_queue_publish_error():
    """Broker errors during send_task must raise QueuePublishError (503)."""
    mock_celery = MagicMock()
    mock_celery.send_task.side_effect = ConnectionError("Redis connection refused")
    publisher = CeleryTaskPublisher(celery_client=mock_celery)
    job_id = uuid.uuid4()

    with pytest.raises(QueuePublishError) as exc_info:
        await publisher.publish_try_on_job(job_id)

    assert exc_info.value.error_code == ErrorCode.QUEUE_PUBLISH_ERROR
    assert exc_info.value.details["job_id"] == str(job_id)


def test_celery_app_registers_generate_try_on_and_ping_tasks():
    """Verify Celery app includes worker.generate_try_on and worker.ping tasks."""
    # Import tasks module to ensure decorator registration
    import app.workers.tasks  # noqa: F401

    assert ping() == "pong"
    assert TRY_ON_TASK_NAME in celery_app.tasks


@pytest.mark.asyncio
async def test_job_guard_claim_and_duplicate_protection():
    """
    Verify JobGuard state transitions:
    1. Queued job -> CLAIMED (status becomes 'processing').
    2. Second worker attempt while 'processing' (allow_processing_resume=False) -> ALREADY_PROCESSING.
    3. Controlled retry while 'processing' (allow_processing_resume=True) -> RESUMED.
    4. Completed job ('succeeded' or 'failed') -> ALREADY_COMPLETED.
    5. Missing job -> NOT_FOUND.
    """
    repo = InMemoryJobRepository()
    guard = JobGuard(repo)

    # Missing job
    missing_res = await guard.claim_or_inspect(uuid.uuid4())
    assert missing_res.decision == ClaimDecision.NOT_FOUND
    assert missing_res.should_proceed is False

    # Create queued job
    job = await repo.create_job(
        person_image_path="inputs/1/person.jpg",
        garment_image_path="inputs/1/garment.jpg",
    )
    await repo.session.commit()

    # 1. First claim succeeds
    claim_1 = await guard.claim_or_inspect(job.id)
    assert claim_1.decision == ClaimDecision.CLAIMED
    assert claim_1.should_proceed is True
    assert claim_1.job is not None
    assert claim_1.job.status == JobStatus.PROCESSING

    # 2. Concurrent claim without resume flag is blocked
    claim_2 = await guard.claim_or_inspect(job.id, allow_processing_resume=False)
    assert claim_2.decision == ClaimDecision.ALREADY_PROCESSING
    assert claim_2.should_proceed is False

    # 3. Retry with allow_processing_resume=True is allowed
    claim_resume = await guard.claim_or_inspect(job.id, allow_processing_resume=True)
    assert claim_resume.decision == ClaimDecision.RESUMED
    assert claim_resume.should_proceed is True

    # 4. Succeeded job is skipped
    await repo.mark_succeeded(job.id, "outputs/1/result.jpg")
    await repo.session.commit()
    claim_done = await guard.claim_or_inspect(job.id, allow_processing_resume=True)
    assert claim_done.decision == ClaimDecision.ALREADY_COMPLETED
    assert claim_done.should_proceed is False


@pytest.mark.asyncio
async def test_failure_handler_retry_classification_and_retry_cap():
    """
    Verify FailureHandler:
    - Transient errors increment retry_count and keep status='processing' until max_retries is reached.
    - Once retry_count reaches max_retries, job transitions to terminal 'failed'.
    - Permanent errors immediately transition to terminal 'failed' without retrying.
    """
    repo = InMemoryJobRepository()
    handler = FailureHandler(repo, max_retries=2)

    job = await repo.create_job("inputs/a/p.jpg", "inputs/a/g.jpg")
    await repo.claim_job(job.id)
    await repo.session.commit()

    # Attempt 1: Transient error (retry 0 < 2 -> should_retry=True, retry_count=1, status=processing)
    d1 = await handler.handle_failure(
        job.id,
        TransientAIProviderError("Temporary 503", error_code="AI_PROVIDER_ERROR"),
    )
    assert d1.should_retry is True
    assert d1.retry_count == 1
    assert d1.job is not None and d1.job.status == JobStatus.PROCESSING

    # Attempt 2: Transient error (retry 1 < 2 -> should_retry=True, retry_count=2, status=processing)
    d2 = await handler.handle_failure(
        job.id,
        TransientAIProviderError("Temporary 503 again", error_code="AI_PROVIDER_ERROR"),
    )
    assert d2.should_retry is True
    assert d2.retry_count == 2
    assert d2.job is not None and d2.job.status == JobStatus.PROCESSING

    # Attempt 3: Transient error at cap (retry 2 == max_retries -> should_retry=False, status=failed)
    d3 = await handler.handle_failure(
        job.id,
        TransientAIProviderError("Still failing", error_code="AI_PROVIDER_ERROR"),
    )
    assert d3.should_retry is False
    assert d3.retry_count == 2
    assert d3.job is not None and d3.job.status == JobStatus.FAILED
    assert d3.job.completed_at is not None

    # Permanent error on a fresh job -> immediately terminal FAILED on first failure
    job2 = await repo.create_job("inputs/b/p.jpg", "inputs/b/g.jpg")
    await repo.claim_job(job2.id)
    await repo.session.commit()

    d_perm = await handler.handle_failure(
        job2.id,
        PermanentAIProviderError("Invalid pose", error_code="AI_PROVIDER_ERROR"),
    )
    assert d_perm.should_retry is False
    assert d_perm.retry_count == 0
    assert d_perm.job is not None and d_perm.job.status == JobStatus.FAILED

    # Missing input file error -> immediately terminal FAILED
    job3 = await repo.create_job("inputs/c/p.jpg", "inputs/c/g.jpg")
    await repo.claim_job(job3.id)
    await repo.session.commit()

    d_missing = await handler.handle_failure(
        job3.id,
        ImageNotFoundError("Input image missing on volume"),
    )
    assert d_missing.should_retry is False
    assert d_missing.error_code == ErrorCode.IMAGE_NOT_FOUND.value
    assert d_missing.job is not None and d_missing.job.status == JobStatus.FAILED


def test_celery_generate_try_on_task_returns_dict_and_triggers_retry_when_needed():
    """
    Verify the bound Celery task `generate_try_on`:
    - Returns serialized WorkerExecutionOutcome dict when should_retry=False.
    - Invokes self.retry(...) with exponential countdown when should_retry=True.
    """
    job_id = uuid.uuid4()
    success_outcome = WorkerExecutionOutcome(
        job_id=job_id,
        status=JobStatus.SUCCEEDED.value,
        decision=ClaimDecision.CLAIMED.value,
        result_image_path=f"outputs/{job_id}/result.jpg",
        provider_name="fake",
        provider_request_id=f"fake-req-{job_id}",
        should_retry=False,
    )

    with patch(
        "app.workers.tasks.execute_try_on_job",
        new=AsyncMock(return_value=success_outcome),
    ):
        res = generate_try_on.run(str(job_id))
        assert res["job_id"] == str(job_id)
        assert res["status"] == "succeeded"
        assert res["result_image_path"] == f"outputs/{job_id}/result.jpg"

    retry_outcome = WorkerExecutionOutcome(
        job_id=job_id,
        status=JobStatus.PROCESSING.value,
        decision=ClaimDecision.CLAIMED.value,
        should_retry=True,
        error_code=ErrorCode.AI_PROVIDER_TIMEOUT.value,
        error_message="Provider timeout",
        retry_count=1,
    )

    with (
        patch(
            "app.workers.tasks.execute_try_on_job",
            new=AsyncMock(return_value=retry_outcome),
        ),
        patch.object(
            generate_try_on,
            "retry",
            side_effect=RuntimeError("CeleryRetryTriggered"),
        ) as mock_retry,
    ):
        with pytest.raises(RuntimeError, match="CeleryRetryTriggered"):
            generate_try_on.run(str(job_id))
        mock_retry.assert_called_once()


def test_build_default_ai_provider_resolution():
    """Verify build_default_ai_provider resolves FalAdapter, FakeAIProvider, or raises ValueError."""
    from app.core.config import settings
    from app.integrations.fal_adapter import FalAdapter
    from app.integrations.fake_ai_provider import FakeAIProvider
    from app.workers.tasks import build_default_ai_provider

    with patch.object(settings, "AI_PROVIDER", "fake"):
        p_fake = build_default_ai_provider()
        assert isinstance(p_fake, FakeAIProvider)

    with patch.object(settings, "AI_PROVIDER", "fal"):
        with patch.object(settings, "FAL_KEY", "dummy-key-for-test"):
            p_fal = build_default_ai_provider()
            assert isinstance(p_fal, FalAdapter)

    with patch.object(settings, "AI_PROVIDER", "unknown_provider"):
        with pytest.raises(ValueError, match="Unsupported AI_PROVIDER"):
            build_default_ai_provider()


@pytest.mark.asyncio
async def test_job_guard_atomic_resume_lease_prevents_concurrent_resume():
    """
    Verify atomic resume lease in JobGuard:
    - First worker successfully acquires resume lease on an in-progress job.
    - Second worker attempting concurrent resume on the same job fails lease and is rejected.
    """
    repo = InMemoryJobRepository()
    guard = JobGuard(repo)

    job = await repo.create_job("inputs/1/p.jpg", "inputs/1/g.jpg")
    await repo.claim_job(job.id)
    await repo.session.commit()

    # Worker 1 claims resume lease
    res1 = await guard.claim_or_inspect(job.id, allow_processing_resume=True)
    assert res1.decision == ClaimDecision.RESUMED
    assert res1.should_proceed is True

    # Simulate race where claim_resume_job returns None (lease already held / status conflict)
    with patch.object(repo, "claim_resume_job", new=AsyncMock(return_value=None)):
        res2 = await guard.claim_or_inspect(job.id, allow_processing_resume=True)
        assert res2.decision == ClaimDecision.ALREADY_PROCESSING
        assert res2.should_proceed is False


def test_secret_masking_filter_scrubs_fal_key_and_bearer_tokens():
    """Verify SecretMaskingFilter redacts sensitive FAL keys and tokens from strings, tuples, and dicts."""
    import logging
    from app.core.config import settings
    from app.core.logging import SecretMaskingFilter

    with patch.object(settings, "FAL_KEY", "secret-fal-key-1234567890abcdef"):
        flt = SecretMaskingFilter()

        # String message
        rec1 = logging.LogRecord("test", logging.INFO, "test.py", 1, "Failed with secret-fal-key-1234567890abcdef here", (), None)
        assert flt.filter(rec1) is True
        assert "secret-fal-key-1234567890abcdef" not in rec1.msg
        assert "******" in rec1.msg

        # Key token pattern
        rec2 = logging.LogRecord("test", logging.INFO, "test.py", 1, "Authorization: Key fal_api_token_abc1234567890", (), None)
        flt.filter(rec2)
        assert "fal_api_token" not in rec2.msg
        assert "Key ******" in rec2.msg

        # Bearer token pattern
        rec3 = logging.LogRecord("test", logging.INFO, "test.py", 1, "Authorization: Bearer my_super_secret_jwt_token_12345", (), None)
        flt.filter(rec3)
        assert "my_super_secret" not in rec3.msg
        assert "Bearer ******" in rec3.msg

        # Tuple args
        rec4 = logging.LogRecord("test", logging.INFO, "test.py", 1, "User key is %s", ("secret-fal-key-1234567890abcdef",), None)
        flt.filter(rec4)
        assert rec4.args == ("******",)


@pytest.mark.asyncio
async def test_failure_handler_scrubs_secrets_and_persists_provider_request_id():
    """Verify FailureHandler scrubs secrets from error message and preserves provider_name and provider_request_id."""
    from app.core.config import settings
    from app.integrations.ai_provider import TransientAIProviderError

    repo = InMemoryJobRepository()
    handler = FailureHandler(repo, max_retries=2)

    job = await repo.create_job("inputs/1/p.jpg", "inputs/1/g.jpg")
    await repo.claim_job(job.id)
    await repo.session.commit()

    with patch.object(settings, "FAL_KEY", "super-secret-fal-key-value"):
        exc = TransientAIProviderError(
            message="Connection failed for super-secret-fal-key-value during polling",
            provider_name="fal",
            provider_request_id="fal-req-999888",
        )
        decision = await handler.handle_failure(job.id, exc)

        assert decision.should_retry is True
        assert decision.job is not None
        assert "super-secret-fal-key-value" not in decision.error_message
        assert "******" in decision.error_message
        assert decision.job.error_message == decision.error_message
        assert decision.job.provider_name == "fal"
        assert decision.job.provider_request_id == "fal-req-999888"

