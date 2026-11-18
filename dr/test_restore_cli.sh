#!/usr/bin/env bash
# Exercise root restore.sh safeguards without live Proxmox/SSH.
set -euo pipefail
base="$(cd -- "$(dirname -- "$0")/.." && pwd)"
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
mkdir -p "$temp/dr" "$temp/bin" "$temp/infrastructure/terraform"
cp "$base/restore.sh" "$temp/restore.sh"
cp "$base/dr/common.sh" "$temp/dr/common.sh"
printf 'vm_id = 101\n' > "$temp/infrastructure/terraform/terraform.tfvars"
printf 'fixture\n' > "$temp/infrastructure/terraform/terraform.tfstate"
printf '%s\n' 'not-a-private-key' > "$temp/id_ed25519"
cat > "$temp/bin/terraform" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"state list"*) echo 'proxmox_virtual_environment_vm.k3s[0]' ;;
  *"managed_vm_id"*) echo "${MOCK_MANAGED_ID:-100}" ;;
  *"managed_vm_name"*) echo 'job-market-dr-test' ;;
  *"managed_vm_ipv4"*) echo '10.10.10.21/24' ;;
  *"managed_vm_username"*) echo 'group3' ;;
  *"managed_vm_ssh_public_key_path"*) echo "$MOCK_SSH_PUB" ;;
  *) exit 1 ;;
esac
SH
cat > "$temp/bin/ssh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"get nodes -o name"*) exit 0 ;;
  *"items[0].metadata.name"*) echo 'job-market-ubuntu-100' ;;
  *"hostname"*) echo 'job-market-ubuntu-100' ;;
  *) echo "Unexpected SSH operation: $*" >&2; exit 2 ;;
esac
SH
cat > "$temp/bin/age" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$temp/bin/"*
export PATH="$temp/bin:$PATH" MOCK_SSH_PUB="$temp/id_ed25519.pub"
# 100 is a reserved production ID and must be rejected before any network call.
out="$(bash "$temp/restore.sh" 100 2>&1 || true)"
[[ "$out" == *"Refusing recovery into VM 100"* ]] ||
  { printf 'Expected VM 100 refusal, got: %s\n' "$out" >&2; exit 1; }
# Even a prepared DR worktree cannot retarget a Terraform state for VM 100.
out="$(MOCK_MANAGED_ID=100 bash "$temp/restore.sh" 101 2>&1 || true)"
[[ "$out" == *"does not match Terraform state"* ]] ||
  { printf 'Expected state mismatch rejection, got: %s\n' "$out" >&2; exit 1; }
# With the matching state, the SSH/k3s node identity guard must reject a
# production host before inspecting archives or making changes.
out="$(MOCK_MANAGED_ID=101 bash "$temp/restore.sh" 101 2>&1 || true)"
[[ "$out" == *"Wrong destination"* ]] ||
  { printf 'Expected wrong-node rejection, got: %s\n' "$out" >&2; exit 1; }
echo "Root restore CLI safeguards PASSED"
