#!/usr/bin/env bash
# Enable the DAG safely; never trigger a manual run when a DAG run is active.
# Run as the regular user on the Ubuntu k3s VM.
set -euo pipefail

namespace="${1:-dev}"
dag_id="job_market_etl"
if [[ "$namespace" != dev && "$namespace" != prod ]]; then
    echo "Usage: bash deployment/scripts/init_airflow.sh [dev|prod]" >&2
    exit 2
fi
for binary in sudo k3s python3; do
    command -v "$binary" >/dev/null || {
        echo "$binary is required on the Ubuntu k3s VM." >&2
        exit 1
    }
done
kubectl=(sudo k3s kubectl -n "$namespace")

# Parse the machine-readable Airflow 3.4 CLI output. On errors, fail closed.
dag_paused() {
    local output
    output="$("${kubectl[@]}" exec deployment/airflow -- \
        airflow dags list --output json)" || return 1
    printf '%s\n' "$output" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert isinstance(rows, list)
matches = [row for row in rows if isinstance(row, dict)
           and row.get("dag_id") == "job_market_etl"]
assert len(matches) == 1, "Expected exactly one job_market_etl DAG"
paused = matches[0].get("is_paused")
assert isinstance(paused, bool), "Missing/invalid pause state"
print("true" if paused else "false")
'
}

active_runs() {
    local output
    # Do not limit to the five most recent runs: an older run may still be active.
    output="$("${kubectl[@]}" exec deployment/airflow -- \
        airflow dags list-runs "$dag_id" --output json)" || return 1
    printf '%s\n' "$output" | python3 -c '
import json, sys
rows = json.load(sys.stdin)
assert isinstance(rows, list)
assert all(isinstance(row, dict) and isinstance(row.get("state"), str)
           for row in rows), "Invalid DAG-run response"
print("yes" if any(row["state"] in ("queued", "running") for row in rows) else "no")
'
}

echo "Checking Airflow deployment readiness in namespace $namespace..."
"${kubectl[@]}" rollout status deployment/airflow --timeout=600s
echo "Airflow version:"
"${kubectl[@]}" exec deployment/airflow -- airflow version
echo "Registered Airflow DAGs:"
"${kubectl[@]}" exec deployment/airflow -- airflow dags list

paused="$(dag_paused)" || {
    echo "Cannot verify the DAG pause state; refusing to trigger ETL." >&2
    exit 1
}
if [[ "$paused" == true ]]; then
    echo "Unpausing $dag_id to enable its daily schedule..."
    "${kubectl[@]}" exec deployment/airflow -- airflow dags unpause -y "$dag_id"
else
    echo "$dag_id was already unpaused."
fi

echo "Checking for queued/running $dag_id DAG runs..."
active="$(active_runs)" || {
    echo "Cannot verify active runs; refusing to trigger ETL." >&2
    exit 1
}
if [[ "$active" == yes ]]; then
    echo "Skipping manual ETL: a queued or running DAG run already exists."
elif [[ "$paused" == true ]]; then
    # The scheduler can create a run immediately after unpausing. Avoid that
    # race by never creating a manual run in the same invocation as unpause.
    echo "Skipping manual ETL after unpause; the scheduler may create a run."
else
    echo "No active runs found. Triggering one manual ETL..."
    "${kubectl[@]}" exec deployment/airflow -- airflow dags trigger "$dag_id"
fi

echo "Most recent DAG runs:"
"${kubectl[@]}" exec deployment/airflow -- \
    airflow dags list-runs "$dag_id" --limit 5
echo "For read-only status, run: bash deployment/scripts/check_airflow_state.sh $namespace"
echo "Note: a later rerun when no ETL is active can trigger another run."
