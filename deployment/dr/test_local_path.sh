#!/usr/bin/env bash
# Offline regression tests for k3s local-path PV resolution, without a cluster.
set -euo pipefail
source "$(dirname "$0")/common.sh"

mock_pv_id="pvc-12345678-1234-1234-1234-1234567890ab"
mock_pv_claim="prod/etl-data"
mock_pv_path="/var/lib/rancher/k3s/storage/${mock_pv_id}_prod_etl-data"
mock_storage_class="local-path"
mock_volume_type="local"

remote() {
  case "$1" in
    *"get pvc etl-data"*) printf '%s' "$mock_pv_id" ;;
    *"jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}'"*)
      printf '%s' "$mock_pv_claim" ;;
    *"jsonpath='{.spec.storageClassName}'"*)
      printf '%s' "$mock_storage_class" ;;
    *"jsonpath='{.spec.local.path}'"*)
      if [[ "$mock_volume_type" == local ]]; then
        printf '%s' "$mock_pv_path"
      fi ;;
    *"jsonpath='{.spec.hostPath.path}'"*)
      if [[ "$mock_volume_type" == hostPath ]]; then
        printf '%s' "$mock_pv_path"
      fi ;;
    *) printf 'Unexpected mock command: %s\n' "$1" >&2; return 1 ;;
  esac
}

# k3s can provision local-path storage with either PV volume type.
actual="$(local_pv_path prod etl-data)"
[[ "$actual" == "$mock_pv_path" ]] || exit 1

mock_volume_type="hostPath"
actual="$(local_pv_path prod etl-data)"
[[ "$actual" == "$mock_pv_path" ]] || exit 1

# Refuse missing paths, unsafe directories, wrong claim and storage classes.
mock_volume_type="none"
if (local_pv_path prod etl-data >/dev/null 2>&1); then
  echo "PV without a backing path was accepted" >&2
  exit 1
fi

mock_volume_type="local"
mock_pv_path="/tmp/untrusted-volume"
if (local_pv_path prod etl-data >/dev/null 2>&1); then
  echo "Unsafe PV host path was accepted" >&2
  exit 1
fi

mock_pv_path="/var/lib/rancher/k3s/storage/${mock_pv_id}_prod_etl-data"
mock_pv_claim="dev/etl-data"
if (local_pv_path prod etl-data >/dev/null 2>&1); then
  echo "PV bound to different namespace was accepted" >&2
  exit 1
fi

mock_pv_claim="prod/etl-data"
mock_storage_class="untrusted"
if (local_pv_path prod etl-data >/dev/null 2>&1); then
  echo "Unexpected storage class was accepted" >&2
  exit 1
fi
echo "k3s local-path PV resolution checks passed"
