from fastapi.testclient import TestClient


def test_root_liveness_check(client: TestClient) -> None:
    """Ensure root /health endpoint is operational and returns 200 OK."""
    response = client.get("/health")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ok"
    assert "app" in data
    assert "version" in data
    assert "environment" in data


def test_api_v1_liveness_check(client: TestClient) -> None:
    """Ensure /api/v1/health endpoint is operational and returns 200 OK."""
    response = client.get("/api/v1/health")
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "ok"
    assert data["app"] == "AI Virtual Outfit Preview"
