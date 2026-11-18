#!/usr/bin/env bash
# Ensure restore.sh refuses an unintended Kubernetes node BEFORE any write.
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/ssh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"items[0].metadata.name"*)
    printf '%s' "${MOCK_NODE_NAME:-job-market-ubuntu-100}"
    ;;
  *)
    exit 0
    ;;
esac
SH
chmod +x "$tmp/ssh"
run_restore() {
  env PATH="$tmp:$PATH" CONFIRM_RESTORE=prod "$@" \
    bash "$repo_root/dr/restore.sh" prod k3s-dr-test \
      /nonexistent-dr-backup /nonexistent-dr-key prepare 2>&1
}
out="$(run_restore DR_EXPECTED_NODE_NAME=job-market-dr-test || true)"
[[ "$out" == *"Restore destination mismatch"* ]] ||
  { printf 'Expected mismatch rejection, got: %s\n' "$out" >&2; exit 1; }
out="$(run_restore DR_EXPECTED_NODE_NAME= || true)"
[[ "$out" == *"Set DR_EXPECTED_NODE_NAME"* ]] ||
  { printf 'Expected missing-target rejection, got: %s\n' "$out" >&2; exit 1; }
out="$(run_restore MOCK_NODE_NAME=job-market-dr-test DR_EXPECTED_NODE_NAME=job-market-dr-test || true)"
[[ "$out" == *"Restore target verified: job-market-dr-test"* ]] ||
  { printf 'Expected destination acceptance, got: %s\n' "$out" >&2; exit 1; }
[[ "$out" == *"Backup, checksums, or age private key missing"* ]] ||
  { printf 'Expected next preflight to reject missing files, got: %s\n' "$out" >&2; exit 1; }
echo "Restore VM node identity guard checks passed"
