import base64

import pytest

from src.data.arbeitsagentur_client import ArbeitsagenturClient


class FakeResponse:
    """A lightweight mock/fake for requests.Response."""

    def __init__(self, data: dict | None = None) -> None:
        self._data = data or {"stellenangebote": []}

    def raise_for_status(self) -> None:
        pass

    def json(self) -> dict:
        return self._data


def test_search_jobs_builds_correct_request(monkeypatch: pytest.MonkeyPatch) -> None:
    """Verify that job searches send the expected URL, parameters, and timeout."""
    client = ArbeitsagenturClient(timeout_seconds=12)
    captured_request: dict[str, object] = {}

    def fake_get(
        url: str,
        *,
        params: dict[str, str | int],
        timeout: int,
    ) -> FakeResponse:
        captured_request["url"] = url
        captured_request["params"] = params
        captured_request["timeout"] = timeout
        return FakeResponse()

    # inject our fake_get function into the client.session.get method
    monkeypatch.setattr(client.session, "get", fake_get)

    result = client.search_jobs(
        "Data Engineer",
        location="Berlin",
        page_number=2,
        jobs_per_page=50,
    )

    assert result == {"stellenangebote": []}
    assert captured_request == {
        "url": client.jobs_url,
        "params": {
            "was": "Data Engineer",
            "wo": "Berlin",
            "page": 2,
            "size": 50,
        },
        "timeout": 12,
    }


@pytest.mark.parametrize("page_number", [0, -1])
def test_search_jobs_rejects_invalid_page_number(page_number: int) -> None:
    """Verify that page numbers below 1 are rejected before an API request."""
    client = ArbeitsagenturClient()

    with pytest.raises(ValueError, match="page_number must be at least 1"):
        client.search_jobs(
            "Data Engineer",
            page_number=page_number,
        )


@pytest.mark.parametrize("jobs_per_page", [0, 101])
def test_search_jobs_rejects_invalid_page_size(jobs_per_page: int) -> None:
    """Verify that page sizes outside the supported range are rejected."""
    client = ArbeitsagenturClient()

    with pytest.raises(
        ValueError,
        match="jobs_per_page must be between 1 and 100",
    ):
        client.search_jobs(
            "Data Engineer",
            jobs_per_page=jobs_per_page,
        )


def test_get_job_details_encodes_reference_number(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Verify that job IDs are Base64-encoded in detail-request URLs."""
    client = ArbeitsagenturClient(timeout_seconds=8)
    captured_request: dict[str, object] = {}

    def fake_get(url: str, *, timeout: int) -> FakeResponse:
        captured_request["url"] = url
        captured_request["timeout"] = timeout
        return FakeResponse({"referenznummer": "10001-123456-S"})

    monkeypatch.setattr(client.session, "get", fake_get)

    result = client.get_job_details("10001-123456-S")

    encoded_reference_number = base64.b64encode(b"10001-123456-S").decode("ascii")

    assert result == {"referenznummer": "10001-123456-S"}
    assert captured_request == {
        "url": f"{client.job_details_url}/{encoded_reference_number}",
        "timeout": 8,
    }


def test_get_job_details_rejects_empty_reference_number() -> None:
    """Verify that job-detail requests reject an empty job ID."""
    client = ArbeitsagenturClient()

    with pytest.raises(
        ValueError,
        match="reference_number must not be empty",
    ):
        client.get_job_details("")
