# LXC 107 — TASK ERROR: Device /dev/nvidia-modeset does not exist

**Affected container:** LXC 107 (node `bthek1`)  
**Trigger:** Proxmox node restart or container restart  
**Error:**
```
TASK ERROR: Device /dev/nvidia-modeset does not exist
```

---

## What is happening

LXC 107 is configured to pass through one or more NVIDIA device nodes (including `/dev/nvidia-modeset`) from the Proxmox host into the container. When the container starts, Proxmox checks that those device nodes exist on the host. If they don't, the container refuses to start.

The device nodes (`/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-modeset`, `/dev/nvidia-uvm`, etc.) are **not persistent** — they are created dynamically by the NVIDIA kernel driver when it loads. If the driver fails to load at boot, none of those nodes exist.

---

## Previous fix attempt (and why it still fails)

A systemd service was created to handle exactly this:

**Service:** `/etc/systemd/system/nvidia-devices.service`  
**Script:** `/usr/local/sbin/nvidia-create-devices.sh`

The service runs before `pve-guests.service` and:
1. Runs `modprobe nvidia`, `modprobe nvidia_uvm`, `modprobe nvidia_modeset`
2. Creates any missing device nodes (`/dev/nvidia-modeset`, `/dev/nvidia-uvm`, etc.)
3. Sets world-readable permissions on all device nodes

The service is **enabled** but **fails on boot** with exit code 1.

### Root cause of the service failure

The `modprobe nvidia` step fails because the NVIDIA kernel driver module is **not compiled for the currently running PVE kernel**.

```
PVE package version:  7.0.2-2-pve
Actual Linux kernel:  6.17.13-2-pve
NVIDIA driver installed:  580.105.08  ← too old, does not support Linux 6.17
```

The NVIDIA 580.105.08 driver source is incompatible with Linux 6.17 — several kernel APIs it uses were renamed or removed (`dma_is_direct`, `map_resource`, `get_backlight_device_by_name`, `drm_gem_object_put_unlocked`). DKMS attempts to rebuild on boot but the compile fails, leaving no kernel module and no device nodes.

The root cause was a PVE kernel upgrade (`apt upgrade`) that moved the host to Linux 6.17 while the NVIDIA driver remained at 580.105.08, which only supports up to ~Linux 6.11.

Since `modprobe nvidia` fails, none of the device nodes are created, so LXC 107 cannot start.

---

## How to diagnose

```bash
ssh proxmox

# Is the service failing?
systemctl status nvidia-devices.service

# Are any nvidia modules loaded?
lsmod | grep nvidia

# Do the device nodes exist?
ls -la /dev/nvidia*

# What kernel is running?
uname -r

# Is there a kernel module for it?
find /lib/modules/$(uname -r) -name 'nvidia.ko*'

# DKMS state (if nvidia was installed via DKMS)
dkms status
```

If `lsmod | grep nvidia` shows only `i2c_nvidia_gpu` and no `nvidia` module, the driver is not loaded.

---

## How to fix (immediate)

The driver must be upgraded to a version that supports the running Linux kernel.

### Check the current kernel and compatible driver

```bash
# On the Proxmox host as ben (or root):
uname -r                   # actual Linux kernel, e.g. 6.17.13-2-pve
dkms status               # currently registered driver version
```

Check https://www.nvidia.com/en-us/drivers/unix/ for the latest production driver. As of May 2026 the latest is **595.71.05**, which supports Linux 6.17.

### Upgrade the driver

Use the **`nvidia/nvidia_upgrade.sh`** script from this repo. Edit `DRIVER_VER` at the top to the latest production version before running.

```bash
# Copy the script to the host and run as root:
scp nvidia/nvidia_upgrade.sh proxmox:/tmp/nvidia_upgrade.sh
ssh -t proxmox "sudo bash /tmp/nvidia_upgrade.sh"
```

The script will: remove the old DKMS entry, download the new driver, install with `--dkms`, load modules, start `nvidia-devices.service`, and start LXC 107.

### Start the service and LXC 107 (if driver is already correct)

If `dkms status` shows the driver as `installed` but the service failed, use **`nvidia/nvidia_fix.sh`**:

```bash
scp nvidia/nvidia_fix.sh proxmox:/tmp/nvidia_fix.sh
ssh -t proxmox "sudo bash /tmp/nvidia_fix.sh"
```

### What was done on 2026-05-13

- Detected: driver 580.105.08 incompatible with kernel 6.17.13-2-pve
- Installed: `proxmox-headers-7.0.2-2-pve` (kernel headers)
- Removed: DKMS entry for `nvidia/580.105.08`
- Installed: `nvidia/595.71.05` via `.run --silent --dkms`
- Result: `nvidia-devices.service` active, all `/dev/nvidia*` nodes present, LXC 107 started

---

## How to prevent recurrence

The `nvidia-devices.service` approach is correct in principle, but it only works if the NVIDIA kernel module is present. There are two things that must both be true:

1. **The NVIDIA driver must survive kernel updates.** Install it with `--dkms` so DKMS automatically rebuilds the module when a new kernel is installed.

2. **The service must run after the module is guaranteed to be present.** The current service already handles this by loading the module itself, but if the module isn't installed it will always fail.

### Recommended: keep DKMS registered and verify after every PVE upgrade

The driver is now installed with `--dkms`, which registers it so DKMS will auto-recompile when a new kernel is installed. However, DKMS can only rebuild if the driver **source supports the new kernel**. After any `apt upgrade` that brings a new PVE/kernel version, always verify:

```bash
dkms status
# Expected: nvidia/<version>, <new-kernel>, x86_64: installed
# If it shows "added" but not "installed", the build failed — upgrade the driver.
```

The minimum driver version for each major Linux kernel:
| Linux kernel | Min NVIDIA driver |
|---|---|
| 6.11.x | ~560+ |
| 6.12.x | ~565+ |
| 6.13.x | ~570+ |
| 6.17.x | ~595+ |

### Check after every PVE kernel update

After running `apt upgrade` on the Proxmox host (which may install a new kernel), always verify:

```bash
reboot
# after reboot:
systemctl status nvidia-devices.service
lsmod | grep '^nvidia '
```

If the service failed, follow the fix steps above before starting LXC 107.

---

## Summary of affected files

| File | Purpose |
|------|---------|
| `nvidia/nvidia_upgrade.sh` | **Use this** — upgrades the NVIDIA driver to a new version, rebuilds DKMS, starts LXC 107 |
| `nvidia/nvidia_fix.sh` | Installs kernel headers, loads modules, starts the service and LXC 107 (only works if driver already supports the current kernel) |
| `/etc/systemd/system/nvidia-devices.service` | Systemd unit on host — loads nvidia modules and creates device nodes before guests start |
| `/usr/local/sbin/nvidia-create-devices.sh` | Script called by the service on host |
| `/etc/pve/nodes/bthek1/lxc/107.conf` | LXC 107 config — references `/dev/nvidia-modeset` and other nvidia devices |
