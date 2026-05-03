# variables.tf — Input variables for the Proxmox LXC container

# ── Provider ────────────────────────────────────────────────────────────────

variable "proxmox_endpoint" {
  description = "Proxmox API URL, e.g. https://proxmox.local:8006/"
  type        = string
}

variable "proxmox_username" {
  description = "Proxmox username, e.g. root@pam. Leave empty when using API token."
  type        = string
  default     = ""
}

variable "proxmox_password" {
  description = "Proxmox password. Leave empty when using API token."
  type        = string
  sensitive   = true
  default     = ""
}

variable "proxmox_api_token" {
  description = "Proxmox API token, e.g. user@pam!token-id=uuid. Leave empty when using username/password."
  type        = string
  sensitive   = true
  default     = ""
}

variable "proxmox_insecure" {
  description = "Skip TLS certificate verification (useful for self-signed certs)."
  type        = bool
  default     = true
}

# ── Node ────────────────────────────────────────────────────────────────────

variable "proxmox_node" {
  description = "Proxmox node name where the container will be created."
  type        = string
}

# ── Container identity ───────────────────────────────────────────────────────

variable "container_id" {
  description = "Numeric VMID for the LXC container. Must be unique on the node."
  type        = number
}

variable "container_hostname" {
  description = "Hostname for the LXC container."
  type        = string
}

variable "container_description" {
  description = "Optional description shown in the Proxmox UI."
  type        = string
  default     = ""
}

variable "container_tags" {
  description = "List of tags to apply to the container."
  type        = list(string)
  default     = []
}

# ── Template / OS ────────────────────────────────────────────────────────────

variable "template_file_id" {
  description = "CT template to use, e.g. 'local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst'."
  type        = string
}

variable "os_type" {
  description = "OS type hint for Proxmox (unmanaged, ubuntu, debian, fedora, etc.)."
  type        = string
  default     = "unmanaged"
}

# ── Resources ────────────────────────────────────────────────────────────────

variable "cpu_cores" {
  description = "Number of CPU cores."
  type        = number
  default     = 1
}

variable "memory_mb" {
  description = "RAM in megabytes."
  type        = number
  default     = 512
}

variable "swap_mb" {
  description = "Swap in megabytes."
  type        = number
  default     = 512
}

# ── Disk ─────────────────────────────────────────────────────────────────────

variable "disk_size" {
  description = "Root filesystem size in GB."
  type        = number
  default     = 8
}

variable "datastore_id" {
  description = "Proxmox storage ID for the root filesystem."
  type        = string
  default     = "local-lvm"
}

# ── Network ───────────────────────────────────────────────────────────────────

variable "network_bridge" {
  description = "Linux bridge to attach the container's network interface to."
  type        = string
  default     = "vmbr0"
}

variable "network_ip" {
  description = "IPv4 address in CIDR notation, or 'dhcp'."
  type        = string
  default     = "dhcp"
}

variable "network_gateway" {
  description = "IPv4 default gateway. Leave empty when using DHCP."
  type        = string
  default     = ""
}

# ── Access ────────────────────────────────────────────────────────────────────

variable "root_password" {
  description = "Root password for the container."
  type        = string
  sensitive   = true
  default     = ""
}

variable "extra_username" {
  description = "Additional non-root user to create inside the container."
  type        = string
  default     = ""
}

variable "extra_user_password" {
  description = "Password for the extra non-root user."
  type        = string
  sensitive   = true
  default     = ""
}

variable "ssh_public_keys" {
  description = "SSH public keys to inject into root's authorized_keys."
  type        = string
  default     = ""
}

variable "start_on_create" {
  description = "Start the container immediately after creation."
  type        = bool
  default     = true
}

variable "start_on_boot" {
  description = "Start the container automatically when the Proxmox node boots."
  type        = bool
  default     = false
}

variable "unprivileged" {
  description = "Run as an unprivileged container (recommended)."
  type        = bool
  default     = true
}

variable "nesting" {
  description = "Enable nesting support (required for systemd 255+ inside the container)."
  type        = bool
  default     = false
}
