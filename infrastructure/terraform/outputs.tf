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
