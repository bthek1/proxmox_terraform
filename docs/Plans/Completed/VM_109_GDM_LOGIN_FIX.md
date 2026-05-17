# VM 109 — Fix GDM Login Crash (NVIDIA GPU Passthrough)

**Status**: ✅ Completed 2026-05-17

**Problem**: GDM login fails on VM 109 after entering password. The user session X server cannot acquire modesetting permission on the passed-through GTX 1660 SUPER because GDM's Wayland greeter holds exclusive DRM master on `/dev/dri/card1`.

**Root error** (`~/.local/share/xorg/Xorg.1.log`, session :1):

```
(EE) systemd-logind: failed to take device /dev/dri/card1: Device or resource busy
(EE) NVIDIA(GPU-0): Failed to acquire modesetting permission.
(EE) NVIDIA(0): Failing initialization of X screen
(EE) Screen(s) found, but none have a usable configuration.
(EE) no screens found
```

**Environment**:

- Host: Proxmox `bthek1` at `192.168.2.70` (SSH alias: `proxmox`)
- VM 109: Ubuntu 24.04, kernel `6.17.0-29-generic`, IP `192.168.2.20` (SSH alias: `proxmox_main`)
- GPU: GTX 1660 SUPER, passed through via VFIO (`hostpci0: 0000:07:00.0,pcie=1,x-vga=1`)
- NVIDIA driver in guest: `580.142` (open kernel module), CUDA 13.0
- Display manager: GDM3

**Already applied**:

- `nvidia-drm.modeset=1` in GRUB and `/etc/modprobe.d/nvidia-kms.conf` ✅
- GRUB rebuilt, all 4 kernel initramfs images regenerated ✅
- Stale USB passthrough entries removed from VM config ✅

---

## Phase 1: Disable GDM Wayland Compositor

**Status**: Not started

**Goal**: Stop GDM from running a Wayland compositor for the greeter session so it no longer holds exclusive DRM master, allowing the user session X server to acquire modesetting permission.

**Deliverables**:

- [ ] Edit `/etc/gdm3/custom.conf` inside VM 109 to add `WaylandEnable=false` under `[daemon]`
- [ ] Restart GDM (`sudo systemctl restart gdm3`) or reboot
- [ ] Confirm login succeeds: desktop appears after entering password

**Verification**:

```bash
# Confirm the setting took effect
ssh proxmox_main "grep -i wayland /etc/gdm3/custom.conf"

# Confirm GDM is running X11 greeter (not Wayland)
ssh proxmox_main "loginctl list-sessions"
# Should show session :0 as x11, not wayland

# Confirm the user session Xorg log no longer errors
ssh proxmox_main "cat ~/.local/share/xorg/Xorg.1.log | grep -E 'EE|modesetting permission' | tail -20"
```

**Stability Criteria**: User can log in to the VM 109 desktop via GDM without session crash.

**Notes**: If login succeeds, proceed to Phase 2. If GDM now launches an X11 greeter but login still fails with a different error, read the new Xorg.1.log and reassess.

**Commands**:

```bash
ssh -tt proxmox_main 'sudo bash -c "
  # Backup original
  cp /etc/gdm3/custom.conf /etc/gdm3/custom.conf.bak

  # Insert WaylandEnable=false under [daemon] section
  if grep -q \"^\[daemon\]\" /etc/gdm3/custom.conf; then
    sed -i \"/^\[daemon\]/a WaylandEnable=false\" /etc/gdm3/custom.conf
  else
    echo -e \"[daemon]\nWaylandEnable=false\" >> /etc/gdm3/custom.conf
  fi

  grep -A5 daemon /etc/gdm3/custom.conf
"'

ssh proxmox_main "sudo systemctl restart gdm3"
```

---

## Phase 2: Add Explicit NVIDIA Xorg Configuration

**Status**: Not started

**Goal**: Create `/etc/X11/xorg.conf.d/10-nvidia.conf` inside VM 109 so the NVIDIA driver is always explicitly selected for the GPU and `AllowEmptyInitialConfiguration` is set. This is required for headless passthrough setups where no monitor is physically connected.

**Deliverables**:

- [ ] Create `/etc/X11/xorg.conf.d/10-nvidia.conf` with `OutputClass` and `AllowEmptyInitialConfiguration`
- [ ] Reboot or restart GDM to confirm the new config is loaded
- [ ] Verify Xorg log shows the config being applied without errors

**Verification**:

```bash
# Confirm file exists and has correct content
ssh proxmox_main "cat /etc/X11/xorg.conf.d/10-nvidia.conf"

# Confirm Xorg picks it up (no new EE lines)
ssh proxmox_main "cat ~/.local/share/xorg/Xorg.0.log | grep -E 'EE|nvidia.conf|OutputClass' | tail -20"
```

**Stability Criteria**: Xorg.0.log (greeter session) loads the new config cleanly; login still works.

**Commands**:

```bash
ssh proxmox_main 'sudo tee /etc/X11/xorg.conf.d/10-nvidia.conf << EOF
Section "OutputClass"
    Identifier "nvidia"
    MatchDriver "nvidia-drm"
    Driver "nvidia"
    Option "AllowEmptyInitialConfiguration"
EndSection
EOF'
```

---

## Phase 3: Update Documentation

**Status**: Not started

**Goal**: Mark the issue as resolved in `docs/109_GPU_SETUP.md` and move this plan to `Completed/`.

**Deliverables**:

- [ ] Update `docs/109_GPU_SETUP.md` — change "Status: Fix identified; not yet applied" to confirmed fix with date
- [ ] Move this plan file from `In_progress/` to `Completed/`

**Stability Criteria**: Docs reflect actual working state of VM 109.

---

## Rollback

If Phase 1 breaks GDM entirely (no login screen):

```bash
# Restore backup
ssh proxmox_main "sudo cp /etc/gdm3/custom.conf.bak /etc/gdm3/custom.conf && sudo systemctl restart gdm3"
```

If that doesn't work, reboot the VM — GDM will restart on boot.
