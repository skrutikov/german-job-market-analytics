from fastapi.testclient import TestClient

from src.api.main import api


client = TestClient(api)


def test_health_returns_ok() -> None:
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_jobs_rejects_limit_zero() -> None:
    response = client.get(
        "/jobs",
        params={"limit": 0},
    )

    assert response.status_code == 422


def test_jobs_rejects_limit_above_100() -> None:
    response = client.get(
        "/jobs",
        params={"limit": 101},
    )

    assert response.status_code == 422


def test_jobs_rejects_negative_offset() -> None:
    response = client.get(
        "/jobs",
        params={"offset": -1},
    )

    assert response.status_code == 422
