---
description: "Use when accessing the Proxmox home lab server via SSH or web UI, managing VMs/containers, or performing any operations on the local Proxmox server."
---
# Proxmox Home Lab — Access Guide

## Server Details

| Field | Value |
|-------|-------|
| SSH Alias | `proxmox` |
| Hostname / IP | `192.168.2.70` |
| SSH User | `ben` |
| SSH Port | `22` |
| SSH Key | `~/.ssh/id_ed25519` (default) |
| Web UI | `https://192.168.2.70:8006` |

The SSH alias `proxmox` is pre-configured in `~/.ssh/config` — use it for all SSH operations.

> **`ben` is not root.** Privileged guest/storage commands must be run via `sudo` with the **full binary path**. Passwordless (`sudo -n`) is granted only for `/usr/sbin/pct`, `/usr/bin/pveam`, and `/usr/sbin/pvesm`; any other `sudo` will prompt for a password. Example:
>
> ```bash
> ssh proxmox 'sudo -n /usr/sbin/pct status 108'
> ssh proxmox 'sudo -n /usr/sbin/pct destroy 108'   # irreversible
> ```

## SSH Access

```bash
# Simple alias (preferred)
ssh proxmox

# Explicit form
ssh -i ~/.ssh/id_ed25519 ben@192.168.2.70
```

## File Transfer

```bash
# Upload
scp /local/path proxmox:/remote/path

# Download
scp proxmox:/remote/path /local/path
```

## Web UI

```bash
xdg-open https://192.168.2.70:8006
```

> Accept the self-signed certificate if prompted.

## Remote Access

This server is on the `192.168.2.0/24` LAN. To access remotely, connect via the WireGuard VPN first:

```bash
just vpn-ssh   # Connect to WireGuard EC2 server
```

Then SSH to Proxmox as normal.

## Guest Management

All commands run over the `proxmox` SSH alias with `sudo -n /usr/sbin/pct …` (see the note above).

```bash
# Inspect
ssh proxmox 'sudo -n /usr/sbin/pct list'              # all containers
ssh proxmox 'sudo -n /usr/sbin/pct config <id>'       # full config
ssh proxmox 'sudo -n /usr/sbin/pct status <id>'

# Re-IP a container (preserve every net0 field except ip=)
ssh proxmox 'sudo -n /usr/sbin/pct set <id> -net0 name=eth0,bridge=vmbr0,firewall=1,gw=192.168.2.1,hwaddr=<MAC>,ip=192.168.2.<id>/24,ip6=dhcp,type=veth'

# Destroy (irreversible — stop first if running)
ssh proxmox 'sudo -n /usr/sbin/pct stop <id> && sudo -n /usr/sbin/pct destroy <id>'
```

> **IP convention:** every guest uses a `192.168.2.<VMID>` address (last octet = VMID). Honour this when creating or re-IP'ing containers. VM 109 (Main) follows it too as of 2026-06-17 — its `.109` is pinned by a router DHCP reservation on the VM's MAC (the host uses DHCP networking), not a `pct`/`qm` net config.
>
> **After re-IP / destroy:** update [docs/PROXMOX_INVENTORY.md](../../docs/PROXMOX_INVENTORY.md), the matching `Host` entry in `~/.ssh/config`, and clear any stale key with `ssh-keygen -R 192.168.2.<id>`. A re-IP applies live but old clients (SSH, services, DNS) keep pointing at the previous address until updated.

## Motherboard RGB (OpenRGB)

The host's RGB (ASUS PRIME X670-P WIFI — 2× ENE DRAM over SMBus + ASUS **Aura** USB
controller `0b05:19af`) is driven by **OpenRGB running on the host** as a systemd
service (`openrgb.service`), exposing a network server on `192.168.2.70:6742` for
Home Assistant / any client. Full setup: [docs/OPENRGB_SERVER_SETUP.md](../../docs/OPENRGB_SERVER_SETUP.md).

```bash
ssh proxmox 'echo <pw> | sudo -S systemctl status openrgb'
ssh proxmox 'echo <pw> | sudo -S /opt/openrgb/squashfs-root/AppRun --list-devices'   # expect 3 devices
```

> ⚠️ **Never USB-pass the Aura controller (`0b05:19af`) to a VM** (it was on VM 109
> until 2026-06-23). QEMU claims it via `usbfs`, so the host's `usbhid` can't bind it,
> no `/dev/hidraw` node appears, and OpenRGB sees only the DRAM. A pre-start hook
> (`/opt/openrgb/bind-aura-hid.sh`) rebinds `usbhid` so a clean host boot Just Works.

## Resource Documentation

Live guest inventory: [docs/PROXMOX_INVENTORY.md](../../docs/PROXMOX_INVENTORY.md)
