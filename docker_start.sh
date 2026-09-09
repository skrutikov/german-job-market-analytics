#!/bin/sh

set -e

SWAGGER_URL="http://127.0.0.1:8000/docs"
HEALTH_URL="http://127.0.0.1:8000/health"
DASH_URL="http://127.0.0.1:8050"
AIRFLOW_URL="http://127.0.0.1:8080"
PROMETHEUS_URL="http://127.0.0.1:9090"
ALERTMANAGER_URL="http://127.0.0.1:9093"
GRAFANA_URL="http://127.0.0.1:3000"
ELASTICSEARCH_URL="http://127.0.0.1:9200"

docker compose up --build -d postgres elasticsearch backend frontend airflow prometheus pushgateway alertmanager grafana

wait_for_url() {
    url="$1"
    service_name="$2"
    maximum_attempts=60
    attempt=1

    while [ "$attempt" -le "$maximum_attempts" ]; do
        if curl -fs "$url" >/dev/null 2>&1; then
            return 0
        fi

        container_id=$(docker compose ps -q "$service_name")

        if [ -z "$container_id" ] ||
           [ "$(docker inspect -f '{{.State.Running}}' "$container_id" 2>/dev/null)" != "true" ]; then
            echo "ERROR: Docker service '$service_name' stopped before becoming ready." >&2
            echo >&2
            docker compose logs "$service_name" >&2
            exit 1
        fi

        sleep 1
        attempt=$((attempt + 1))
    done

    echo "ERROR: Timed out waiting for $url" >&2
    docker compose logs "$service_name" >&2
    exit 1
}

echo "Waiting for FastAPI..."
wait_for_url "$HEALTH_URL" backend

echo "Waiting for Dash..."
wait_for_url "$DASH_URL" frontend

echo "Waiting for Airflow..."
wait_for_url "$AIRFLOW_URL" airflow

echo "Waiting for Prometheus..."
wait_for_url "$PROMETHEUS_URL" prometheus

echo "Waiting for Alertmanager..."
wait_for_url "$ALERTMANAGER_URL" alertmanager

echo "Waiting for Grafana..."
wait_for_url "$GRAFANA_URL" grafana

echo "Waiting for Elasticsearch..."
wait_for_url "$GRAFANA_URL" elasticsearch

AIRFLOW_PASSWORD_LINE=$(
    docker compose logs airflow 2>/dev/null \
        | grep "Password for user" \
        | tail -1
)

python -c '
import sys
import webbrowser

for url in sys.argv[1:]:
    webbrowser.open(url)
' "$SWAGGER_URL" "$DASH_URL" "$AIRFLOW_URL" "$PROMETHEUS_URL"

echo
echo "======================================"
echo "Job Market is ready"
echo "======================================"
echo "Swagger: $SWAGGER_URL"
echo "Dash:    $DASH_URL"
echo "Airflow: $AIRFLOW_URL"
echo "Prometheus: $PROMETHEUS_URL"
echo "Alert Manager: $ALERTMANAGER_URL"
echo "Grafana: $GRAFANA_URL"
echo

if [ -n "$AIRFLOW_PASSWORD_LINE" ]; then
    echo "Airflow credentials:"
    echo "$AIRFLOW_PASSWORD_LINE"
else
    echo "Airflow password was not found in the logs."
    echo "Run:"
    echo "docker compose logs airflow | grep \"Password for user\""
fi

echo "======================================"