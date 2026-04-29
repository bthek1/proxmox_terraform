# outputs.tf — Outputs for the Proxmox LXC container

output "container_id" {
  description = "The VMID of the LXC container."
  value       = proxmox_virtual_environment_container.lxc.vm_id
}

output "container_hostname" {
  description = "Hostname of the LXC container."
  value       = proxmox_virtual_environment_container.lxc.initialization[0].hostname
}

output "network_ip" {
  description = "Configured IPv4 address (or 'dhcp')."
  value       = var.network_ip
}
