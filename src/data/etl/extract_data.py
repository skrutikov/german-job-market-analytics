"""E/ETL: Extract raw job data from the Arbeitsagentur job-search API."""

import logging
import math
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import requests

from src.config.settings import (
    API_START_PAGE,
    JOB_DETAIL_FAILURES_FILE_NAME,
    JOB_DETAILS_FILE_NAME,
    API_REQUEST_PAGE_SIZE,
    DEFAULT_JOB_SEARCH_KEYWORDS,
    RAW_DATA_DIRECTORY,
)
from src.data.arbeitsagentur_client import ArbeitsagenturClient
from src.data.utils.json_utils import save_json
from src.data.job_freshness import get_job_states

logger = logging.getLogger(__name__)


def _parse_modified_at(value: Any) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None

    try:
        return datetime.fromisoformat(value)
    except ValueError:
        return None


def _search_jobs(
    client: ArbeitsagenturClient,
    *,
    keywords: tuple[str, ...],
    first_page: int,
    jobs_per_page: int,
    output_directory: Path,
) -> list[dict[str, Any]]:
    job_summaries: list[dict[str, Any]] = []
    seen_reference_numbers: set[str] = set()

    for keyword in keywords:
        keyword_directory = (
            output_directory / "search-results" / keyword.lower().replace(" ", "-")
        )

        try:
            first_result = client.search_jobs(
                keyword=keyword,
                page_number=first_page,
                jobs_per_page=jobs_per_page,
            )
        except requests.RequestException:
            logger.exception(
                "Failed to retrieve first page for %r",
                keyword,
            )
            continue

        max_results = first_result.get("maxErgebnisse", 0)
        page_size = first_result.get("size", jobs_per_page)

        if not isinstance(max_results, int) or not isinstance(page_size, int):
            logger.warning(
                "Invalid pagination information for %r",
                keyword,
            )
            continue

        if page_size <= 0:
            logger.warning(
                "Invalid page size for %r: %r",
                keyword,
                page_size,
            )
            continue

        total_pages = math.ceil(max_results / page_size)

        logger.info(
            "%r: %d results across %d pages (page size %d)",
            keyword,
            max_results,
            total_pages,
            page_size,
        )

        for page_number in range(first_page, first_page + total_pages):
            if page_number == first_page:
                search_result = first_result
            else:
                try:
                    search_result = client.search_jobs(
                        keyword=keyword,
                        page_number=page_number,
                        jobs_per_page=jobs_per_page,
                    )
                except requests.RequestException:
                    logger.exception(
                        "Failed to retrieve page %d for %r",
                        page_number,
                        keyword,
                    )
                    continue

            save_json(
                search_result,
                keyword_directory / f"page-{page_number:03d}.json",
            )

            jobs = search_result.get("ergebnisliste")

            if not isinstance(jobs, list):
                logger.warning(
                    "Skipping page %d for %r: " "'ergebnisliste' is not a list",
                    page_number,
                    keyword,
                )
                continue

            for job in jobs:
                if not isinstance(job, dict):
                    logger.warning(
                        "Skipping malformed search-result entry: %r",
                        job,
                    )
                    continue

                reference_number = job.get("referenznummer")

                if not isinstance(reference_number, str) or not reference_number:
                    logger.warning(
                        "Skipping search result without a valid "
                        "reference number: %r",
                        job,
                    )
                    continue

                if reference_number in seen_reference_numbers:
                    continue

                seen_reference_numbers.add(reference_number)
                job_summaries.append(job)

    return job_summaries


def _retrieve_job_details(
    client: ArbeitsagenturClient,
    job_summaries: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    job_details: list[dict[str, Any]] = []
    failures: list[dict[str, str]] = []

    for job_number, job_summary in enumerate(job_summaries, start=1):
        reference_number = job_summary["referenznummer"]

        logger.info(
            "Retrieving details for %d/%d: %s",
            job_number,
            len(job_summaries),
            reference_number,
        )

        try:
            details = client.get_job_details(reference_number)
        except requests.RequestException as error:
            logger.warning(
                "Failed to retrieve details for %s: %s",
                reference_number,
                error,
            )
            failures.append(
                {
                    "referenznummer": reference_number,
                    "error": str(error),
                }
            )
            continue

        job_details.append(details)

    return job_details, failures


def _select_jobs_requiring_details(
    job_summaries: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    job_states = get_job_states()

    jobs_requiring_details: list[dict[str, Any]] = []

    for job_summary in job_summaries:
        reference_number = job_summary["referenznummer"]

        stored_state = job_states.get(reference_number)

        # New job.
        if stored_state is None:
            jobs_requiring_details.append(job_summary)
            continue

        stored_modified_at, _is_active = stored_state

        source_modified_at = _parse_modified_at(job_summary.get("aenderungsdatum"))

        # If either timestamp is missing, we cannot safely say
        # that the job is unchanged.
        if source_modified_at is None or stored_modified_at is None:
            jobs_requiring_details.append(job_summary)
            continue

        # Existing job changed at BA.
        if source_modified_at != stored_modified_at:
            jobs_requiring_details.append(job_summary)

    logger.info(
        "%d of %d jobs require detail retrieval",
        len(jobs_requiring_details),
        len(job_summaries),
    )

    return jobs_requiring_details


def extract_data(keywords: tuple[str, ...]) -> tuple[Path, set[str]]:
    """Extract raw job data and return the details path and seen references."""
    extraction_time = datetime.now(timezone.utc)
    output_directory = RAW_DATA_DIRECTORY / extraction_time.strftime(
        "%Y-%m-%dT%H-%M-%SZ"
    )
    details_output_path = output_directory / JOB_DETAILS_FILE_NAME
    failures_output_path = output_directory / JOB_DETAIL_FAILURES_FILE_NAME

    client = ArbeitsagenturClient()

    job_summaries = _search_jobs(
        client,
        keywords=keywords,
        first_page=API_START_PAGE,
        jobs_per_page=API_REQUEST_PAGE_SIZE,
        output_directory=output_directory,
    )

    seen_reference_numbers = {job["referenznummer"] for job in job_summaries}

    logger.info(
        "Retrieved %d unique search results",
        len(job_summaries),
    )

    jobs_requiring_details = _select_jobs_requiring_details(job_summaries)

    job_details, failed_jobs = _retrieve_job_details(
        client,
        jobs_requiring_details,
    )

    save_json(job_details, details_output_path)
    save_json(failed_jobs, failures_output_path)

    logger.info(
        "Extraction finished: %d details retrieved, %d detail requests failed",
        len(job_details),
        len(failed_jobs),
    )
    logger.info("Raw job details saved to %s", details_output_path)

    return details_output_path, seen_reference_numbers


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
    )

    extract_data(DEFAULT_JOB_SEARCH_KEYWORDS)


if __name__ == "__main__":
    main()
