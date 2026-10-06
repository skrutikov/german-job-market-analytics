"""HTTP client for the Arbeitsagentur job-search interface."""

import base64
import os
from typing import Any

import requests

from src.monitoring.metrics import monitor_arbeitsagentur_request


class ArbeitsagenturClient:
    """Small client for searching Arbeitsagentur job advertisements."""

    DEFAULT_BASE_URL = "https://rest.arbeitsagentur.de/jobboerse/jobsuche-service"

    API_KEY = "jobboerse-jobsuche"

    KEYWORD_SEARCH_PARAM = "was"
    LOCATION_SEARCH_PARAM = "wo"
    PAGE_SEARCH_PARAM = "page"
    JOBS_PER_PAGE_SEARCH_PARAM = "size"

    def __init__(self, timeout_seconds: int = 30) -> None:
        self.timeout_seconds = timeout_seconds

        self.base_url = os.getenv(
            "JOB_API_BASE_URL",
            self.DEFAULT_BASE_URL,
        )

        self.jobs_url = f"{self.base_url}/pc/v6/jobs"
        self.job_details_url = f"{self.base_url}/pc/v4/jobdetails"

        self.session = requests.Session()
        self.session.headers.update(
            {
                "X-API-Key": self.API_KEY,
                "Accept": "application/json",
                "User-Agent": "jun26bde-job-market/0.1",
            }
        )

    @monitor_arbeitsagentur_request("search_jobs")
    def search_jobs(
        self,
        keyword: str,
        *,
        location: str | None = None,
        page_number: int = 1,
        jobs_per_page: int = 25,
    ) -> dict[str, Any]:
        """Search for job advertisements."""

        if page_number < 1:
            raise ValueError("page_number must be at least 1")

        if not 1 <= jobs_per_page <= 100:
            raise ValueError("jobs_per_page must be between 1 and 100")

        params: dict[str, str | int] = {
            self.KEYWORD_SEARCH_PARAM: keyword,
            self.PAGE_SEARCH_PARAM: page_number,
            self.JOBS_PER_PAGE_SEARCH_PARAM: jobs_per_page,
        }

        if location:
            params[self.LOCATION_SEARCH_PARAM] = location

        response = self.session.get(
            self.jobs_url,
            params=params,
            timeout=self.timeout_seconds,
        )
        response.raise_for_status()

        data = response.json()

        if not isinstance(data, dict):
            raise TypeError("Expected the API response to be a JSON object")

        return data

    def does_job_exist(self, reference_number: str) -> bool:
        try:
            self.get_job_details(reference_number)
            return True

        except requests.HTTPError as error:
            response = error.response

            if response is None or response.status_code != 404:
                raise

            try:
                data = response.json()
            except requests.JSONDecodeError:
                raise

            messages = data.get("messages", [])

            if any(
                isinstance(message, dict)
                and message.get("code") == "STELLENANGEBOT_NICHT_GEFUNDEN"
                for message in messages
            ):
                return False

            raise

    @monitor_arbeitsagentur_request("get_job_details")
    def get_job_details(self, reference_number: str) -> dict[str, Any]:
        """Retrieve the full details for one job advertisement."""

        if not reference_number:
            raise ValueError("reference_number must not be empty")

        encoded_reference_number = base64.b64encode(
            reference_number.encode("utf-8")
        ).decode("ascii")

        response = self.session.get(
            f"{self.job_details_url}/{encoded_reference_number}",
            timeout=self.timeout_seconds,
        )
        response.raise_for_status()

        data = response.json()

        if not isinstance(data, dict):
            raise TypeError("Expected the API response to be a JSON object")

        return data
