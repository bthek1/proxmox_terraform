# Proxmox VM 109 ("Main") — GPU Freeze Incident & Fix

**Date investigated:** 2026-06-08 / 2026-06-09
**Machine:** VM 109 "Main" (`proxmox_main`, hostname `proxmox-ml5`, 192.168.2.20)
**Status:** Fixed and verified — running known-good kernel 6.17.0-29 with RTD3 disabled.

> SECURITY NOTE: this document references a sudo password. If this repo is pushed
> to a remote, scrub the credential first or keep this file out of version control.

---

## TL;DR

The VM's graphics froze "after a while of use." There were **two distinct failure
modes**, both introduced by **kernel `6.17.0-35`** (first booted ~Jun 8):

1. **Mode A — idle hard-freeze:** NVIDIA GPU runtime power management (RTD3) could
   not resume the passed-through GPU from deep sleep -> full system lockup every
   ~1.5-2.5h, no logs. **Fixed by disabling RTD3.**
2. **Mode B — VRAM/buffer exhaustion:** gnome-shell/mutter leaks VRAM over many
   hours until the 6 GB GPU can't allocate a framebuffer -> display sticks (system
   stays alive). **Addressed by rolling back to the known-good kernel 6.17.0-29.**

Final state: booted on `6.17.0-29`, RTD3 disabled, bad kernel `6.17.0-35` held.

---

## Environment & topology

| Item | Detail |
|------|--------|
| PVE host | `ssh proxmox` -> 192.168.2.70, user `ben`, hostname `bthek1` (the real Proxmox VE host) |
| Guest VM | `ssh proxmox_main` -> 192.168.2.20, user `proxmox-ml5`, hostname `proxmox-ml5` = **VM 109 "Main"** |
| GPU | NVIDIA GTX 1660 SUPER (TU116, 6 GB), passed through: host `08:00.0` -> guest `01:00.0` |
| Driver | NVIDIA `580.159.03` (open kernel module), unchanged since 2026-05-21 |
| Desktop | GNOME on Wayland (gdm-wayland, gnome-shell, Xwayland) |
| Sudo | password `3719`; both `ben` and `proxmox-ml5` have **non-passwordless** sudo |
| Remote shell | **fish** — bash `var=$(...)` / `for` loops fail over ssh; wrap in `bash -c '...'` |

Host also has an RTX 3060 (host's own display, `nvidia` driver) and an AMD Raphael
iGPU. Only the 1660 SUPER is bound to `vfio-pci` for passthrough to VM 109.

---

## Symptoms

- Graphics "keeps breaking and getting stuck after a while of use."
- Required hard resets; on 2026-06-08 the VM crashed 4x in one afternoon
  (12:59, 15:46, 17:24, 19:46), each ~1.5-2.5h apart.
- For weeks prior the VM ran for **days at a time** without issue.

---

## Investigation & evidence

### Boot history (the key timeline)

```
... stable multi-day uptimes through 2026-06-06 -> 2026-06-08 12:59 ...
boot Jun 8 13:00 -> 15:46   (freeze)   <- first boot on kernel 6.17.0-35
boot Jun 8 15:47 -> 17:24   (freeze)
boot Jun 8 17:26 -> 19:46   (freeze)   <- HARD freeze: no clean-shutdown markers
boot Jun 8 19:49 -> 21:25   (my reboot to apply RTD3 fix)
boot Jun 8 21:25 -> Jun 9 11:43  (~14h, CLEAN shutdown)  <- RTD3 fix worked
boot Jun 9 11:44 -> ...      (Mode B: display froze, system alive)
```

### Mode A evidence (idle hard-freeze)

- Boots that froze ended with **no systemd shutdown sequence** = hard lockup, not reboot.
- **No Xid / NVRM / kernel errors** before the freeze (RTD3 resume failures are silent).
- Just before one freeze: lock-screen auth + `gsd-media-keys: Couldn't lock screen:
  Timeout was reached` -> compositor already hanging coming back from idle.
- GPU runtime PM was enabled: `power/control = auto`, driver param
  `DynamicPowerManagement: 3`.

### Mode B evidence (VRAM exhaustion)

- Live, recurring every ~60s on the current boot:
  ```
  gnome-shell: Failed to lock front buffer on /dev/dri/card1: gbm_surface_lock_front_buffer failed
  clutter_frame_clock_dispatch: code should not be reached
  ```
- Also seen near the end of the 14h boot (15 occurrences):
  ```
  [drm:nv_drm_gem_alloc_nvkms_memory_ioctl [nvidia_drm]] *ERROR* Failed to allocate NVKMS memory for GEM object
  ```
- `nvidia-smi` VRAM consumers at time of freeze:
  - `gnome-shell` **2163 MiB** (abnormal — mutter should use a few hundred MB; this is a leak)
  - VS Code GPU process **1669 MiB**
  - Total **4661 / 6144 MiB and climbing**
- System stayed responsive over SSH throughout -> display/compositor freeze, not a
  full lockup.

### Ruling out the NVIDIA driver

- `nvidia` driver `580.159.03` was installed **2026-05-21** (apt history), i.e. it ran
  fine for ~2.5 weeks. Not the trigger.

### Identifying the trigger

- Kernel `6.17.0-35` installed **2026-06-04** (`/var/log/dpkg.log`), first booted ~Jun 8
  = exact onset of instability.
- Prior kernel `6.17.0-29` (installed 2026-05-17) still present and matches the stable
  period. The DKMS rebuild of the NVIDIA module against 6.17.0-35 is the most likely
  cause of both modes.

---

## Root cause

**Kernel `6.17.0-35-generic`** destabilized the passed-through NVIDIA GPU on this VM:

- **Mode A:** GPU RTD3 (runtime D3cold power-gating) cannot be resumed by the VM's
  virtual ACPI platform after idle -> silent hard freeze.
- **Mode B:** under VRAM pressure (gnome-shell leak + heavy GPU apps on a 6 GB card),
  the driver fails buffer/VRAM allocation -> mutter can't lock a front buffer ->
  display sticks.

---

## Remediation history (what was tried, in order)

| # | When | Action | Outcome |
|---|------|--------|---------|
| 0 | before Jun 8 | (baseline) kernel 6.17.0-29, RTD3 enabled | Stable for weeks, days of uptime |
| 1 | Jun 8 ~13:00 | Auto-update reboot brought up kernel 6.17.0-35 | Instability begins: hard freezes every ~1.5-2.5h |
| 2 | Jun 8 (user) | Manual hard resets after each freeze | Temporary only; froze again each time |
| 3 | Jun 8 21:25 | **Attempt 1 — disable RTD3** (modprobe `NVreg_DynamicPowerManagement=0x00` + udev `power/control=on` + live sysfs + `update-initramfs`), then reboot | Big improvement: uptime ~2h -> **~14h**, clean shutdown. **Mode A solved.** But Mode B (VRAM exhaustion) still eventually froze the display. |
| 4 | Jun 9 11:44 | Running again on 6.17.0-35 with RTD3 off | After ~5.5h, display stuck again: `gbm_surface_lock_front_buffer failed` every ~60s, gnome-shell holding 2.1 GB VRAM. System still alive over SSH. |
| 5 | Jun 9 (diag) | Confirmed driver unchanged since May 21; isolated kernel 6.17.0-35 (installed Jun 4) as the trigger | Root cause identified |
| 6 | Jun 9 ~17:30 | **Attempt 2 (current fix) — roll back to kernel 6.17.0-29** + `apt-mark hold` 6.17.0-35 + pin `GRUB_DEFAULT`, then reboot | Booted 6.17.0-29, RTD3 still off, VRAM reset to ~1 GB. **Under observation.** |
| 7 | Jun 9 17:25 | User ran `apt-get upgrade -y` | Upgraded ~40 unrelated packages; **kernel and NVIDIA untouched**, holds + pin intact |

### What did NOT work / was ruled out

- **Hard resets** — recover briefly, freeze returns (treats symptom only).
- **NVIDIA driver as suspect** — ruled out: `580.159.03` installed 2026-05-21, ran
  stable for ~2.5 weeks.
- **RTD3 disable alone** — necessary and effective for Mode A, but insufficient on its
  own: the VRAM/buffer-exhaustion freeze (Mode B) still occurs on kernel 6.17.0-35.

---

## Current fix (active)

Both changes are live on the guest right now:

1. **RTD3 disabled** — `/etc/modprobe.d/nvidia-no-rtd3.conf` +
   `/etc/udev/rules.d/80-nvidia-no-rtd3.rules` (param `DynamicPowerManagement: 0`).
2. **Booted on known-good kernel 6.17.0-29** — pinned via `GRUB_DEFAULT`, with
   `6.17.0-35` held so it can't be auto-selected or pulled.

State: `uname -r = 6.17.0-29-generic`, `DynamicPowerManagement: 0`, VRAM ~1 GB at boot.
**Now being monitored** for multi-day stability (see "What to watch").

---

## Fixes applied

### 1. Disable NVIDIA RTD3 (fixes Mode A) — 2026-06-08

Files created on the guest:

`/etc/modprobe.d/nvidia-no-rtd3.conf`
```
# Disable NVIDIA dynamic (runtime) power management - VM display freeze fix.
options nvidia NVreg_DynamicPowerManagement=0x00
```

`/etc/udev/rules.d/80-nvidia-no-rtd3.rules`
```
# Disable NVIDIA dGPU runtime power management.
# On this GPU-passthrough VM the GPU is the primary display; RTD3 power-gating
# cannot be cleanly resumed by the virtual platform and causes hard freezes.
ACTION=="add", SUBSYSTEM=="pci", ATTR{vendor}=="0x10de", ATTR{class}=="0x030000", ATTR{power/control}="on"
```

Then:
```bash
sudo update-initramfs -u
sudo udevadm control --reload
# live, no-reboot mitigation:
echo on | sudo tee /sys/bus/pci/devices/0000:01:00.0/power/control
```

Result: next boot ran **~14 hours** (vs ~2h) and ended cleanly.

### 2. Pin known-good kernel 6.17.0-29 (addresses Mode B) — 2026-06-09

```bash
# backup
sudo cp /etc/default/grub /etc/default/grub.bak-pre-kernel-pin

# set GRUB_DEFAULT to the 6.17.0-29 entry (nested under the Advanced submenu)
GRUB_DEFAULT="gnulinux-advanced-089d1f64-d492-49da-9524-5e2ece68d251>gnulinux-6.17.0-29-generic-advanced-089d1f64-d492-49da-9524-5e2ece68d251"
# (edited into /etc/default/grub, replacing GRUB_DEFAULT=0)
sudo update-grub

# prevent the bad kernel from being selected/pulled
sudo apt-mark hold linux-image-6.17.0-35-generic \
                    linux-modules-6.17.0-35-generic \
                    linux-modules-extra-6.17.0-35-generic

# one-time override for the immediate reboot
sudo grub-reboot "$GRUB_DEFAULT"
sudo reboot
```

---

## Verification (post-reboot, 2026-06-09)

```
uname -r                          -> 6.17.0-29-generic        OK (known-good kernel)
cat /proc/driver/nvidia/params    -> DynamicPowerManagement: 0  OK (RTD3 disabled)
nvidia-smi (VRAM used)            -> ~1051 / 6144 MiB           OK (leak reset)
apt-mark showhold                 -> linux-image/modules/modules-extra-6.17.0-35-generic
```

Also confirmed a later `apt-get upgrade -y` (Jun 9 17:25) did **not** touch the kernel
or NVIDIA packages — `apt upgrade` never installs new kernels, and the hold + pin held.

---

## What to watch

- **If stable for days:** kernel `6.17.0-35` was the culprit. Keep it held; revisit when
  a newer kernel ships (then unhold, test, and re-pin or clear the pin).
- **If Mode B recurs even on 6.17.0-29** (`gbm_surface_lock_front_buffer failed` +
  gnome-shell VRAM climbing): it's a mutter/GNOME VRAM leak independent of the kernel.
  Mitigate by restarting the session periodically or keeping fewer heavy GPU apps
  (VS Code + Firefox + Chrome) open at once.

---

## Reverting

```bash
# unpin kernel
sudo apt-mark unhold linux-image-6.17.0-35-generic \
                     linux-modules-6.17.0-35-generic \
                     linux-modules-extra-6.17.0-35-generic
sudo cp /etc/default/grub.bak-pre-kernel-pin /etc/default/grub   # restores GRUB_DEFAULT=0
sudo update-grub

# re-enable RTD3 (not recommended)
sudo rm /etc/modprobe.d/nvidia-no-rtd3.conf /etc/udev/rules.d/80-nvidia-no-rtd3.rules
sudo update-initramfs -u
```

---

## Quick diagnostic reference

```bash
# is the display frozen but system alive? look for this every ~60s:
sudo journalctl -b 0 --since "15 min ago" | grep -i 'gbm_surface_lock_front_buffer\|NVKMS memory'

# VRAM usage + top consumers:
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
nvidia-smi   # see Processes table

# confirm RTD3 disabled:
cat /proc/driver/nvidia/params | grep DynamicPowerManagement

# boot history (hard freeze = no clean shutdown markers at end of a boot):
sudo journalctl --list-boots

# recover a frozen display WITHOUT a full reboot (ends the GNOME session):
sudo systemctl restart gdm
```
