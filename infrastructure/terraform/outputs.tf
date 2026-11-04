output "managed_vm_id" {
  description = "New VM ID, when optional provisioning is enabled."
  value       = try(proxmox_virtual_environment_vm.k3s[0].vm_id, null)
}

output "managed_vm_name" {
  description = "New VM name, when optional provisioning is enabled."
  value       = try(proxmox_virtual_environment_vm.k3s[0].name, null)
}
