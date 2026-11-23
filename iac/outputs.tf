locals {
  # First routable IPv4 reported by the guest agent (skips loopback and link-local); null if none yet.
  vm_ip = {
    for name, vm in proxmox_virtual_environment_vm.vm : name => try(
      [for ip in flatten(vm.ipv4_addresses) : ip if !startswith(ip, "127.") && !startswith(ip, "169.254.")][0],
      null
    )
  }
}

output "vm_ips" {
  description = "IPv4 address of each VM, keyed by hostname"
  value       = local.vm_ip
}

output "vms" {
  description = "Name, role, IP and SSH command for each VM"
  value = {
    for name, vm in proxmox_virtual_environment_vm.vm : name => {
      vm_id = vm.vm_id
      role  = var.vms[name].role
      ip    = local.vm_ip[name]
      ssh   = local.vm_ip[name] == null ? null : "ssh ${var.vm_username}@${local.vm_ip[name]}"
    }
  }
}
