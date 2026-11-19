#!/usr/bin/env bash
# Read-only status: five most recent job_market_etl runs in dev or prod.
set -euo pipefail

namespace="${1:-dev}"
if [[ "$namespace" != dev && "$namespace" != prod ]]; then
    echo "Usage: bash check_airflow_state.sh [dev|prod]" >&2
    exit 2
fi
command -v sudo >/dev/null || { echo "sudo is required." >&2; exit 1; }
command -v k3s >/dev/null || {
    echo "k3s is required. Run this on the Ubuntu VM." >&2
    exit 1
}

echo "Latest job_market_etl runs in namespace $namespace:"
sudo k3s kubectl -n "$namespace" exec deployment/airflow -- \
    airflow dags list-runs job_market_etl --limit 5
