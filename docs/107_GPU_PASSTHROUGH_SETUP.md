# GPU Setup — Proxmox LXC Device Passthrough

## Architecture

The GPU is a **physical NVIDIA card on the Proxmox host** (`bthek1`). It is shared with LXC containers via **device node passthrough** — not PCIe passthrough or vGPU.

```
┌──────────────────────────────────────────┐
│  Proxmox Host (bthek1)                   │
│                                          │
│  NVIDIA driver (DKMS)                    │
│    └── /dev/nvidia0                      │
│    └── /dev/nvidiactl                    │
│    └── /dev/nvidia-modeset               │
│    └── /dev/nvidia-uvm                   │
│                                          │
│  ┌──────────┐   ┌──────────┐             │
│  │  LXC 107 │   │  LXC NNN │  ...        │
│  │ (nvidia) │   │ (nvidia) │             │
│  └──────────┘   └──────────┘             │
└──────────────────────────────────────────┘
```

Multiple LXC containers can mount the same host device nodes simultaneously. The host driver handles multiplexing; the practical limit is GPU VRAM.

---

## Host Driver Setup

The NVIDIA driver is installed on the Proxmox host via **DKMS** so it rebuilds automatically after kernel upgrades.

| Component      | Details                                                |
| -------------- | ------------------------------------------------------ |
| Driver version | `595.71.05` (target; see `nvidia/nvidia_upgrade.sh`)   |
| Install method | DKMS (`.run` installer with `--dkms` flag)             |
| Kernel module  | rebuilt per PVE kernel via `dkms install nvidia/<ver>` |

### Modules loaded at boot

```
nvidia
nvidia_uvm
nvidia_modeset
```

### Systemd service

**`/etc/systemd/system/nvidia-devices.service`** runs before `pve-guests.service` and:

1. `modprobe nvidia` / `nvidia_uvm` / `nvidia_modeset`
2. Creates any missing device nodes (`/dev/nvidia-modeset`, `/dev/nvidia-uvm`, etc.)
3. Sets world-readable permissions on all `/dev/nvidia*` nodes

This ensures device nodes exist before Proxmox tries to start LXC containers that reference them.

---

## LXC Container Configuration

In the Proxmox container config (e.g. `/etc/pve/lxc/107.conf`), the host device nodes are mounted into the container:

```ini
lxc.cgroup2.devices.allow: c 195:* rwm   # /dev/nvidia*
lxc.cgroup2.devices.allow: c 507:* rwm   # /dev/nvidia-uvm*
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
```

The container uses the GPU through the **host's kernel driver** — no driver is installed inside the container itself. Only the NVIDIA userspace libraries (e.g. `libnvidia-compute`) need to be present inside the container.

---

## Multi-Container GPU Sharing

| Method                              | Multi-container?  | Notes                                                                                  |
| ----------------------------------- | ----------------- | -------------------------------------------------------------------------------------- |
| **Device node passthrough (LXC)**   | **Yes**           | All containers share the same `/dev/nvidia*` nodes. Each gets full GPU access.         |
| **PCIe passthrough (VM, vfio-pci)** | No                | GPU is exclusively owned by one VM.                                                    |
| **vGPU (NVIDIA GRID)**              | Yes (partitioned) | Requires enterprise GRID driver and supported GPU (A-series, T4, etc.). Not used here. |

With the current setup, any LXC container configured with the device mounts above can use the GPU concurrently. All containers compete for the same VRAM pool.

---

## Upgrade Procedure

When a PVE kernel upgrade breaks the driver (DKMS compile fails → no device nodes → LXC 107 won't start):

```bash
# 1. Edit DRIVER_VER in the script to the latest production driver
#    Check: https://www.nvidia.com/en-us/drivers/unix/
nano nvidia/nvidia_upgrade.sh

# 2. Copy and run on the Proxmox host
scp nvidia/nvidia_upgrade.sh proxmox:/tmp/
ssh proxmox "bash /tmp/nvidia_upgrade.sh"
```

The `nvidia_upgrade.sh` script:

- Removes the old DKMS entry
- Downloads and installs the new `.run` driver with `--dkms`
- Loads modules
- Starts `nvidia-devices.service`
- Starts LXC 107

If only the DKMS rebuild is needed (driver version already compatible, just missing module for new kernel):

```bash
scp nvidia/nvidia_fix.sh proxmox:/tmp/
ssh proxmox "bash /tmp/nvidia_fix.sh"
```

---

## Diagnosis Commands

Run these on the Proxmox host to diagnose GPU/driver issues:

```bash
# Is the service failing?
systemctl status nvidia-devices.service

# Are nvidia modules loaded?
lsmod | grep nvidia

# Do device nodes exist?
ls -la /dev/nvidia*

# What kernel is running?
uname -r

# Is there a compiled module for it?
find /lib/modules/$(uname -r) -name 'nvidia.ko*'

# DKMS state
dkms status

# GPU status (if driver is loaded)
nvidia-smi
```

---

## Known Issue: nvidia-modeset missing after reboot

See [LXC_107_NVIDIA_MODESET_ERROR.md](LXC_107_NVIDIA_MODESET_ERROR.md) for the full diagnosis and fix history.

**Root cause:** PVE kernel upgrade moves the host to a kernel version not supported by the currently installed NVIDIA driver. DKMS rebuild fails, no modules load, no device nodes are created, LXC 107 fails to start.

**Fix:** Upgrade the NVIDIA driver to a version that supports the running kernel (see upgrade procedure above).
