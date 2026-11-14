# Terraform: Ubuntu VM on Proxmox

This module provisions a new Ubuntu 24.04 virtual machine from a pre-imported Cloud Image on Proxmox VE. It configures CPU, memory, disk, network interface and Cloud-Init SSH access.

Run the complete Terraform + Ansible workflow from the repository root using [`deploy.sh`](../../deploy.sh). Detailed host and SSH prerequisites are in the [infrastructure guide](../README.md).

## Default example

| Variable | Example value |
|---|---|
| `vm_id` | `100` |
| `vm_name` | `job-market-ubuntu-100` |
| `cpu_cores` | `4` |
| `memory_mb` | `16384` |
| `disk_gb` | `30` |
| `network_bridge` | `nat0` |
| `vm_ipv4_cidr` | `10.10.10.20/24` |
| `vm_gateway` | `10.10.10.1` |
| `vm_username` | `group3` |
| `datastore_id` | `local` |
| `create_vm` | `false` (safety default) |

The values are a **configuration example**, not a claim about resources available on any Proxmox host. Choose an unused, authorized VM ID and IP address before setting `create_vm = true`. Terraform does **not** import or adopt a VM that already exists with that ID.

## Prerequisites

- Proxmox HTTPS API endpoint and an API token with scoped VM, storage and VNet permissions.
- Trusted Proxmox CA certificate for TLS verification.
- An Ubuntu Cloud Image already imported into the specified Proxmox datastore.
- A configured virtual network and gateway.
- An SSH public key available to Cloud-Init.

The module does not create host-level networking, API users, SSH gateway accounts or the Cloud Image itself.

## Configure

From the repository root:

```bash
cp infrastructure/terraform/terraform.tfvars.example infrastructure/terraform/terraform.tfvars
nano infrastructure/terraform/terraform.tfvars
```

Review the values for the target environment. The example uses:

```hcl
create_vm    = true
vm_id        = 100
vm_name      = "job-market-ubuntu-100"
cpu_cores    = 4
memory_mb    = 16384
disk_gb      = 30
vm_ipv4_cidr = "10.10.10.20/24"
```

Set `node_name` to the actual Proxmox node, and review `datastore_id`, `network_bridge`, `vm_gateway`, `cloud_image_file_id` and `ssh_public_key_path` as well.

The local `terraform.tfvars` is intentionally **not committed to Git**. Pulling new repository changes will not update it.

## Validate and plan

Configure the Proxmox API connection in your shell, for example:

```bash
export PROXMOX_VE_ENDPOINT="https://PROXMOX_HOST:8006/"
export SSL_CERT_FILE="$HOME/.config/proxmox/pve-root-ca.pem"
# Supply PROXMOX_VE_API_TOKEN securely (format: USER@REALM!TOKEN=SECRET).
```

Then:

```bash
terraform init
terraform validate
terraform state list
terraform plan
```

Run those commands from this `infrastructure/terraform` directory. The state must not already track an unrelated VM. Review the complete plan, particularly any `delete` or `replace` actions.

**Prefer `../../deploy.sh` for creation:** it checks for destructive actions, verifies the expected VM ID, requests explicit approval and then invokes Ansible. Manual `terraform apply` provisions the VM only; it does not install k3s.

## Outputs

The module exposes the managed VM ID, name, static IP/CIDR, SSH username, public-key path and imported image ID. The deployment script uses these outputs to construct its SSH/Ansible connection.

## State and deletion

Terraform tracks a VM only after creating or explicitly importing it into state. It cannot manage a VM merely because its ID matches `vm_id`.

Keep the state file safe and **never remove it to bypass a plan**. Setting `create_vm = false` for a state-managed VM can plan destruction; use the repository's guarded `destroy.sh` only when deletion is intentional, authorized and backed up.

Destroying a VM also removes its managed disks. A pre-imported Cloud Image is not destroyed by this module. Consult the [infrastructure guide](../README.md) for access controls and SSH prerequisites.
