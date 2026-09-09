"""L/ETL: Load cleaned Arbeitsagentur job data into the job database."""

import argparse
import logging
from datetime import date, datetime
from pathlib import Path
from typing import Any
from sqlalchemy import Connection, text
from sqlalchemy.exc import IntegrityError

from src.data.database import get_database_connection
from src.data.utils.json_utils import load_json

# region SQL statements

CREATE_JOBS_TABLE_SQL = text("""
CREATE TABLE IF NOT EXISTS jobs (
    reference_number TEXT PRIMARY KEY,
    title TEXT,
    occupation TEXT,
    company TEXT,
    description TEXT,
    offer_type TEXT,
    full_time BOOLEAN,
    contract_duration TEXT,
    career_change_suitable BOOLEAN,
    home_office_possible BOOLEAN,
    temporary_employment BOOLEAN,
    private_placement BOOLEAN,
    salary_period TEXT,
    salary_type TEXT,
    salary_min DOUBLE PRECISION,
    salary_max DOUBLE PRECISION,
    entry_date DATE,
    publication_date DATE,
    first_publication_date DATE,
    external_url TEXT,
    partner_name TEXT,
    partner_url TEXT,
    employer_customer_hash TEXT,
    category TEXT NOT NULL DEFAULT 'Other',
    reappearance_count INTEGER NOT NULL DEFAULT 0,
    modification_count INTEGER NOT NULL DEFAULT 0,
    modified_at TIMESTAMP,
    -- first_seen := first time our system confirmed the job existed
    first_seen TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    -- last_seen := most recent time our system confirmed it existed
    last_seen TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    -- is_active := most recent existence state
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    -- unchanged_republish_count := how often the job was republished without changes since last update
    unchanged_republish_count INTEGER NOT NULL DEFAULT 0
);
""")


CREATE_JOB_LOCATIONS_TABLE_SQL = text("""
CREATE TABLE IF NOT EXISTS job_locations (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reference_number TEXT NOT NULL
        REFERENCES jobs(reference_number)
        ON DELETE CASCADE,
    postal_code TEXT,
    city TEXT,
    region TEXT,
    country TEXT,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION
);
""")


CREATE_LOCATION_INDEX_SQL = text("""
CREATE INDEX IF NOT EXISTS idx_job_locations_reference_number
ON job_locations (reference_number);
""")


UPSERT_JOB_SQL = text("""
INSERT INTO jobs (
    reference_number,
    title,
    occupation,
    company,
    description,
    offer_type,
    full_time,
    contract_duration,
    career_change_suitable,
    home_office_possible,
    temporary_employment,
    private_placement,
    salary_period,
    salary_type,
    salary_min,
    salary_max,
    entry_date,
    publication_date,
    first_publication_date,
    external_url,
    partner_name,
    partner_url,
    employer_customer_hash,
    category,
    modified_at
)
VALUES (
    :reference_number,
    :title,
    :occupation,
    :company,
    :description,
    :offer_type,
    :full_time,
    :contract_duration,
    :career_change_suitable,
    :home_office_possible,
    :temporary_employment,
    :private_placement,
    :salary_period,
    :salary_type,
    :salary_min,
    :salary_max,
    :entry_date,
    :publication_date,
    :first_publication_date,
    :external_url,
    :partner_name,
    :partner_url,
    :employer_customer_hash,
    :category,
    :modified_at
)
ON CONFLICT(reference_number) DO UPDATE SET
    title = excluded.title,
    occupation = excluded.occupation,
    company = excluded.company,
    description = excluded.description,
    offer_type = excluded.offer_type,
    full_time = excluded.full_time,
    contract_duration = excluded.contract_duration,
    career_change_suitable = excluded.career_change_suitable,
    home_office_possible = excluded.home_office_possible,
    temporary_employment = excluded.temporary_employment,
    private_placement = excluded.private_placement,
    salary_period = excluded.salary_period,
    salary_type = excluded.salary_type,
    salary_min = excluded.salary_min,
    salary_max = excluded.salary_max,
    entry_date = excluded.entry_date,
    publication_date = excluded.publication_date,
    first_publication_date = excluded.first_publication_date,
    external_url = excluded.external_url,
    partner_name = excluded.partner_name,
    partner_url = excluded.partner_url,
    employer_customer_hash = excluded.employer_customer_hash,
    category = excluded.category,
    -- modification_count = 0  →  never observed changing
    -- modification_count > 0  →  has been modified
    modification_count =
        CASE
            WHEN jobs.modified_at IS DISTINCT FROM excluded.modified_at
                AND jobs.modified_at IS NOT NULL
                AND excluded.modified_at IS NOT NULL
            THEN jobs.modification_count + 1
            ELSE jobs.modification_count
        END,
    modified_at = excluded.modified_at,
    -- Important: the reappearance_count expression must inspect the old jobs.is_active value before setting it back to TRUE.
    reappearance_count =
        CASE
            WHEN jobs.is_active = FALSE
            THEN jobs.reappearance_count + 1
            ELSE jobs.reappearance_count
        END,
    unchanged_republish_count =
    CASE
        -- A real modification resets the streak of unchanged publications.
        WHEN jobs.modified_at IS DISTINCT FROM EXCLUDED.modified_at THEN 0
        -- Publication date moved, but the job was not modified.
        WHEN jobs.publication_date IS DISTINCT FROM EXCLUDED.publication_date THEN jobs.unchanged_republish_count + 1
        -- Nothing relevant changed.
        ELSE jobs.unchanged_republish_count
    END,
    last_seen = CURRENT_TIMESTAMP,
    is_active = TRUE
""")

INSERT_LOCATION_SQL = text("""
INSERT INTO job_locations (
    reference_number,
    postal_code,
    city,
    region,
    country,
    latitude,
    longitude
)
VALUES (
    :reference_number,
    :postal_code,
    :city,
    :region,
    :country,
    :latitude,
    :longitude
);
""")

# endregion


logger = logging.getLogger(__name__)


def _parse_arguments() -> argparse.Namespace:
    """Parse command-line arguments."""

    parser = argparse.ArgumentParser(
        description="Load clean Arbeitsagentur jobs into the job database."
    )

    parser.add_argument(
        "source",
        type=Path,
        help="Path to a clean-jobs.json file.",
    )

    return parser.parse_args()


def _to_date(value: str | None) -> date | None:
    if value is None:
        return None

    return date.fromisoformat(value)


def _to_datetime(value: str | None) -> datetime | None:
    if value is None:
        return None

    return datetime.fromisoformat(value)


def _prepare_job(job: dict[str, Any]) -> dict[str, Any]:
    """Prepare one cleaned job for insertion into the database."""

    reference_number = job.get("reference_number")

    if not isinstance(reference_number, str) or not reference_number:
        raise ValueError("Job is missing a valid reference_number")

    # Exclude locations because they are stored separately in the
    # job_locations table.
    prepared_job = {key: value for key, value in job.items() if key != "locations"}

    prepared_job["publication_date"] = _to_date(job.get("publication_date"))
    prepared_job["first_publication_date"] = _to_date(job.get("first_publication_date"))
    prepared_job["entry_date"] = _to_date(job.get("entry_date"))
    prepared_job["modified_at"] = _to_datetime(job.get("modified_at"))

    return prepared_job


def _load_jobs(
    connection: Connection,
    jobs: list[dict[str, Any]],
) -> tuple[int, int]:
    """Insert or update jobs, using one transaction per job."""

    num_loaded_jobs = 0
    num_skipped_jobs = 0

    for job_number, job in enumerate(jobs, start=1):
        try:
            # Commit all changes for this job together, or roll them all back.
            with connection.begin():
                prepared_job = _prepare_job(job)
                reference_number = prepared_job["reference_number"]

                connection.execute(UPSERT_JOB_SQL, prepared_job)

                connection.execute(
                    text("""
                        DELETE FROM job_locations
                        WHERE reference_number = :reference_number
                    """),
                    {
                        "reference_number": reference_number,
                    },
                )

                locations = job.get("locations", [])

                if locations is None:
                    locations = []

                if not isinstance(locations, list):
                    raise TypeError("'locations' must be a list")

                for location in locations:
                    if not isinstance(location, dict):
                        raise TypeError("Each location must be a JSON object")

                    connection.execute(
                        INSERT_LOCATION_SQL,
                        {
                            "reference_number": reference_number,
                            "postal_code": location.get("postal_code"),
                            "city": location.get("city"),
                            "region": location.get("region"),
                            "country": location.get("country"),
                            "latitude": location.get("latitude"),
                            "longitude": location.get("longitude"),
                        },
                    )

            num_loaded_jobs += 1

        except (ValueError, TypeError, IntegrityError) as error:
            num_skipped_jobs += 1
            logger.warning(
                "Skipping job %d: %s",
                job_number,
                error,
            )

    return num_loaded_jobs, num_skipped_jobs


def _load_clean_jobs_to_db(
    jobs: list[dict[str, Any]],
) -> tuple[int, int]:
    """Create the database schema and load cleaned jobs."""

    with get_database_connection() as connection:
        # Create Schema is one transaction
        with connection.begin():
            connection.execute(CREATE_JOBS_TABLE_SQL)
            connection.execute(CREATE_JOB_LOCATIONS_TABLE_SQL)
            connection.execute(CREATE_LOCATION_INDEX_SQL)

        # Creates one transaction per job
        return _load_jobs(
            connection=connection,
            jobs=jobs,
        )


def load_data(source_path: Path) -> tuple[int, int]:
    """Load a clean-jobs JSON file into the job database."""

    if not source_path.is_file():
        raise FileNotFoundError(f"JSON file not found: {source_path}")

    jobs = load_json(source_path)

    loaded_jobs, skipped_jobs = _load_clean_jobs_to_db(jobs=jobs)

    logger.info("Source file: %s", source_path)
    logger.info("Loaded jobs: %d", loaded_jobs)
    logger.info("Skipped jobs: %d", skipped_jobs)

    return loaded_jobs, skipped_jobs


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
    )

    arguments = _parse_arguments()
    load_data(arguments.source)


if __name__ == "__main__":
    main()
