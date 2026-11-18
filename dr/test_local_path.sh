#!/usr/bin/env bash
# Offline regression tests for strict k3s local-path PVC lookup.
set -euo pipefail
source "$(dirname "$0")/common.sh"

mock_pv_id="pvc-12345678-1234-1234-1234-1234567890ab"
mock_pv_claim="prod/etl-data"
mock_pv_path="/var/lib/rancher/k3s/storage/${mock_pv_id}_prod_etl-data"

remote() {
  case "$1" in
    *"get pvc etl-data"*) printf '%s' "$mock_pv_id" ;;
    *"jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}'"*)
      printf '%s' "$mock_pv_claim" ;;
    *"jsonpath='{.spec.hostPath.path}'"*)
      printf '%s' "$mock_pv_path" ;;
    *) printf 'Unexpected mock command: %s\n' "$1" >&2; return 1 ;;
  esac
}

actual="$(local_pv_path prod etl-data)"
[[ "$actual" == "$mock_pv_path" ]] || exit 1

mock_pv_path="/tmp/untrusted-volume"
if (local_pv_path prod etl-data >/dev/null 2>&1); then
  echo "Unsafe PV host path was accepted" >&2
  exit 1
fi

mock_pv_path="/var/lib/rancher/k3s/storage/${mock_pv_id}_prod_etl-data"
mock_pv_claim="dev/etl-data"
if (local_pv_path prod etl-data >/dev/null 2>&1); then
  echo "A PV bound to a different namespace was accepted" >&2
  exit 1
fi
echo "k3s local-path PVC resolution checks passed"
