# Proxmox deployment

Provision an Ubuntu virtual machine on Proxmox VE with **Terraform**, then configure a single-node **k3s** cluster with **Ansible**.

Run Terraform and Ansible from the Linux machine containing this repository. The Proxmox host is the SSH jump server; the Ubuntu VM is the Ansible target.

## Prerequisites

- A running Proxmox VE host, its web interface, and **root access to the Proxmox Linux shell** (Proxmox node → Shell).
- HTTPS access to the Proxmox API (TCP 8006) and SSH access to the host (TCP 22) from the Linux machine.
- A Proxmox datastore that accepts **Import** files, an available private subnet, and permission to configure a Simple SDN zone, VNet and Source NAT (SNAT). The Proxmox host must have working outbound connectivity.
- A free VM ID and sufficient CPU, RAM and disk capacity.
- Installed locally: **Terraform**, **Ansible**, **OpenSSH** and **curl**.
- This repository already present on the Linux machine.

The commands below use these names; replace their values with those for your environment:

- `PROXMOX_HOST`: public hostname or IP of the Proxmox host.
- `VM_ID`: a free Proxmox VM ID (100 or greater).
- `VM_IP`: assigned *private* IPv4 address of the Ubuntu VM, **without CIDR**.
- `SDN_ZONE`: identifier of the Proxmox Simple zone.
- `SDN_VNET`: identifier of the VNet connected to the VM.
- `VM_USER`: Ubuntu username configured through Cloud-Init.
- `jumpuser`: restricted Linux SSH account on the Proxmox host.

## 1. Prepare an SSH key on the Linux machine

```bash
test -f ~/.ssh/id_ed25519.pub || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
cat ~/.ssh/id_ed25519.pub
```

Keep the **private key** (`id_ed25519`) on this machine. Copy the **public key line** (`id_ed25519.pub`) for the SSH gateway setup. Terraform will use that same public key to configure SSH login to the new VM.

## 2. Prepare Proxmox

### Upload the Ubuntu Cloud Image

In the Proxmox web interface, open **Datacenter → Storage** and ensure the selected datastore allows **Import** content.

Then open **Datacenter → your node → local → Import → Download from URL**:

- URL: `https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img`
- Filename: `ubuntu-noble-cloudimg-amd64.qcow2`

On the Proxmox **host** shell, confirm that the image is available:

```bash
pvesm list local --content import
```

Set its identifier (the string beginning with `local:import/`) as the value of `cloud_image_file_id` in the project's `infrastructure/terraform/terraform.tfvars` file.

### Configure a private network with NAT

Configure the network in the Proxmox web interface before creating the VM:

1. Go to **Datacenter → SDN → Zones → Add → Simple**. Create a Simple zone, assigning it an ID (`SDN_ZONE`) and selecting the node that will run the VM.
2. Go to **Datacenter → SDN → VNets → Add**. Create a VNet (`SDN_VNET`) and assign it to that Simple zone.
3. Select the VNet, open **Subnets**, and add an IPv4 subnet with the chosen CIDR range and gateway address. **Enable SNAT** on the subnet.
4. Go to **Datacenter → SDN** and click **Apply** to activate the configuration.

For example, a subnet of `10.50.0.0/24` with gateway `10.50.0.1` can serve a VM at `10.50.0.10/24`. Use an address range that does not overlap existing networks. Do not assign the gateway address to the VM.

**SNAT** lets the VM reach the internet through the Proxmox host's outgoing connection. The VM stays on a private IP; inbound access from the Linux machine uses the SSH jump account configured below.

In `infrastructure/terraform/terraform.tfvars`, these values must match the SDN settings:

```hcl
network_bridge = "SDN_VNET"
vm_ipv4_cidr   = "10.50.0.10/24"
vm_gateway     = "10.50.0.1"
```

Replace `SDN_VNET` and the example addresses with the actual VNet ID, chosen VM IP/CIDR and subnet gateway. Terraform attaches the VM to **the VNet**, not the zone.

### Create a Proxmox API token

In the web interface:

1. **Datacenter → Permissions → API Tokens**: create a token named `terraform` for an existing Proxmox user with sufficient underlying privileges. Enable **Privilege Separation** and securely save the token secret.
2. **Datacenter → Permissions → Add → API Token Permission**: assign the token these roles, using the chosen VM ID, datastore and VNet.

| Path | Role |
| --- | --- |
| `/vms/VM_ID` | `PVEVMAdmin` |
| `/storage/DATASTORE` | `PVEDatastoreUser` |
| `/sdn/zones/SDN_ZONE/SDN_VNET` | `PVESDNUser` |

For the third permission, use the **zone ID and VNet ID created above**. This allows Terraform to connect the new VM's network adapter to that VNet. For example, if the zone is `private` and the VNet is `nat0`, enter `/sdn/zones/private/nat0`.

**Important:** The API token cannot have more permissions than the Proxmox user who owns it. That user must also have permission to create the VM and use the configured storage and VNet.

**Keep the token ID** (for example `automation@pve!terraform`) **and its secret** for Terraform. The token authenticates to the Proxmox *API*; it is not an SSH login.

### Create the SSH jump account

Run on the **Proxmox host** as root:

```bash
adduser --disabled-password --gecos "" jumpuser
install -d -m 700 -o jumpuser -g jumpuser /home/jumpuser/.ssh
sshd -T | grep -E '^(pubkeyauthentication|allowtcpforwarding)'
```

SSH public-key authentication and TCP forwarding must be enabled.

Create `/home/jumpuser/.ssh/authorized_keys` with **one line** containing your Linux machine's public key, preceded by these restrictions. Replace `VM_PRIVATE_IP` with the VM's assigned IP and `ssh-ed25519 AAAA... comment` with the **entire real public key line**:

```text
restrict,port-forwarding,permitopen="VM_PRIVATE_IP:22",command="/bin/false" ssh-ed25519 AAAA... comment
```

For example, open the file with:

```bash
nano /home/jumpuser/.ssh/authorized_keys
chown jumpuser:jumpuser /home/jumpuser/.ssh/authorized_keys
chmod 600 /home/jumpuser/.ssh/authorized_keys
```

This grants the account only the SSH forwarding needed to reach the VM's port 22; it does not grant root privileges.

Record the Proxmox SSH server's host-key fingerprint from the **trusted web console**:

```bash
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Verify that fingerprint when connecting to the Proxmox host for the first time.

### Copy the Proxmox CA certificate

From the **Proxmox host's trusted web console**, display:

```bash
cat /etc/pve/pve-root-ca.pem
```

Copy the full PEM certificate (including its BEGIN/END lines) to a local file on the Linux machine, for example `~/.config/proxmox/pve-root-ca.pem`:

```bash
mkdir -p ~/.config/proxmox
nano ~/.config/proxmox/pve-root-ca.pem
```

This establishes TLS trust for Terraform's API connection. Verify the certificate through the trusted Proxmox console; do not disable TLS verification.

## 3. Configure and run Terraform

On the **Linux machine**, enter:

```bash
cd infrastructure/terraform
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars
```

Set the actual configuration values:

| Variable | Value to supply |
| --- | --- |
| `create_vm` | `true` |
| `node_name` | Exact Proxmox node name |
| `vm_id`, `vm_name` | Free VM ID and desired name |
| `cpu_cores`, `memory_mb`, `disk_gb` | Desired capacity |
| `datastore_id` | Storage containing the image and new VM disk |
| `network_bridge` | The `SDN_VNET` ID created in step 2 |
| `vm_ipv4_cidr`, `vm_gateway` | IP **with CIDR** and gateway from the NAT subnet in step 2 |
| `vm_username` | Ubuntu SSH username |
| `ssh_public_key_path` | `~/.ssh/id_ed25519.pub` |
| `download_cloud_image` | `false` |
| `cloud_image_file_id` | Exact Proxmox file ID from step 2 |

Replace the environment-specific values in the copied example, including the node name, VM identity, address and username. Choose an unused VM ID and IP that satisfy the safety checks in `main.tf`. Do **not** point the configuration at a VM already in use.

Configure API access in the **same Linux shell** (enter the real endpoint and token ID):

```bash
export PROXMOX_VE_ENDPOINT="https://PROXMOX_HOST:8006/"
export SSL_CERT_FILE="$HOME/.config/proxmox/pve-root-ca.pem"
export API_TOKEN_ID="USER@REALM!terraform"
read -rsp "Proxmox API token secret: " API_TOKEN_SECRET; echo
export PROXMOX_VE_API_TOKEN="$API_TOKEN_ID=$API_TOKEN_SECRET"
unset API_TOKEN_SECRET
```

Provision the Ubuntu VM:

```bash
terraform init
terraform fmt -check
terraform validate
terraform plan -out=vm.tfplan
terraform apply vm.tfplan
```

Check that the planned changes affect **only the intended VM** before applying. Terraform creates the VM from the staged Cloud Image, sets its static IP, configures the Ubuntu username and SSH public key through Cloud-Init, and starts the VM.

**Keep** the local `terraform.tfvars` and `terraform.tfstate` for subsequent runs. Changing `create_vm` to `false` while a VM is managed by that state can plan its destruction.

## 4. Configure SSH access to the new VM

On the **Linux machine**, edit `~/.ssh/config`, replacing the host, guest IP and guest username:

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

## 5. Configure k3s with Ansible

From the **Linux machine**, not inside the VM:

```bash
cd ../ansible
cat > inventory.ini <<'EOF'
[k3s_servers]
k3s-vm ansible_connection=ssh ansible_python_interpreter=/usr/bin/python3
EOF

ansible -i inventory.ini k3s_servers -m ping
ansible-playbook -i inventory.ini install-k3s.yml
```

The Ubuntu Cloud-Init account must have working `sudo` privileges for the playbook's `become: true` tasks. If it requires a sudo password, supply it with `--ask-become-pass`.

The playbook installs and enables k3s, waits for a Ready node, and applies the `dev` and `prod` namespace manifest. Re-run the same playbook to verify that it makes no unnecessary changes.

Verify the installation:

```bash
ssh k3s-vm 'sudo k3s kubectl get nodes'
ssh k3s-vm 'sudo k3s kubectl get namespaces'
```

**Result:** a Terraform-provisioned Ubuntu VM running a single-node k3s cluster, configured by Ansible.

