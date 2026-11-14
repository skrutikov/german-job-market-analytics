#!/usr/bin/env bash
# Local WSL/Linux access to a private k3s VM; does NOT deploy or restart pods.
set -euo pipefail
umask 077

environment="${1:-dev}"
action="${2:-start}"
vm="${JOB_MARKET_VM_SSH_HOST:-liora-vm100}"

if [[ "$environment" != "dev" && "$environment" != "prod" ]]; then
    echo "Usage: ./kubernetes_start.sh [dev|prod] [start|stop|status]" >&2
    exit 2
fi
if [[ "$action" != "start" && "$action" != "stop" && "$action" != "status" ]]; then
    echo "Unknown action: $action (expected start, stop or status)" >&2
    exit 2
fi
command -v ssh >/dev/null || { echo "OpenSSH is required." >&2; exit 1; }

socket_dir="${XDG_RUNTIME_DIR:-$HOME/.cache}/job-market-kubernetes"
mkdir -p "$socket_dir"
chmod 700 "$socket_dir"
socket="$socket_dir/$environment.sock"

ssh_args=(-o BatchMode=yes -o ConnectTimeout=15)
tunnel_running() {
    [[ -S "$socket" ]] &&
        ssh -S "$socket" -O check "$vm" >/dev/null 2>&1
}

if [[ "$action" == "stop" ]]; then
    if tunnel_running; then
        ssh -S "$socket" -O exit "$vm"
        echo "Stopped $environment Kubernetes access tunnel."
    else
        [[ ! -e "$socket" ]] || rm -f -- "$socket"
        echo "No active $environment tunnel found."
    fi
    exit 0
fi
if [[ "$action" == "status" ]]; then
    if tunnel_running; then
        echo "$environment Kubernetes access tunnel is running."
    else
        echo "No active $environment Kubernetes access tunnel."
    fi
    exit 0
fi

for required in python3 base64 curl; do
    command -v "$required" >/dev/null ||
        { echo "$required is required on local WSL/Linux." >&2; exit 1; }
done

# Non-overlapping local ports let both environments be accessed if the VM has capacity.
if [[ "$environment" == "dev" ]]; then
    ports=(8088 18080 13000 19090 19093 19200 19091)
else
    ports=(28088 28080 23000 29090 29093 29200 29091)
fi
services=(nginx airflow grafana prometheus alertmanager elasticsearch pushgateway)
service_ports=(80 8080 3000 9090 9093 9200 9091)

if tunnel_running; then
    echo "Existing $environment tunnel is active; reusing it."
else
    # Stale socket from a crashed SSH master; ours is in a private directory.
    [[ ! -e "$socket" ]] || rm -f -- "$socket"
    echo "Finding $environment Kubernetes Service IPs through $vm..."
    # The Service's ClusterIP is routable from the k3s node; no kubectl
    # port-forward processes or extra VM terminal sessions are needed.
    if ! service_json="$(ssh "${ssh_args[@]}" "$vm" \
        "sudo -n k3s kubectl -n $environment get services ${services[*]} -o json")"; then
        echo "Cannot query services. Run this from local WSL (where the '$vm' SSH alias works)." >&2
        echo "The VM must be reachable and permit passwordless sudo k3s kubectl." >&2
        exit 1
    fi
    if ! ip_list="$(printf '%s' "$service_json" | python3 -c '
import json, sys
obj = json.load(sys.stdin)
items = obj.get("items", [obj])
by_name = {item["metadata"]["name"]: item["spec"]["clusterIP"] for item in items}
names = ("nginx", "airflow", "grafana", "prometheus",
         "alertmanager", "elasticsearch", "pushgateway")
print("\n".join(by_name[name] for name in names))
')"; then
        echo "Could not parse Kubernetes Service IPs." >&2
        exit 1
    fi
    unset service_json
    mapfile -t service_ips <<< "$ip_list"
    if (( ${#service_ips[@]} != ${#services[@]} )); then
        echo "Missing Kubernetes Service addresses." >&2
        exit 1
    fi

    forwards=()
    for i in "${!services[@]}"; do
        ip="${service_ips[$i]}"
        if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "Invalid ClusterIP for ${services[$i]}: $ip" >&2
            exit 1
        fi
        forwards+=(-L "127.0.0.1:${ports[$i]}:$ip:${service_ports[$i]}")
    done

    echo "Starting a background SSH tunnel (only localhost ports are exposed)..."
    if ! ssh "${ssh_args[@]}" -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -M -S "$socket" -fNT "${forwards[@]}" "$vm"; then
        echo "Cannot start SSH forwarding. Stop any previous WSL tunnels using these ports." >&2
        exit 1
    fi
fi

# An active SSH master only confirms local listeners, not that every HTTP
# endpoint is healthy. Test the actual Nginx response too.
if ! curl -fsS --connect-timeout 5 --max-time 15 \
    "http://127.0.0.1:${ports[0]}/nginx-health" >/dev/null; then
    echo "WARNING: SSH is running, but Nginx did not answer. Check VM connectivity and services." >&2
    echo "Stop and retry: ./kubernetes_start.sh $environment stop" >&2
fi

echo
echo "======================================"
echo "Job Market Kubernetes ($environment)"
echo "======================================"
printf 'Dash:          http://127.0.0.1:%s/\n' "${ports[0]}"
printf 'Swagger:       http://127.0.0.1:%s/api/docs\n' "${ports[0]}"
printf 'Airflow:       http://127.0.0.1:%s/\n' "${ports[1]}"
printf 'Grafana:       http://127.0.0.1:%s/\n' "${ports[2]}"
printf 'Prometheus:    http://127.0.0.1:%s/\n' "${ports[3]}"
printf 'Alertmanager:  http://127.0.0.1:%s/\n' "${ports[4]}"
printf 'Elasticsearch: http://127.0.0.1:%s/\n' "${ports[5]}"
printf 'Pushgateway:   http://127.0.0.1:%s/\n' "${ports[6]}"

echo
echo "Credentials (sensitive; displayed only on this terminal):"
if secret_json="$(ssh "${ssh_args[@]}" "$vm" \
    "sudo -n k3s kubectl -n $environment get secret job-market-secrets -o json")"; then
    if decoded="$(printf '%s' "$secret_json" | python3 -c '
import base64, json, sys
data = json.load(sys.stdin)["data"]
for name in ("GRAFANA_ADMIN_PASSWORD", "POSTGRES_PASSWORD"):
    print(base64.b64decode(data[name]).decode())
')"; then
        mapfile -t passwords <<< "$decoded"
        if (( ${#passwords[@]} == 2 )); then
            printf 'Grafana:    admin / %s\n' "${passwords[0]}"
            printf 'PostgreSQL: job_market / %s (internal database)\n' "${passwords[1]}"
        fi
        unset passwords decoded
    else
        echo "Could not decode Grafana/PostgreSQL credentials." >&2
    fi
else
    echo "Could not fetch Grafana/PostgreSQL credentials." >&2
fi
unset secret_json

if airflow_json="$(ssh "${ssh_args[@]}" "$vm" \
    "sudo -n k3s kubectl -n $environment exec deployment/airflow -- cat /opt/airflow/state/simple_auth_manager_passwords.json.generated")"; then
    if airflow_password="$(printf '%s' "$airflow_json" | python3 -c '
import json, sys
print(json.load(sys.stdin)["admin"])
')"; then
        printf 'Airflow:    admin / %s\n' "$airflow_password"
        unset airflow_password
    else
        echo "Could not parse Airflow admin password." >&2
    fi
else
    echo "Could not read Airflow credentials (is Airflow running?)." >&2
fi
unset airflow_json

echo
echo "Keep these passwords private; they are not saved locally."
echo "The tunnel stays in the background. To close:"
echo "  ./kubernetes_stop.sh $environment"
echo "======================================"
