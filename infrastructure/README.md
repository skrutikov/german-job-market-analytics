# Proxmox deployment

This guide explains how to provision an Ubuntu virtual machine on Proxmox VE using **Terraform** and configure a single-node **k3s** cluster using **Ansible**.

![Infrastructure deployment architecture](../docs/images/infrastructure.png)

Run Terraform and Ansible from a local Linux machine with this repository checked out. The Proxmox host acts as an SSH jump server, and the Ubuntu VM is the Ansible target.

## Deployment overview

- **One-time Proxmox preparation:** download the Ubuntu Cloud Image, verify the NAT VNet, create the API token, and grant it the shared storage and VNet permissions (Section 2). These actions require authorized Proxmox administration.
- **Before creating or recreating a VM:** verify and, if necessary, grant that specific VM ID's `/vms/VM_ID` ACL. On this host, destroying a VM has removed its VM-specific ACL; the shared storage/VNet permissions remain (Section 2).
- **VM + k3s deployment:** from local Ubuntu/Linux (including WSL), configure `infrastructure/terraform/terraform.tfvars`, trust the Proxmox CA and run `./deploy.sh` (Section 3). The script plans/applies Terraform **only after confirmation**, waits for SSH and Cloud-Init, then invokes Ansible to install/configure k3s and verify the node. The restricted `jumpuser` SSH account must already be configured on Proxmox (Section 2).
- **After deployment:** use the optional SSH alias for interactive access (Section 4), or rerun the Ansible playbook manually for troubleshooting (Section 5). **The application itself is not deployed by `deploy.sh`.**

This guide describes a tested bootcamp setup, not a zero-touch installation of a fresh Proxmox host. For the **tested destroy/redeploy sequence on this already-prepared host**, use the quick procedure below. For a fresh host, follow the full prerequisites. Never assume that the example VM ID, private IP, subnet, VNet or permissions are available on another host. Keep the Terraform state for repeat runs.

## Configuration names

The commands below use these names; replace their values with those for your environment:

- `PROXMOX_HOST`: public hostname or IP of the Proxmox host.
- `VM_ID`: a free Proxmox VM ID (100 or greater).
- `VM_IP`: assigned *private* IPv4 address of the Ubuntu VM, **without CIDR**.
- `SDN_ZONE`: identifier of the Proxmox Simple zone.
- `SDN_VNET`: identifier of the VNet connected to the VM.
- `VM_USER`: Ubuntu username configured through Cloud-Init.
- `jumpuser`: restricted local SSH account on the Proxmox host.

## Prerequisites

- A running Proxmox VE host, its web interface, and **root access to the Proxmox Linux shell** (run `id -u` in the Proxmox shell; the result must be `0`).
- HTTPS access to the Proxmox API (TCP 8006) and SSH access to the host (TCP 22) from the local machine (check with `nc -vz PROXMOX_HOST 8006` and `nc -vz PROXMOX_HOST 22`).
- A Proxmox datastore supporting **Import** files and VM disks (check `cat /etc/pve/storage.cfg`; the selected datastore's `content` entry must include `import` and `images`).
- An available private subnet (check existing ranges with `ip -4 route` and `cat /etc/pve/sdn/subnets.cfg` on Proxmox; choose a non-overlapping private subnet).
- Permission to configure a **Simple SDN zone** (requires Proxmox administrator privileges, available through the root shell; view existing zones with `pvesh get /cluster/sdn/zones`).
- Permission to configure a **VNet and Source NAT (SNAT)** (same administrator access; view existing VNets with `pvesh get /cluster/sdn/vnets`).
- The Proxmox host must have internet access so that VMs can reach the internet through NAT (check from Proxmox with `curl -I --max-time 10 https://cloud-images.ubuntu.com`).
- Installed on the **local machine**: **Terraform**, **Ansible**, **OpenSSH** and **curl** (check with `terraform version`, `ansible --version`, `ssh -V` and `curl --version`).

## 1. Prepare an SSH key on the local machine

Create the key-pair (`id_ed25519`/`id_ed25519.pub`) on the local machine:

```bash
test -f ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
```

## 2. Prepare Proxmox

### Download the Ubuntu Cloud Image

In the Proxmox web interface, open **Datacenter → Storage** and ensure the selected datastore allows **Import** content.

Then open **Datacenter → your node → local → Import → Download from URL**:

- URL: `https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img`
- Filename: `job-market-noble-server-cloudimg-amd64.qcow2` (must match the default `cloud_image_file_id`)

On the Proxmox **host** shell, confirm that the image is available:

```bash
pvesm list local --content import
```

Set its identifier (the string beginning with `local:import/`) as the value of `cloud_image_file_id` in `infrastructure/terraform/terraform.tfvars`. If the image is **already present**, reuse it instead of downloading again. `qemu-img info` can confirm the QCOW2 format but does not by itself guarantee a complete download; verify the source/checksum when preparing a new image. **Image download happens manually through the Proxmox web interface, not through Terraform.**

### Configure a private network with NAT

Configure the network in the Proxmox web interface before creating the VM:

1. Go to **Datacenter → SDN → Zones → Add → Simple**. Create a Simple zone, assigning it an ID (`SDN_ZONE`) and selecting the node that will run the VM.
2. Go to **Datacenter → SDN → VNets → Add**. Create a VNet (`SDN_VNET`) and assign it to that Simple zone.
3. Select the VNet, open **Subnets**, and add an IPv4 subnet with the chosen CIDR range and gateway address. **Enable SNAT** on the subnet.
4. Go to **Datacenter → SDN** and click **Apply** to activate the configuration.

For example, a subnet of `10.50.0.0/24` with gateway `10.50.0.1` can serve a VM at `10.50.0.10/24`. Use an address range that does not overlap existing networks. Do not assign the gateway address to the VM.

**SNAT** lets the VM reach the internet through the Proxmox host's outgoing connection. The VM stays on a private IP; inbound access from the local machine uses the SSH jump account configured below.

In `infrastructure/terraform/terraform.tfvars`, these values must match the SDN settings:

```hcl
network_bridge = "SDN_VNET"
vm_ipv4_cidr   = "10.50.0.10/24"
vm_gateway     = "10.50.0.1"
```

Replace `SDN_VNET` and the example addresses with the actual VNet ID, chosen VM IP/CIDR and subnet gateway. Terraform attaches the VM to **the VNet**, not the zone.

### Create a Proxmox API token and permissions

**Two distinct kinds of permission are needed:** shared infrastructure permissions are configured once, while the permission for the **specific VM ID must be checked before creating or recreating that VM**. These are administrator tasks on the **Proxmox host**, not tasks performed by `deploy.sh`.

#### A. One-time setup: API token and shared storage/VNet permissions

In **Datacenter → Permissions → API Tokens**, create a token (for example `terraform` owned by `root1@pve`) with **Privilege Separation** enabled. Save the token secret securely. The token ID `root1@pve!terraform` identifies the token; `deploy.sh` prompts for the complete `ID=secret` value. An API token is not an SSH login.

For this bootcamp host, the shared resources and privileges are:

| ACL path | Role/privileges | Purpose |
| --- | --- | --- |
| `/storage/local` | Custom role with `Datastore.AllocateSpace` and `Datastore.Audit` | Allocate and inspect VM disks |
| `/sdn/zones/studnat/nat0` | `PVESDNUser` (including `SDN.Use`) | Attach VM network interfaces to `nat0` |

The actual SDN zone is **`studnat`**, not `private`; verify it with `pvesh get /cluster/sdn/vnets`. The `network_bridge` variable in `terraform.tfvars` is the VNet ID `nat0`, not its zone name.

On the **Proxmox root shell**, with permission to administer this shared host, run the following when setting up a new environment. Create `TerraformVMStorage` only if it does not already exist (`pveum role list`):

```bash
TOKEN_OWNER='root1@pve'
TOKEN_ID='root1@pve!terraform'
DATASTORE='local'
SDN_ZONE='studnat'
SDN_VNET='nat0'

pveum role add TerraformVMStorage --privs "Datastore.AllocateSpace Datastore.Audit"

pveum acl modify "/storage/$DATASTORE" \
    --roles TerraformVMStorage --users "$TOKEN_OWNER" --tokens "$TOKEN_ID"
pveum acl modify "/sdn/zones/$SDN_ZONE/$SDN_VNET" \
    --roles PVESDNUser --users "$TOKEN_OWNER" --tokens "$TOKEN_ID"
```

Both the **owner** and the **privilege-separated token** must have the required privileges; Proxmox uses their effective intersection. Check these permissions (they normally survive VM deletion):

```bash
pveum user token permissions root1@pve terraform --path /storage/local
pveum user token permissions root1@pve terraform --path /sdn/zones/studnat/nat0
```

Expect `Datastore.AllocateSpace` and `SDN.Use`, respectively.

#### B. Before each new VM creation or recreation: VM-specific permission

Unlike the shared ACLs, the permission at `/vms/101` is tied to **VM ID 101**. In our test, **Proxmox removed this ACL when `destroy.sh` deleted VM 101**. Consequently, restoring the VM with `./deploy.sh` failed with **HTTP 403** until the VM ACL was granted again.

Before deploying a new or previously destroyed VM, check the token's effective permission on the intended VM ID. On the **Proxmox root shell**:

```bash
pveum user token permissions root1@pve terraform \
    --path /vms/101
```

If the output does not include `VM.Allocate`, restore permissions for this VM ID **only**:

```bash
pveum acl modify /vms/101 \
    --roles PVEVMAdmin \
    --users root1@pve \
    --tokens 'root1@pve!terraform'
```

Run the first command again to verify `VM.Allocate` (and the `VM.Config.*` privileges). The example uses the approved test VM **101**, not the separately existing VM **100**. Substitute your own approved, unused VM ID for other environments. Do **not** give the token cluster-wide VM administration permissions.

The essential distinction:

- **One-time host setup:** create the token and configure permissions for shared storage and VNet (Section A).
- **Per-VM provisioning/reprovisioning:** check `/vms/VM_ID` and grant `PVEVMAdmin` there when missing (Section B). Recheck after `destroy.sh`, because VM deletion can remove this ACL.

If `VM.Allocate` is still absent, check the underlying owner permissions with `pveum user permissions root1@pve --path /vms/101`. **HTTP 401** indicates an authentication issue (invalid token/secret), while **HTTP 403** generally indicates insufficient authorization.

### Create the SSH jump account

Run on the **Proxmox host** as root:

```bash
adduser --disabled-password --gecos "" jumpuser
install -d -m 700 -o jumpuser -g jumpuser /home/jumpuser/.ssh
sshd -T | grep -E '^(pubkeyauthentication|allowtcpforwarding)'
```

Confirm that SSH public-key authentication and TCP forwarding are enabled (using the `sshd -T` command above). The `authorized_keys` file **does not enable these SSH server settings**; it authorizes your local machine's public key for the jump account.

In the **Proxmox Linux shell**, create `/home/jumpuser/.ssh/authorized_keys` containing **one line**:

```text
restrict,port-forwarding,permitopen="VM_PRIVATE_IP:22",command="/bin/false" ssh-ed25519 AAAA... comment
```

Replace `VM_PRIVATE_IP` with the assigned private IP of the VM. Replace **`ssh-ed25519 AAAA... comment` entirely** with the complete output of `cat ~/.ssh/id_ed25519.pub` from your **local Linux machine** (Step 1). The restrictions and public key must be on the **same line**, separated by a single space.

Create/edit the file and set the correct ownership and permissions on **Proxmox**:

```bash
nano /home/jumpuser/.ssh/authorized_keys
chown jumpuser:jumpuser /home/jumpuser/.ssh/authorized_keys
chmod 600 /home/jumpuser/.ssh/authorized_keys
```

This key allows SSH forwarding to the VM's port 22 without granting root privileges on Proxmox.

From the **trusted Proxmox web console**, run:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Keep the displayed `SHA256:...` fingerprint available for comparison (for example, in a temporary text file).

From your **local Linux machine**, initiate the first SSH connection to Proxmox (replace `PROXMOX_HOST` with its hostname or IP address):

```bash
ssh jumpuser@PROXMOX_HOST
```

SSH will show an authenticity warning and an **ED25519 key fingerprint**, followed by `Are you sure you want to continue connecting (yes/no/[fingerprint])?`. Compare the complete `SHA256:...` value with the fingerprint from the Proxmox web console. **Only if they match**, type `yes`. SSH stores the accepted host key in `~/.ssh/known_hosts`; the jump account may then close the interactive session because it is restricted to forwarding.

This verifies the **server's identity**. It is distinct from your personal SSH key used for login.

### Copy the Proxmox CA certificate

From the **Proxmox host's trusted web console**, display:

```bash
cat /etc/pve/pve-root-ca.pem
```

Copy the full PEM certificate (including its BEGIN/END lines) to a local file on the local machine, for example `~/.config/proxmox/pve-root-ca.pem`:

```bash
mkdir -p ~/.config/proxmox
nano ~/.config/proxmox/pve-root-ca.pem
```

This establishes TLS trust for Terraform's API connection. Verify the certificate through the trusted Proxmox console; do not disable TLS verification.

## 3. Configure and run Terraform with `deploy.sh`

On your **local Ubuntu/Linux machine**, from the repository root:

```bash
cp infrastructure/terraform/terraform.tfvars.example infrastructure/terraform/terraform.tfvars
nano infrastructure/terraform/terraform.tfvars
```

Set `create_vm = true` only once you've obtained approval for an **unused** VM ID and static IP. Confirm the Proxmox node name, `datastore_id`, `network_bridge`, `vm_ipv4_cidr`, `vm_gateway`, `vm_username`, VM sizing and SSH public-key path. This bootcamp's `nat0` VNet uses zone `studnat`; the gateway `10.10.10.1` is an **environment-specific value**, not a Proxmox default. The Ubuntu user is created by Cloud-Init and is independent of the Proxmox API user.

After downloading the image through the Proxmox web interface (Section 2), reference the existing image in Terraform:

```hcl
cloud_image_file_id = "local:import/job-market-noble-server-cloudimg-amd64.qcow2"
```

There is no `download_cloud_image` switch: Terraform only provisions the VM from the manually staged Cloud Image. If your local, Git-ignored `terraform.tfvars` still contains `download_cloud_image` or `cloud_image_url` from an older configuration, remove those lines.

Before running Terraform, complete **Section 2B** on the Proxmox host: the token must have `VM.Allocate` on the chosen VM ID (including after a previous `destroy.sh`). Make sure the Proxmox CA file from Section 2 exists at `~/.config/proxmox/pve-root-ca.pem`. Then run:

```bash
chmod +x deploy.sh
./deploy.sh
```

The script uses the current lab's Proxmox API host as a **non-secret default**. To use a different Proxmox host without editing the script:

```bash
PROXMOX_HOST=YOUR_PROXMOX_HOST ./deploy.sh
```

Paste the **complete API token** from your password manager in `USER@REALM!terraform=SECRET` format (for example `root1@pve!terraform=...`). The prompt hides what you type. The script exports `PROXMOX_VE_API_TOKEN` in its own process, verifies the local CA file and `terraform.tfvars`, runs `terraform init`, `validate`, and saves `vm.tfplan` with `terraform plan`. After reviewing the plan, type `apply` to execute the saved Terraform plan. **Once Terraform succeeds**, the script continues to SSH readiness, Cloud-Init, the existing Ansible k3s playbook, and Kubernetes verification. Running `./deploy.sh` does **not** leave credentials in your interactive shell.

**SSH and Ansible prerequisites for the automated phase:** install `ansible` and `openssh-client` locally; create the SSH key from Section 1; configure the restricted `jumpuser` account and permitted forwarding on Proxmox (Section 2). The script automatically connects as `vm_username` to the **IP in `terraform.tfvars`**, via `jumpuser@$PROXMOX_HOST`. It derives the matching local private key by stripping `.pub` from `ssh_public_key_path` and creates a temporary Ansible inventory (not committed to Git). You may override the default jump username with `JUMP_USER=other_user ./deploy.sh`. No `~/.ssh/config` alias is required for the scripted deployment.

**SSH host-key security:** the first SSH connection may ask you to trust the Proxmox host and/or new VM. Compare each displayed fingerprint with the key reported by the **trusted Proxmox console** or the VM console (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the corresponding host) before accepting. The script does not disable host-key checking. If you recreate the VM at the same IP, its host key will usually change: verify the new VM fingerprint from its Proxmox console first, then remove the obsolete entry (for example `ssh-keygen -R 10.10.10.21`) before rerunning the deployment. Do not blindly accept host-key changes.

**Cloud-Init exit codes:** `cloud-init status --wait` may display `status: done` but exit with code `2`, indicating recoverable errors (code `0` is success; code `1` is a fatal Cloud-Init error). The script prints `cloud-init status --long` for code `2` and continues with Ansible, while other nonzero codes stop deployment. Review any recoverable errors and correct issues relevant to networking, packages or sudo before relying on the VM.

**If SSH or Ansible fails after Terraform succeeds:** the VM still exists and remains managed by Terraform; the script does not roll back the VM. Fix the jump-account configuration, SSH key, network, host-key trust or sudo access and rerun `./deploy.sh` using the same state. The playbook is designed to be rerun and skips fresh installation when k3s is already present. Ansible requires the Ubuntu Cloud-Init account to have `sudo` privileges.

Formatting is optional: run `terraform -chdir=infrastructure/terraform fmt` from the repository root if you want to normalize Terraform files. A formatting difference in `terraform.tfvars` will not block `deploy.sh`; configuration validation still runs.

**Avoid duplicated configuration:** `terraform.tfvars` is now the single source of truth for `vm_id`, `vm_ipv4_cidr` and other Terraform inputs; `deploy.sh` intentionally does not override them with `-var`. Re-running with the same local Terraform state should produce no changes. **Back up the state** securely and do not commit `terraform.tfvars`, `vm.tfplan`, the state or credentials. Never set `create_vm = false` to “skip provisioning”: Terraform would plan to destroy an already-managed VM. Review destructive changes before approving.

Common errors:

- `curl (77)` or certificate errors: trusted Proxmox CA file missing/unreadable or incorrect.
- HTTP `401`: token ID or secret incorrect. Paste the full `USER@REALM!TOKEN=SECRET` value into this script.
- HTTP `403` on VM creation: verify effective `VM.Allocate`, `Datastore.AllocateSpace` and `SDN.Use` permissions (Section 2).
- “Refusing to override existing file” during image download: the image already exists on Proxmox; reuse its file ID instead of downloading it again.
- VM `101` already exists outside the current Terraform state: do not overwrite or adopt it automatically. Check the VM ownership and state first.

The current Ubuntu URL uses `noble/current`, which can change; **for bit-for-bit reproducibility**, pin a dated/released image and verify its checksum before distributing the environment setup.

### Destroy a Terraform-managed VM with `destroy.sh`

To remove the test VM when you no longer need it, run the following **from the repository root** on the same local machine and with the same `infrastructure/terraform/terraform.tfstate` used by `deploy.sh`:

```bash
chmod +x destroy.sh
./destroy.sh
```

The script asks for the **full Proxmox API token** (as `deploy.sh` does), verifies that `proxmox_virtual_environment_vm.k3s[0]` is present in the Terraform state, and checks that its managed VM ID matches `vm_id` in `terraform.tfvars`. It rejects a mismatch and explicitly refuses VM `100`. It then prepares a **targeted Terraform destroy plan for that VM**, displays it, and requires the exact confirmation `destroy VM_ID` (for example, `destroy 101`) before applying. You should still review the plan carefully.

**Important:** `destroy.sh` does **not** search Proxmox for any VM with a matching numeric ID. It can only destroy the VM already managed by your current Terraform state. Do not delete your state to “reset” the project; losing it would prevent Terraform from tracking the existing VM. A VM's disks/data are deleted when it is destroyed. The manually downloaded Cloud Image and NAT networking are left alone. **In this test, Proxmox removed the destroyed VM's `/vms/101` ACL**, so before the next `./deploy.sh`, follow **Section 2B** to verify and restore the VM-specific permission; shared storage/VNet ACLs normally remain unchanged.

Do not set `create_vm = false` as a substitute for `destroy.sh`: that could make a later `./deploy.sh` plan destruction without the extra VM-ID confirmation.

## 4. Optional: SSH alias for interactive VM access

`deploy.sh` uses SSH with `-J jumpuser@PROXMOX_HOST` directly, so **you do not need to edit `~/.ssh/config` for automated deployment**. To connect interactively using the shorter `ssh k3s-vm` command, edit `~/.ssh/config` on the local machine and replace the host, guest IP and username:

```sshconfig
Host proxmox-jump
    HostName PROXMOX_HOST
    User jumpuser
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes

Host k3s-vm
    HostName VM_PRIVATE_IP
    User VM_USER
    ProxyJump proxmox-jump
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

```bash
chmod 600 ~/.ssh/config
ssh k3s-vm
```

The VM's SSH public key was installed by Terraform/Cloud-Init, so no manual `ssh-copy-id` to the new guest is needed. On first connection, verify the guest's SSH host-key fingerprint against a trusted source.

While logged into the **Ubuntu VM**, verify its address, route, internet access and DNS:

```bash
ip -br addr
ip route
ping -c 3 VM_GATEWAY_IP    # Replace with the subnet gateway from step 2
ping -c 3 1.1.1.1
getent hosts ubuntu.com
sudo apt update
```

The VM should show its configured private IP, a default route via the subnet gateway, and successful outbound network and DNS access. Terraform passes the IP, gateway and DNS settings through **Cloud-Init**, so **do not create a second Netplan configuration manually**.

Exit the guest session to return to the local Linux shell.

## 5. k3s with Ansible (run automatically by `deploy.sh`)

`deploy.sh` now runs the existing `infrastructure/ansible/install-k3s.yml` playbook after SSH and Cloud-Init are ready. It creates a temporary inventory from Terraform outputs, runs an Ansible ping, installs/configures k3s, then verifies the node and namespaces. No separate inventory file is needed for the automatic deployment.

For **manual troubleshooting or replaying the playbook**, first configure the optional `k3s-vm` SSH alias in Section 4. Then, from the **repository root** on the local machine:

```bash
cd infrastructure/ansible
cat > inventory.ini <<'EOF'
[k3s_servers]
k3s-vm ansible_connection=ssh ansible_python_interpreter=/usr/bin/python3
EOF

ansible -i inventory.ini k3s_servers -m ping
ansible-playbook -i inventory.ini install-k3s.yml
```

The Ubuntu Cloud-Init account must have working `sudo` privileges for the playbook's `become: true` tasks. The automatic script assumes passwordless sudo; if the account requires a sudo password, the manual command can supply it with `--ask-become-pass`.

The playbook installs and enables k3s, waits for a Ready node, and applies the `dev` and `prod` namespace manifest. Re-run the same playbook to verify that it makes no unnecessary changes.

Verify the installation:

```bash
ssh k3s-vm 'sudo k3s kubectl get nodes'
ssh k3s-vm 'sudo k3s kubectl get namespaces'
```

**Result:** one `./deploy.sh` invocation provisions or updates the Ubuntu VM using Terraform and configures its single-node k3s cluster with Ansible, provided the Proxmox token, VM-specific ACL, SSH jump account and trusted host keys are prepared.

