import uuid
import httpx
import pytest
from app.repositories.job_repository import JobRepository
from app.services.image_service import ImageService
from tests.conftest import create_synthetic_image_bytes


@pytest.mark.asyncio
async def test_get_try_on_input_media_success(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    image_service: ImageService,
):
    """
    GET /api/v1/try-ons/{id}/inputs/person and garment:
    - Streams correct binary bytes
    - Returns expected MIME Content-Type
    - Protects privacy with 'Cache-Control: private, no-cache' header
    """
    job_id = uuid.uuid4()
    person_bytes = create_synthetic_image_bytes(fmt="JPEG", color=(100, 150, 200))
    garment_bytes = create_synthetic_image_bytes(fmt="PNG", color=(200, 50, 50))

    await image_service.storage.save_bytes(f"inputs/{job_id}/person.jpg", person_bytes)
    await image_service.storage.save_bytes(f"inputs/{job_id}/garment.png", garment_bytes)

    job = await api_job_repository.create_job(
        person_image_path=f"inputs/{job_id}/person.jpg",
        garment_image_path=f"inputs/{job_id}/garment.png",
        job_id=job_id,
    )

    # 1. Fetch person input image
    resp_person = await async_api_client.get(f"/api/v1/try-ons/{job.id}/inputs/person")
    assert resp_person.status_code == 200
    assert resp_person.content == person_bytes
    assert resp_person.headers["content-type"] == "image/jpeg"
    assert "private" in resp_person.headers.get("cache-control", "")

    # 2. Fetch garment input image
    resp_garment = await async_api_client.get(f"/api/v1/try-ons/{job.id}/inputs/garment")
    assert resp_garment.status_code == 200
    assert resp_garment.content == garment_bytes
    assert resp_garment.headers["content-type"] == "image/png"
    assert "private" in resp_garment.headers.get("cache-control", "")


@pytest.mark.asyncio
async def test_get_try_on_result_image_has_private_cache(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
    image_service: ImageService,
):
    """GET /api/v1/try-ons/{id}/image returns Cache-Control: private, no-cache."""
    job_id = uuid.uuid4()
    result_bytes = create_synthetic_image_bytes(fmt="JPEG")
    await image_service.storage.save_bytes(f"outputs/{job_id}/result.jpg", result_bytes)

    job = await api_job_repository.create_job(
        person_image_path=f"inputs/{job_id}/person.jpg",
        garment_image_path=f"inputs/{job_id}/garment.png",
        job_id=job_id,
    )
    await api_job_repository.mark_succeeded(job.id, f"outputs/{job_id}/result.jpg")

    resp = await async_api_client.get(f"/api/v1/try-ons/{job.id}/image")
    assert resp.status_code == 200
    assert resp.content == result_bytes
    assert "private" in resp.headers.get("cache-control", "")


@pytest.mark.asyncio
async def test_get_input_media_invalid_kind(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
):
    """GET /api/v1/try-ons/{id}/inputs/{invalid_kind} returns 400 Bad Request."""
    job = await api_job_repository.create_job(
        person_image_path="inputs/k/person.jpg",
        garment_image_path="inputs/k/garment.png",
    )
    resp = await async_api_client.get(f"/api/v1/try-ons/{job.id}/inputs/shoes")
    assert resp.status_code == 400
    assert resp.json()["error_code"] == "INVALID_REQUEST"


@pytest.mark.asyncio
async def test_get_input_media_missing_job_or_file(
    async_api_client: httpx.AsyncClient,
    api_job_repository: JobRepository,
):
    """
    - Non-existent job returns 404 JOB_NOT_FOUND
    - Missing image file on disk returns 404 IMAGE_NOT_FOUND
    """
    random_id = uuid.uuid4()
    resp_missing_job = await async_api_client.get(
        f"/api/v1/try-ons/{random_id}/inputs/person"
    )
    assert resp_missing_job.status_code == 404
    assert resp_missing_job.json()["error_code"] == "JOB_NOT_FOUND"

    # Job exists in DB but file missing on disk
    job = await api_job_repository.create_job(
        person_image_path="inputs/ghost/person.jpg",
        garment_image_path="inputs/ghost/garment.png",
    )
    resp_missing_file = await async_api_client.get(
        f"/api/v1/try-ons/{job.id}/inputs/person"
    )
    assert resp_missing_file.status_code == 404
    assert resp_missing_file.json()["error_code"] == "IMAGE_NOT_FOUND"

