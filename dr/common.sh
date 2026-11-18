#!/usr/bin/env bash
# Shared helpers for the DR operator workstation scripts.
set -euo pipefail

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

validate_namespace() {
  [[ "${1:-}" == dev || "${1:-}" == prod ]] ||
    die "Namespace must be dev or prod"
}

require_tools() {
  for program in ssh age sha256sum gzip; do
    command -v "$program" >/dev/null || die "Missing dependency: $program"
  done
}

# The operator workstation initiates all connections to the VM. Its local
# backups survive destruction of the VM and do not require public VM ports.
remote() {
  ssh -T -o BatchMode=yes "$DR_SSH_HOST" "$1"
}

check_host() {
  DR_SSH_HOST="${1:-}"
  [[ -n "$DR_SSH_HOST" && "$DR_SSH_HOST" != -* &&
     "$DR_SSH_HOST" =~ ^[a-zA-Z0-9_.@-]+$ ]] ||
    die "Provide a trusted SSH alias or user@host (no options)"
  remote "sudo -n k3s kubectl get nodes -o name >/dev/null" ||
    die "Cannot reach k3s through SSH with passwordless sudo"
}

check_quiesced() {
  local ns="$1" replicas active
  for deployment in airflow grafana; do
    replicas="$(remote "sudo -n k3s kubectl -n $ns get deployment $deployment -o jsonpath='{.spec.replicas}'")"
    [[ "$replicas" == 0 ]] ||
      die "$ns/$deployment must have 0 replicas (found $replicas); see runbook"
  done
  # An active one-off ETL Job could still write to the shared PVC/database.
  active="$(remote "sudo -n k3s kubectl -n $ns get jobs -o json" |
    python3 -c 'import json,sys; print(sum(j.get("status",{}).get("active",0) for j in json.load(sys.stdin)["items"]))')"
  [[ "$active" == 0 ]] || die "$ns still has $active active Jobs"
}

validate_volume() {
  case "$1" in airflow-state|etl-data|grafana-data) ;; *) die "Unknown DR volume: $1";; esac
}

create_helper() {
  local ns="$1" claim="$2"
  validate_namespace "$ns"
  validate_volume "$claim"
  # Must be absent before creating next helper; do not replace unrelated Pods.
  remote "sudo -n k3s kubectl -n $ns get pod dr-volume-helper >/dev/null 2>&1" &&
    die "dr-volume-helper already exists in $ns; investigate before continuing"
  remote "sudo -n k3s kubectl -n $ns apply -f -" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: dr-volume-helper
  namespace: $ns
  labels:
    app: dr-volume-helper
spec:
  restartPolicy: Never
  containers:
    - name: backup
      image: busybox:1.36
      command: [sh, -c, "sleep 1800"]
      volumeMounts:
        - name: data
          mountPath: /backup
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: $claim
YAML
  remote "sudo -n k3s kubectl -n $ns wait --for=condition=Ready pod/dr-volume-helper --timeout=180s"
}

delete_helper() {
  local ns="$1"
  remote "sudo -n k3s kubectl -n $ns delete pod dr-volume-helper --ignore-not-found --wait=true --timeout=180s" >&2
}
