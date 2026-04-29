# provider.tf — Proxmox provider configuration
# Credentials via environment variables:
#   PROXMOX_VE_ENDPOINT   — e.g. https://proxmox.local:8006/
#   PROXMOX_VE_USERNAME   — e.g. root@pam
#   PROXMOX_VE_PASSWORD   — plaintext password
#   OR
#   PROXMOX_VE_API_TOKEN  — e.g. user@pam!token-id=uuid

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  username  = var.proxmox_username
  password  = var.proxmox_password
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure
}
