import logging
from typing import Any

from geopy.extra.rate_limiter import RateLimiter
from geopy.geocoders import Nominatim

from src.monitoring.metrics import record_failed_geocoding

GEOPY_USER_AGENT = "job-market-mapper"
GEOPY_DELAY_SECONDS = 1.0
GEOPY_MAX_RETRIES = 2
GEOPY_ERROR_WAIT_SECONDS = 5.0
GEOPY_SWALLOW_EXCEPTIONS = True
GEOPY_RETURN_VALUE_ON_EXCEPTION = None

logger = logging.getLogger(__name__)


class JobLocationGeocoder:
    def __init__(
        self,
        delay_seconds: float = GEOPY_DELAY_SECONDS,
        max_retries: int = GEOPY_MAX_RETRIES,
        error_wait_seconds: float = GEOPY_ERROR_WAIT_SECONDS,
    ) -> None:
        self.geolocator = Nominatim(user_agent=GEOPY_USER_AGENT)
        self._geocode = RateLimiter(
            self.geolocator.geocode,
            min_delay_seconds=delay_seconds,
            max_retries=max_retries,
            error_wait_seconds=error_wait_seconds,
            swallow_exceptions=GEOPY_SWALLOW_EXCEPTIONS,
            return_value_on_exception=GEOPY_RETURN_VALUE_ON_EXCEPTION,
        )
        self._cache: dict[str, tuple[float | None, float | None]] = {}

    @staticmethod
    def _normalize_query_part(value: Any) -> str | None:
        if value is None:
            return None
        cleaned = str(value).strip()
        return cleaned or None

    def _geocode_location(
        self,
        postal_code: Any = None,
        city: Any = None,
        country: Any = None,
    ) -> tuple[float | None, float | None]:
        postal_code = self._normalize_query_part(postal_code)
        city = self._normalize_query_part(city)
        country = self._normalize_query_part(country)

        if not any([postal_code, city, country]):
            return None, None

        query_parts = [part for part in (postal_code, city, country) if part]

        query = ", ".join(query_parts)

        if query in self._cache:
            return self._cache[query]

        location = self._geocode(query, exactly_one=True)

        if location is not None:
            result = (location.latitude, location.longitude)
        else:
            record_failed_geocoding()
            logger.warning("Geocoding returned no result for %r", query)
            result = (None, None)
        self._cache[query] = result
        return result

    def _enrich_location_with_geocoding(
        self, location: dict[str, Any]
    ) -> dict[str, Any]:
        latitude = location.get("latitude")
        longitude = location.get("longitude")

        if latitude is not None and longitude is not None:
            location["coordinates_source"] = "source"
            return location

        lat, lon = self._geocode_location(
            postal_code=location.get("postal_code"),
            city=location.get("city"),
            country=location.get("country"),
        )

        if lat is not None and lon is not None:
            location["latitude"] = lat
            location["longitude"] = lon
            location["coordinates_source"] = "geocoded"
        else:
            location["coordinates_source"] = "missing"

        return location

    def _enrich_job_with_geocoding(
        self, job: dict[str, Any]
    ) -> tuple[dict[str, Any], int]:
        locations = job.get("locations", [])

        if not isinstance(locations, list):
            logger.warning(
                "Skipping malformed locations value (not a list): %r",
                locations,
            )
            return job, 1

        enriched_locations = []
        num_malformed = 0

        for location in locations:
            if not isinstance(location, dict):
                logger.warning(
                    "Skipping malformed location entry (not a dict): %r", location
                )
                num_malformed += 1
                continue
            enriched_locations.append(self._enrich_location_with_geocoding(location))

        job["locations"] = enriched_locations
        return job, num_malformed

    def enrich_jobs_with_geocoding(
        self, jobs: list[dict[str, Any]]
    ) -> tuple[list[dict[str, Any]], int]:
        enriched_jobs = []
        total_malformed = 0

        for job in jobs:
            enriched_job, num_malformed = self._enrich_job_with_geocoding(job)
            enriched_jobs.append(enriched_job)
            total_malformed += num_malformed

        return enriched_jobs, total_malformed
