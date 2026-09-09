import argparse
from pathlib import Path

from sqlalchemy import text

from src.config.settings import DEFAULT_JOB_SEARCH_KEYWORDS, PUSHGATEWAY_URL
from src.data.database import get_database_connection
from src.data.etl.extract_data import extract_data
from src.data.etl.transform_data import transform_data
from src.data.etl.load_data import load_data
from src.data.job_freshness import update_job_freshness
from src.elasticsearch.elasticsearch import sync_jobs_index
from src.monitoring.metrics import monitor_etl_run
from src.data.utils.json_utils import load_json


def _parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run the complete job-market ETL pipeline."
    )

    parser.add_argument(
        "--keyword",
        action="append",
        dest="keywords",
        help="Job-search keyword. Can be specified multiple times.",
    )

    parser.add_argument(
        "--simulate",
        action="store_true",
        help="Run the ETL with predefined sample snapshots.",
    )

    return parser.parse_args()


def _run_simulation() -> None:
    # clean DB first
    with get_database_connection() as connection:
        with connection.begin():
            connection.execute(text("""
                    DROP TABLE IF EXISTS job_locations;
                    DROP TABLE IF EXISTS jobs;
                """))

    for sample_number in range(1, 4):
        raw_path = Path("data/samples") / f"job-details-{sample_number}.json"
        job_details = load_json(raw_path)

        seen_reference_numbers = {job["referenznummer"] for job in job_details}

        clean_path = transform_data(raw_path)
        load_data(clean_path)
        update_job_freshness(
            seen_reference_numbers,
            does_job_exist_func=lambda reference_number: (
                reference_number in seen_reference_numbers
            ),
        )


@monitor_etl_run
def main() -> None:
    arguments = _parse_arguments()

    if arguments.simulate:
        _run_simulation()
        return

    keywords = (
        tuple(arguments.keywords) if arguments.keywords else DEFAULT_JOB_SEARCH_KEYWORDS
    )

    raw_path, seen_reference_numbers = extract_data(keywords)
    clean_path = transform_data(raw_path)
    load_data(clean_path)
    update_job_freshness(seen_reference_numbers)
    sync_jobs_index()


if __name__ == "__main__":
    main()
