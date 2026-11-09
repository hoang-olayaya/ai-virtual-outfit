from datetime import datetime, timedelta, timezone
import os
import time
import uuid
import pytest
from app.core.errors import ErrorCode
from app.maintenance.cleanup_files import cleanup_storage_files
from app.maintenance.reconcile_jobs import reconcile_stale_jobs
from app.models.try_on_job import JobStatus, TryOnJob
from app.queue.publisher import FakeTaskPublisher
from app.storage.local_storage import LocalStorageAdapter


@pytest.mark.asyncio
async def test_reconcile_stale_processing_job_requeued(job_repository, fake_publisher):
    # Setup stale job: processing status, updated_at 500s ago
    old_time = datetime.now(timezone.utc) - timedelta(seconds=500)
    job = await job_repository.create_job(
        person_image_path="inputs/person.jpg",
        garment_image_path="inputs/garment.jpg",
    )
    job.status = JobStatus.PROCESSING
    job.updated_at = old_time
    job.retry_count = 0

    report = await reconcile_stale_jobs(
        job_repository=job_repository,
        publisher=fake_publisher,
        stale_threshold_seconds=300,
        max_retries=2,
    )

    assert report.stale_jobs_found == 1
    assert report.stale_jobs_requeued == 1
    assert report.stale_jobs_failed == 0
    assert fake_publisher.published_job_ids == [job.id]

    rechecked = await job_repository.get_by_id(job.id)
    assert rechecked.status == JobStatus.QUEUED
    assert rechecked.retry_count == 1


@pytest.mark.asyncio
async def test_reconcile_stale_processing_job_max_retries_marked_failed(job_repository, fake_publisher):
    # Setup stale job with max retries already reached
    old_time = datetime.now(timezone.utc) - timedelta(seconds=500)
    job = await job_repository.create_job(
        person_image_path="inputs/person.jpg",
        garment_image_path="inputs/garment.jpg",
    )
    job.status = JobStatus.PROCESSING
    job.updated_at = old_time
    job.retry_count = 2  # max retries reached

    report = await reconcile_stale_jobs(
        job_repository=job_repository,
        publisher=fake_publisher,
        stale_threshold_seconds=300,
        max_retries=2,
    )

    assert report.stale_jobs_found == 1
    assert report.stale_jobs_requeued == 0
    assert report.stale_jobs_failed == 1
    assert fake_publisher.published_job_ids == []

    rechecked = await job_repository.get_by_id(job.id)
    assert rechecked.status == JobStatus.FAILED
    assert rechecked.error_code == ErrorCode.STALE_JOB_TIMEOUT.value
    assert "exceeded stale processing threshold" in rechecked.error_message


@pytest.mark.asyncio
async def test_reconcile_recent_processing_job_not_touched(job_repository, fake_publisher):
    # Setup recent job: processing status, updated_at 30s ago (< 300s)
    recent_time = datetime.now(timezone.utc) - timedelta(seconds=30)
    job = await job_repository.create_job(
        person_image_path="inputs/person.jpg",
        garment_image_path="inputs/garment.jpg",
    )
    job.status = JobStatus.PROCESSING
    job.updated_at = recent_time
    job.retry_count = 0

    report = await reconcile_stale_jobs(
        job_repository=job_repository,
        publisher=fake_publisher,
        stale_threshold_seconds=300,
    )

    assert report.stale_jobs_found == 0
    assert report.stale_jobs_requeued == 0
    assert fake_publisher.published_job_ids == []

    rechecked = await job_repository.get_by_id(job.id)
    assert rechecked.status == JobStatus.PROCESSING
    assert rechecked.retry_count == 0


@pytest.mark.asyncio
async def test_reconcile_stuck_queued_job_republished(job_repository, fake_publisher):
    # Setup stuck queued job: created_at 800s ago (> 600s timeout)
    old_created = datetime.now(timezone.utc) - timedelta(seconds=800)
    job = await job_repository.create_job(
        person_image_path="inputs/person.jpg",
        garment_image_path="inputs/garment.jpg",
    )
    job.created_at = old_created

    report = await reconcile_stale_jobs(
        job_repository=job_repository,
        publisher=fake_publisher,
        queued_timeout_seconds=600,
    )

    assert report.stuck_queued_found == 1
    assert report.stuck_queued_republished == 1
    assert fake_publisher.published_job_ids == [job.id]


@pytest.mark.asyncio
async def test_cleanup_temp_files_ttl(storage_adapter, job_repository, temp_storage_dir):
    tmp_dir = temp_storage_dir / "tmp"
    tmp_dir.mkdir(parents=True, exist_ok=True)

    # 1. Stale .part file (2 hours old)
    stale_part = tmp_dir / "stale_upload.part"
    stale_part.write_bytes(b"stale data")
    two_hours_ago = time.time() - 7200
    os.utime(stale_part, (two_hours_ago, two_hours_ago))

    # 2. Fresh .part file (10 seconds old)
    fresh_part = tmp_dir / "fresh_upload.part"
    fresh_part.write_bytes(b"fresh data")

    # 3. Non-.part file (should never be touched by temp cleanup)
    other_file = tmp_dir / "keep_me.txt"
    other_file.write_bytes(b"keep")
    os.utime(other_file, (two_hours_ago, two_hours_ago))

    report = await cleanup_storage_files(
        storage=storage_adapter,
        job_repository=job_repository,
        temp_ttl_seconds=3600,
    )

    assert report.temp_files_deleted == 1
    assert not stale_part.exists()
    assert fresh_part.exists()
    assert other_file.exists()


@pytest.mark.asyncio
async def test_cleanup_orphan_storage_dirs_with_grace_period(storage_adapter, job_repository, temp_storage_dir):
    now = time.time()
    two_hours_ago = now - 7200

    # 1. Existing valid job in DB -> Directory should be preserved
    valid_job = await job_repository.create_job(
        person_image_path="inputs/person.jpg",
        garment_image_path="inputs/garment.jpg",
    )
    valid_dir = temp_storage_dir / "inputs" / str(valid_job.id)
    valid_dir.mkdir(parents=True, exist_ok=True)
    os.utime(valid_dir, (two_hours_ago, two_hours_ago))

    # 2. Orphan job NOT in DB, but recent (within grace period 15m) -> PRESERVED
    recent_orphan_id = uuid.uuid4()
    recent_dir = temp_storage_dir / "inputs" / str(recent_orphan_id)
    recent_dir.mkdir(parents=True, exist_ok=True)
    # recent mtime (30 seconds ago)
    os.utime(recent_dir, (now - 30, now - 30))

    # 3. Orphan job NOT in DB, old (outside grace period) -> SWEPT / DELETED
    old_orphan_id = uuid.uuid4()
    old_dir = temp_storage_dir / "inputs" / str(old_orphan_id)
    old_dir.mkdir(parents=True, exist_ok=True)
    os.utime(old_dir, (two_hours_ago, two_hours_ago))

    # 4. Old orphan in 'outputs/' -> SWEPT / DELETED
    old_output_orphan_id = uuid.uuid4()
    old_out_dir = temp_storage_dir / "outputs" / str(old_output_orphan_id)
    old_out_dir.mkdir(parents=True, exist_ok=True)
    os.utime(old_out_dir, (two_hours_ago, two_hours_ago))

    report = await cleanup_storage_files(
        storage=storage_adapter,
        job_repository=job_repository,
        grace_period_seconds=900,
        temp_ttl_seconds=3600,
    )

    assert report.orphan_dirs_scanned == 2  # old_orphan_id & old_output_orphan_id
    assert report.orphan_dirs_deleted == 2
    assert report.preserved_by_grace_period >= 1

    assert valid_dir.exists(), "Valid DB job directory must never be deleted"
    assert recent_dir.exists(), "Recent orphan directory within grace period must be preserved"
    assert not old_dir.exists(), "Old orphan directory must be deleted by sweeper"
    assert not old_out_dir.exists(), "Old output orphan directory must be deleted by sweeper"


@pytest.mark.asyncio
async def test_cleanup_storage_dry_run(storage_adapter, job_repository, temp_storage_dir):
    now = time.time()
    two_hours_ago = now - 7200

    old_orphan_id = uuid.uuid4()
    old_dir = temp_storage_dir / "inputs" / str(old_orphan_id)
    old_dir.mkdir(parents=True, exist_ok=True)
    os.utime(old_dir, (two_hours_ago, two_hours_ago))

    report = await cleanup_storage_files(
        storage=storage_adapter,
        job_repository=job_repository,
        grace_period_seconds=900,
        dry_run=True,
    )

    assert report.orphan_dirs_scanned == 1
    assert report.orphan_dirs_deleted == 0  # not deleted in dry run
    assert old_dir.exists(), "Directory must not be deleted in dry-run mode"

