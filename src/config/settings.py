"""Shared application settings."""

import os
from pathlib import Path

FASTAPI_URL = os.getenv(
    "FASTAPI_URL",
    "http://127.0.0.1:8000",
)

FRONTEND_PORT = int(os.getenv("FRONTEND_PORT", "8050"))


PROJECT_ROOT = Path(__file__).resolve().parents[2]
DATA_DIRECTORY = PROJECT_ROOT / "data"


RAW_DATA_DIRECTORY = DATA_DIRECTORY / "raw" / "arbeitsagentur"
PROCESSED_DATA_DIRECTORY = DATA_DIRECTORY / "processed" / "arbeitsagentur"


CLEAN_JSON_FILE_NAME = "clean-jobs.json"
JOB_DETAILS_FILE_NAME = "job-details.json"
JOB_DETAIL_FAILURES_FILE_NAME = "job-detail-failures.json"


DATABASE_URL = os.getenv(
    "DATABASE_URL",
    "postgresql+psycopg://job_market:job_market@localhost:5432/job_market",
)


PUSHGATEWAY_URL = os.getenv(
    "PUSHGATEWAY_URL",
    "http://127.0.0.1:9091",
)


# region Arbeitsagentur API / ETL

DEFAULT_JOB_SEARCH_KEYWORDS = ("Data Engineer", "Data Analyst", "AI Engineer")
API_START_PAGE = 1
API_REQUEST_PAGE_SIZE = 50

# endregion


# region Job categories

JOB_CATEGORIES = (
    "Data Engineering",
    "Data Analysis",
    "AI / Machine Learning",
    "Backend Development",
    "Cloud / DevOps",
    "Other",
)

CATEGORY_KEYWORDS = {
    "AI / Machine Learning": (
        "machine learning",
        "deep learning",
        "artificial intelligence",
        "künstliche intelligenz",
        "data scientist",
        "ml engineer",
        "ai engineer",
        "computer vision",
        "nlp",
        "llm",
    ),
    "Data Engineering": (
        "data engineer",
        "dateningenieur",
        "etl",
        "data warehouse",
        "dataplattform",
        "data platform",
        "big data",
        "spark",
    ),
    "Data Analysis": (
        "data analyst",
        "datenanalyst",
        "business intelligence",
        "bi analyst",
        "business analyst",
        "analytics",
    ),
    "Cloud / DevOps": (
        "devops",
        "cloud engineer",
        "cloud architect",
        "site reliability",
        "sre",
        "platform engineer",
        "kubernetes",
        "infrastructure engineer",
    ),
    "Backend Development": (
        "backend",
        "back-end",
        "softwareentwickler",
        "software developer",
        "python developer",
        "java developer",
        ".net developer",
        "api developer",
    ),
}

# endregion


# region Dashboard

DASH_DEBUG = os.getenv("DASH_DEBUG", "true").lower() == "true"

JOBS_PAGE_SIZE = 20

JOB_ANY_CATEGORY_DROPDOWN_VALUE = "all"
JOB_ANY_CATEGORY_DROPDOWN_LABEL = "Any category"

CATEGORY_COLORS = {
    "Data Engineering": "#0072B2",  # blue
    "Data Analysis": "#56B4E9",  # sky blue
    "AI / Machine Learning": "#CC79A7",  # reddish purple
    "Backend Development": "#E69F00",  # orange
    "Cloud / DevOps": "#009E73",  # bluish green
    "Other": "#7F7F7F",  # gray
}

# endregion


# region Elasticsearch

ELASTICSEARCH_URL = os.getenv(
    "ELASTICSEARCH_URL",
    "http://127.0.0.1:9200",
)

ELASTICSEARCH_JOBS_INDEX = "jobs"

# endregion
