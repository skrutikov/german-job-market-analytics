"""T/ETL: Transform raw Arbeitsagentur job details into clean job data."""

import argparse
import logging
from pathlib import Path
from typing import Any

from src.config.settings import CLEAN_JSON_FILE_NAME, PROCESSED_DATA_DIRECTORY
from src.data.job_location_geocoder import JobLocationGeocoder
from src.data.utils.json_utils import load_json, save_json
from src.data.job_category_classifier import classify_job

logger = logging.getLogger(__name__)


def _parse_arguments() -> argparse.Namespace:
    """Parse command-line arguments."""

    parser = argparse.ArgumentParser(
        description="Transform raw Arbeitsagentur job details into clean job data."
    )

    parser.add_argument(
        "source_path",
        type=Path,
        help="Path to a job-details.json file.",
    )

    return parser.parse_args()


def _clean_job(raw_job: dict[str, Any]) -> dict[str, Any]:
    """Convert one raw Arbeitsagentur job into our cleaner structure."""

    raw_locations = raw_job.get("stellenlokationen", [])
    clean_locations: list[dict[str, Any]] = []

    if not isinstance(raw_locations, list):
        logger.warning(
            "Ignoring malformed 'stellenlokationen' value: %r",
            raw_locations,
        )
        raw_locations = []

    for raw_location in raw_locations:
        if not isinstance(raw_location, dict):
            continue

        raw_address = raw_location.get("adresse", {})

        if not isinstance(raw_address, dict):
            raw_address = {}

        clean_locations.append(
            {
                "postal_code": raw_address.get("plz"),
                "city": raw_address.get("ort"),
                "region": raw_address.get("region"),
                "country": raw_address.get("land"),
                "latitude": raw_location.get("breite"),
                "longitude": raw_location.get("laenge"),
            }
        )

    entry_period = raw_job.get("eintrittszeitraum", {})
    publication_period = raw_job.get("veroeffentlichungszeitraum", {})

    if not isinstance(entry_period, dict):
        entry_period = {}

    if not isinstance(publication_period, dict):
        publication_period = {}

    return {
        "reference_number": raw_job.get("referenznummer"),
        "title": raw_job.get("stellenangebotsTitel"),
        "occupation": raw_job.get("hauptberuf"),
        "company": raw_job.get("firma"),
        "description": raw_job.get("stellenangebotsBeschreibung"),
        "offer_type": raw_job.get("stellenangebotsart"),
        "full_time": raw_job.get("arbeitszeitVollzeit"),
        "contract_duration": raw_job.get("vertragsdauer"),
        "career_change_suitable": raw_job.get("quereinstiegGeeignet"),
        "home_office_possible": raw_job.get("homeofficemoeglich"),
        "temporary_employment": raw_job.get("istArbeitnehmerUeberlassung"),
        "private_placement": raw_job.get("istPrivateArbeitsvermittlung"),
        "salary_period": raw_job.get("verguetungsangabe"),
        "salary_type": raw_job.get("artDerVerguetung"),
        "salary_min": raw_job.get("gehaltsspanneVon"),
        "salary_max": raw_job.get("gehaltsspanneBis"),
        "entry_date": entry_period.get("von"),
        "publication_date": publication_period.get("von"),
        "first_publication_date": raw_job.get("datumErsteVeroeffentlichung"),
        "modified_at": raw_job.get("aenderungsdatum"),
        "external_url": raw_job.get("externeURL"),
        "partner_name": raw_job.get("allianzpartnerName"),
        "partner_url": raw_job.get("allianzpartnerUrl"),
        "employer_customer_hash": raw_job.get("arbeitgeberKundennummerHash"),
        "locations": clean_locations,
        "category": classify_job(
            title=raw_job.get("stellenangebotsTitel"),
            occupation=raw_job.get("hauptberuf"),
        ),
    }


def _is_job_in_germany(job: dict[str, Any]) -> bool:
    return any(
        location.get("country") == "DEUTSCHLAND"
        for location in job.get("locations", [])
    )


def transform_data(source_path: Path) -> Path:
    """Transform raw job details and return the clean JSON path."""
    clean_output_path = (
        PROCESSED_DATA_DIRECTORY / source_path.parent.name / CLEAN_JSON_FILE_NAME
    )

    job_details = load_json(source_path)
    clean_jobs = [_clean_job(job) for job in job_details]
    clean_jobs = [job for job in clean_jobs if _is_job_in_germany(job)]

    geocoder = JobLocationGeocoder()
    clean_jobs, num_malformed_locations = geocoder.enrich_jobs_with_geocoding(
        clean_jobs
    )

    save_json(clean_jobs, clean_output_path)

    logger.info(
        "Transformation finished: %d jobs transformed, "
        "%d malformed locations skipped",
        len(clean_jobs),
        num_malformed_locations,
    )
    logger.info("Clean job data saved to %s", clean_output_path)

    return clean_output_path


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
    )

    arguments = _parse_arguments()
    transform_data(arguments.source_path)


if __name__ == "__main__":
    main()
