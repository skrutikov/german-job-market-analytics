"""
API routes for reading job advertisements from the job database.

The endpoints in this module provide read-only access to jobs previously
collected and processed by the data pipeline.
"""

from datetime import date
import logging

from fastapi import APIRouter, HTTPException, Query, status
from pydantic import BaseModel
from sqlalchemy import text

from src.data.database import (
    DatabaseUnavailableError,
    get_database_connection,
)

# region Setup

logger = logging.getLogger(__name__)

router = APIRouter(
    prefix="/statistics",
    tags=["Statistics"],
)

# endregion


# region SQL queries

# Retrieve the general numbers and publication-date range of stored jobs.
GET_OVERVIEW_SQL = text("""
SELECT
    COUNT(*) AS total_jobs,
    COUNT(
        DISTINCT CASE
            WHEN TRIM(company) <> '' THEN company
        END
    ) AS total_companies,
    MIN(publication_date) AS earliest_publication_date,
    MAX(publication_date) AS latest_publication_date
FROM jobs
""")

# Count distinct locations that have a valid city.
GET_TOTAL_LOCATIONS_SQL = text("""
SELECT COUNT(*) AS total_locations
FROM (
    SELECT DISTINCT
        city,
        region,
        country
    FROM job_locations
    WHERE city IS NOT NULL
      AND TRIM(city) <> ''
)
""")

# Retrieve companies with the highest numbers of job advertisements.
GET_COMPANY_STATISTICS_SQL = text("""
SELECT
    company,
    COUNT(*) AS job_count
FROM jobs
WHERE company IS NOT NULL
  AND TRIM(company) <> ''
GROUP BY company
ORDER BY job_count DESC, company ASC
LIMIT :limit
""")

# Retrieve locations with the highest numbers of distinct jobs.
GET_LOCATION_STATISTICS_SQL = text("""
SELECT
    city,
    region,
    country,
    COUNT(DISTINCT reference_number) AS job_count
FROM job_locations
WHERE city IS NOT NULL
  AND TRIM(city) <> ''
GROUP BY
    city,
    region,
    country
ORDER BY
    job_count DESC,
    country ASC,
    region ASC,
    city ASC
LIMIT :limit
""")

# Count jobs by their reported home-office availability.
GET_HOME_OFFICE_STATISTICS_SQL = text("""
SELECT
    COUNT(
        CASE WHEN home_office_possible THEN 1 END
    ) AS possible,
    COUNT(
        CASE WHEN NOT home_office_possible THEN 1 END
    ) AS not_possible,
    COUNT(
        CASE WHEN home_office_possible IS NULL THEN 1 END
    ) AS unknown
FROM jobs
""")

# Count jobs in each standardized category.
GET_CATEGORY_STATISTICS_SQL = text("""
SELECT
    category,
    COUNT(*) AS job_count
FROM jobs
GROUP BY category
ORDER BY job_count DESC, category ASC
""")

# Count jobs by the month in which they were first published.
GET_PUBLICATION_TREND_SQL = text("""
SELECT
    DATE_TRUNC('month', first_publication_date)::date AS month,
    COUNT(*) AS job_count
FROM jobs
WHERE first_publication_date IS NOT NULL
GROUP BY 1
ORDER BY 1
""")

# endregion


# region Pydantic models


class StatisticsOverviewModel(BaseModel):
    """An overview of the job advertisements stored in the database."""

    total_jobs: int
    total_companies: int
    total_locations: int
    earliest_publication_date: date | None = None
    latest_publication_date: date | None = None


class CompanyStatisticsModel(BaseModel):
    """The number of job advertisements stored for a company."""

    company: str
    job_count: int


class LocationStatisticsModel(BaseModel):
    """The number of job advertisements stored for a location."""

    city: str
    region: str | None = None
    country: str | None = None
    job_count: int


class HomeOfficeStatisticsModel(BaseModel):
    """The availability of home office among stored job advertisements."""

    possible: int
    not_possible: int
    unknown: int


class CategoryStatisticsModel(BaseModel):
    """The number of job advertisements in a standardized category."""

    category: str
    job_count: int


class PublicationTrendModel(BaseModel):
    """The number of job advertisements first published in a month."""

    month: date
    job_count: int


# endregion


# region API endpoints


@router.get(
    "/overview",
    summary="Get job statistics overview",
    response_description="An overview of the stored job advertisements",
    response_model=StatisticsOverviewModel,
    responses={
        503: {
            "description": "The job database is unavailable",
        }
    },
)
def get_overview() -> StatisticsOverviewModel:
    """
    Return general statistics about the stored job advertisements.
    """
    try:
        with get_database_connection() as connection:
            overview_row = connection.execute(GET_OVERVIEW_SQL).one()
            locations_row = connection.execute(GET_TOTAL_LOCATIONS_SQL).one()
    except DatabaseUnavailableError:
        logger.exception("Could not read statistics from the job database")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="The job database is unavailable.",
        )

    overview_data = dict(overview_row._mapping)
    overview_data["total_locations"] = locations_row._mapping["total_locations"]

    return StatisticsOverviewModel(**overview_data)


@router.get(
    "/companies",
    summary="Get company statistics",
    response_description="Companies and their numbers of job advertisements",
    response_model=list[CompanyStatisticsModel],
    responses={
        503: {
            "description": "The job database is unavailable",
        }
    },
)
def get_company_statistics(
    limit: int = Query(
        default=20,
        ge=1,
        le=100,
        description="Maximum number of companies to return",
        examples=[5, 10, 20],
        openapi_examples={
            "small": {
                "summary": "Five companies",
                "value": 5,
            },
            "medium": {
                "summary": "Ten companies",
                "value": 10,
            },
            "large": {
                "summary": "Twenty companies",
                "value": 20,
            },
        },
    ),
) -> list[CompanyStatisticsModel]:
    """
    Return companies ordered by their number of job advertisements.

    Companies without a name are excluded.
    """
    try:
        with get_database_connection() as connection:
            rows = connection.execute(
                GET_COMPANY_STATISTICS_SQL,
                {"limit": limit},
            ).fetchall()

    except DatabaseUnavailableError:
        logger.exception("Could not read company statistics from the job database")

        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="The job database is unavailable.",
        )

    return [CompanyStatisticsModel(**row._mapping) for row in rows]


@router.get(
    "/locations",
    summary="Get location statistics",
    response_description="Locations and their numbers of job advertisements",
    response_model=list[LocationStatisticsModel],
    responses={
        503: {
            "description": "The job database is unavailable",
        }
    },
)
def get_location_statistics(
    limit: int = Query(
        default=20,
        ge=1,
        le=100,
        description="Maximum number of locations to return",
        examples=[5, 10, 20],
        openapi_examples={
            "small": {
                "summary": "Five locations",
                "value": 5,
            },
            "medium": {
                "summary": "Ten locations",
                "value": 10,
            },
            "large": {
                "summary": "Twenty locations",
                "value": 20,
            },
        },
    ),
) -> list[LocationStatisticsModel]:
    """
    Return locations ordered by their number of job advertisements.

    Locations without a city are excluded.
    """

    try:
        with get_database_connection() as connection:

            rows = connection.execute(
                GET_LOCATION_STATISTICS_SQL,
                {"limit": limit},
            ).fetchall()

    except DatabaseUnavailableError:
        logger.exception("Could not read location statistics from the job database")

        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="The job database is unavailable.",
        )

    return [LocationStatisticsModel(**row._mapping) for row in rows]


@router.get(
    "/home-office",
    summary="Get home-office statistics",
    response_description=(
        "Numbers of jobs with possible, unavailable, or unknown home office"
    ),
    response_model=HomeOfficeStatisticsModel,
    responses={
        503: {
            "description": "The job database is unavailable",
        }
    },
)
def get_home_office_statistics() -> HomeOfficeStatisticsModel:
    """
    Return job counts grouped by home-office availability.
    """

    try:
        with get_database_connection() as connection:

            row = connection.execute(GET_HOME_OFFICE_STATISTICS_SQL).one()

    except DatabaseUnavailableError:
        logger.exception("Could not read home-office statistics from the job database")

        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="The job database is unavailable.",
        )

    return HomeOfficeStatisticsModel(**row._mapping)


@router.get(
    "/categories",
    summary="Get category statistics",
    response_description=(
        "Standardized job categories and their numbers of job advertisements"
    ),
    response_model=list[CategoryStatisticsModel],
    responses={
        503: {
            "description": "The job database is unavailable",
        }
    },
)
def get_category_statistics() -> list[CategoryStatisticsModel]:
    """
    Return standardized categories and their job counts.

    Categories are ordered by job count, highest first.
    """
    try:
        with get_database_connection() as connection:
            rows = connection.execute(GET_CATEGORY_STATISTICS_SQL).fetchall()

    except DatabaseUnavailableError:
        logger.exception("Could not read category statistics from the job database")

        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="The job database is unavailable.",
        )

    return [CategoryStatisticsModel(**row._mapping) for row in rows]


@router.get(
    "/publication-trends",
    summary="Get publication trends",
    response_description="Monthly numbers of published job advertisements",
    response_model=list[PublicationTrendModel],
    responses={
        503: {
            "description": "The job database is unavailable",
        }
    },
)
def get_publication_trends() -> list[PublicationTrendModel]:
    """
    Return the number of job advertisements first published per month.

    Months without publications are included with a job count of zero.
    """
    try:
        with get_database_connection() as connection:
            rows = connection.execute(GET_PUBLICATION_TREND_SQL).fetchall()

    except DatabaseUnavailableError:
        logger.exception("Could not read publication trends from the job database")

        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="The job database is unavailable.",
        )

    return [PublicationTrendModel(**row._mapping) for row in rows]


# endregion
