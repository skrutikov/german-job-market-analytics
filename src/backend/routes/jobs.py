"""
API routes for reading job advertisements from the job database.

The endpoints in this module provide read-only access to jobs previously
collected and processed by the data pipeline.
"""

from datetime import date, datetime
import logging

from fastapi import APIRouter, HTTPException, Query, status
from pydantic import BaseModel, Field
from sqlalchemy import text
from src.elasticsearch.elasticsearch import (
    ElasticsearchUnavailableError,
    search_job_reference_numbers,
)

from src.data.database import (
    DatabaseUnavailableError,
    get_database_connection,
)
from src.monitoring.metrics import monitor_job_search

# region Setup

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/jobs",
    tags=["Jobs"],
)

# endregion


# region SQL queries

# Retrieve summary information for all stored jobs.
GET_ALL_JOBS_SQL = """
SELECT
    jobs.reference_number,
    jobs.title,
    jobs.company,
    jobs.occupation,
    jobs.salary_min,
    jobs.salary_max,
    jobs.salary_period,
    jobs.category,
    selected_location.city,
    selected_location.latitude,
    selected_location.longitude
FROM jobs
LEFT JOIN LATERAL (
    SELECT
        job_locations.city,
        job_locations.latitude,
        job_locations.longitude
    FROM job_locations
    WHERE job_locations.reference_number = jobs.reference_number
    ORDER BY
        CASE
            WHEN LOWER(job_locations.city) = LOWER(CAST(:preferred_city AS TEXT))
                AND job_locations.latitude IS NOT NULL
                AND job_locations.longitude IS NOT NULL
                THEN 0

            WHEN LOWER(job_locations.city) = LOWER(CAST(:preferred_city AS TEXT))
                THEN 1

            WHEN job_locations.latitude IS NOT NULL
                AND job_locations.longitude IS NOT NULL
                THEN 2

            ELSE 3
        END,
        job_locations.id
    LIMIT 1
) AS selected_location ON TRUE
"""

# Retrieve all available details for one job.
GET_SINGLE_JOB_SQL = text("""
SELECT
    reference_number,
    title,
    occupation,
    company,
    category,
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
    modified_at,
    first_seen,
    last_seen,
    is_active,
    reappearance_count,
    modification_count,
    unchanged_republish_count
FROM jobs
WHERE reference_number = :reference_number
""")

# Retrieve all locations associated with one job.
GET_JOB_LOCATIONS_SQL = text("""
SELECT
    postal_code,
    city,
    region,
    country,
    latitude,
    longitude
FROM job_locations
WHERE reference_number = :reference_number
ORDER BY id
""")

# endregion


# region Pydantic models


class JobModel(BaseModel):
    """A compact representation of a job advertisement."""

    reference_number: str
    title: str
    company: str | None = None
    occupation: str | None = None
    city: str | None = None
    salary_min: float | None = None
    salary_max: float | None = None
    salary_period: str | None = None
    latitude: float | None = None
    longitude: float | None = None
    category: str


class JobLocationModel(BaseModel):
    """A geographical location associated with a job advertisement."""

    postal_code: str | None = None
    city: str | None = None
    region: str | None = None
    country: str | None = None
    latitude: float | None = None
    longitude: float | None = None


class JobDetailModel(JobModel):
    """A complete job advertisement, including details and locations."""

    description: str | None = None
    offer_type: str | None = None
    full_time: bool | None = None
    contract_duration: str | None = None
    career_change_suitable: bool | None = None
    home_office_possible: bool | None = None
    temporary_employment: bool | None = None
    private_placement: bool | None = None
    salary_period: str | None = None
    salary_type: str | None = None
    salary_min: float | None = None
    salary_max: float | None = None
    entry_date: date | None = None
    publication_date: date | None = None
    first_publication_date: date | None = None
    external_url: str | None = None
    partner_name: str | None = None
    partner_url: str | None = None
    employer_customer_hash: str | None = None
    modified_at: datetime | None = None
    first_seen: datetime
    last_seen: datetime
    is_active: bool
    reappearance_count: int
    modification_count: int
    unchanged_republish_count: int
    # "Field(default_factory=list)" ensures that the default value is a new empty list for EACH instance
    locations: list[JobLocationModel] = Field(default_factory=list)


# endregion


# region Private helpers


def _get_jobs_by_reference_numbers(
    reference_numbers: list[str],
    preferred_city: str | None = None,
) -> list[dict]:
    """Retrieve jobs from PostgreSQL while preserving Elasticsearch ranking."""

    if not reference_numbers:
        return []

    parameters: dict[str, object] = {
        "preferred_city": preferred_city,
    }

    parameters.update(
        {
            f"reference_{index}": reference_number
            for index, reference_number in enumerate(reference_numbers)
        }
    )

    placeholders = ", ".join(
        f":reference_{index}" for index in range(len(reference_numbers))
    )

    ordering = " ".join(
        f"WHEN :reference_{index} THEN {index}"
        for index in range(len(reference_numbers))
    )

    # ORDER BY CASE preserves Elasticsearch's relevance ranking.
    query = text(GET_ALL_JOBS_SQL + f"""
        WHERE jobs.reference_number IN ({placeholders})
        ORDER BY CASE jobs.reference_number
            {ordering}
        END
        """)

    with get_database_connection() as connection:
        rows = (
            connection.execute(
                query,
                parameters,
            )
            .mappings()
            .all()
        )

    return [dict(row) for row in rows]


# endregion

# region API endpoints


@router.get(
    "",
    summary="Get jobs",
    response_description="A list of available jobs",
    response_model=list[JobModel],
    responses={
        503: {
            "description": "The job database or search service is unavailable",
        }
    },
)
@monitor_job_search  # order is important (@monitor_job_search should be close to the function)
def get_jobs(
    keyword: str | None = Query(
        default=None,
        description=(
            "Full-text search across job title, occupation, description, company, and category"
        ),
        examples=["Python Kubernetes"],
    ),
    limit: int = Query(
        default=20,
        ge=1,
        le=100,
        description="Maximum number of jobs to return",
        examples=[5, 10, 20],
        openapi_examples={
            "small": {
                "summary": "Small result set",
                "value": 5,
            },
            "medium": {
                "summary": "Medium result set",
                "value": 10,
            },
            "large": {
                "summary": "Large result set",
                "value": 20,
            },
        },
    ),
    offset: int = Query(
        default=0,
        ge=0,
        description="Number of jobs to skip",
        examples=[0],
    ),
    city: str | None = Query(
        default=None,
        description="City to filter jobs by",
        examples=["Berlin", "München", "Hamburg"],
    ),
    company: str | None = Query(
        default=None,
        description="Company name to filter jobs by",
        examples=["FERCHAU"],
        openapi_examples={
            "FERCHAU": {
                "summary": "FERCHAU GmbH",
                "value": "FERCHAU",
            },
        },
    ),
    home_office: bool | None = Query(
        default=None,
        description="Filter by home-office availability",
        examples=[None, True, False],
    ),
    category: str | None = Query(
        default=None,
        description="Standardized job category",
        examples=["Data Engineering"],
    ),
) -> list[JobModel]:
    """
    Return active job advertisements.

    Keyword searches use Elasticsearch and are ordered by relevance.
    Without a keyword, jobs are ordered by publication date, newest first.

    Use `limit` and `offset` for pagination.
    """

    query_conditions = ["jobs.is_active = TRUE"]
    query_parameters: dict[str, object] = {
        "preferred_city": city,
    }

    if keyword is not None:
        try:
            reference_numbers = search_job_reference_numbers(
                keyword,
                limit=limit,
                offset=offset,
                city=city,
                company=company,
                home_office=home_office,
                category=category,
            )

            jobs = _get_jobs_by_reference_numbers(
                reference_numbers,
                preferred_city=city,
            )
        except ElasticsearchUnavailableError:
            logger.exception("Could not search Elasticsearch")

            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="The job search service is unavailable.",
            )
        except DatabaseUnavailableError:
            logger.exception("Could not read the job database")
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="The job database is unavailable.",
            )
        return [JobModel(**job) for job in jobs]

    if city is not None:
        query_conditions.append("""
            EXISTS (
                SELECT 1
                FROM job_locations
                WHERE job_locations.reference_number = jobs.reference_number
                  AND LOWER(job_locations.city) = LOWER(:city)
            )
            """)
        query_parameters["city"] = city

    if company is not None:
        query_conditions.append("LOWER(company) LIKE LOWER(:company)")
        query_parameters["company"] = f"%{company}%"

    if home_office is not None:
        query_conditions.append("home_office_possible = :home_office")
        query_parameters["home_office"] = home_office

    if category is not None:
        query_conditions.append("LOWER(category) = LOWER(:category)")
        query_parameters["category"] = category

    query = GET_ALL_JOBS_SQL

    if query_conditions:
        query += " WHERE " + " AND ".join(query_conditions)

    query += """
    ORDER BY publication_date DESC, reference_number ASC
    LIMIT :limit OFFSET :offset
    """

    query_parameters["limit"] = limit
    query_parameters["offset"] = offset

    try:
        with get_database_connection() as connection:
            rows = connection.execute(text(query), query_parameters).fetchall()
    except DatabaseUnavailableError:
        logger.exception("Could not read the job database")

        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="The job database is unavailable.",
        )

    return [JobModel(**row._mapping) for row in rows]


@router.get(
    "/{reference_number}",
    summary="Get a single job",
    response_description="The complete job advertisement",
    response_model=JobDetailModel,
    responses={
        404: {
            "description": "The requested job was not found",
        },
        503: {
            "description": "The job database is unavailable",
        },
    },
)
def get_single_job(reference_number: str) -> JobDetailModel:
    """
    Return a complete job advertisement and all its locations.

    A 404 response is returned if the reference number is unknown.
    """
    try:
        with get_database_connection() as connection:

            job_row = connection.execute(
                GET_SINGLE_JOB_SQL,
                {"reference_number": reference_number},
            ).fetchone()

            if job_row is None:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail="Job not found.",
                )

            location_rows = connection.execute(
                GET_JOB_LOCATIONS_SQL,
                {"reference_number": reference_number},
            ).fetchall()

    except DatabaseUnavailableError:
        logger.exception("Could not read the job database")

        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="The job database is unavailable.",
        )

    job_data = dict(job_row._mapping)
    job_data["locations"] = [JobLocationModel(**row._mapping) for row in location_rows]

    return JobDetailModel(**job_data)


# endregion
