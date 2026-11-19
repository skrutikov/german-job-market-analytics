#!/usr/bin/env bash
# Shared Terraform workspace selection for per-VM Proxmox automation.
# Source only from the deployment scripts after setting TF_DIR and VM_ID.

vm_workspace_name() {
    printf 'vm-%s' "$VM_ID"
}

terraform_vm_workspace() {
    local mode="$1" workspaces
    VM_WORKSPACE="$(vm_workspace_name)"
    if [[ -n "${TF_WORKSPACE:-}" && "$TF_WORKSPACE" != "$VM_WORKSPACE" ]]; then
        echo "ERROR: TF_WORKSPACE conflicts with requested $VM_WORKSPACE." >&2
        return 1
    fi
    # Terraform must initialize before querying or creating local workspaces.
    terraform -chdir="$TF_DIR" init -input=false
    workspaces="$(terraform -chdir="$TF_DIR" workspace list)"
    WORKSPACE_ALREADY_EXISTED=false
    if printf '%s\n' "$workspaces" | sed -E 's/^[*[:space:]]+//' |
        grep -Fxq "$VM_WORKSPACE"; then
        WORKSPACE_ALREADY_EXISTED=true
        terraform -chdir="$TF_DIR" workspace select "$VM_WORKSPACE"
    elif [[ "$mode" == create ]]; then
        terraform -chdir="$TF_DIR" workspace new "$VM_WORKSPACE"
    else
        echo "ERROR: No Terraform workspace $VM_WORKSPACE; refusing." >&2
        return 1
    fi
    # Pin every subsequent Terraform invocation explicitly to this VM state,
    # even if another process selects a different CLI workspace later.
    export TF_WORKSPACE="$VM_WORKSPACE"
    [[ "$(terraform -chdir="$TF_DIR" workspace show)" == "$VM_WORKSPACE" ]] || {
        echo "ERROR: Failed to select Terraform workspace $VM_WORKSPACE." >&2
        return 1
    }
}
