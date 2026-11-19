output "managed_vm_id" {
  description = "ID of the new VM, when provisioning is enabled."
  value       = try(proxmox_virtual_environment_vm.k3s[0].vm_id, null)
}

output "managed_vm_name" {
  description = "Name of the new VM, when provisioning is enabled."
  value       = try(proxmox_virtual_environment_vm.k3s[0].name, null)
}

output "managed_vm_ipv4" {
  description = "Configured private IPv4/CIDR for the new VM, when provisioning is enabled."
  value       = var.create_vm ? var.vm_ipv4_cidr : null
}

output "ubuntu_image_id" {
  description = "ID of the Cloud Image manually staged on Proxmox."
  value       = var.create_vm ? var.cloud_image_file_id : null
}

output "managed_vm_username" {
  description = "Cloud-Init Ubuntu username for SSH and Ansible."
  value       = var.create_vm ? var.vm_username : null
}

output "managed_vm_ssh_public_key_path" {
  description = "Expanded local SSH public key path used for Cloud-Init; its sibling private key is used by Ansible."
  value       = var.create_vm ? pathexpand(var.ssh_public_key_path) : null
}
