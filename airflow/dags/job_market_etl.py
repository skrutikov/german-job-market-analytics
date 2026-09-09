from datetime import datetime
from pathlib import Path
import time

from airflow.sdk import dag, task  # type: ignore

from src.config.settings import DEFAULT_JOB_SEARCH_KEYWORDS
from src.data.etl.extract_data import extract_data
from src.data.etl.transform_data import transform_data
from src.data.etl.load_data import load_data
from src.data.job_freshness import update_job_freshness
from src.elasticsearch.elasticsearch import sync_jobs_index
from src.monitoring.metrics import (
    get_failed_geocoding_count,
    push_etl_metrics,
    reset_failed_geocoding,
)


@dag(
    schedule="0 6 * * *",
    start_date=datetime(2026, 8, 1),
    catchup=False,
    max_active_runs=1,
    tags=["job-market"],
)
def job_market_etl():

    @task
    def start_monitoring() -> float:
        return time.time()

    @task(multiple_outputs=True)
    def extract(_: float):
        raw_path, seen_reference_numbers = extract_data(DEFAULT_JOB_SEARCH_KEYWORDS)

        return {
            "raw_path": str(raw_path),
            "seen_reference_numbers": list(seen_reference_numbers),
        }

    @task(multiple_outputs=True)
    def transform(raw_path: str):
        reset_failed_geocoding()

        clean_path = transform_data(Path(raw_path))

        return {
            "clean_path": str(clean_path),
            "failed_geocoding_requests": get_failed_geocoding_count(),
        }

    @task
    def load(clean_path: str) -> str:
        load_data(Path(clean_path))
        return clean_path

    @task
    def update_freshness(
        seen_reference_numbers: list[str],
        clean_path: str,
    ) -> str:
        update_job_freshness(set(seen_reference_numbers))
        return clean_path

    @task
    def update_elasticsearch(clean_path: str) -> str:
        sync_jobs_index()
        return clean_path

    @task
    def publish_metrics(
        _: str,
        started_at: float,
        failed_geocoding_requests: int,
    ) -> None:
        push_etl_metrics(
            runtime_seconds=time.time() - started_at,
            failed_geocoding_requests=failed_geocoding_requests,
        )

    monitoring_starttime = start_monitoring()

    extracted_data = extract(monitoring_starttime)
    transformed_data = transform(extracted_data["raw_path"])
    loaded_data_path = load(transformed_data["clean_path"])

    freshness_done = update_freshness(
        extracted_data["seen_reference_numbers"],
        loaded_data_path,
    )

    elasticsearch_done = update_elasticsearch(freshness_done)

    publish_metrics(
        elasticsearch_done,
        monitoring_starttime,
        transformed_data["failed_geocoding_requests"],
    )

    # start monitoring → extract → transform → load → update job freshness → sync Elasticsearch → publish metrics


job_market_etl()
