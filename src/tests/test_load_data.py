from datetime import date, datetime

import pytest

from src.data.etl.load_data import _prepare_job


def test_prepare_job_converts_dates_and_excludes_locations() -> None:
    job = {
        "reference_number": "10001-123456-S",
        "title": "Data Engineer",
        "publication_date": "2026-09-10",
        "first_publication_date": "2026-09-01",
        "entry_date": "2026-10-01",
        "modified_at": "2026-09-12T08:30:00",
        "locations": [
            {
                "city": "Berlin",
                "country": "DEUTSCHLAND",
            }
        ],
    }

    prepared_job = _prepare_job(job)

    assert "locations" not in prepared_job
    assert prepared_job["reference_number"] == "10001-123456-S"
    assert prepared_job["publication_date"] == date(2026, 9, 10)
    assert prepared_job["first_publication_date"] == date(2026, 9, 1)
    assert prepared_job["entry_date"] == date(2026, 10, 1)
    assert prepared_job["modified_at"] == datetime(2026, 9, 12, 8, 30)


@pytest.mark.parametrize(
    "reference_number",
    [None, "", 12345],
)
def test_prepare_job_rejects_invalid_reference_number(
    reference_number: object,
) -> None:
    job = {
        "reference_number": reference_number,
        "locations": [],
    }

    with pytest.raises(
        ValueError,
        match="Job is missing a valid reference_number",
    ):
        _prepare_job(job)
