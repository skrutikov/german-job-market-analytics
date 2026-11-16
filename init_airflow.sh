#!/usr/bin/env bash
# Enable the Job Market Airflow DAG and trigger one manual ETL run.
# Run on the Ubuntu k3s VM as the regular VM user.
set -euo pipefail

namespace="${1:-dev}"
dag_id="job_market_etl"
if [[ "$namespace" != "dev" && "$namespace" != "prod" ]]; then
    echo "Usage: bash init_airflow.sh [dev|prod]" >&2
    exit 2
fi
command -v sudo >/dev/null || { echo "sudo is required." >&2; exit 1; }
command -v k3s >/dev/null || {
    echo "k3s is required. Run this on the Proxmox Ubuntu VM." >&2
    exit 1
}

kubectl=(sudo k3s kubectl -n "$namespace")

echo "Checking Airflow deployment readiness in namespace $namespace..."
"${kubectl[@]}" rollout status deployment/airflow --timeout=600s

echo "Airflow version:"
"${kubectl[@]}" exec deployment/airflow -- airflow version

echo "Registered Airflow DAGs:"
"${kubectl[@]}" exec deployment/airflow -- airflow dags list

echo "Enabling scheduled runs for $dag_id..."
"${kubectl[@]}" exec deployment/airflow -- airflow dags unpause -y "$dag_id"

echo "Triggering one manual ETL run of $dag_id..."
"${kubectl[@]}" exec deployment/airflow -- airflow dags trigger "$dag_id"

echo "Most recent DAG runs (new runs may initially be queued or running):"
"${kubectl[@]}" exec deployment/airflow -- airflow dags list-runs "$dag_id" --limit 5

echo "ETL run requested. Inspect Airflow UI/task logs to verify eventual success."
echo "Warning: rerunning this script triggers an additional manual ETL run."
