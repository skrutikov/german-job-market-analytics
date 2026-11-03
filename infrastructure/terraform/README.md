# Group 3 Proxmox Terraform scaffold

This directory prepares infrastructure-as-code for the Liora DataOps project.
It is deliberately **non-provisioning by default**: `create_vm = false`.

## Important: current VM and network

The existing manually created `group3-group3-ubuntu01` VM is **not** automatically imported or managed by Terraform. Do not apply Terraform to an existing VM ID without first reviewing and planning an import.

The current Ubuntu VM has an IPv6 address but no IPv4 address or default IPv4 route. Terraform cannot assume or repair Liora's shared upstream networking. Ask Liora to confirm the assigned bridge/VLAN, DHCP or static IP plan, IPv4 gateway, DNS and allowed outbound internet. Do not modify Proxmox host networking or other groups' resources.

## Required confirmation before provisioning

- Proxmox node name and group 3 VM ID allocation
- Approved bridge/VLAN and IP configuration; whether NAT or a gateway is available
- Group 3 resource quota, datastore and permitted VM templates
- Whether a scoped Proxmox API token may create/clone VMs

## Local workflow

1. Install Terraform on a workstation with network access (not necessarily the offline VM).
2. Configure the bpg/proxmox provider using environment variables:
   ```bash
   export PROXMOX_VE_ENDPOINT="https://YOUR-PROXMOX-HOST:8006/"
   export PROXMOX_VE_API_TOKEN="YOUR_SCOPED_API_TOKEN"
   ```
   Never commit tokens or credentials. Use a valid trusted TLS certificate; do not disable certificate verification merely for convenience.
3. Copy `terraform.tfvars.example` to `terraform.tfvars` and replace placeholders with approved values.
4. Run:
   ```bash
   terraform init
   terraform fmt -check
   terraform validate
   terraform plan
   ```
   With `create_vm = false`, the intended plan is **no resources to add**.
5. Only if a **new** VM is approved and a suitable cloud-init template exists, set `create_vm = true`, set its unique group 3 VM ID, verify the full plan and obtain team approval before applying.

## Limitations

- VM creation is template-based. This scaffold does not download an OS image, create an Ubuntu template, configure NAT, install k3s or deploy Kubernetes manifests.
- It does not declare or manage the existing manually created VM.
- The optional VM starts powered off to avoid unexpected resource usage.
- `prevent_destroy` protects the Terraform-managed VM from accidental destroy, but this is not a backup strategy.
- We will add Kubernetes manifests and CI/CD separately once networking and cluster design are confirmed.
- Local Terraform state must be kept private. For teamwork, agree on a protected remote-state solution and state locking before applying.
