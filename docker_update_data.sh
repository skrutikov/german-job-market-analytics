#!/bin/sh

set -e

docker compose run --rm --build \
  data-update \
  python -m job_market.etl.etl.etl "$@"

# Examples:
# ./docker_update_data.sh --keyword "Data Engineer" --keyword "AI Engineer"
# ./docker_update_data.sh --simulate