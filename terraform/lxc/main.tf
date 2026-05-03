# main.tf — Proxmox LXC container resource

resource "proxmox_virtual_environment_container" "lxc" {
  node_name   = var.proxmox_node
  vm_id       = var.container_id
  description = var.container_description
  tags        = var.container_tags

  unprivileged = var.unprivileged

  features {
    nesting = var.nesting
  }

  started       = var.start_on_create
  start_on_boot = var.start_on_boot

  initialization {
    hostname = var.container_hostname

    # Network: set static IP or DHCP
    ip_config {
      ipv4 {
        address = var.network_ip
        gateway = var.network_ip != "dhcp" ? var.network_gateway : null
      }
    }

    user_account {
      password = var.root_password != "" ? var.root_password : null
      keys     = var.ssh_public_keys != "" ? [var.ssh_public_keys] : []
    }
  }

  cpu {
    cores = var.cpu_cores
  }

  memory {
    dedicated = var.memory_mb
    swap      = var.swap_mb
  }

  disk {
    datastore_id = var.datastore_id
    size         = var.disk_size
  }

  network_interface {
    name    = "eth0"
    bridge  = var.network_bridge
    enabled = true
  }

  operating_system {
    template_file_id = var.template_file_id
    type             = var.os_type
  }
}

resource "null_resource" "extra_user" {
  count = var.extra_username != "" ? 1 : 0

  depends_on = [proxmox_virtual_environment_container.lxc]

  connection {
    type        = "ssh"
    host        = replace(var.network_ip, "/24", "")
    user        = "root"
    private_key = file("~/.ssh/id_ed25519")
    timeout     = "120s"
  }

  provisioner "remote-exec" {
    inline = [
      "id ${var.extra_username} >/dev/null 2>&1 || useradd -m -s /bin/bash ${var.extra_username}",
      "printf '%s:%s' '${var.extra_username}' '${var.extra_user_password}' | chpasswd",
    ]
  }
}
