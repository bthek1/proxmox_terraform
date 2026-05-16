# GPU Setup — Proxmox Host `bthek1`

This document is the single reference for the NVIDIA GPU setup on Proxmox node `bthek1`. It covers hardware, architecture, driver installation, LXC container configuration, and maintenance.

---

## Hardware

| Slot     | GPU                        | PCI address |
| -------- | -------------------------- | ----------- |
| Primary  | NVIDIA RTX 3060 LHR        | `01:00.0`   |
| Secondary| NVIDIA GTX 1660 SUPER      | `08:00.0`   |

Both GPUs are physically installed in the Proxmox host. They are **not** passed through to VMs via VFIO/PCIe passthrough. Instead, they are shared with LXC containers via **device node passthrough**.

---

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  Proxmox Host (bthek1)                               │
│                                                      │
│  NVIDIA driver 595.71.05 (DKMS)                      │
│    ├── /dev/nvidia0          (RTX 3060)               │
│    ├── /dev/nvidia1          (GTX 1660 SUPER)         │
│    ├── /dev/nvidiactl                                 │
│    ├── /dev/nvidia-modeset                            │
│    ├── /dev/nvidia-uvm                                │
│    └── /dev/nvidia-uvm-tools                          │
│                                                      │
│  ┌──────────────┐   ┌──────────────┐                 │
│  │   LXC 107    │   │  other LXCs  │  ...            │
│  │  (bind mounts│   │  (same nodes)│                 │
│  │  /dev/nvidia*)   └──────────────┘                 │
│  └──────────────┘                                    │
└──────────────────────────────────────────────────────┘
```

The Proxmox host kernel module handles the GPU. Containers access it through bind-mounted device nodes — they share the host driver. No driver is installed inside the container; only the NVIDIA userspace libraries (e.g. `libnvidia-compute`) are needed there.

Multiple containers can use the GPUs concurrently; all compete for the same VRAM pool.

---

## Host Driver Setup

### Installation method

The driver is installed as a **DKMS** module using the official NVIDIA `.run` installer with the `--dkms` flag. DKMS rebuilds the module automatically when the PVE kernel is upgraded.

```
Driver:  595.71.05
Method:  DKMS (.run installer)
Source:  https://download.nvidia.com/XFree86/Linux-x86_64/
```

### Kernel modules loaded at boot

```
nvidia
nvidia_uvm
nvidia_modeset
```

### Systemd service — `nvidia-devices.service`

Because Proxmox starts LXC containers before the NVIDIA modules are guaranteed to be loaded, a custom service ensures the device nodes exist first:

**`/etc/systemd/system/nvidia-devices.service`** — runs before `pve-guests.service`:

1. Runs `modprobe nvidia`, `nvidia_uvm`, `nvidia_modeset`
2. Creates any missing device nodes (especially `/dev/nvidia-modeset` and `/dev/nvidia-uvm`)
3. Sets world-readable permissions on all `/dev/nvidia*` nodes

---

## LXC Container Configuration

The device nodes are bind-mounted into the container via `/etc/pve/lxc/107.conf`:

```ini
# cgroup2 device access
lxc.cgroup2.devices.allow: c 195:* rwm   # /dev/nvidia*
lxc.cgroup2.devices.allow: c 507:* rwm   # /dev/nvidia-uvm*

# bind mounts
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
```

The same entries can be applied to any other LXC container that needs GPU access.

---

## Kernel ↔ Minimum Driver Version

A PVE kernel upgrade may require a newer NVIDIA driver. Reference table:

| PVE Kernel | Minimum NVIDIA driver |
| ---------- | --------------------- |
| 6.11       | ~560                  |
| 6.12       | ~565                  |
| 6.13       | ~570                  |
| 6.17       | ~595 (current)        |

Check the latest production driver at: https://www.nvidia.com/en-us/drivers/unix/

---

## Maintenance Scripts

Both scripts live in `nvidia/` and must be copied to the Proxmox host before running as root.

### `nvidia/nvidia_fix.sh` — quick DKMS rebuild

Use when: the kernel was upgraded but the installed driver version is still compatible — DKMS just needs to rebuild the module for the new kernel.

```bash
scp nvidia/nvidia_fix.sh proxmox:/tmp/
ssh -t proxmox "sudo bash /tmp/nvidia_fix.sh"
```

What it does:
1. Installs kernel headers for the running kernel if missing
2. Auto-detects the registered DKMS nvidia version
3. Runs `dkms install nvidia/<ver> -k <kernel>`
4. Loads all nvidia modules
5. Starts `nvidia-devices.service` and LXC 107

### `nvidia/nvidia_upgrade.sh` — full driver upgrade

Use when: the installed driver does not support the running kernel and must be replaced.

```bash
# 1. Edit DRIVER_VER at the top of the script to the latest production version
nano nvidia/nvidia_upgrade.sh

# 2. Copy and run on the host
scp nvidia/nvidia_upgrade.sh proxmox:/tmp/
ssh -t proxmox "sudo bash /tmp/nvidia_upgrade.sh"
```

What it does:
1. Removes the old DKMS entry
2. Downloads the new `.run` installer
3. Installs with `--dkms --no-drm --silent`
4. Loads modules and starts `nvidia-devices.service`
5. Starts LXC 107

---

## Diagnosis Commands

Run on the Proxmox host:

```bash
# Is the systemd service running?
systemctl status nvidia-devices.service

# Are nvidia modules loaded?
lsmod | grep nvidia

# Do device nodes exist?
ls -la /dev/nvidia*

# What kernel is running?
uname -r

# Is there a compiled module for this kernel?
find /lib/modules/$(uname -r) -name 'nvidia.ko*'

# DKMS registration and build status
dkms status

# GPU status (only works if driver is loaded)
nvidia-smi
```

---

## Common Issue: LXC Fails to Start After Kernel Upgrade

**Error:** `TASK ERROR: Device /dev/nvidia-modeset does not exist`

**Root cause:** A `pve-kernel` upgrade moves the host to a kernel version that the installed NVIDIA driver does not support. DKMS compilation fails → no modules load → no device nodes → LXC 107 cannot start.

**Symptom check:**
```bash
lsmod | grep nvidia   # shows only i2c_nvidia_gpu, no nvidia module
dkms status           # shows nvidia as "build failed" or missing for running kernel
```

**Fix:**
- If the driver version is compatible, run `nvidia_fix.sh` (DKMS rebuild).
- If the driver version is too old for the kernel, run `nvidia_upgrade.sh` with an updated `DRIVER_VER`.

See [LXC_107_NVIDIA_MODESET_ERROR.md](LXC_107_NVIDIA_MODESET_ERROR.md) for the full diagnosis history.
