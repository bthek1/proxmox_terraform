# VM 109 — GPU Passthrough Reference

Single reference for the GTX 1660 SUPER PCIe passthrough setup on VM 109. Covers hardware, Proxmox host config, VM guest config, display stack, and maintenance.

---

## Hardware

| Component          | Detail                                                                  |
| ------------------ | ----------------------------------------------------------------------- |
| GPU                | NVIDIA GeForce GTX 1660 SUPER                                           |
| VRAM               | 6144 MiB                                                                |
| Host PCI address   | `08:00.0`–`.3` (all functions passed since 2026-07-22: VGA, HDMI audio, USB-C, UCSI) |
| Guest PCI address  | `01:00.0` (appears as `/dev/dri/card1` — no integrated GPU, no `card0`) |
| Passthrough method | VFIO PCIe passthrough (`vfio-pci`)                                      |
| IOMMU groups       | 27–30, one per function (ACS override applied; verified 2026-07-22)     |

| Component     | Detail                                                          |
| ------------- | --------------------------------------------------------------- |
| VM            | 109                                                             |
| OS            | Ubuntu 24.04.4 LTS                                              |
| Kernel        | `6.17.0-40-generic`                                             |
| NVIDIA driver | `595.71.05` (open kernel module; see [Plans/Completed/VM_109_NVIDIA_595_UPGRADE.md](Plans/Completed/VM_109_NVIDIA_595_UPGRADE.md)) |
| IP            | `192.168.2.20` (SSH alias: `proxmox_main`, user: `proxmox-ml5`) |
| GDM           | 46.2                                                            |
| GNOME Shell   | 46.0                                                            |
| Session type  | Full Wayland (GDM Wayland greeter + GNOME Wayland user session) |

---

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Proxmox Host (bthek1, 192.168.2.70)                     │
│                                                          │
│  GTX 1660 SUPER @ 08:00.0                                │
│  bound to vfio-pci — hidden from host driver             │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │  VM 109 (Ubuntu 24.04, QEMU/KVM, PCIe passthrough) │  │
│  │                                                    │  │
│  │  GTX 1660 SUPER @ 01:00.0 (/dev/dri/card1)        │  │
│  │  NVIDIA driver 580.142 (open kernel module)        │  │
│  │  nvidia-drm.modeset=1                              │  │
│  │                                                    │  │
│  │  GDM 46.2 ──► gdm-wayland-session (Wayland greeter)│  │
│  │  GNOME Shell 46.0 ──► Wayland compositor (Mutter)  │  │
│  │  Xwayland nested inside Wayland compositor         │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

The GPU is exclusively owned by VM 109. No other VM or LXC container can use it concurrently. The host kernel never binds an NVIDIA driver to this GPU — it is bound to `vfio-pci` at boot.

---

## Proxmox Host Configuration

### IOMMU / VFIO

IOMMU must be enabled on the host for PCIe passthrough. In `/etc/default/grub` on the **Proxmox host**:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet intel_iommu=on iommu=pt"
```

(Or `amd_iommu=on` for AMD CPUs — this host uses Intel.)

The GTX 1660 SUPER is in **IOMMU group 24**. ACS override is active to allow it to be isolated.

### VM config — `/etc/pve/qemu-server/109.conf` (relevant lines)

```ini
hostpci0: 0000:08:00,pcie=1,x-vga=1
machine: q35
bios: ovmf
```

- `0000:08:00` (no function suffix) — passes **all functions** of the card: VGA (`.0`), HDMI/DP audio (`.1`), USB-C controller (`.2`), UCSI (`.3`). Changed from `.0`-only on 2026-07-22 to enable monitor-speaker audio; each function sits in its own IOMMU group so this is clean
- `pcie=1` — exposes the device as a PCIe device (required for NVIDIA)
- `x-vga=1` — enables VGA arbitration, required for display output passthrough

Full peripheral map (USB controller `hostpci2`, AMD audio `hostpci1`, per-device USB entries): [109_PERIPHERAL_PASSTHROUGH.md](109_PERIPHERAL_PASSTHROUGH.md).

**Applying `hostpci` changes:** they are *pending* until the QEMU process restarts — use the Proxmox UI Reboot button or `sudo qm reboot 109` on the host. A `reboot` inside the guest does **not** apply them.
- `machine: q35` — Q35 chipset, required for PCIe passthrough
- `bios: ovmf` — UEFI firmware (OVMF), required for Q35 + VGA passthrough

### USB passthrough caution

QEMU hard-fails at startup if any `usb-host` device in the VM config is not physically connected. Always verify before starting the VM:

```bash
# On Proxmox host
cat /etc/pve/qemu-server/109.conf | grep usb
lsusb   # compare — any missing device will prevent QEMU from starting
```

Only store USB passthrough entries for permanently-attached devices. Hot-plug occasional devices via the Proxmox web UI instead.

---

## VM Guest Configuration

### Kernel parameters

`/etc/default/grub` inside VM 109:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amd_iommu=on nvidia-drm.modeset=1 vt.handoff=7"
```

- `nvidia-drm.modeset=1` — registers the NVIDIA DRM KMS device; required for Wayland compositors and for logind to properly transfer GPU ownership between sessions
- `vt.handoff=7` — smooth handoff from framebuffer to display manager

Apply after editing:

```bash
sudo update-grub
sudo update-initramfs -u -k all
sudo reboot
```

### Modprobe config

`/etc/modprobe.d/nvidia-kms.conf`:

```
options nvidia-drm modeset=1
```

Ensures `nvidia-drm` loads with `modeset=1` even if the kernel cmdline parameter is absent.

### NVIDIA driver

Installed via Ubuntu package manager (`ubuntu-drivers` / `apt`). The **open kernel module** variant (driver series 580) is in use.

```bash
# Verify inside VM
nvidia-smi
# NVIDIA GeForce GTX 1660 SUPER, Driver Version: 580.142, CUDA Version: 13.0
```

---

## Display Stack — Full Wayland

VM 109 runs a full Wayland stack: GDM presents a Wayland greeter and GNOME starts a Wayland user session. No X11 workarounds are needed.

### Why Wayland works here

- `nvidia-drm.modeset=1` is active — Wayland compositors use DRM directly, no VT ioctl needed
- NVIDIA driver 580 ships the GBM backend (`nvidia-drm_gbm.so` via `libnvidia-extra-580`) — Mutter uses GBM for Wayland rendering
- GNOME 46 on Ubuntu 24.04 has first-class NVIDIA Wayland support
- No `card0` vs `card1` issue: Mutter enumerates all DRM devices, not just `card0`
- DRM master is held by the Wayland compositor for the full session; Xwayland runs nested inside it

### Config file 1 — `/etc/gdm3/custom.conf`

```ini
[daemon]
# Uncomment the line below to force the login screen to use Xorg
#WaylandEnable=false
PreferredDisplayServer=wayland
```

### Config file 2 — `/etc/udev/rules.d/60-gdm-nvidia-wayland.rules`

```
# Force Wayland greeter for NVIDIA passthrough GPU
# Runs before 61-gdm.rules to set GDM_PREFER_WAYLAND=1
ACTION=="bind", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", DRIVER=="nvidia", ENV{GDM_PREFER_WAYLAND}="1"
```

**Why this file exists:** Ubuntu's `/usr/lib/udev/rules.d/61-gdm.rules` fires when the NVIDIA PCI device is bound at boot and unconditionally writes `PreferredDisplayServer=xorg` to `/run/gdm3/custom.conf` for all non-Dell NVIDIA systems (driver ≥ 470). This runtime file overrides the static `/etc/gdm3/custom.conf`. The `60-gdm-nvidia-wayland.rules` file runs first (lower number = higher priority) and sets `GDM_PREFER_WAYLAND=1`, which causes `61-gdm.rules` to take the `gdm_prefer_wayland` path instead.

### Suspend disabled

VFIO GPU passthrough and ACPI S3 suspend are incompatible. The NVIDIA GPU loses its firmware state on suspend and cannot restore it through VFIO, leaving the display blank after resume and breaking the Wayland compositor. Suspend is permanently disabled on VM 109.

**Systemd targets masked** (symlinked to `/dev/null`):

```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

**`/etc/systemd/logind.conf`** (appended):

```ini
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
```

Use **`Super + L`** to lock the screen and blank the display instead. The session stays fully alive — any key or mouse movement brings it back instantly.

If the VM is accidentally suspended via `qm suspend` from the Proxmox host, recover with:

```bash
# Resume the VM
ssh -t proxmox "sudo /usr/sbin/qm resume 109"
# Then restart GDM to restore the display
ssh -t proxmox_main "sudo systemctl restart gdm3"
```

### fstab — secondary drive

`/etc/fstab` has a secondary 512GB ext4 drive that is not always present at boot. It must have `nofail` to prevent emergency mode:

```
UUID=00e86635-1295-4921-a0e9-103d90b7d301 /media/proxmox-ml5/512GB ext4 defaults,nofail 0 0
```

---

## Verification

```bash
# Confirm GPU is recognised inside VM
ssh proxmox_main 'nvidia-smi'

# Confirm kernel DRM modeset is active
ssh proxmox_main 'cat /proc/cmdline | grep modeset'

# Confirm GDM greeter is Wayland
ssh proxmox_main 'bash -c "loginctl show-session c27 --property=Type"'
# Expected: Type=wayland

# Confirm user session is Wayland (after login)
ssh proxmox_main 'bash -c "systemctl --user show-environment | grep XDG_SESSION_TYPE"'
# Expected: XDG_SESSION_TYPE=wayland

# Check udev rule is in place
ssh proxmox_main 'cat /etc/udev/rules.d/60-gdm-nvidia-wayland.rules'
```

---

## Rollback: Restore X11 Stack

If Wayland causes blocking display issues, revert to the X11 configuration via SSH:

```bash
# 1. Re-enable X11 greeter
ssh -tt proxmox_main 'sudo sed -i "s/#WaylandEnable=false/WaylandEnable=false/" /etc/gdm3/custom.conf'
ssh -tt proxmox_main 'sudo sed -i "/PreferredDisplayServer=wayland/d" /etc/gdm3/custom.conf'

# 2. Remove the Wayland udev override
ssh -tt proxmox_main 'sudo rm /etc/udev/rules.d/60-gdm-nvidia-wayland.rules'

# 3. Restore BusID xorg config (needed because no card0 exists)
ssh proxmox_main 'printf "Section \"Device\"\n    Identifier \"nvidia\"\n    Driver \"nvidia\"\n    BusID \"PCI:1:0:0\"\n    Option \"AllowEmptyInitialConfiguration\"\nEndSection\n" | sudo tee /etc/X11/xorg.conf.d/10-nvidia.conf'

# 4. Restore Xwrapper (allows gdm user to run Xorg with root rights)
ssh -tt proxmox_main 'sudo sed -i "s/allowed_users=console/allowed_users=anybody/" /etc/X11/Xwrapper.config'
ssh proxmox_main 'printf "needs_root_rights=yes\n" | sudo tee -a /etc/X11/Xwrapper.config'

# 5. Restart GDM
ssh -tt proxmox_main 'sudo systemctl restart gdm'
```

---

## Troubleshooting

### Emergency mode on boot

**Symptom:** `Dependency failed for local-fs.target` at boot.
**Cause:** An fstab entry for a non-always-present drive lacks `nofail`.
**Fix:** At the emergency console: `sed -i '/512GB/s/defaults/defaults,nofail/' /etc/fstab && systemctl reboot`

### GDM falls back to X11 after reboot

**Symptom:** `loginctl show-session c27` returns `Type=x11` after a reboot.
**Cause:** `/etc/udev/rules.d/60-gdm-nvidia-wayland.rules` is missing or the udev rule number is ≥ 61.
**Fix:** Re-create the file (see Config file 2 above). Ensure filename starts with `60-`.

### QEMU fails to start (blank display, SSH unreachable)

**Symptom:** VM shows `status: running` in Proxmox but no QEMU process exists.
**Cause:** A `usb-host` device in the VM config is not physically connected.
**Fix:**

```bash
# On Proxmox host — identify missing USB devices
cat /etc/pve/qemu-server/109.conf | grep usb
lsusb
# Remove entries for missing devices, then start
```

### VM suspended — display blank, keyboard/mouse won't wake it

**Symptom:** VM was suspended (via GNOME power menu or `qm suspend`). Keyboard and mouse do not wake it. After `qm resume`, display stays blank.
**Cause:** VFIO GPU passthrough is incompatible with ACPI S3 suspend. The GPU loses its firmware state and the Wayland compositor crashes.
**Fix:**

```bash
# 1. Resume the VM from the Proxmox host
ssh -t proxmox "sudo /usr/sbin/qm resume 109"

# 2. Restart GDM inside the VM to restore the display
ssh -t proxmox_main "sudo systemctl restart gdm3"
```

**Prevention:** Suspend is permanently disabled on VM 109 (see Suspend disabled section above). Use `Super + L` to lock/blank the screen instead.

### GDM login crash — "no screens found" or "failed to acquire modesetting permission"

See [109_GPU_SETUP.md](109_GPU_SETUP.md) for the full diagnosis history of these issues. Both are resolved by the current Wayland configuration. The X11 rollback procedure above restores the interim X11 fix if needed.
