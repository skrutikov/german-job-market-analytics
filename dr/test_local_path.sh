#!/usr/bin/env bash
# Offline regression tests for strict k3s local-path PVC lookup.
set -euo pipefail
source "$(dirname "$0")/common.sh"

pv_id="pvc-12345678-1234-1234-1234-1234567890ab"
pv_claim="prod/etl-data"
pv_path="/var/lib/rancher/k3s/storage/${pv_id}_prod_etl-data"

remote() {
  case "$1" in
    *"get pvc etl-data"*) printf '%s' "$pv_id" ;;
    *"jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}'"*)
      printf '%s' "$pv_claim" ;;
    *"jsonpath='{.spec.hostPath.path}'"*)
      printf '%s' "$pv_path" ;;
    *) printf 'Unexpected mock command: %s\n' "$1" >&2; return 1 ;;
  esac
}

actual="$(local_pv_path prod etl-data)"
[[ "$actual" == "$pv_path" ]] || exit 1

pv_path="/tmp/untrusted-volume"
if (local_pv_path prod etl-data >/dev/null 2>&1); then
  echo "Unsafe PV host path was accepted" >&2
  exit 1
fi

pv_path="/var/lib/rancher/k3s/storage/${pv_id}_prod_etl-data"
pv_claim="dev/etl-data"
if (local_pv_path prod etl-data >/dev/null 2>&1); then
  echo "A PV bound to a different namespace was accepted" >&2
  exit 1
fi
echo "k3s local-path PVC resolution checks passed"
