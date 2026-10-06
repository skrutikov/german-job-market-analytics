import logging

import requests
from sqlalchemy import text
from collections.abc import Callable

from src.data.arbeitsagentur_client import ArbeitsagenturClient
from src.data.database import get_database_connection


from datetime import datetime

logger = logging.getLogger(__name__)


GET_ACTIVE_JOBS_SQL = text("""
SELECT reference_number
FROM jobs
WHERE is_active = TRUE
""")


MARK_JOB_INACTIVE_SQL = text("""
UPDATE jobs
SET is_active = FALSE
WHERE reference_number = :reference_number
""")


MARK_JOB_SEEN_SQL = text("""
UPDATE jobs
SET last_seen = CURRENT_TIMESTAMP
WHERE reference_number = :reference_number
""")

MARK_SEEN_JOBS_SQL = text("""
UPDATE jobs
SET
    reappearance_count =
        CASE
            WHEN is_active = FALSE
            THEN reappearance_count + 1
            ELSE reappearance_count
        END,
    last_seen = CURRENT_TIMESTAMP,
    is_active = TRUE
WHERE reference_number = ANY(:reference_numbers)
""")

JOBS_TABLE_EXISTS_SQL = text("""
SELECT to_regclass('public.jobs')
""")


GET_JOB_STATES_SQL = text("""
SELECT
    reference_number,
    modified_at,
    is_active
FROM jobs
""")


def get_job_states() -> dict[str, tuple[datetime | None, bool]]:
    """Return the stored modification timestamp and active state."""

    with get_database_connection() as connection:
        table_name = connection.scalar(JOBS_TABLE_EXISTS_SQL)

        if table_name is None:
            return {}

        rows = connection.execute(GET_JOB_STATES_SQL)

        return {
            row.reference_number: (
                row.modified_at,
                row.is_active,
            )
            for row in rows
        }


def update_job_freshness(
    seen_reference_numbers: set[str],
    does_job_exist_func: Callable[[str], bool] | None = None,
) -> None:
    if does_job_exist_func is None:
        does_job_exist_func = ArbeitsagenturClient().does_job_exist

    # The search result itself confirms that these jobs exist.
    if seen_reference_numbers:
        with get_database_connection() as connection:
            with connection.begin():
                connection.execute(
                    MARK_SEEN_JOBS_SQL,
                    {"reference_numbers": list(seen_reference_numbers)},
                )

    with get_database_connection() as connection:
        active_reference_numbers = {
            row.reference_number for row in connection.execute(GET_ACTIVE_JOBS_SQL)
        }

    missing_reference_numbers = active_reference_numbers - seen_reference_numbers

    logger.info(
        "Checking %d previously active jobs not seen in this run",
        len(missing_reference_numbers),
    )

    for reference_number in missing_reference_numbers:
        try:
            does_job_exist = does_job_exist_func(reference_number)
        except requests.RequestException as error:
            logger.warning(
                "Could not verify job %s: %s",
                reference_number,
                error,
            )
            continue

        if does_job_exist:
            with get_database_connection() as connection:
                with connection.begin():
                    connection.execute(
                        MARK_JOB_SEEN_SQL,
                        {
                            "reference_number": reference_number,
                        },
                    )
            continue

        with get_database_connection() as connection:
            with connection.begin():
                connection.execute(
                    MARK_JOB_INACTIVE_SQL,
                    {
                        "reference_number": reference_number,
                    },
                )

        logger.info(
            "Marked job %s as inactive",
            reference_number,
        )
