#!/usr/bin/env bash
# Backwards-compatible alias for the renamed access-tunnel script.
set -euo pipefail
exec bash "$(dirname -- "${BASH_SOURCE[0]}")/open_access_to_vm.sh" "$@"
