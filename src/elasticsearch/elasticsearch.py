"""Elasticsearch configuration and index management."""

from sqlalchemy import text
from elasticsearch import Elasticsearch, NotFoundError
from elasticsearch.helpers import bulk
from elastic_transport import ConnectionError, ConnectionTimeout

from src.config.settings import (
    ELASTICSEARCH_JOBS_INDEX,
    ELASTICSEARCH_URL,
)
from src.data.database import get_database_connection


class ElasticsearchUnavailableError(RuntimeError):
    """Raised when the Elasticsearch search service is unavailable."""


# This index contains:
# reference_number       keyword
# title                  text
# occupation             text
# description            text
# company                text + keyword
# category               text + keyword
# cities                 keyword
# home_office_possible   boolean
# is_active              boolean
# REMARKS:
#   "text" → full-text searching
#   "keyword" → exact filtering
#   "dynamic": "strict" → Elasticsearch will reject any accidental (not defined) property titles in the mapping.
#   "number_of_shards": 1, "number_of_replicas": 0, because this is a single-node project deployment.
#
JOBS_INDEX_DEFINITION = {
    "settings": {
        "number_of_shards": 1,
        "number_of_replicas": 0,
        "analysis": {
            "normalizer": {
                "lowercase_normalizer": {
                    "type": "custom",
                    "filter": ["lowercase"],
                }
            }
        },
    },
    "mappings": {
        "dynamic": "strict",
        "properties": {
            "reference_number": {
                "type": "keyword",
            },
            "title": {
                "type": "text",
            },
            "occupation": {
                "type": "text",
            },
            "description": {
                "type": "text",
            },
            "company": {
                "type": "text",
                "fields": {
                    "keyword": {
                        "type": "keyword",
                    }
                },
            },
            "category": {
                "type": "text",
                "fields": {
                    "keyword": {
                        "type": "keyword",
                        "normalizer": "lowercase_normalizer",
                    }
                },
            },
            "cities": {
                "type": "keyword",
                "normalizer": "lowercase_normalizer",
            },
            "home_office_possible": {
                "type": "boolean",
            },
            "is_active": {
                "type": "boolean",
            },
        },
    },
}


# region SQL Queries

# Performs the relational → document transformation.
# REMARKS:
#   ARRAY_AGG() is for putting different locations of a job in the same job-document. For example:
#   job  "REF-123|Data Engineer|Company X"
#   with job_locations  "REF-123|Berlin"  and  "REF-123|Potsdam"
#   should become one document:
#   {
#     "reference_number": "REF-123",
#     "title": "Data Engineer",
#     "cities": ["Berlin", "Potsdam"]
#   }
GET_SEARCHABLE_JOBS_SQL = text("""
SELECT
    jobs.reference_number,
    jobs.title,
    jobs.occupation,
    jobs.description,
    jobs.company,
    jobs.category,
    jobs.home_office_possible,
    jobs.is_active,
    COALESCE(
        ARRAY_AGG(DISTINCT job_locations.city)
            FILTER (WHERE job_locations.city IS NOT NULL),
        ARRAY[]::TEXT[]
    ) AS cities
FROM jobs
LEFT JOIN job_locations
    ON job_locations.reference_number = jobs.reference_number
WHERE jobs.is_active = TRUE
GROUP BY
    jobs.reference_number,
    jobs.title,
    jobs.occupation,
    jobs.description,
    jobs.company,
    jobs.category,
    jobs.home_office_possible,
    jobs.is_active
ORDER BY jobs.reference_number
""")

# endregion


def _get_elasticsearch_client() -> Elasticsearch:
    """Create an Elasticsearch client."""
    return Elasticsearch(ELASTICSEARCH_URL)


def create_jobs_index() -> None:
    """Create the jobs search index if it does not already exist."""
    client = _get_elasticsearch_client()

    if client.indices.exists(index=ELASTICSEARCH_JOBS_INDEX):
        return

    client.indices.create(
        index=ELASTICSEARCH_JOBS_INDEX,
        settings=JOBS_INDEX_DEFINITION["settings"],
        mappings=JOBS_INDEX_DEFINITION["mappings"],
    )


def recreate_jobs_index() -> None:
    """Recreate the jobs index from its configured mapping."""
    client = _get_elasticsearch_client()

    client.indices.delete(
        index=ELASTICSEARCH_JOBS_INDEX,
        ignore_unavailable=True,
    )

    client.indices.create(
        index=ELASTICSEARCH_JOBS_INDEX,
        settings=JOBS_INDEX_DEFINITION["settings"],
        mappings=JOBS_INDEX_DEFINITION["mappings"],
    )


def sync_jobs_index() -> int:
    """Rebuild the Elasticsearch jobs index from active PostgreSQL jobs."""

    # SELECT active PostgreSQL jobs + JOIN/aggregate their locations
    with get_database_connection() as connection:
        rows = connection.execute(GET_SEARCHABLE_JOBS_SQL).fetchall()

    recreate_jobs_index()

    client = _get_elasticsearch_client()

    actions = (
        {
            "_index": ELASTICSEARCH_JOBS_INDEX,
            "_id": row.reference_number,  # don't let ES generate its own document ID but use the job ID instead
            "_source": {
                "reference_number": row.reference_number,
                "title": row.title,
                "occupation": row.occupation,
                "description": row.description,
                "company": row.company,
                "category": row.category,
                "cities": list(row.cities),
                "home_office_possible": row.home_office_possible,
                "is_active": row.is_active,
            },
        }
        for row in rows
    )

    indexed_count, _ = bulk(
        client,
        actions,
    )

    client.indices.refresh(index=ELASTICSEARCH_JOBS_INDEX)

    return indexed_count


def search_job_reference_numbers(
    keyword: str,
    *,
    limit: int,
    offset: int,
    city: str | None = None,
    company: str | None = None,
    home_office: bool | None = None,
    category: str | None = None,
) -> list[str]:
    """
    Search jobs in Elasticsearch and return ranked reference numbers.
    Example:
        keyword = "Python Kubernetes"     → relevance
        city = "Berlin"                   → yes/no
        category = "Backend Development"  → yes/no
        home_office = True                → yes/no
    """

    client = _get_elasticsearch_client()

    filters: list[dict] = [
        {
            "term": {
                "is_active": True,
            }
        }
    ]

    if city is not None:
        filters.append(
            {
                "term": {
                    "cities": city.lower(),
                }
            }
        )

    if category is not None:
        filters.append(
            {
                "term": {
                    "category.keyword": category.lower(),
                }
            }
        )

    if home_office is not None:
        filters.append(
            {
                "term": {
                    "home_office_possible": home_office,
                }
            }
        )

    if company is not None:
        filters.append(
            {
                "match": {
                    "company": {
                        "query": company,
                        "operator": "and",
                    }
                }
            }
        )

    try:
        response = client.search(
            index=ELASTICSEARCH_JOBS_INDEX,
            query={
                "bool": {
                    "must": [
                        {
                            "multi_match": {
                                "query": keyword,
                                "fields": [
                                    "title^4",
                                    "occupation^3",
                                    "company^2",
                                    "category^2",
                                    "description",
                                ],
                            }
                        }
                    ],
                    "filter": filters,
                }
            },
            from_=offset,
            size=limit,
            source=False,
        )
    except (ConnectionError, ConnectionTimeout, NotFoundError) as error:
        raise ElasticsearchUnavailableError(
            "Could not access the Elasticsearch jobs index."
        ) from error

    return [hit["_id"] for hit in response["hits"]["hits"]]
