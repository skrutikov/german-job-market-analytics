# Proxmox API credentials must be supplied through environment variables.
# See README.md. This configuration does not touch host-level networking.
provider "proxmox" {}

# OPTIONAL: Provision a NEW VM by cloning a template owned/approved by Liora.
# The existing manually created group3 VM is not managed by this resource.
# No VM is created unless create_vm=true is explicitly set.
resource "proxmox_virtual_environment_vm" "k3s" {
  count = var.create_vm ? 1 : 0

  name        = var.vm_name
  description = "Group 3 Kubernetes lab VM - managed by Terraform"
  tags        = ["group3", "liora", "terraform", "k3s"]
  node_name   = var.node_name
  vm_id       = var.vm_id
  started     = false

  clone {
    vm_id = var.template_vm_id
  }

  agent {
    enabled = false
  }

  cpu {
    cores = var.cpu_cores
  }

  memory {
    dedicated = var.memory_mb
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}
