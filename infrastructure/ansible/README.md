# Group 3 k3s configuration with Ansible

This playbook configures the **existing** Group 3 Ubuntu VM, not the shared Proxmox host.
It is designed to be run from a workstation such as Ubuntu WSL over SSH.

## What it does

- Confirms the target is Ubuntu on amd64.
- Installs **k3s v1.36.5+k3s1** only if `/usr/local/bin/k3s` is absent.
- Enables and starts the `k3s` systemd service without restarting a running service.
- Waits for the Kubernetes node to be Ready.
- Declaratively applies the `dev` and `prod` namespace manifests.
- Reports the Kubernetes node status.

**Existing k3s installations are not reinstalled or upgraded.** The version variable pins *new* installs only. The script is downloaded from the official k3s installation endpoint; review this script and your organization's execution policy before using on a new machine.

The playbook does not manage Proxmox host networking, create VMs, install application services, change Kubernetes ingress defaults or change cluster configuration flags.

## Prerequisites

- Ansible installed on the control machine (Ubuntu WSL is suitable).
- SSH access from the control machine to the VM at `10.10.10.20`.
- The `group3` SSH account has sudo permissions.
- Network/DNS access on the VM for a fresh k3s installation.
- The VM belongs to Group 3 and has sufficient allocated resources.

## Run from Ubuntu WSL

From the repository root:

```bash
git switch ansible
cd infrastructure/ansible
cp inventory.example.ini inventory.ini
ansible -i inventory.ini k3s_servers -m ping
ansible-playbook -i inventory.ini install-k3s.yml --check --diff
ansible-playbook -i inventory.ini install-k3s.yml --ask-become-pass
```

If SSH uses a key, configure it through your SSH agent or an entry in `~/.ssh/config`. If your user has passwordless sudo, omit `--ask-become-pass`. Ansible might require `--ask-pass` for password-based SSH authentication, although SSH keys are recommended.

**Note:** Ansible check mode does not accurately simulate command-module operations or a fresh install. On the existing k3s VM, use the first actual run to validate behavior, then run it a second time: the second run should report no changes unless something drifted.

After completion, verify from the VM:

```bash
sudo k3s kubectl get nodes
sudo k3s kubectl get namespaces
```

## Safety

- Do **not** point the inventory at the shared Proxmox host or another group's VM.
- Do not commit SSH passwords, private keys, kubeconfig files or API tokens.
- The playbook preserves an existing installation, but it is not a full cluster disaster-recovery or backup solution.
- Running it does modify the VM and Kubernetes namespaces. Run only against an authorized host.
