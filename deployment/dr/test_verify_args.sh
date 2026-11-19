#!/usr/bin/env bash
# Guard against a mismatch between backup.sh and verify_backup.sh arguments.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
four="$(bash "$repo_root/deployment/dr/verify_backup.sh" prod k3s-vm /nonexistent /nonexistent 2>&1 || true)"
if [[ "$four" == *"Usage: bash deployment/dr/verify_backup.sh"* ]]; then
  echo "Verifier rejected the correct 4-argument invocation" >&2
  exit 1
fi
three="$(bash "$repo_root/deployment/dr/verify_backup.sh" prod k3s-vm /nonexistent 2>&1 || true)"
if [[ "$three" != *"Usage: bash deployment/dr/verify_backup.sh"* ]]; then
  echo "Verifier did not reject a 3-argument invocation" >&2
  exit 1
fi
echo "Verifier CLI argument count checks passed"
