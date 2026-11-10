# Proxmox infrastructure with Terraform

This directory contains infrastructure-as-code for the Liora DataOps project.
It defines **optional** Proxmox VM provisioning, but is deliberately **non-provisioning by default**: `create_vm = false`.

## Current infrastructure (November 2026)

The project's Ubuntu VM was created **manually in the Proxmox Web UI**, not by Terraform.

- Ubuntu 24.04 VM: `group3-ubuntu01`, IPv4 `10.10.10.20/24`, default gateway `10.10.10.1`.
- Allocated resources: **4 vCPUs, approximately 16 GB RAM, 30 GB virtual disk** (approximately 28 GB root filesystem).
- Outbound IPv4, DNS resolution, and HTTPS internet access have been tested successfully.
- A **single-node k3s v1.36.5+k3s1** cluster is installed and operational on this VM.
- The Kubernetes node is `Ready`, and the `dev` and `prod` namespaces exist.
- The installation/configuration is documented in `../ansible/`. Ansible was tested **locally inside the VM** and reached `changed=0` on repeat runs.

**Terraform does not currently manage or import this existing VM.** Do not point the optional clone resource at its VM ID. Importing or managing an existing VM would require a separate reviewed plan.

## What the Terraform code does

- Uses the `bpg/proxmox` provider.
- Optionally clones a **new**, Liora-approved VM template when `create_vm = true`.
- Allows configuration of node, unique VM ID, bridge, CPU, and RAM through variables.
- Starts the optional newly cloned VM **powered off**.
- Does **not** configure Proxmox host networking, fix connectivity, install k3s, or deploy the application.

The example clone configuration uses DHCP and is **not a description of the existing VM's static IP configuration**.

## Validation completed

The following commands were successfully executed in local Ubuntu WSL using Terraform v1.17.1:

```bash
terraform init
terraform fmt -check
terraform validate
```

The provider was downloaded and the configuration validated. **We have not verified a Proxmox API connection, performed VM provisioning with Terraform, or run `terraform apply`.** A successful `validate` does not establish that the configured VM would be provisioned successfully.

The generated `.terraform.lock.hcl` is committed to the repository to record the selected provider dependency.

## Optional: provisioning an additional VM

The existing VM is operational; **none of the following is required to continue deploying the application**. If an additional VM is needed later, confirm with Liora:

- Approved Proxmox node, storage/datastore, resource quota, and a unique VM ID.
- Approved bridge/VLAN and IP addressing (including DHCP versus static IP).
- An approved, clonable cloud-init template.
- Whether a suitably scoped Proxmox API token is available and permitted.

The server is shared with another group. **Do not change Proxmox host networks, storage, firewall settings, or other groups' resources.**

## Terraform workflow (from Ubuntu WSL or another approved workstation)

1. Install Terraform and open this directory.
2. For Proxmox API operations, set credentials using local environment variables:

   ```bash
   export PROXMOX_VE_ENDPOINT="https://YOUR-PROXMOX-HOST:8006/"
   export PROXMOX_VE_API_TOKEN="YOUR_SCOPED_API_TOKEN"
   ```

   Do not commit credentials. Use a trusted TLS certificate rather than disabling certificate verification.
3. Copy `terraform.tfvars.example` to `terraform.tfvars` and enter only approved values. The latter is ignored by Git.
4. Check the configuration:

   ```bash
   terraform init
   terraform fmt -check
   terraform validate
   terraform plan
   ```

   With `create_vm = false` and empty Terraform state, the intended plan is **no resources to add**. A no-change plan is not proof that authenticated Proxmox provisioning works.
5. Only after explicit approval, select a **new** VM ID and suitable template, enable `create_vm`, inspect the complete plan, and agree on state storage/locking and a recovery procedure before `terraform apply`.

## Limitations and safety

- The existing VM remains outside Terraform state; the current resource is intended for a **new VM only**.
- The scaffold does not create an Ubuntu image/template, install k3s, or provide production-ready Proxmox networking.
- `prevent_destroy` guards the optional Terraform-managed VM against routine destroy operations, but is **not** a backup strategy.
- Terraform state can contain sensitive infrastructure details: keep local state private, and use protected shared state with locking before collaborative provisioning.
- Kubernetes application manifests and deployment CI/CD are separate project milestones.
