#!/usr/bin/env bash
# Prepare a DR-only Kustomize overlay WITHOUT mutating the source checkout.
# It must be applied to a temporary copy of the recorded production revision.
set -euo pipefail
(( $# == 2 )) || { echo "Usage: bash dr/sanitize_overlay.sh KUSTOMIZATION_FILE sha-<40 hex>" >&2; exit 2; }
overlay="$1"
release_tag="$2"
[[ -f "$overlay" && "$release_tag" =~ ^sha-[a-f0-9]{40}$ ]] ||
  { echo "ERROR: Missing prod overlay or invalid immutable release tag" >&2; exit 1; }
[[ "$(grep -c 'newTag: sha-' "$overlay")" == 2 ]] ||
  { echo "ERROR: Expected two SHA-tagged images in recorded overlay" >&2; exit 1; }
if grep -q '^patches:' "$overlay"; then
  echo "ERROR: Production overlay already declares patches; inspect before DR isolation" >&2
  exit 1
fi
sed -i -E "s/newTag: sha-[a-f0-9]{40}/newTag: $release_tag/" "$overlay"
[[ "$(grep -Fc "newTag: $release_tag" "$overlay")" == 2 ]] ||
  { echo "ERROR: Failed to pin both restored images" >&2; exit 1; }
cat >> "$overlay" <<'PATCHES'

# DR-only isolation. Do not run saved Airflow DAGs or alert notifications.
patches:
  - target:
      kind: Deployment
      name: airflow
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 0
  - target:
      kind: Deployment
      name: alertmanager
    patch: |-
      - op: replace
        path: /spec/replicas
        value: 0
  - target:
      kind: CronJob
      name: data-update
    patch: |-
      - op: replace
        path: /spec/suspend
        value: true
PATCHES
echo "DR overlay pinned to $release_tag; Airflow/Alertmanager disabled and CronJob suspended."
