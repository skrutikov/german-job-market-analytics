"""Generate artificial backend traffic for testing and demonstrating monitoring.

Sends concurrent requests to the /jobs endpoint with varying load so that
Prometheus metrics and Grafana dashboard panels can be tested with realistic
request activity. This script is a development utility and is not part of the
normal application runtime.
"""

from concurrent.futures import ThreadPoolExecutor
import random
import threading
import time

import requests

JOBS_URL = "http://127.0.0.1:8000/jobs"

MIN_WORKERS = 2
MAX_WORKERS = 15
PHASE_DURATION_SECONDS = 20
NUMBER_OF_PHASES = 10


def generate_requests(stop_event: threading.Event) -> None:
    with requests.Session() as session:
        while not stop_event.is_set():
            try:
                session.get(
                    JOBS_URL,
                    params={
                        "limit": random.choice([5, 10, 20, 50]),
                        "offset": random.choice([0, 5, 10, 20]),
                    },
                    timeout=10,
                )
            except requests.RequestException as error:
                print(f"Request failed: {error}")


def main() -> None:
    for phase in range(1, NUMBER_OF_PHASES + 1):
        workers = random.randint(
            MIN_WORKERS,
            MAX_WORKERS,
        )

        print(
            f"Phase {phase}/{NUMBER_OF_PHASES}: "
            f"{workers} concurrent workers for "
            f"{PHASE_DURATION_SECONDS} seconds"
        )

        stop_event = threading.Event()

        with ThreadPoolExecutor(max_workers=workers) as executor:
            futures = [
                executor.submit(generate_requests, stop_event) for _ in range(workers)
            ]

            time.sleep(PHASE_DURATION_SECONDS)
            stop_event.set()

            for future in futures:
                future.result()


if __name__ == "__main__":
    main()
