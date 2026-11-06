import uuid
from pathlib import Path
from unittest.mock import patch
import pytest

from app.core.errors import ErrorCode, ImageNotFoundError, StorageError
from app.services.image_service import ImageService
from tests.conftest import create_synthetic_image_bytes, make_upload_file


@pytest.mark.asyncio
async def test_store_and_read_input_and_result_images(
    image_service: ImageService,
    temp_storage_dir: Path,
):
    """
    End-to-end B02 integration test:
    1. Validate 2 upload files (person JPEG + garment PNG).
    2. Store both separately under 'inputs/{job_id}/'.
    3. Store result image under 'outputs/{job_id}/'.
    4. Read back bytes & MIME types, then delete all job images.
    """
    job_id = uuid.uuid4()
    person_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(320, 480), color=(200, 100, 50))
    garment_bytes = create_synthetic_image_bytes(fmt="PNG", size=(256, 256), color=(20, 40, 200))
    result_bytes = create_synthetic_image_bytes(fmt="WEBP", size=(320, 480), color=(50, 180, 90))

    person_upload = make_upload_file(person_bytes, filename="user_photo.jpg")
    garment_upload = make_upload_file(garment_bytes, filename="shirt.png")

    v_person, v_garment = await image_service.validator.validate_try_on_inputs(
        person_upload, garment_upload
    )

    stored_inputs = await image_service.store_input_images(job_id, v_person, v_garment)

    assert stored_inputs.job_id == job_id
    assert stored_inputs.person_image_path == f"inputs/{job_id}/person.jpg"
    assert stored_inputs.garment_image_path == f"inputs/{job_id}/garment.png"

    # Both files exist separately on disk
    assert (temp_storage_dir / "inputs" / str(job_id) / "person.jpg").is_file()
    assert (temp_storage_dir / "inputs" / str(job_id) / "garment.png").is_file()

    # Store result image
    result_rel_path = await image_service.store_result_image(job_id, result_bytes)
    assert result_rel_path == f"outputs/{job_id}/result.webp"
    assert (temp_storage_dir / "outputs" / str(job_id) / "result.webp").is_file()

    # Read back and verify content + MIME types
    read_person, person_mime = await image_service.read_image(stored_inputs.person_image_path)
    assert read_person == person_bytes
    assert person_mime == "image/jpeg"

    read_garment, garment_mime = await image_service.read_image(stored_inputs.garment_image_path)
    assert read_garment == garment_bytes
    assert garment_mime == "image/png"

    read_result, result_mime = await image_service.read_image(result_rel_path)
    assert read_result == result_bytes
    assert result_mime == "image/webp"

    # Delete all job images
    inputs_deleted, outputs_deleted = await image_service.delete_job_images(job_id)
    assert inputs_deleted is True
    assert outputs_deleted is True
    assert not (temp_storage_dir / "inputs" / str(job_id)).exists()
    assert not (temp_storage_dir / "outputs" / str(job_id)).exists()

    with pytest.raises(ImageNotFoundError):
        await image_service.read_image(result_rel_path)


@pytest.mark.asyncio
async def test_rollback_partial_files_when_second_input_save_fails(
    image_service: ImageService,
    temp_storage_dir: Path,
):
    """
    If saving garment_image fails after person_image has already been written,
    ImageService must clean up 'inputs/{job_id}' so no orphan files remain.
    """
    job_id = uuid.uuid4()
    person_bytes = create_synthetic_image_bytes(fmt="JPEG", size=(200, 200))
    garment_bytes = create_synthetic_image_bytes(fmt="PNG", size=(200, 200))

    v_person = await image_service.validator.validate_bytes(person_bytes, field_name="person_image")
    v_garment = await image_service.validator.validate_bytes(garment_bytes, field_name="garment_image")

    original_save = image_service.storage.save_bytes
    call_count = 0

    async def fail_on_second_write(relative_path, data):
        nonlocal call_count
        call_count += 1
        if call_count == 2:
            raise StorageError(
                error_code=ErrorCode.STORAGE_UNAVAILABLE,
                message="Simulated disk failure on garment write",
            )
        return await original_save(relative_path, data)

    with patch.object(image_service.storage, "save_bytes", side_effect=fail_on_second_write):
        with pytest.raises(StorageError) as exc_info:
            await image_service.store_input_images(job_id, v_person, v_garment)
        assert exc_info.value.error_code == ErrorCode.STORAGE_UNAVAILABLE

    # Verify rollback removed the first image and the job input directory
    job_input_dir = temp_storage_dir / "inputs" / str(job_id)
    assert not job_input_dir.exists()

