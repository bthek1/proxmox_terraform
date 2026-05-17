# VM 109 — Switch to Full Wayland Session

**Status**: 🔄 In Progress

**Problem**: VM 109 currently runs an X11 greeter + X11 user session, requiring four non-obvious workarounds (`WaylandEnable=false`, BusID xorg.conf, `gdm` video group, `Xwrapper.config` root rights). A full Wayland stack (Wayland greeter + Wayland user session) avoids all of these: Wayland compositors enumerate DRM devices directly, handle DRM master handoff natively, and do not need the Xorg VT ioctl machinery.

**Environment**:

- Host: Proxmox `bthek1` at `192.168.2.70` (SSH alias: `proxmox`)
- VM 109: Ubuntu 24.04, kernel `6.17.0-29-generic`, IP `192.168.2.20` (SSH alias: `proxmox_main`)
- GPU: GTX 1660 SUPER at `PCI:1:0:0`, `/dev/dri/card1` (no integrated GPU, no `card0`)
- NVIDIA driver: `580.142` (open kernel module), CUDA 13.0
- Current state: X11 greeter + X11 session working after fix applied 2026-05-17

**Goal**: Replace the X11 greeter + X11 user session with a Wayland greeter + Wayland user session (GNOME on Wayland via Mutter), then remove the X11-specific workarounds that are no longer needed.

**Why this should work**:

- `nvidia-drm.modeset=1` is already active (required for Wayland) ✅
- NVIDIA driver 525+ supports GBM (used by Mutter for Wayland) ✅
- GNOME 46 (Ubuntu 24.04) has first-class NVIDIA Wayland support ✅
- No `card0` vs `card1` issue: Mutter/wlroots enumerate all DRM devices, not just `card0`
- No DRM master conflict: compositor-to-compositor handoff is Wayland's native design

**Risk**: Wayland in GPU passthrough VMs can have display quirks (cursor rendering artifacts, VRR timing, multi-monitor arrangement). The X11 config is preserved as a rollback target.

---

## Phase 1: Pre-flight Checks

**Status**: ✅ Completed 2026-05-17

**Goal**: Confirm prerequisites are met and document current state before making any changes.

**Deliverables**:

- [x] Verify `nvidia-drm.modeset=1` is active in guest: `cat /proc/cmdline | grep modeset`
- [x] Confirm NVIDIA GBM library is present: `nvidia-drm_gbm.so` present at `/usr/lib/x86_64-linux-gnu/gbm/` (from `libnvidia-extra-580`)
- [x] Check GNOME session type available: `ubuntu-wayland.desktop` present in `/usr/share/wayland-sessions/`
- [x] Confirm `libnvidia-egl-wayland1` installed; `libnvidia-egl-gbm1` not a separate package — GBM backend bundled in `libnvidia-extra-580`
- [x] Record current X11 configs for rollback reference (already in `docs/109_GPU_SETUP.md`)

**Commands**:

```bash
ssh proxmox_main 'cat /proc/cmdline | grep modeset'
ssh proxmox_main 'ls /usr/lib/x86_64-linux-gnu/libgbm* /usr/lib/x86_64-linux-gnu/gbm/ 2>/dev/null'
ssh proxmox_main 'ls /usr/share/xsessions/ /usr/share/wayland-sessions/'
ssh proxmox_main 'dpkg -l gnome-shell | tail -1'
```

**Stability Criteria**: All prerequisites confirmed present. If GBM library or `gnome-wayland` session file is missing, install before proceeding.

**Notes**: All prerequisites met. GNOME 46.0, driver 580.142, modeset=1 confirmed. No missing packages.

---

## Phase 2: Enable Full Wayland

**Status**: ✅ Completed 2026-05-17

**Goal**: Re-enable the GDM Wayland greeter and ensure GNOME starts a Wayland user session by default.

**Deliverables**:

- [x] Re-enable Wayland greeter: `WaylandEnable=false` → `#WaylandEnable=false` in `/etc/gdm3/custom.conf`
- [x] Added `PreferredDisplayServer=wayland` to `/etc/gdm3/custom.conf` (needed — see Notes)
- [x] GBM backend confirmed via `nvidia-drm_gbm.so`; no extra env vars needed for driver 580
- [x] `libnvidia-egl-wayland1` confirmed installed
- [x] Restarted GDM; verified greeter session `c27` shows `Type=wayland`
- [x] Created `/etc/udev/rules.d/60-gdm-nvidia-wayland.rules` to make Wayland persistent across reboots (see Notes)

**Commands**:

```bash
# Re-enable Wayland greeter
ssh -tt proxmox_main 'sudo sed -i "s/^WaylandEnable=false/#WaylandEnable=false/" /etc/gdm3/custom.conf'

# Check EGL/GBM libraries
ssh proxmox_main 'dpkg -l libnvidia-egl-wayland1 libnvidia-egl-gbm1 2>/dev/null | grep ^ii'

# Restart GDM
ssh -tt proxmox_main 'sudo systemctl restart gdm3'

# Verify
ssh proxmox_main 'loginctl list-sessions'
ssh proxmox_main 'loginctl show-session <gdm-session-id> --property=Type'
```

**Stability Criteria**: `loginctl list-sessions` shows a `gdm` session with `Type=wayland`. GDM did not enter a failure restart loop.

**Notes**: Ubuntu's `61-gdm.rules` udev rule fires at boot for the NVIDIA PCI device and unconditionally writes `PreferredDisplayServer=xorg` to `/run/gdm3/custom.conf` (for all non-Dell NVIDIA systems), overriding `/etc/gdm3/custom.conf`. Two fixes applied:

1. `/run/gdm3/custom.conf` updated manually via `sudo /usr/libexec/gdm-runtime-config set daemon PreferredDisplayServer wayland` (current boot).
2. `/etc/udev/rules.d/60-gdm-nvidia-wayland.rules` created to set `GDM_PREFER_WAYLAND=1` before `61-gdm.rules` runs at next boot — this causes `61-gdm.rules` to take the `gdm_prefer_wayland` path instead of `gdm_prefer_xorg`.

---

## Phase 3: Verify Wayland User Session

**Status**: 🔄 In Progress

**Goal**: Log into GNOME on the physical display and confirm the user session runs on Wayland.

**Deliverables**:

- [ ] Log in at the physical display (enter password at GDM greeter — Wayland greeter confirmed running)
- [ ] Confirm session type: `echo $XDG_SESSION_TYPE` → should print `wayland`
- [ ] Confirm GNOME Shell is running Wayland: `loginctl show-session $(loginctl | grep proxmox-ml5 | awk '{print $1}') --property=Type`
- [ ] Confirm NVIDIA Wayland rendering: `glxinfo | grep -i renderer` (via Xwayland) or `eglinfo | grep NVIDIA`
- [ ] Check for obvious display issues: multi-monitor arrangement, cursor rendering, screen tearing

**Commands** (run inside VM after login, via SSH):

```bash
ssh proxmox_main 'echo $XDG_SESSION_TYPE'
ssh proxmox_main 'loginctl list-sessions'
# Check the user session type:
ssh proxmox_main 'loginctl show-session <user-session-id> --property=Type,Desktop'
ssh proxmox_main 'nvidia-smi'  # confirms GPU is in use
```

**Stability Criteria**: User session `Type=wayland`. GNOME Shell running. No immediate crash or fallback to X11.

**Notes**:

---

## Phase 4: Remove X11 Workarounds

**Status**: Not started

**Goal**: Clean up the X11-specific configurations that are no longer needed under full Wayland.

**Deliverables**:

- [ ] Remove `/etc/X11/xorg.conf.d/10-nvidia.conf` (BusID device section, X11-only)
- [ ] Revert `/etc/X11/Xwrapper.config` to `allowed_users=console` (remove `needs_root_rights=yes`)
- [ ] Optionally remove `gdm` from `video` group (Wayland compositors use logind/DRM leasing, not video group) — **skip if uncertain, harmless to keep**
- [ ] Restart GDM and re-verify Wayland session still works

**Commands**:

```bash
# Remove BusID xorg config
ssh -tt proxmox_main 'sudo rm /etc/X11/xorg.conf.d/10-nvidia.conf'

# Revert Xwrapper (optional — safe to leave as-is)
ssh -tt proxmox_main 'sudo sed -i "s/allowed_users=anybody/allowed_users=console/" /etc/X11/Xwrapper.config'
ssh -tt proxmox_main 'sudo sed -i "/needs_root_rights=yes/d" /etc/X11/Xwrapper.config'

# Restart and verify
ssh -tt proxmox_main 'sudo systemctl restart gdm3'
ssh proxmox_main 'loginctl list-sessions'
```

**Stability Criteria**: Wayland session still starts after removing X11 configs. GDM shows login screen without errors.

**Notes**:

---

## Phase 5: Update Documentation

**Status**: Not started

**Goal**: Update `docs/109_GPU_SETUP.md` to reflect the Wayland configuration and record the X11 configs as a rollback option.

**Deliverables**:

- [ ] Update the GDM section of `docs/109_GPU_SETUP.md`:
  - Change current config state to Wayland
  - Document the X11 workarounds as a "Rollback / Alternative: X11 stack" section
  - Add note on Wayland-specific known issues if any were observed in Phase 3
- [ ] Move this plan to `docs/Plans/Completed/`

**Stability Criteria**: `docs/109_GPU_SETUP.md` accurately reflects the running config.

**Notes**:

---

## Rollback

If Wayland causes blocking display issues (e.g., black screen, no output, unrecoverable crash), revert to the working X11 config via SSH:

```bash
# Restore Wayland=false
ssh -tt proxmox_main 'sudo sed -i "s/#WaylandEnable=false/WaylandEnable=false/" /etc/gdm3/custom.conf'

# Restore BusID xorg config
ssh proxmox_main 'sudo tee /etc/X11/xorg.conf.d/10-nvidia.conf' << 'EOF'
Section "Device"
    Identifier "nvidia"
    Driver "nvidia"
    BusID "PCI:1:0:0"
    Option "AllowEmptyInitialConfiguration"
EndSection
EOF

# Restore Xwrapper
ssh -tt proxmox_main 'sudo sed -i "s/allowed_users=console/allowed_users=anybody/" /etc/X11/Xwrapper.config'
ssh proxmox_main 'printf "needs_root_rights=yes\n" | sudo tee -a /etc/X11/Xwrapper.config'

# Restart
ssh -tt proxmox_main 'sudo systemctl restart gdm3'
```
