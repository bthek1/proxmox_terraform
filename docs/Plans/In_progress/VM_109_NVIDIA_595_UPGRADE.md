# VM 109 — Upgrade NVIDIA Driver to 595.71.05

**Status**: 🔄 In Progress

**Problem**: VM 109 currently runs NVIDIA driver `580.142` (open kernel module). Upgrading to `595.71.05` brings bug fixes, improved Wayland/GBM support, and aligns the guest driver with the Proxmox host target version.

**Environment**:

- Host: Proxmox `bthek1` at `192.168.2.70` (SSH alias: `proxmox`)
- VM 109: Ubuntu 24.04, kernel `6.17.0-29-generic`, IP `192.168.2.20` (SSH alias: `proxmox_main`)
- GPU: GTX 1660 SUPER via PCIe passthrough at `PCI:1:0:0`, `/dev/dri/card1`
- Current driver: `580.142` (open kernel module), CUDA 13.0
- Target driver: `595.71.05`
- Current session: Wayland (GNOME on Wayland via GDM)

**Goal**: Replace NVIDIA driver `580.142` with `595.71.05` using the `.run` installer in DKMS mode, keeping the Wayland session functional.

**Rollback**: If the new driver fails, reinstall `580.142` from the same `.run` installer. The current Wayland config (udev rule + `custom.conf`) does not need to change — it is driver-version-agnostic.

---

## Phase 1: Pre-flight Checks

**Status**: Not started

**Goal**: Confirm current driver version, kernel, and Wayland state before making any changes.

**Deliverables**:

- [ ] Record current driver version: `nvidia-smi --query-gpu=driver_version --format=csv,noheader`
- [ ] Record current kernel: `uname -r`
- [ ] Confirm Wayland session is active: `loginctl list-sessions` → GDM session `Type=wayland`
- [ ] Confirm DKMS entries: `dkms status`
- [ ] Confirm disk space: `df -h /` — need at least 2 GB free for installer + build

**Commands**:

```bash
ssh proxmox_main 'nvidia-smi --query-gpu=driver_version --format=csv,noheader'
ssh proxmox_main 'uname -r'
ssh proxmox_main 'loginctl list-sessions'
ssh proxmox_main 'dkms status'
ssh proxmox_main 'df -h /'
```

**Stability Criteria**: Current driver reported as `580.142`, Wayland session active, at least 2 GB free on `/`.

**Notes**:

---

## Phase 2: Download Driver Installer

**Status**: Not started

**Goal**: Download the `595.71.05` `.run` installer to VM 109 and verify its integrity.

**Deliverables**:

- [ ] Download installer to `/tmp/NVIDIA-Linux-x86_64-595.71.05.run`
- [ ] Make installer executable
- [ ] Verify download succeeded (non-zero file size)

**Commands**:

```bash
DRIVER_VER="595.71.05"
DRIVER_FILE="NVIDIA-Linux-x86_64-${DRIVER_VER}.run"
DRIVER_URL="https://download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VER}/${DRIVER_FILE}"

ssh proxmox_main "wget -q --show-progress -O /tmp/${DRIVER_FILE} ${DRIVER_URL}"
ssh proxmox_main "chmod +x /tmp/${DRIVER_FILE} && ls -lh /tmp/${DRIVER_FILE}"
```

**Stability Criteria**: Installer file present at `/tmp/NVIDIA-Linux-x86_64-595.71.05.run` with size > 100 MB.

**Notes**:

---

## Phase 3: Install Driver

**Status**: Not started

**Goal**: Remove the old driver DKMS entry and install `595.71.05` in DKMS mode.

**Deliverables**:

- [ ] Stop GDM to release the GPU before install: `sudo systemctl stop gdm3`
- [ ] Remove old DKMS entry: `sudo dkms remove nvidia/580.142 --all`
- [ ] Run installer in silent DKMS mode with open kernel module
- [ ] Confirm DKMS registered: `dkms status` shows `nvidia/595.71.05, <kernel>: installed`

**Commands**:

```bash
# Stop display manager to free GPU
ssh -tt proxmox_main 'sudo systemctl stop gdm3'

# Remove old DKMS entry (safe — does not remove userspace libs yet)
ssh -tt proxmox_main 'sudo dkms remove nvidia/580.142 --all 2>/dev/null || true'

# Install new driver
ssh -tt proxmox_main "sudo bash /tmp/NVIDIA-Linux-x86_64-595.71.05.run \
    --silent \
    --dkms \
    --no-backup \
    --no-x-check \
    --no-nouveau-check"

# Confirm DKMS
ssh proxmox_main 'dkms status'
```

**Stability Criteria**: `dkms status` lists `nvidia/595.71.05` as `installed` for the running kernel. No error output from the installer.

**Notes**:

> The `--no-drm` flag used in the host upgrade script is **not** used here because VM 109 needs `nvidia-drm` for Wayland/GBM. Omitting it ensures the `nvidia-drm` module is built and loaded.

---

## Phase 4: Verify Driver and Wayland

**Status**: Not started

**Goal**: Reboot VM 109, confirm the new driver is loaded, and verify the Wayland session is still functional.

**Deliverables**:

- [ ] Reboot VM 109: `sudo reboot`
- [ ] Confirm driver version after reboot: `nvidia-smi` shows `595.71.05`
- [ ] Confirm kernel modules loaded: `lsmod | grep -E 'nvidia|drm'`
- [ ] Confirm Wayland session active: GDM `Type=wayland`, user session `Type=wayland`
- [ ] Confirm `nvidia-drm.modeset=1` still active in kernel cmdline

**Commands**:

```bash
# Reboot
ssh -tt proxmox_main 'sudo reboot'
# Wait ~30s then reconnect
sleep 30

ssh proxmox_main 'nvidia-smi'
ssh proxmox_main 'lsmod | grep nvidia'
ssh proxmox_main 'cat /proc/cmdline | grep modeset'
ssh proxmox_main 'loginctl list-sessions'
ssh proxmox_main 'loginctl show-session $(loginctl list-sessions --no-legend | awk "/gdm/{print \$1}") --property=Type'
```

**Stability Criteria**: `nvidia-smi` reports `595.71.05`. GDM session shows `Type=wayland`. No kernel module errors in `dmesg | grep -i nvidia`.

**Notes**:

---

## Phase 5: Cleanup

**Status**: Not started

**Goal**: Remove installer file and record the completed upgrade.

**Deliverables**:

- [ ] Remove installer: `sudo rm /tmp/NVIDIA-Linux-x86_64-595.71.05.run`
- [ ] Update `docs/Plans/Completed/VM_109_FULL_WAYLAND.md` — add note that driver was upgraded to `595.71.05` post-completion
- [ ] Move this plan file to `docs/Plans/Completed/`

**Commands**:

```bash
ssh -tt proxmox_main 'sudo rm -f /tmp/NVIDIA-Linux-x86_64-595.71.05.run'
```

**Stability Criteria**: Plan file moved to `Completed/`. No stale installer on disk.

**Notes**:
