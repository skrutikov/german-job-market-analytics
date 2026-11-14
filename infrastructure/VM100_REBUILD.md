# Replace manually provisioned VM 100 with Terraform + Ansible

**Target for the next deployment:** VM ID `100`, private IP `10.10.10.20/24`, Ubuntu user `group3`, **4 vCPUs**, **16,384 MiB (16 GiB)** RAM and **30 GiB** disk on the approved `nat0` VNet.

**Current status (14 November 2026):** VM 100 still exists as a manually provisioned, running Ubuntu/k3s VM. It is **not** in Terraform state. An experimental VM 101 was also visible in Proxmox; keep it separate. Changing Terraform variables does not reassign VM IDs or make Terraform manage an existing manually created VM.

This procedure is **destructive to the old VM 100**. Perform it only with explicit instructor/host-owner approval and verified backups. It has not yet been executed end to end.

## 1. Back up before touching VM 100

In **Proxmox Web UI → VM 100 → Backup → Backup now**, make a backup and verify that the backup completed and can be located/restored. A Proxmox snapshot is not a substitute for a backup. Preserve any data/configuration you need from the existing k3s cluster (e.g. PVC contents, secrets and kubeconfig) and preferably hold a backup outside the VM's underlying storage. Confirm availability of space/quota.

Record the current VM configuration on the **authorized Proxmox host shell**:

```bash
qm config 100
qm list
```

Do not remove VM 101 or any other group's VM during this operation.

## 2. Inspect Terraform state on WSL *before* deleting anything

```bash
cd ~/german-job-market-analytics
git switch proxmox-deployment
git pull --ff-only origin proxmox-deployment
cd infrastructure/terraform
terraform init
terraform state list
```

The target VM resource is `proxmox_virtual_environment_vm.k3s[0]`. If it appears in the state, inspect it with:

```bash
terraform state show 'proxmox_virtual_environment_vm.k3s[0]'
```

**Stop and reconcile** if this state still manages experimental VM 101 (or any VM other than the intended replacement). Do not edit the ID of an existing state-managed VM, reset/delete state, or approve a destroy-and-recreate plan. `deploy.sh` rejects any Terraform plan containing a deletion/replacement.

The existing manually created VM 100 is **not imported** by this repository's Terraform configuration and cannot be deleted using this repository's `destroy.sh`.

## 3. Remove the old manually created VM 100 (Proxmox Web UI)

Only after backup verification and authorization:

1. Select **VM 100 → Shutdown** (graceful shutdown). Wait until Proxmox shows **stopped**. Use **Stop** (forced power-off) only if absolutely necessary, after assessing data-loss risk.
2. In the Proxmox UI, select the stopped VM and use **More → Remove** or **right-click → Remove** (depending on UI version/permissions). Verify the dialog targets **VM 100**, not VM 101. Understand any disk-deletion/purge options before confirming.
3. Verify that `qm list` no longer contains VM 100. **Shutdown alone is not enough:** a stopped VM still owns its ID.

If the Remove option is unavailable, do not attempt to work around restrictions on a shared Proxmox host; ask the instructor/administrator.

## 4. Check VM-specific API permission again

On this host, deleting a VM previously removed the token's `/vms/VM_ID` ACL. An authorized Proxmox administrator should verify that the configured API token has `VM.Allocate` on **`/vms/100`**, plus the scoped datastore/VNet permissions:

```bash
pveum user token permissions root1@pve terraform --path /vms/100
```

Follow [the privilege-scoped permission procedure](README.md#b-before-each-new-vm-creation-or-recreation-vm-specific-permission) if it is missing. Never grant broad cluster-wide VM administration rights just to make this work.

## 5. Check the SSH jump destination

WSL's jump account is `jumpuser` on Proxmox. The guest account is `group3`. During the 14 November test, connecting through `jumpuser` to `10.10.10.21:22` worked, while `10.10.10.20:22` returned **`administratively prohibited`**. This proves the gateway currently refuses the desired destination; it does **not** establish which Proxmox VM owns `.21`.

Have an authorized host administrator inspect `/home/jumpuser/.ssh/authorized_keys` and SSH forwarding policy. The replacement **VM 100** needs forwarding restricted to the approved **`10.10.10.20:22`** (for example, the `permitopen` option on the correct authorized public key). Do not grant unrestricted TCP forwarding or access to other groups' VMs.

In WSL `~/.ssh/config`, use separate aliases so `liora-vm100` cannot accidentally connect to `.21`:

```sshconfig
Host liora-proxmox
    HostName 195.154.103.231
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

## 6. Deploy the replacement with Terraform and Ansible from WSL

The tracked `infrastructure/terraform/terraform.tfvars.example` specifies **100 / 10.10.10.20/24 / 4 CPUs / 16384 MiB / 30 GiB**. The actual `terraform.tfvars` is **Git-ignored** and therefore is **not changed by a Git pull**. Edit the existing file manually, or copy the updated example if there is no local file:

```bash
cd ~/german-job-market-analytics
test -f infrastructure/terraform/terraform.tfvars || \
  cp infrastructure/terraform/terraform.tfvars.example infrastructure/terraform/terraform.tfvars
nano infrastructure/terraform/terraform.tfvars
```

Verify these entries:

```hcl
create_vm    = true
vm_id        = 100
vm_name      = "job-market-ubuntu-100"
cpu_cores    = 4
memory_mb    = 16384
disk_gb      = 30
vm_ipv4_cidr = "10.10.10.20/24"
```

Verify the approved node, datastore, VNet `nat0`, gateway `10.10.10.1`, SSH public-key path, and cloud-image file ID. The cloud image must be staged already.

Then, only after **the old VM 100 is removed** and Terraform state/permissions/forwarding have been checked, run:

```bash
cd ~/german-job-market-analytics
./deploy.sh
```

The script checks the saved plan, **refuses deletions/replacements**, requires a clear confirmation of the expected VM ID, then runs Ansible. Do **not** launch it merely to stop an existing VM. The first complete fresh-VM Cloud-Init → Ansible/k3s path has not yet been verified.

## 7. Revalidate the new guest's SSH identity and k3s

Recreating the same private IP typically changes the guest SSH host key. Verify the **new VM 100's SSH host-key fingerprint using its trusted Proxmox console**. Only then remove the stale `known_hosts` entry on WSL and reconnect:

```bash
ssh-keygen -R 10.10.10.20
ssh liora-vm100
```

Inside the **new Ubuntu VM**:

```bash
hostname
ip -4 -br addr
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get namespaces
```

Expected: one **Ready** control-plane node, and the `dev`/`prod` namespaces. Do not assume success until these checks pass.

## Destruction of the *new* Terraform-managed VM 100 (separate operation)

The root `destroy.sh` is **not** a way to remove the original manual VM. For a **future** Terraform-managed replacement, it first verifies the exact Terraform state-managed resource and ID, then requires **both** the extra environment opt-in `ALLOW_DESTROY_VM100=true` and the typed confirmation `destroy 100`. Use only after fresh backups and authorization.
