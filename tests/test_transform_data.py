from src.data.etl.transform_data import _clean_job, _is_job_in_germany


def test_clean_job_maps_raw_fields_to_internal_schema() -> None:
    """Verify that raw API job data is mapped into the internal job schema."""
    raw_job = {
        "referenznummer": "10001-123456-S",
        "stellenangebotsTitel": "Senior Data Engineer",
        "hauptberuf": "Softwareentwicklung",
        "firma": "Example GmbH",
        "stellenangebotsBeschreibung": "Build data pipelines.",
        "arbeitszeitVollzeit": True,
        "homeofficemoeglich": True,
        "eintrittszeitraum": {"von": "2026-10-01"},
        "veroeffentlichungszeitraum": {"von": "2026-09-10"},
        "datumErsteVeroeffentlichung": "2026-09-01",
        "aenderungsdatum": "2026-09-12T08:30:00",
        "stellenlokationen": [
            {
                "adresse": {
                    "plz": "10115",
                    "ort": "Berlin",
                    "region": "Berlin",
                    "land": "DEUTSCHLAND",
                },
                "breite": 52.53,
                "laenge": 13.38,
            }
        ],
    }

    clean_job = _clean_job(raw_job)

    assert clean_job["reference_number"] == "10001-123456-S"
    assert clean_job["title"] == "Senior Data Engineer"
    assert clean_job["occupation"] == "Softwareentwicklung"
    assert clean_job["company"] == "Example GmbH"
    assert clean_job["description"] == "Build data pipelines."
    assert clean_job["full_time"] is True
    assert clean_job["home_office_possible"] is True
    assert clean_job["entry_date"] == "2026-10-01"
    assert clean_job["publication_date"] == "2026-09-10"
    assert clean_job["first_publication_date"] == "2026-09-01"
    assert clean_job["modified_at"] == "2026-09-12T08:30:00"
    assert clean_job["category"] == "Data Engineering"
    assert clean_job["locations"] == [
        {
            "postal_code": "10115",
            "city": "Berlin",
            "region": "Berlin",
            "country": "DEUTSCHLAND",
            "latitude": 52.53,
            "longitude": 13.38,
        }
    ]


def test_clean_job_handles_malformed_locations() -> None:
    """Verify that malformed location data is ignored without breaking transformation."""
    raw_job = {
        "referenznummer": "10001-123456-S",
        "stellenangebotsTitel": "Data Analyst",
        "stellenlokationen": "not-a-list",
    }

    clean_job = _clean_job(raw_job)

    assert clean_job["locations"] == []
    assert clean_job["category"] == "Data Analysis"


def test_is_job_in_germany_accepts_german_location() -> None:
    """Verify that a job is accepted when at least one location is in Germany."""
    job = {
        "locations": [
            {"country": "FRANKREICH"},
            {"country": "DEUTSCHLAND"},
        ]
    }

    assert _is_job_in_germany(job) is True


def test_is_job_in_germany_rejects_non_german_job() -> None:
    """Verify that jobs without a German location are rejected."""
    job = {
        "locations": [
            {"country": "FRANKREICH"},
            {"country": "ÖSTERREICH"},
        ]
    }

    assert _is_job_in_germany(job) is False
