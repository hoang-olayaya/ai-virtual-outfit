import uuid
import httpx
import pytest
from app.models.try_on_job import JobStatus
from app.repositories.job_repository import JobRepository
from app.services.image_service import ImageService
from tests.conftest import create_synthetic_image_bytes


@pytest.mark.asyncio
async def test_save_try_on_job_lifecycle(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    image_service: ImageService,
):
    """
    POST /api/v1/try-ons/{id}/save:
    - Fails with 409 when job is not succeeded
    - Succeeds with 200 when job is succeeded
    - Is idempotent: repeated call returns 200 with matching saved_at
    """
    job = await api_job_repository.create_job(
        person_image_path="inputs/h1/person.jpg",
        garment_image_path="inputs/h1/garment.png",
    )

    # 1. Try to save when queued -> 409 Conflict
    resp_queued = await async_api_client.post(f"/api/v1/try-ons/{job.id}/save")
    assert resp_queued.status_code == 409
    assert resp_queued.json()["error_code"] == "RESULT_NOT_READY"

    # 2. Mark succeeded and save -> 200 OK
    await api_job_repository.mark_succeeded(job.id, "outputs/h1/result.jpg")
    resp_save = await async_api_client.post(f"/api/v1/try-ons/{job.id}/save")
    assert resp_save.status_code == 200
    save_data = resp_save.json()
    assert save_data["job_id"] == str(job.id)
    assert save_data["is_saved"] is True
    assert save_data["saved_at"] is not None
    saved_at_first = save_data["saved_at"]

    # 3. Repeat save (idempotency test) -> 200 OK with same saved_at
    resp_repeat = await async_api_client.post(f"/api/v1/try-ons/{job.id}/save")
    assert resp_repeat.status_code == 200
    assert resp_repeat.json()["saved_at"] == saved_at_first


@pytest.mark.asyncio
async def test_save_non_existent_job_returns_404(
    async_api_client: httpx.AsyncClient,
):
    """POST /api/v1/try-ons/{random_uuid}/save returns 404."""
    random_id = uuid.uuid4()
    resp = await async_api_client.post(f"/api/v1/try-ons/{random_id}/save")
    assert resp.status_code == 404
    assert resp.json()["error_code"] == "JOB_NOT_FOUND"


@pytest.mark.asyncio
async def test_list_and_detail_history_api(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
):
    """
    GET /api/v1/history & GET /api/v1/history/{id}:
    - Returns paginated list of only saved jobs
    - Returns detail with person, garment, and result image URLs
    """
    # Create and save 2 succeeded jobs
    job1 = await api_job_repository.create_job(
        person_image_path="inputs/h2/person.jpg",
        garment_image_path="inputs/h2/garment.png",
    )
    await api_job_repository.mark_succeeded(job1.id, "outputs/h2/result.jpg")
    await async_api_client.post(f"/api/v1/try-ons/{job1.id}/save")

    job2 = await api_job_repository.create_job(
        person_image_path="inputs/h3/person.jpg",
        garment_image_path="inputs/h3/garment.png",
    )
    await api_job_repository.mark_succeeded(job2.id, "outputs/h3/result.jpg")
    await async_api_client.post(f"/api/v1/try-ons/{job2.id}/save")

    # 1. List history
    list_resp = await async_api_client.get("/api/v1/history?limit=10&offset=0")
    assert list_resp.status_code == 200
    list_data = list_resp.json()
    assert list_data["total"] >= 2
    assert len(list_data["items"]) >= 2
    item_ids = [item["job_id"] for item in list_data["items"]]
    assert str(job1.id) in item_ids
    assert str(job2.id) in item_ids

    # 2. Get detail for job1
    detail_resp = await async_api_client.get(f"/api/v1/history/{job1.id}")
    assert detail_resp.status_code == 200
    detail_data = detail_resp.json()
    assert detail_data["job_id"] == str(job1.id)
    assert detail_data["is_saved"] is True
    assert f"/api/v1/try-ons/{job1.id}/inputs/person" in detail_data["person_image_url"]
    assert f"/api/v1/try-ons/{job1.id}/inputs/garment" in detail_data["garment_image_url"]
    assert f"/api/v1/try-ons/{job1.id}/image" in detail_data["result_image_url"]


@pytest.mark.asyncio
async def test_delete_history_api(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    image_service: ImageService,
):
    """
    DELETE /api/v1/history/{id}:
    - Deletes saved history item and returns 204 No Content
    - Subsequent GET /history/{id} returns 404
    - Subsequent DELETE returns 404
    """
    # Create files on disk
    job_id = uuid.uuid4()
    person_bytes = create_synthetic_image_bytes(fmt="JPEG")
    garment_bytes = create_synthetic_image_bytes(fmt="PNG")
    result_bytes = create_synthetic_image_bytes(fmt="JPEG")

    await image_service.storage.save_bytes(f"inputs/{job_id}/person.jpg", person_bytes)
    await image_service.storage.save_bytes(f"inputs/{job_id}/garment.png", garment_bytes)
    await image_service.storage.save_bytes(f"outputs/{job_id}/result.jpg", result_bytes)

    job = await api_job_repository.create_job(
        person_image_path=f"inputs/{job_id}/person.jpg",
        garment_image_path=f"inputs/{job_id}/garment.png",
        job_id=job_id,
    )
    await api_job_repository.mark_succeeded(job.id, f"outputs/{job_id}/result.jpg")
    await async_api_client.post(f"/api/v1/try-ons/{job.id}/save")

    # Verify files exist before deletion
    assert (image_service.storage.base_path / f"inputs/{job_id}/person.jpg").exists()
    assert (image_service.storage.base_path / f"outputs/{job_id}/result.jpg").exists()

    # Delete history item -> 204 No Content
    del_resp = await async_api_client.delete(f"/api/v1/history/{job.id}")
    assert del_resp.status_code == 204

    # Verify files on storage volume were purged
    assert not (image_service.storage.base_path / f"inputs/{job_id}").exists()
    assert not (image_service.storage.base_path / f"outputs/{job_id}").exists()

    # GET detail now returns 404
    get_after = await async_api_client.get(f"/api/v1/history/{job.id}")
    assert get_after.status_code == 404

    # Second DELETE returns 404
    del_repeat = await async_api_client.delete(f"/api/v1/history/{job.id}")
    assert del_repeat.status_code == 404

