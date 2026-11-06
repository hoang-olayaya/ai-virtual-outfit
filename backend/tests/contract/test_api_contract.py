from datetime import datetime, timezone
import uuid
from fastapi.testclient import TestClient
from app.api.deps import get_job_service, get_try_on_service
from app.core.errors import ErrorCode, JobNotFoundError
from app.main import app
from app.models.try_on_job import JobStatus, TryOnJob

EXPECTED_JOB_RESPONSE_KEYS = {
    "job_id",
    "status",
    "result_image_url",
    "person_image_url",
    "garment_image_url",
    "error",
    "is_saved",
    "saved_at",
    "created_at",
    "updated_at",
    "completed_at",
}

EXPECTED_HISTORY_ITEM_KEYS = {
    "job_id",
    "status",
    "person_image_url",
    "garment_image_url",
    "result_image_url",
    "is_saved",
    "saved_at",
    "created_at",
    "completed_at",
}


class _StubTryOnService:
    def __init__(self, job: TryOnJob) -> None:
        self.job = job

    async def create_try_on_job(self, person_image, garment_image, idempotency_key=None) -> TryOnJob:
        return self.job


class _StubJobService:
    def __init__(self, job: TryOnJob | None) -> None:
        self.job = job

    async def get_job(self, job_id: uuid.UUID) -> TryOnJob:
        if self.job is None or self.job.id != job_id:
            raise JobNotFoundError(details={"job_id": str(job_id)})
        return self.job


def test_openapi_contract_exposes_b03_try_on_and_job_status_endpoints(client: TestClient):
    """Verify OpenAPI specification registers POST /api/v1/try-ons and GET /api/v1/try-ons/{job_id}."""
    resp = client.get("/api/v1/openapi.json")
    assert resp.status_code == 200
    spec = resp.json()

    paths = spec["paths"]
    assert "/api/v1/try-ons" in paths
    assert "post" in paths["/api/v1/try-ons"]
    post_responses = paths["/api/v1/try-ons"]["post"]["responses"]
    assert "202" in post_responses
    assert "400" in post_responses
    assert "413" in post_responses
    assert "415" in post_responses
    assert "503" in post_responses

    assert "/api/v1/try-ons/{job_id}" in paths
    assert "get" in paths["/api/v1/try-ons/{job_id}"]
    get_responses = paths["/api/v1/try-ons/{job_id}"]["get"]["responses"]
    assert "200" in get_responses
    assert "404" in get_responses
    assert "422" in get_responses

    assert "/api/v1/try-ons/{job_id}/image" in paths
    assert "get" in paths["/api/v1/try-ons/{job_id}/image"]
    media_responses = paths["/api/v1/try-ons/{job_id}/image"]["get"]["responses"]
    assert "200" in media_responses
    assert "404" in media_responses
    assert "409" in media_responses
    assert "422" in media_responses

    # B07 endpoints: Input media, Save, List history, Detail, Delete
    assert "/api/v1/try-ons/{job_id}/inputs/{kind}" in paths
    assert "get" in paths["/api/v1/try-ons/{job_id}/inputs/{kind}"]

    assert "/api/v1/try-ons/{job_id}/save" in paths
    assert "post" in paths["/api/v1/try-ons/{job_id}/save"]
    save_responses = paths["/api/v1/try-ons/{job_id}/save"]["post"]["responses"]
    assert "200" in save_responses
    assert "404" in save_responses
    assert "409" in save_responses

    assert "/api/v1/history" in paths
    assert "get" in paths["/api/v1/history"]

    assert "/api/v1/history/{job_id}" in paths
    assert "get" in paths["/api/v1/history/{job_id}"]
    assert "delete" in paths["/api/v1/history/{job_id}"]
    del_responses = paths["/api/v1/history/{job_id}"]["delete"]["responses"]
    assert "204" in del_responses


def test_contract_response_shape_for_post_202_and_get_200(client: TestClient):
    """Verify exact JSON key contract for POST 202 and GET 200 responses."""
    now = datetime.now(timezone.utc)
    sample_id = uuid.uuid4()
    sample_job = TryOnJob(
        id=sample_id,
        status=JobStatus.QUEUED,
        person_image_path=f"inputs/{sample_id}/person.jpg",
        garment_image_path=f"inputs/{sample_id}/garment.png",
        created_at=now,
        updated_at=now,
    )

    app.dependency_overrides[get_try_on_service] = lambda: _StubTryOnService(sample_job)
    app.dependency_overrides[get_job_service] = lambda: _StubJobService(sample_job)
    try:
        post_resp = client.post(
            "/api/v1/try-ons",
            files={
                "person_image": ("person.jpg", b"stub", "image/jpeg"),
                "garment_image": ("garment.png", b"stub", "image/png"),
            },
        )
        assert post_resp.status_code == 202
        post_json = post_resp.json()
        assert set(post_json.keys()) == EXPECTED_JOB_RESPONSE_KEYS
        assert post_json["job_id"] == str(sample_id)
        assert post_json["status"] == "queued"

        get_resp = client.get(f"/api/v1/try-ons/{sample_id}")
        assert get_resp.status_code == 200
        get_json = get_resp.json()
        assert set(get_json.keys()) == EXPECTED_JOB_RESPONSE_KEYS
        assert get_json["job_id"] == str(sample_id)
    finally:
        app.dependency_overrides.clear()


def test_contract_error_response_shape(client: TestClient):
    """Verify standardized ErrorResponse contract ({error_code, message, details})."""
    app.dependency_overrides[get_job_service] = lambda: _StubJobService(None)
    try:
        missing_id = uuid.uuid4()
        resp = client.get(f"/api/v1/try-ons/{missing_id}")
        assert resp.status_code == 404
        err_json = resp.json()
        assert err_json["error_code"] == ErrorCode.JOB_NOT_FOUND.value
        assert isinstance(err_json["message"], str) and len(err_json["message"]) > 0
        assert err_json["details"] == {"job_id": str(missing_id)}
    finally:
        app.dependency_overrides.clear()

