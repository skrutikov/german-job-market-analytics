# Proxmox infrastructure deployment

This directory provisions an Ubuntu VM on Proxmox VE with **Terraform** and configures a **single-node k3s Kubernetes cluster** with **Ansible**. The root `deploy.sh` script runs both stages.

![Infrastructure architecture](../docs/images/infrastructure.png)

The application itself is **not** deployed by these scripts. Kubernetes application manifests and continuous delivery are separate deployment stages.

## Architecture

```text
Local Linux / WSL (Terraform + Ansible)
           |
           +-- Proxmox HTTPS API --> VM (Terraform)
           |
           +-- SSH jump host -----> Ubuntu guest (Ansible)
                                       |
                                      k3s
                                     /   \
                                   dev   prod
```

The checked-in `terraform.tfvars.example` uses the following **example environment**. Adjust its values to match your own Proxmox installation and available resources.

| Setting | Example |
|---|---|
| Proxmox VM ID | 100 |
| VM name | `job-market-ubuntu-100` |
| Ubuntu | 24.04 Cloud Image |
| vCPUs | 4 |
| RAM | 16384 MiB (16 GiB) |
| Boot disk | 30 GiB |
| Network | `nat0` |
| Guest IP | `10.10.10.20/24` |
| Gateway | `10.10.10.1` |
| Guest SSH user | `group3` |
| SSH gateway user | `jumpuser` |

## Prerequisites

- An authorized Proxmox VE host, VM ID, IP address, datastore and virtual network.
- An existing Proxmox SDN VNet with internet connectivity, or a network prepared by the host administrator.
- A Proxmox API token with permission to create and configure the specific VM, allocate storage and attach the selected VNet.
- A Linux workstation (WSL is supported) with Terraform, Ansible, Python 3 and OpenSSH.
- An SSH public/private key pair, with the public key configured for the VM through Cloud-Init.
- A trusted copy of the Proxmox CA certificate for TLS verification.
- An Ubuntu 24.04 Cloud Image imported into a Proxmox datastore that supports `import`.

**Use an unallocated VM ID and IP address.** This Terraform configuration creates a new VM; it does not import an existing VM or take over its disks. Replacing an existing VM requires a separate, authorized migration or decommissioning procedure with verified backups. Never apply a plan that would unexpectedly delete or replace resources.

## 1. Prepare the Proxmox environment

### Ubuntu Cloud Image

Download an Ubuntu 24.04 Cloud Image from [Ubuntu Cloud Images](https://cloud-images.ubuntu.com/noble/) and import it through the Proxmox web interface (`Datacenter → node → local → Import`). For the example configuration, store it as:

```text
local:import/job-market-noble-server-cloudimg-amd64.qcow2
```

On the Proxmox host, verify that the image exists:

```bash
pvesm list local --content import
```

Set `cloud_image_file_id` in `terraform.tfvars` to the actual file ID. Reuse an existing verified image instead of importing duplicates.

### Networking and API permissions

The example uses the `nat0` VNet and gateway `10.10.10.1`. These values must match the selected Proxmox SDN configuration. Terraform creates the VM, **not** the host-wide SDN zone/VNet.

Create a Proxmox API token in **Datacenter → Permissions → API Tokens**. With privilege separation enabled, the token's effective permissions are limited by its owner's permissions. Grant only the privileges required for the selected VM, storage and VNet; do not grant cluster-wide administrator access.

Typical required capabilities include:

| Resource | Purpose |
|---|---|
| `/vms/VM_ID` | Allocate and configure the target VM |
| `/storage/DATASTORE` | Allocate VM and Cloud-Init disk space |
| `/sdn/zones/ZONE/VNET` | Attach the VM to the approved network |

Check the token's effective permissions before provisioning. Some Proxmox setups may require a VM-specific ACL to be re-established after the VM is removed.

### Restricted SSH jump account

When the VM is reachable only through a private network, an authorized administrator can create a non-privileged gateway account (the example uses `jumpuser`). The corresponding SSH public key may be constrained to forward **only** to the selected VM's SSH port.

An example `authorized_keys` entry has this shape:

```text
restrict,port-forwarding,permitopen="VM_PRIVATE_IP:22",command="/bin/false" ssh-ed25519 PUBLIC_KEY comment
```

Replace the placeholders with the actual guest IP and the workstation's **public** key. Keep host-level SSH policy and file permissions consistent with your organization's security requirements. A `channel 0: open failed: administratively prohibited` message often indicates an SSH port-forwarding restriction or destination mismatch; inspect the approved forwarding policy rather than disabling the restriction.

### Trust the Proxmox API certificate

Copy the Proxmox CA certificate from a trusted source into a local file such as `~/.config/proxmox/pve-root-ca.pem`. The deployment script reads this path through `SSL_CERT_FILE`. Do not disable certificate verification.

## 2. Configure Terraform

From the repository root:

```bash
cp infrastructure/terraform/terraform.tfvars.example infrastructure/terraform/terraform.tfvars
nano infrastructure/terraform/terraform.tfvars
```

Review the VM identity, resources, network, Proxmox node, Cloud Image path and SSH public-key path. Set:

```hcl
create_vm = true
```

only when you are ready to create the new VM. `terraform.tfvars` is ignored by Git; updates to the example file do not overwrite it.

Check any existing state before deployment:

```bash
terraform -chdir=infrastructure/terraform init
terraform -chdir=infrastructure/terraform state list
```

If the state already tracks a different VM, resolve that discrepancy explicitly. Do not delete the state file to make Terraform forget a live resource.

## 3. Provision the VM and install k3s

From the repository root:

```bash
./deploy.sh
```

`deploy.sh` will:

1. Validate the Terraform configuration and save a plan.
2. Reject plans that delete or replace Terraform resources or target an unexpected VM ID.
3. Request confirmation using the VM ID (for example `apply 100`).
4. Apply Terraform, wait for guest SSH and Cloud-Init, and run the Ansible playbook.
5. Display the Kubernetes node and namespace status.

The example script uses `EXPECTED_VM_ID=100` by default and `jumpuser` as the SSH gateway user. For an authorized different VM, set `EXPECTED_VM_ID` and the corresponding values in `terraform.tfvars`. Configure `PROXMOX_HOST`, `PROXMOX_VE_API_TOKEN` and `SSL_CERT_FILE` for the target Proxmox host.

On first connection, verify the Proxmox and guest SSH host-key fingerprints through trusted channels before accepting them. Recreated guests typically have new SSH host keys.

## 4. Connect and verify

Optionally add SSH aliases to the workstation's `~/.ssh/config` (replace the placeholder with the gateway hostname or IP):

```sshconfig
Host liora-proxmox
    HostName PROXMOX_HOST
    User jumpuser
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes

Host liora-vm100
    HostName 10.10.10.20
    User group3
    ProxyJump liora-proxmox
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

```bash
ssh liora-vm100
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get namespaces
```

The expected result is a `Ready` Kubernetes node with `dev` and `prod` namespaces. See [Ansible setup](ansible/README.md) for running the playbook independently.

## 5. Lifecycle and safety

`destroy.sh` deletes **only** a VM recorded in this Terraform state and requires an explicit confirmation. For VM ID 100, it also requires `ALLOW_DESTROY_VM100=true`. It cannot delete a manually created VM that Terraform does not manage.

Take and verify backups of any persistent data before planned destruction or reprovisioning. Preserve Terraform state and keep API tokens, private SSH keys, `terraform.tfvars` and kubeconfigs out of Git.

**A single-node k3s cluster is not highly available.** Data backups, recovery procedures, Kubernetes application deployments and monitoring are separate responsibilities.
