import logging
import requests
import time

from functools import wraps
from contextlib import contextmanager
from urllib.error import URLError

from prometheus_client import (
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    push_to_gateway,
)

from src.config.settings import PUSHGATEWAY_URL

# region Setup

logger = logging.getLogger(__name__)

# endregion

_arbeitsagentur_requests_total = Counter(
    "arbeitsagentur_requests_total",
    "Number of requests to the Arbeitsagentur API",
    ["operation", "status"],
)

_arbeitsagentur_request_duration_seconds = Histogram(
    "arbeitsagentur_request_duration_seconds",
    "Duration of requests to the Arbeitsagentur API",
    ["operation"],
)

_arbeitsagentur_api_up = Gauge(
    "arbeitsagentur_api_up",
    "Whether the last Arbeitsagentur API request succeeded",
)

# Number of database connections currently in use by the application
_active_database_connections = Gauge(
    "active_database_connections",
    "Number of database connections currently in use by the application",
)

_job_search_requests_total = Counter(
    "job_search_requests_total",
    "Number of job search requests",
    ["status"],
)

_job_search_duration_seconds = Histogram(
    "job_search_duration_seconds",
    "Duration of job search requests",
)

_etl_registry = CollectorRegistry()

_etl_runtime_seconds = Gauge(
    "etl_runtime_seconds",
    "Duration of the last ETL run in seconds",
    registry=_etl_registry,
)

_etl_last_success_unixtime = Gauge(
    "etl_last_success_unixtime",
    "Unix timestamp of the last successful ETL run",
    registry=_etl_registry,
)

# Using Gauge representing the latest run rather than a cumulative Counter that would reset with every ETL process
_failed_geocoding_requests = Gauge(
    "failed_geocoding_requests",
    "Number of failed geocoding requests in the latest ETL run",
    registry=_etl_registry,
)


_failed_geocoding_count = 0


def reset_failed_geocoding() -> None:
    global _failed_geocoding_count
    _failed_geocoding_count = 0


def record_failed_geocoding() -> None:
    global _failed_geocoding_count
    _failed_geocoding_count += 1


def get_failed_geocoding_count() -> int:
    return _failed_geocoding_count


def push_etl_metrics(
    runtime_seconds: float,
    failed_geocoding_requests: int,
) -> None:
    """Publish metrics for a successfully completed ETL run."""

    _etl_runtime_seconds.set(runtime_seconds)
    _etl_last_success_unixtime.set_to_current_time()
    _failed_geocoding_requests.set(failed_geocoding_requests)

    try:
        push_to_gateway(
            PUSHGATEWAY_URL,
            job="job-market-etl",
            registry=_etl_registry,
        )
    except URLError:
        logger.exception("Could not push ETL metrics to Pushgateway")


def monitor_arbeitsagentur_request(operation: str):
    """Track the duration and outcome of an Arbeitsagentur API operation."""

    def decorator(function):

        # "@wraps" preserves the original function's name, docstring, and other metadata.
        @wraps(function)
        def wrapper(*args, **kwargs):
            try:
                with _arbeitsagentur_request_duration_seconds.labels(
                    operation=operation
                ).time():
                    result = function(*args, **kwargs)
            except requests.RequestException:
                _arbeitsagentur_api_up.set(0)
                _arbeitsagentur_requests_total.labels(
                    operation=operation,
                    status="failure",
                ).inc()
                raise

            _arbeitsagentur_api_up.set(1)
            _arbeitsagentur_requests_total.labels(
                operation=operation,
                status="success",
            ).inc()

            return result

        return wrapper

    return decorator


def monitor_database_connection(function):
    """Track the number of database connections currently in use."""

    @wraps(function)
    def wrapper(*args, **kwargs):
        @contextmanager
        def monitored_connection():
            with function(*args, **kwargs) as connection:
                _active_database_connections.inc()
                try:
                    yield connection
                finally:
                    _active_database_connections.dec()

        return monitored_connection()

    return wrapper


def monitor_job_search(function):
    """Track the duration and outcome of a job search."""

    @wraps(function)
    def wrapper(*args, **kwargs):
        try:
            with _job_search_duration_seconds.time():
                result = function(*args, **kwargs)

        except Exception:
            _job_search_requests_total.labels(status="failure").inc()
            raise

        _job_search_requests_total.labels(status="success").inc()

        return result

    return wrapper


def monitor_etl_run(function):
    """Track a successful ETL run and push its metrics."""

    @wraps(function)
    def wrapper(*args, **kwargs):
        reset_failed_geocoding()
        start_time = time.perf_counter()

        result = function(*args, **kwargs)

        push_etl_metrics(
            runtime_seconds=time.perf_counter() - start_time,
            failed_geocoding_requests=get_failed_geocoding_count(),
        )

        return result

    return wrapper
