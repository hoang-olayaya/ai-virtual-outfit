import uuid
import pytest
from sqlalchemy.exc import IntegrityError
from app.models.try_on_job import JobStatus
from app.repositories.job_repository import JobRepository


@pytest.mark.asyncio
async def test_create_and_get_job(db_session):
    repo = JobRepository(db_session)
    job_id = uuid.uuid4()
    
    created_job = await repo.create_job(
        person_image_path="inputs/person_1.jpg",
        garment_image_path="inputs/garment_1.jpg",
        idempotency_key="idemp-001",
        job_id=job_id,
    )
    await db_session.commit()

    assert created_job.id == job_id
    assert created_job.status == JobStatus.QUEUED
    assert created_job.person_image_path == "inputs/person_1.jpg"
    assert created_job.garment_image_path == "inputs/garment_1.jpg"
    assert created_job.idempotency_key == "idemp-001"
    assert created_job.retry_count == 0
    assert created_job.is_saved is False
    assert created_job.created_at is not None

    fetched_job = await repo.get_by_id(job_id)
    assert fetched_job is not None
    assert fetched_job.id == job_id
    assert fetched_job.status == JobStatus.QUEUED


@pytest.mark.asyncio
async def test_get_by_idempotency_key(db_session):
    repo = JobRepository(db_session)
    key = f"key-{uuid.uuid4()}"
    await repo.create_job(
        person_image_path="inputs/p.png",
        garment_image_path="inputs/g.png",
        idempotency_key=key,
    )
    await db_session.commit()

    found = await repo.get_by_idempotency_key(key)
    assert found is not None
    assert found.idempotency_key == key

    not_found = await repo.get_by_idempotency_key("non-existent-key")
    assert not_found is None


@pytest.mark.asyncio
async def test_atomic_claim_job(db_session):
    repo = JobRepository(db_session)
    job = await repo.create_job(
        person_image_path="inputs/p.png",
        garment_image_path="inputs/g.png",
    )
    await db_session.commit()

    # Worker 1 claims the job
    claimed = await repo.claim_job(job.id)
    await db_session.commit()
    assert claimed is not None
    assert claimed.id == job.id
    assert claimed.status == JobStatus.PROCESSING

    # Worker 2 attempts to claim the same job -> returns None because status is no longer 'queued'
    second_claim = await repo.claim_job(job.id)
    assert second_claim is None


@pytest.mark.asyncio
async def test_update_provider_tracking(db_session):
    repo = JobRepository(db_session)
    job = await repo.create_job(
        person_image_path="inputs/p.png",
        garment_image_path="inputs/g.png",
    )
    await db_session.commit()

    updated = await repo.update_provider_tracking(
        job_id=job.id,
        provider_name="fal.ai",
        provider_request_id="fal-req-9999",
    )
    await db_session.commit()

    assert updated is not None
    assert updated.provider_name == "fal.ai"
    assert updated.provider_request_id == "fal-req-9999"


@pytest.mark.asyncio
async def test_mark_succeeded(db_session):
    repo = JobRepository(db_session)
    job = await repo.create_job(
        person_image_path="inputs/p.png",
        garment_image_path="inputs/g.png",
    )
    await repo.claim_job(job.id)
    await db_session.commit()

    succeeded_job = await repo.mark_succeeded(
        job_id=job.id,
        result_image_path="outputs/result_1.png",
    )
    await db_session.commit()

    assert succeeded_job is not None
    assert succeeded_job.status == JobStatus.SUCCEEDED
    assert succeeded_job.result_image_path == "outputs/result_1.png"
    assert succeeded_job.completed_at is not None


@pytest.mark.asyncio
async def test_mark_failed_retry_and_terminal(db_session):
    repo = JobRepository(db_session)
    job = await repo.create_job(
        person_image_path="inputs/p.png",
        garment_image_path="inputs/g.png",
    )
    await repo.claim_job(job.id)
    await db_session.commit()

    # Non-terminal failure with retry increment
    retry_job = await repo.mark_failed(
        job_id=job.id,
        error_code="RATE_LIMIT",
        error_message="Too many requests",
        increment_retry=True,
        terminal=False,
    )
    await db_session.commit()
    assert retry_job is not None
    assert retry_job.status == JobStatus.PROCESSING
    assert retry_job.retry_count == 1
    assert retry_job.error_code == "RATE_LIMIT"

    # Terminal failure
    failed_job = await repo.mark_failed(
        job_id=job.id,
        error_code="INFERENCE_FAILED",
        error_message="Failed to process image",
        increment_retry=False,
        terminal=True,
    )
    await db_session.commit()
    assert failed_job is not None
    assert failed_job.status == JobStatus.FAILED
    assert failed_job.error_code == "INFERENCE_FAILED"
    assert failed_job.completed_at is not None


@pytest.mark.asyncio
async def test_idempotency_unique_constraint(db_session):
    repo = JobRepository(db_session)
    same_key = f"key-{uuid.uuid4()}"

    await repo.create_job("inputs/p1.jpg", "inputs/g1.jpg", idempotency_key=same_key)
    await db_session.commit()

    # Attempting to create another job with the exact same idempotency key
    with pytest.raises(IntegrityError):
        await repo.create_job("inputs/p2.jpg", "inputs/g2.jpg", idempotency_key=same_key)
        await db_session.commit()

    await db_session.rollback()


@pytest.mark.asyncio
async def test_mark_saved_and_list_history(db_session):
    repo = JobRepository(db_session)
    
    # 1. Reject save on queued job
    queued_job = await repo.create_job("inputs/p.png", "inputs/g.png")
    await db_session.commit()

    with pytest.raises(ValueError, match="Only succeeded jobs can be saved"):
        await repo.mark_saved(queued_job.id, is_saved=True)

    # 2. Succeed and save
    await repo.claim_job(queued_job.id)
    await repo.mark_succeeded(queued_job.id, result_image_path="outputs/out.png")
    await db_session.commit()

    saved_job = await repo.mark_saved(queued_job.id, is_saved=True)
    await db_session.commit()
    assert saved_job is not None
    assert saved_job.is_saved is True
    assert saved_job.saved_at is not None

    # 3. Query history
    history = await repo.list_saved_jobs(limit=10, offset=0)
    assert len(history) == 1
    assert history[0].id == queued_job.id


@pytest.mark.asyncio
async def test_delete_job(db_session):
    repo = JobRepository(db_session)
    job = await repo.create_job("inputs/p.png", "inputs/g.png")
    await db_session.commit()

    deleted = await repo.delete_job(job.id)
    await db_session.commit()
    assert deleted is True

    fetched = await repo.get_by_id(job.id)
    assert fetched is None

    # Deleting non-existent job returns False
    deleted_again = await repo.delete_job(uuid.uuid4())
    assert deleted_again is False
