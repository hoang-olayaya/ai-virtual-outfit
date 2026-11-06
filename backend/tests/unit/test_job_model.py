import uuid
from app.models.try_on_job import JobStatus, TryOnJob


def test_job_status_enum_values():
    """Verify JobStatus enum members and string representations."""
    assert JobStatus.QUEUED.value == "queued"
    assert JobStatus.PROCESSING.value == "processing"
    assert JobStatus.SUCCEEDED.value == "succeeded"
    assert JobStatus.FAILED.value == "failed"


def test_try_on_job_instantiation():
    """Verify model initialization and default attribute assignments."""
    test_id = uuid.uuid4()
    job = TryOnJob(
        id=test_id,
        person_image_path="inputs/person.jpg",
        garment_image_path="inputs/garment.jpg",
        idempotency_key="key-12345",
    )

    assert job.id == test_id
    assert job.person_image_path == "inputs/person.jpg"
    assert job.garment_image_path == "inputs/garment.jpg"
    assert job.idempotency_key == "key-12345"
    assert job.status == JobStatus.QUEUED
    assert job.retry_count == 0
    assert job.is_saved is False
    assert job.result_image_path is None
    assert job.provider_name is None
    assert job.provider_request_id is None
    assert job.error_code is None
    assert job.error_message is None
    assert "TryOnJob" in repr(job)
