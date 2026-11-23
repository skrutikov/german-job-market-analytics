#!/usr/bin/env bash
# Open SSH access to a chosen private k3s VM; does NOT deploy or restart pods.
# Override: JOB_MARKET_VM_SSH_HOST, JOB_MARKET_SSH_JUMP, JOB_MARKET_SSH_KEY.
set -euo pipefail
umask 077

environment="${1:-dev}"
action="${2:-start}"
vm="${JOB_MARKET_VM_SSH_HOST:-k3s-vm}"

if [[ "$environment" != "dev" && "$environment" != "prod" ]]; then
    echo "Usage: ./deployment/scripts/open_access_to_vm.sh [dev|prod] [start|stop|status]" >&2
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
[[ -z "${JOB_MARKET_SSH_JUMP:-}" ]] || ssh_args+=(-J "$JOB_MARKET_SSH_JUMP")
if [[ -n "${JOB_MARKET_SSH_KEY:-}" ]]; then
    [[ -r "$JOB_MARKET_SSH_KEY" ]] || {
        echo "SSH identity is not readable: $JOB_MARKET_SSH_KEY" >&2
        exit 1
    }
    ssh_args+=(-i "$JOB_MARKET_SSH_KEY" -o IdentitiesOnly=yes)
fi

# One tunnel per environment: local ports are fixed, so switching VMs requires stop/start.
# A private marker prevents silently reusing an active tunnel to the wrong VM.
target_file="$socket_dir/$environment.target"
requested_target="$vm|${JOB_MARKET_SSH_JUMP:-}|${JOB_MARKET_SSH_KEY:-}"
saved_vm() {
    if [[ -r "$target_file" ]]; then
        IFS='|' read -r recorded_vm _ < "$target_file"
        printf '%s' "$recorded_vm"
    else
        printf '%s' "$vm"
    fi
}
tunnel_running() {
    [[ -S "$socket" ]] &&
        ssh -S "$socket" -O check "$(saved_vm)" >/dev/null 2>&1
}

if [[ "$action" == "stop" ]]; then
    if tunnel_running; then
        ssh -S "$socket" -O exit "$(saved_vm)"
        rm -f -- "$target_file"
        echo "Stopped $environment Kubernetes access tunnel."
    else
        [[ ! -e "$socket" ]] || rm -f -- "$socket"
        rm -f -- "$target_file"
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
        { echo "$required is required on the local machine." >&2; exit 1; }
done

# Non-overlapping local ports let both environments be accessed if the VM has capacity.
if [[ "$environment" == "dev" ]]; then
    ports=(8088 18080 13000 19090 19093 19200 19091)
    argocd_local_port=18443
else
    ports=(28088 28080 23000 29090 29093 29200 29091)
    argocd_local_port=28443
fi
services=(nginx airflow grafana prometheus alertmanager elasticsearch pushgateway)
service_ports=(80 8080 3000 9090 9093 9200 9091)

if tunnel_running; then
    if [[ ! -r "$target_file" || "$(cat "$target_file")" != "$requested_target" ]]; then
        echo "ERROR: An existing $environment tunnel may point to another VM." >&2
        echo "Stop it first: ./deployment/scripts/open_access_to_vm.sh $environment stop" >&2
        exit 1
    fi
    echo "Existing $environment tunnel is active; reusing it."
else
    # Stale socket from a crashed SSH master; ours is in a private directory.
    [[ ! -e "$socket" ]] || rm -f -- "$socket"
    rm -f -- "$target_file"
    echo "Finding $environment Kubernetes Service IPs through $vm..."
    # The Service's ClusterIP is routable from the k3s node; no kubectl
    # port-forward processes or extra VM terminal sessions are needed.
    if ! service_json="$(ssh "${ssh_args[@]}" "$vm" \
        "sudo -n k3s kubectl -n $environment get services ${services[*]} -o json")"; then
        echo "Cannot query services. Run this from the local machine (where the '$vm' SSH alias works)." >&2
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

    # Argo CD is an optional service in its own namespace, shared across environments.
    # A missing Argo CD installation must not prevent normal application access.
    if argocd_ip="$(ssh "${ssh_args[@]}" "$vm" \
        "sudo -n k3s kubectl -n argocd get service argocd-server -o jsonpath='{.spec.clusterIP}'" 2>/dev/null)"; then
        if [[ "$argocd_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            forwards+=(-L "127.0.0.1:$argocd_local_port:$argocd_ip:443")
        fi
    fi
    unset argocd_ip

    echo "Starting a background SSH tunnel (only localhost ports are exposed)..."
    if ! ssh "${ssh_args[@]}" -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -M -S "$socket" -fNT "${forwards[@]}" "$vm"; then
        echo "Cannot start SSH forwarding. Stop any previous local SSH tunnels using these ports." >&2
        exit 1
    fi
    printf '%s\n' "$requested_target" > "$target_file"
    chmod 600 "$target_file"
fi

# An active SSH master only confirms local listeners, not that every HTTP
# endpoint is healthy. Test the actual Nginx response too.
if ! curl -fsS --connect-timeout 5 --max-time 15 \
    "http://127.0.0.1:${ports[0]}/nginx-health" >/dev/null; then
    echo "WARNING: SSH is running, but Nginx did not answer. Check VM connectivity and services." >&2
    echo "Stop and retry: ./deployment/scripts/open_access_to_vm.sh $environment stop" >&2
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
argocd_reachable=false
if curl -kfsS --connect-timeout 2 --max-time 5 \
    "https://127.0.0.1:$argocd_local_port/" >/dev/null 2>&1; then
    printf 'Argo CD:       https://127.0.0.1:%s/ (self-signed certificate)\n' "$argocd_local_port"
    argocd_reachable=true
fi

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

if [[ "$argocd_reachable" == true ]]; then
    # Show only the initial password, if still present. Never print a rotated password.
    if argocd_password_b64="$(ssh "${ssh_args[@]}" "$vm" \
        "sudo -n k3s kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}'" 2>/dev/null)" \
        && [[ -n "$argocd_password_b64" ]]; then
        if argocd_password="$(printf '%s' "$argocd_password_b64" | base64 -d)"; then
            printf 'Argo CD:    admin / %s (initial password)\n' "$argocd_password"
            unset argocd_password
        fi
    else
        echo "Argo CD:    admin / password changed or initial secret unavailable"
    fi
    unset argocd_password_b64
fi

echo
echo "Keep these passwords private; they are not saved locally."
echo "The tunnel stays in the background. To close:"
echo "  ./deployment/scripts/open_access_to_vm.sh $environment stop"
echo "======================================"
