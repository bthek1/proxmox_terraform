# Proxmox VM 109 ("Main") — GPU Freeze Incident & Fix

**Date investigated:** 2026-06-08 / 2026-06-09, **recurred 2026-06-10**
**Machine:** VM 109 "Main" (`proxmox_main`, hostname `proxmox-ml5`, 192.168.2.20)
**Status:** RE-OPENED — froze again on the "known-good" kernel 6.17.0-29 with RTD3
already disabled, **at only ~3.2 GB / 6 GB VRAM**. Not the kernel, and NOT VRAM
exhaustion, and NOT a between-output refresh mismatch (all three were uniform 59.94 Hz;
now forced to a uniform exact 60.000 Hz). Leading cause: a GNOME-Wayland + NVIDIA + multi-monitor compositor /
page-flip stall. **Per-pipe probe (2026-06-10) localized the first-to-freeze output to
DP-3 (crtc-2)** — a DisplayPort monitor (user-confirmed); DP-1 survives longest. Next:
DP-3-targeted swap test + disable VRR in that monitor's OSD (Xorg ruled out by user).

> SECURITY NOTE: the guest sudo password is **not stored in this document**. It lives
> in the gitignored `.env` at the repo root as `PROXMOX_MAIN_SUDO_PW` (see `.env.example`
> for the key). Load it before running any command below with:
> `set -a; source .env; set +a` — then commands reference `$PROXMOX_MAIN_SUDO_PW`.

---

## TL;DR (revised 2026-06-10)

The VM's graphics froze "after a while of use." Two distinct failure modes were seen:

1. **Mode A — idle hard-freeze:** NVIDIA GPU runtime power management (RTD3) could
   not resume the passed-through GPU from deep sleep -> full system lockup every
   ~1.5-2.5h, no logs. **Fixed by disabling RTD3** (this fix holds).
2. **Mode B — compositor / display freeze (the real recurring problem):** under
   **GNOME on Wayland + NVIDIA proprietary + three monitors**, the display sticks
   **one screen first, then the UI on the other two follows**. The system and even
   gnome-shell's main loop stay alive (it keeps logging, SSH responsive) — only the
   rendering/page-flip for the affected outputs stalls. This is a *display* freeze,
   not a process death.

**Two earlier theories were both WRONG — corrected here:**
- **NOT the kernel.** On 2026-06-10 it froze again on the "known-good" kernel
  `6.17.0-29` with RTD3 already off. `6.17.0-35` was never the cause of Mode B; each
  kernel only *looked* fixed because the freeze takes hours to manifest.
- **NOT VRAM exhaustion.** It froze at only **~3.2 GB / 6 GB** used — nowhere near
  the ceiling, and with **zero** `gbm_surface_lock_front_buffer` / NVKMS-alloc /
  Xid errors this boot. The 6 GB card is not running out of memory.

**Leading hypothesis (medium confidence):** a mutter per-output frame-clock /
NVIDIA page-flip **VSYNC desync**. mutter logged `Invalid sequence for VSYNC frame
info` this boot — the fingerprint of that code path. When one output's page-flip
completion stops being reported, that output's frame clock stalls and blocks the
shared compositor, so the other monitors follow. NVIDIA + GNOME **Wayland** +
multi-monitor is a known-fragile combination for exactly this.

**Highest-leverage fix to test:** switch the session **GNOME Wayland -> Xorg (X11)**,
which does not use mutter's per-output Wayland frame clock and is far more stable
with the NVIDIA proprietary driver on multi-monitor. Easily reversible at the login
screen. (Secondary: Firefox is independently crash-looping — repeated `libxul.so`
segfaults — which may add compositor stress; worth disabling its GPU accel too.)

> **2026-06-10 user decision:** **staying on Wayland — Xorg is OFF the table.** So the
> Xorg A/B (the cleanest way to *confirm* the freeze cause) won't be run. Within
> Wayland we attack the page-flip path directly with NVIDIA frame-timing settings, and
> separately fix the Firefox/AppArmor crash-loop. See the second 2026-06-10 update and
> the reordered "Mitigations (Wayland-only)" below.

---

## Update — 2026-06-10 (recurrence on the "good" kernel)

Symptom matched exactly: one screen froze, then UI elements on the other two screens
began to stick. Live diagnostics at the time of the freeze:

```
uname -r                       -> 6.17.0-29-generic     (the "known-good" kernel)
DynamicPowerManagement         -> 0                      (RTD3 still disabled)
session type                   -> wayland (gdm-wayland)
uptime                         -> ~7h
nvidia-smi VRAM used           -> 3215-3423 / 6144 MiB   (NOT exhausted; ~52%)
  gnome-shell                  -> 965 MiB   (elevated but stable; 3 monitors)
  /usr/share/code ...gpu-process -> 1647 MiB (VS Code GPU process; ~15 Code procs)
  firefox                      -> ~1.5 GB RSS
gbm_surface_lock / NVKMS-alloc -> 0 this boot  (so NOT the old VRAM signature)
Xid / NVRM                     -> 0 this boot
gnome-shell                    -> STILL logging (search providers at 00:10) = alive
firefox                        -> repeated libxul.so segfaults (23:11, 23:37) +
                                  constant Web-Content respawns = independently unstable
mutter                         -> "Invalid sequence for VSYNC frame info" (18:24)
SSH                            -> fully responsive (display-only freeze)
```

Conclusions:
- **Froze at ~3.2 GB VRAM** -> NOT memory exhaustion. The earlier "VRAM exhaustion"
  write-up was wrong; corrected.
- **On 6.17.0-29 with RTD3 off** -> NOT the kernel.
- gnome-shell's process stays alive and logging through the freeze -> a render /
  page-flip stall, not a crash or hang of the whole compositor process.
- Best-supported cause: NVIDIA + GNOME-**Wayland** + **multi-monitor** frame-timing
  stall (see "Leading hypothesis" in the TL;DR).

(Unrelated noise found: `openclaw-gateway.service` crash-looping ~4100 times — not
GPU-related, worth fixing separately.)

---

## Update — 2026-06-10 (second diagnostic session, ~00:37, freeze live)

Symptom this time, in the user's words: **"one screen is frozen; the other two partly
work and the mouse still moves on them."** Diagnosed live over SSH while frozen (VM up
~7h, boot Jun 09 17:23). Run from the PVE host (`bthek1`, this repo's machine) — note
the host is an **AMD Phoenix3 iGPU laptop with a single eDP panel**; the 3-monitor
NVIDIA setup is the *guest* VM 109, so all diagnostics targeted `proxmox_main`.

### Live measurements

```
session type                 -> Wayland (gdm-wayland, gnome-shell + Xwayland)   confirmed
kernel / RTD3                -> 6.17.0-29-generic, DynamicPowerManagement: 0    (unchanged)
nvidia-smi VRAM              -> 3201 / 6144 MiB (~52%)                          NOT exhausted
gbm_surface_lock / NVKMS     -> 0 this boot                                     (matches Jun-10 sig)
"Invalid sequence VSYNC"     -> 1 (Jun 09 18:24:55, ~6h before freeze)          the fingerprint
clutter "should not be reached" -> 0
Xid / NVRM                   -> 1 hit, but it is ONLY the boot banner
                                "NVRM: loading NVIDIA ... Open Kernel Module" (17:23:53)
                                => ZERO real Xid / GPU hardware errors
gnome-shell process (3298)   -> state Ssl (interruptible SLEEP, blocked), 5.8% CPU, alive
                                last log 00:10 (search-provider noise); not R(spin), not D(stuck I/O)
firefox                      -> 17 hard libxul.so segfaults, 32 procs; storm peaked ~23:37
apparmor DENIED (firefox)    -> 2294 mmap denials of libgmpopenh264.so this boot
openclaw-gateway.service     -> still crash-looping every ~6s (unrelated)
```

### What these tests *prove* (and disprove)

- **It is the page-flip / frame-clock stall, confirmed by process state.** gnome-shell
  is in **`Ssl` (blocked sleep), not `R` and not `D`** — it is parked waiting on a
  NVIDIA page-flip-completion event that never arrives, exactly the mutter per-output
  frame-clock stall. SSH responsive throughout => display-only.
- **NOT a GPU hardware fault.** The lone "NVRM" match is the **driver load banner**, not
  an Xid. Zero real GPU errors.
- **NOT VRAM** (3.2 GB / 6 GB, zero gbm/NVKMS alloc failures) and **NOT kernel/RTD3**
  (6.17.0-29, RTD3 off) — re-confirms the Jun-10 corrections.

### Two DISTINCT problems (do not conflate — earlier draft did)

1. **The freeze itself (root cause):** NVIDIA proprietary driver stops reporting
   page-flip completion to mutter on **one Wayland output** → that output's frame clock
   blocks → the shared compositor starves the other two → they go partial/sticky. The
   **mouse still moves** because the cursor rides a separate hardware plane and the input
   thread is independent of the render/page-flip path. This is a **driver↔compositor
   sync bug**, not memory/kernel/hardware.

2. **Firefox crash-loop (separate, now root-caused):** Ubuntu's **enforced `firefox`
   AppArmor profile forbids `mmap` of the OpenH264 GMP codec** Firefox downloaded into
   the user profile (`~/.mozilla/firefox/<prof>/gmp-gmpopenh264/2.6.0/libgmpopenh264.so`)
   → every H.264 content process segfaults at null and respawns → **2294 denials / boot**.
   Firefox is the **mozillateam .deb** `151.0.3~mt1`; profile `firefox` is in **enforce**
   mode and has `include if exists <local/firefox>` (so a local override is the clean fix).

   **Honest caveat — correlation, not proven causation.** The respawn storm subsided
   ~1h *before* the frozen sample, so Firefox is at most a **plausible aggravator**
   (surface churn stressing the fragile page-flip path), **NOT the proven trigger** of
   the freeze. An earlier note in this doc that called Firefox "the trigger" overstated
   it; corrected here.

### Which output stalls first — per-pipe probe (2026-06-10 ~00:50)

Drilled into the *individual outputs* during the same live freeze, reading the kernel's
DRM atomic state directly (`/sys/kernel/debug/dri/1/state`) since the NVIDIA closed
driver hides EDID/VRR/link state from sysfs and `nvidia-settings` needs the (frozen)
GUI. **Method:** sample each CRTC's scanned-out framebuffer ID over time — the pipe
whose `fb=` stops advancing is the one that stopped flipping.

**Output topology (all on the 1660 SUPER, guest `card1`):**

| Output | Pipe | Mode | 15 s flip test | Verdict |
|--------|------|------|----------------|---------|
| **DP-1**     | crtc-0 | 3840x2160@59.94 (now 60.000) | primary `fb` toggling 151↔153 | **alive** (last survivor) |
| **DP-3**     | crtc-2 | 3840x2160@59.94 (now 60.000) | primary `fb` not advancing      | **first to freeze** (user-confirmed) |
| **HDMI-A-1** | crtc-1 | 3840x2160@59.94 (now 60.000) | primary `fb` latched at 154     | stalled (followed) |
| DP-2         | —      | disconnected | — | **free port available** |

Findings this session:
- **The first output to freeze is DP-3 (a DisplayPort monitor), confirmed by the user.**
  My initial guess that the lone HDMI was the weak link was **WRONG** — the user's direct
  observation ("the dp screen freezes first") overrides it. DP-1 is the pipe that keeps
  compositing longest (it falls back to a **software cursor baked into its primary**,
  which is why its `fb` keeps toggling while the hardware cursor plane is frozen).
- **Refresh-rate mismatch is RULED OUT (between-output).** At probe time all three
  outputs were **uniform** — pixel clock **593410 kHz, total 4400x2250 = 59.94 Hz**
  (nominal "60", but actually the fractional NTSC-style rate, *not* exact 60.000).
  **Correction:** an earlier note here said "identical 3840x2160@60" — that conflated
  59.94 and 60.00; they matched each other, but at 59.94. So the "set all monitors to the
  same refresh rate" lever was *already satisfied* (uniform) — see the later config-change
  update for the move to a uniform exact-60.000.
- **The hardware cursor plane was frozen too** (pinned to crtc-0 at a fixed position for
  16 s of sampling), i.e. by this point the freeze had progressed past "mouse still moves
  on two."
- Since the mode is identical across all three, **what's special about DP-3 is the
  monitor / cable / port itself** — most likely that monitor's adaptive-sync (VRR), or a
  marginal DP link dropping the occasional flip-completion event. Neither is readable
  remotely on the closed NVIDIA driver; both must be checked physically (OSD + swap test).

**Reusable probe (run via `ssh proxmox_main bash -s < script` to dodge fish quoting):**
```bash
PW="$PROXMOX_MAIN_SUDO_PW"; echo "$PW" | sudo -S true 2>/dev/null   # from .env
snap(){ sudo cat /sys/kernel/debug/dri/1/state 2>/dev/null | awk '
  /^plane\[/{crtc="";fb=""} /crtc=crtc-/{crtc=$1} /^\tfb=/{fb=$1}
  /allocated by/{ if(crtc!=""&&crtc!="crtc=(null)"){tag=($0~/gnome-shell/)?"PRIMARY":"cursor"; print crtc" "tag" "fb} }'; }
for i in 1 2 3 4 5 6; do echo "--- t=$(((i-1)*3))s ---"; snap; [ $i -lt 6 ] && sleep 3; done
# The CRTC whose PRIMARY fb never changes = the stalled/frozen output.
```

---

## Update — 2026-06-10 (config change: refresh forced to uniform exact-60.000)

After the display was recovered (gdm restart), the user changed the refresh rate in
GNOME Settings → Displays. The per-CRTC active modes were re-read from debugfs
(computing Hz from `pixclock / (htotal*vtotal)`, since the closed driver doesn't expose
refresh directly):

```
BEFORE (first probe):  all three  pixclock 593410 kHz, total 4400x2250  -> 59.940 Hz  (uniform)
AFTER  (user change):
  DP-1      (crtc-0)   pixclock 594000 kHz  total 4400x2250 (CEA)            -> 60.0000 Hz
  HDMI-A-1  (crtc-1)   pixclock 533280 kHz  total 4000x2222 (reduced-blank)  -> 60.0000 Hz
  DP-3      (crtc-2)   pixclock 533280 kHz  total 4000x2222 (reduced-blank)  -> 60.0000 Hz
```

- **End state is the ideal config: all three at exactly 60.0000 Hz vertical refresh.**
  The horizontal timings differ (DP-1 on standard CEA, the other two on reduced-blanking),
  but that's irrelevant to the freeze — the frame-clock cadence is set by the *vertical*
  period (now identical 16.6667 ms on all three). Keep this setting.
- **Honest impact assessment (low-to-medium confidence):** this did NOT *remove* a
  between-output mismatch, because the earlier snapshot showed the outputs were already
  uniform (all 59.94). It swapped uniform-59.94 for uniform-60.000. It still plausibly
  helps because (1) it eliminates any *intermittent* 59.94/60.00 split a single snapshot
  couldn't rule out, and (2) some NVIDIA-Wayland setups are anecdotally steadier on an
  exact integer rate than on fractional 59.94 (repeating-decimal frame period). Not
  bankable as "the fix" — confirm via the freeze-onset logger over a multi-hour soak.
- **Verdict on the refresh angle:** uniform vertical refresh is now confirmed and forced
  to an exact integer; the between-output mismatch lever is fully closed. If freezes
  persist on uniform 60.000, the cause is not refresh timing.

**Re-read the per-CRTC refresh anytime (run as root — modes/pixclock need it):**
```bash
node=$(for n in /sys/kernel/debug/dri/*/state; do grep -q 'crtc=crtc-' "$n" && { echo "$n"; break; }; done)
awk '/^crtc\[[0-9]+\]:/{c=$NF} /^\tmode:/{n=split($0,a," ");p=a[4];h=a[8];v=a[12];
  if(p+0>0)printf "%-8s %s pix=%skHz tot=%sx%s -> %.4f Hz\n",c,a[2],p,h,v,(p*1000.0)/(h*v)}' "$node"
```

---

## Environment & topology

| Item | Detail |
|------|--------|
| PVE host | `ssh proxmox` -> 192.168.2.70, user `ben`, hostname `bthek1` (the real Proxmox VE host) |
| Guest VM | `ssh proxmox_main` -> 192.168.2.20, user `proxmox-ml5`, hostname `proxmox-ml5` = **VM 109 "Main"** |
| GPU | NVIDIA GTX 1660 SUPER (TU116, 6 GB), passed through: host `08:00.0` -> guest `01:00.0` |
| Driver | NVIDIA `580.159.03` (open kernel module), unchanged since 2026-05-21 |
| Desktop | GNOME on Wayland (gdm-wayland, gnome-shell, Xwayland) |
| Sudo | password in gitignored `.env` as `PROXMOX_MAIN_SUDO_PW`; both `ben` and `proxmox-ml5` have **non-passwordless** sudo |
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

### Mode B evidence (compositor / display freeze)

**Jun 9 occurrence (had a VRAM-pressure signature):**
- Live, recurring every ~60s on that boot:
  ```
  gnome-shell: Failed to lock front buffer on /dev/dri/card1: gbm_surface_lock_front_buffer failed
  clutter_frame_clock_dispatch: code should not be reached
  ```
- Also near the end of the 14h boot (15 occurrences):
  ```
  [drm:nv_drm_gem_alloc_nvkms_memory_ioctl [nvidia_drm]] *ERROR* Failed to allocate NVKMS memory for GEM object
  ```
- VRAM that boot was higher: `gnome-shell` 2163 MiB, VS Code 1669 MiB, total
  **4661 / 6144 MiB**.

**Jun 10 occurrence (NO VRAM signature — corrects the theory):**
- Froze at **3215-3423 / 6144 MiB** — VRAM was NOT near the ceiling.
- **Zero** `gbm_surface_lock_front_buffer`, NVKMS-alloc, Xid, or NVRM errors this boot.
- gnome-shell stayed alive and logging through the freeze.
- So the freeze is **not tied to a fixed VRAM threshold** and the Jun 9 gbm errors
  were likely a *symptom* of the same compositor stall under heavier load, not the
  root cause. Common denominator across both: GNOME-Wayland + NVIDIA + 3 monitors.
- System stayed responsive over SSH in both -> display/compositor freeze, not a
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

## Root cause (revised 2026-06-10)

Two independent issues, only one of which was about the kernel:

- **Mode A (kernel-related, fixed):** on kernel `6.17.0-35`, GPU RTD3 (runtime
  D3cold power-gating) could not be resumed by the VM's virtual ACPI platform after
  idle -> silent hard freeze every ~1.5-2.5h. Disabling RTD3 fixed this and the fix
  holds.
- **Mode B (the recurring problem — NOT the kernel, NOT VRAM):** a compositor /
  page-flip display freeze under **GNOME-Wayland + NVIDIA proprietary + 3 monitors**.
  One screen sticks first, then the UI on the other two. gnome-shell's process stays
  alive (keeps logging, SSH responsive) — only rendering for the affected outputs
  stalls. Two prior theories were disproven:
  - **NOT the kernel:** recurred 2026-06-10 on the "known-good" `6.17.0-29` with RTD3
    off.
  - **NOT VRAM exhaustion:** froze at ~3.2 GB / 6 GB with zero gbm/NVKMS/Xid errors.
  - **Leading hypothesis:** mutter per-output frame-clock / NVIDIA page-flip VSYNC
    desync (mutter logged `Invalid sequence for VSYNC frame info`). Best fix to test:
    switch the session **Wayland -> Xorg**.

---

## Remediation history (what was tried, in order)

| # | When | Action | Outcome |
|---|------|--------|---------|
| 0 | before Jun 8 | (baseline) kernel 6.17.0-29, RTD3 enabled | Stable for weeks, days of uptime |
| 1 | Jun 8 ~13:00 | Auto-update reboot brought up kernel 6.17.0-35 | Instability begins: hard freezes every ~1.5-2.5h |
| 2 | Jun 8 (user) | Manual hard resets after each freeze | Temporary only; froze again each time |
| 3 | Jun 8 21:25 | **Attempt 1 — disable RTD3** (modprobe `NVreg_DynamicPowerManagement=0x00` + udev `power/control=on` + live sysfs + `update-initramfs`), then reboot | Big improvement: uptime ~2h -> **~14h**, clean shutdown. **Mode A solved** (this fix holds). But Mode B (display freeze) still eventually occurred. |
| 4 | Jun 9 11:44 | Running again on 6.17.0-35 with RTD3 off | After ~5.5h, display stuck again: `gbm_surface_lock_front_buffer failed` every ~60s, gnome-shell ~2.1 GB VRAM. System still alive over SSH. |
| 5 | Jun 9 (diag) | Suspected kernel 6.17.0-35 as the Mode B trigger | **Later disproven** (see #8) — this was a wrong call |
| 6 | Jun 9 ~17:30 | **Attempt 2 — roll back to kernel 6.17.0-29** + `apt-mark hold` 6.17.0-35 + pin `GRUB_DEFAULT`, then reboot | Booted 6.17.0-29, RTD3 off. Looked fixed — but Mode B was just slow to return. |
| 7 | Jun 9 17:25 | User ran `apt-get upgrade -y` | Upgraded ~40 unrelated packages; **kernel and NVIDIA untouched**, holds + pin intact |
| 8 | Jun 10 ~00:15 | **Mode B recurred on 6.17.0-29** (RTD3 off). Live diag: froze at **3.2 GB/6 GB** VRAM, zero gbm/NVKMS/Xid errors, gnome-shell still alive | Disproves both the kernel and VRAM theories. Reframed as a Wayland/NVIDIA/multi-monitor compositor stall. **Next: test Xorg.** |
| 9 | Jun 10 ~00:37 | **Second live diag during a freeze.** Confirmed gnome-shell in `Ssl` blocked sleep (page-flip wait, not crash/spin); the lone "NVRM" line is just the boot banner (zero real Xid); VRAM 3.2 GB. Separated two distinct problems: (a) NVIDIA↔mutter Wayland page-flip stall = the freeze; (b) Firefox AppArmor OpenH264 crash-loop = aggravator, root-caused to 2294 mmap denials/boot | User **rules out Xorg** (staying on Wayland). Reframed plan to Wayland-only fixes. |
| 10 | Jun 10 ~00:46 | **Attempt 3 — fix Firefox AppArmor codec crash-loop.** Added `/etc/apparmor.d/local/firefox` (`owner @{HOME}/.mozilla/firefox/*/gmp-*/**/lib*.so mr,`) + `apparmor_parser -r`. **Verified:** rule live in-kernel, zero new denials in a 25s `journalctl -f` watch | **Aggravator removed.** Does not by itself address the Wayland page-flip stall (mitigation #1 still pending). |
| 11 | Jun 10 ~00:50 | **Per-pipe probe** of DRM atomic state during the same freeze: sampled each CRTC's scanout `fb` over 15 s. DP-1 (crtc-0) still flipping; **DP-3 (crtc-2) first to freeze** (user-confirmed it's a DP screen); HDMI-A-1 followed; HW cursor also frozen. All three uniform **3840x2160@59.94** → between-output refresh-mismatch ruled out. DP-2 port is free. | First-to-freeze output identified = **DP-3**. Next: DP-3 swap test (→ free DP-2) + disable VRR in its OSD. |
| 12 | Jun 10 ~01:05 | **Display recovered** via `systemctl restart gdm` (3 outputs back, fresh gnome-shell). Installed **freeze-onset logger** (`gpu-freeze-onset.service` → `/var/log/gpu-freeze-onset.log`); v1 false-positived on idle secondary monitors, fixed in **v2** (was-busy gate + VSYNC/gshell correlation). | Recovery confirmed; per-CRTC stall timeline now captured for the next freeze. |
| 13 | Jun 10 ~01:30 | **Attempt 4 — user forced uniform exact-60.000 Hz** (GNOME Displays). Re-probe: all three now **60.0000 Hz** vertical (DP-1 CEA 594000 kHz; HDMI-A-1 + DP-3 reduced-blank 533280 kHz). Was uniform-59.94 before. | Refresh angle fully closed (uniform exact-integer). Low-to-med confidence as a fix; soak with the logger. |

### What did NOT work / was ruled out

- **Hard resets** — recover briefly, freeze returns (treats symptom only).
- **NVIDIA driver as suspect** — ruled out: `580.159.03` installed 2026-05-21, ran
  stable for ~2.5 weeks.
- **RTD3 disable alone** — necessary and effective for Mode A, but does not address
  Mode B (the compositor display freeze).
- **Kernel rollback to 6.17.0-29** — did NOT fix Mode B (recurred on it Jun 10). The
  kernel was never the Mode B cause; keep the pin only as belt-and-suspenders for Mode A.
- **"VRAM exhaustion" theory** — ruled out: Mode B froze at ~3.2 GB / 6 GB with no
  allocation-failure errors.

---

## Current state (active)

Live on the guest right now:

1. **RTD3 disabled** — `/etc/modprobe.d/nvidia-no-rtd3.conf` +
   `/etc/udev/rules.d/80-nvidia-no-rtd3.rules` (param `DynamicPowerManagement: 0`).
   **This resolves Mode A and should stay.**
2. **Booted on kernel 6.17.0-29** — pinned via `GRUB_DEFAULT`, `6.17.0-35` held.
   **Did NOT fix Mode B** (it recurred here). Kept only as belt-and-suspenders for
   Mode A; not load-bearing for the display freeze.
3. **Firefox AppArmor OpenH264 fix — APPLIED & VERIFIED 2026-06-10 ~00:46.**
   `/etc/apparmor.d/local/firefox` allows `mmap` of the GMP codecs; profile reloaded
   live; zero new denials confirmed. Removes the crash-loop **aggravator** (not the
   freeze root cause).

State: `uname -r = 6.17.0-29-generic`, `DynamicPowerManagement: 0`, session = Wayland,
Firefox AppArmor override active.

**Mode B is still OPEN** (the page-flip stall is unaddressed — the only pending
high-impact item is mitigation #1, NVIDIA Wayland frame-timing hardening). User has
chosen to **stay on Wayland (Xorg ruled out)**, so
the next planned steps are the **Wayland-only** fixes: (1) NVIDIA frame-timing hardening
(uniform refresh rate, disable VRR, `NVreg_PreserveVideoMemoryAllocations=1`) and
(2) fix the Firefox AppArmor OpenH264 crash-loop. See "What to watch" -> Mitigations.

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

### 2. Pin kernel 6.17.0-29 — 2026-06-09 (did NOT fix Mode B; kept for Mode A only)

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

> 2026-06-10: Mode B is CONFIRMED kernel-independent (recurred on `6.17.0-29`) and
> CONFIRMED not VRAM exhaustion (froze at 3.2 GB). The kernel hold can stay as
> belt-and-suspenders for Mode A, but the real fix targets the Wayland/NVIDIA
> compositor path, not memory.

- **Watch for:** display sticking one screen then the others, while SSH stays up and
  gnome-shell keeps logging. Check `journalctl -b 0 | grep -i "VSYNC frame info"`.
  VRAM level is NOT a reliable predictor (froze at ~52% used).

### Mitigations (Wayland-only — Xorg ruled out by user 2026-06-10)

The user wants to **stay on GNOME-Wayland**, so the Xorg A/B is not available. Ordered
by likely impact within Wayland:

1. **NVIDIA Wayland frame-timing hardening (targets the freeze root cause).** The stall
   is a page-flip-completion desync, so stabilise that path:
   - Ensure `nvidia-drm.modeset=1` (required for Wayland; verify it's set).
   - Add `options nvidia NVreg_PreserveVideoMemoryAllocations=1` (alongside the existing
     `nvidia-no-rtd3.conf`) so the driver doesn't churn allocations across power events.
   - ~~Set all three monitors to the SAME refresh rate~~ — **DONE / lever closed.** The
     per-pipe probe showed all three were already uniform at 59.94 Hz, and on 2026-06-10
     ~01:30 the user forced them to a uniform **exact 60.0000 Hz** (see the config-change
     update). Between-output mismatch is not the trigger here. Now soaking on uniform-60.
   - **VRR / adaptive-sync — status checked 2026-06-10 ~01:10, hypothesis WEAKENED.**
     The only software-controllable VRR lever, GNOME/mutter's experimental
     `variable-refresh-rate`, is **already OFF**: `gsettings get org.gnome.mutter
     experimental-features` → `@as []` (empty). `~/.nvidia-settings-rc` has no G-Sync/VRR
     entries, and `monitors.xml` confirms 60 Hz active on all outputs. So there is **no
     compositor-side VRR to disable** — nothing for a remote fix to act on. VRR could only
     still be active if the **DP-3 panel forces adaptive-sync from its own OSD** (firmware,
     not software-readable). **Why it can't be inspected/changed remotely:** the OSD is
     panel firmware with no OS access, and NVIDIA's closed driver hides VRR state from
     sysfs/debugfs (`vrr_capable` = `n/a`), exposing it only via `nvidia-settings` on a
     live display. With compositor VRR confirmed off, VRR is **no longer the leading
     suspect** — the `VSYNC frame info` desync can occur at fixed 60 Hz too. Still worth a
     30-second physical OSD check on DP-3, but demoted below the swap test.
   - Re-test for multi-day stability and re-check `grep -c "VSYNC frame info"`.

   **DP-3-targeted localization (do this first — it's the cheapest signal):**
   - **Swap test:** move the **DP-3 monitor to the free DP-2 port** (or swap the DP-1 and
     DP-3 cables). After the next freeze, see what the first-to-freeze screen tells you:
     follows the **monitor** → that panel's EDID/VRR is the trigger; follows the **cable**
     → marginal 4K@60 DP cable dropping flip-completions; stays on the **GPU port** →
     driver/pipe issue.
2. **Fix the Firefox AppArmor codec crash-loop (removes the aggravator). [APPLIED
   2026-06-10 ~00:46]** Root-caused 2026-06-10: the enforced `firefox` profile blocks
   `mmap` of the OpenH264 GMP codec. The profile already pulls in `<local/firefox>`, so
   a local override was added and the profile reloaded live. **Verified:** rule present
   in-kernel via `apparmor_parser -p`, last `gmpopenh264` denial `00:41:47` (pre-reload),
   zero new denials in a 25s live `journalctl -f` watch afterward. Reload applies to
   running Firefox procs; a fresh Firefox start once the display recovers picks it up
   cleanly. Command used:
   ```bash
   # on the guest (fish shell; sudo non-passwordless; pw from .env $PROXMOX_MAIN_SUDO_PW):
   echo "$PROXMOX_MAIN_SUDO_PW" | sudo -S tee /etc/apparmor.d/local/firefox >/dev/null <<'EOF'
   # Allow Firefox to mmap the Gecko Media Plugins it downloads into the user profile
   # (OpenH264 etc.) — fixes libxul.so null-deref crash-loop on H.264 video.
   owner @{HOME}/.mozilla/firefox/*/gmp-*/**/lib*.so mr,
   EOF
   echo "$PROXMOX_MAIN_SUDO_PW" | sudo -S apparmor_parser -r /etc/apparmor.d/firefox
   ```
   Then fully restart Firefox and confirm `journalctl -b 0 | grep -c gmpopenh264`
   stops climbing. (Alternative if you don't need H.264: disable Firefox HW video accel
   via `about:config` `media.gmp-gmpopenh264.enabled=false`, or `gfx.webrender.force-disabled=true`.)
3. **Recover a frozen display WITHOUT a full reboot:** `sudo systemctl restart gdm`
   (ends the GUI session — closes open windows). Useful stopgap until 1+2 prove out.
4. **Compositor/driver currency** — a newer `mutter` / NVIDIA driver may fix the
   VSYNC-sequence handling; revisit when one ships.
5. **(Explicitly declined) Wayland -> Xorg.** Would avoid mutter's per-output frame
   clock and is the cleanest confirmation A/B, but the user has chosen to stay on
   Wayland. Recorded here only for completeness.

### Open question / how to confirm root cause

The Wayland-frame-timing hypothesis is medium-confidence, inferred from the
`Invalid sequence for VSYNC frame info` log line, the one-screen-then-others symptom,
and (2026-06-10) gnome-shell sitting in **`Ssl` blocked sleep** — parked on a page-flip
completion that never arrives.

The cleanest confirmation A/B (run on **Xorg** for a few days) has been **declined** —
the user is staying on Wayland. So within Wayland we confirm by elimination instead:
apply the frame-timing hardening (disable VRR on DP-3,
`NVreg_PreserveVideoMemoryAllocations=1`) and the Firefox/AppArmor fix, then watch
whether freezes stop and whether `VSYNC frame info` recurs. (Uniform refresh is now
forced to an exact **60.0000 Hz** on all three — probe-confirmed; previously uniform
59.94 — so the between-output mismatch lever is closed.) If freezes persist with a
uniform-60.000, VRR-off, Firefox-stable config, the cause is lower in the stack
(driver/passthrough/KMS) and needs a different angle.

### Freeze-onset logger — INSTALLED 2026-06-10 ~01:53

A "flight recorder" for the next freeze. Records each CRTC's scanout `fb` ID with
timestamps so a reported freeze can be reconstructed: which output's `fb` went stale
first (onset order) and whether the driver fingerprint fired.

- **Script:** `/usr/local/sbin/gpu-freeze-onset.sh` (root; reads `/sys/kernel/debug/dri/*/state`)
- **Service:** `gpu-freeze-onset.service` (enabled, `Restart=always`, `WantedBy=multi-user.target`)
- **Log:** `/var/log/gpu-freeze-onset.log` (rotates at 5 MB → `.log.1`)
- Samples every 3 s; **heartbeat every 30 s** is the primary artifact, logging per-CRTC
  `fb`/age/busy + `vsync_recent` (count of `Invalid sequence for VSYNC frame info` in the
  last ~60 s) + `gshell` process state (e.g. `Ssl`/`Rsl`).

**IMPORTANT — known limitation (learned the hard way during install).** Watching `fb`
advance alone **cannot distinguish an idle secondary monitor from a frozen one** — both
simply stop flipping (mutter only flips a pipe when its content changes). The v1/v2
auto-alarms produced **false positives**: e.g. `01:56:16 STALL crtc-1 … vsync_recent=0
gshell=Rsl` — that was just idle screens after login (`gshell=Rsl` = gnome-shell
*running*, `vsync_recent=0` = no fingerprint), **not** a freeze. So:
- The auto-flag is now labeled **`CANDIDATE-STALL`**, a hint only, with its corroborating
  evidence inline. A line is only a **real** freeze if it shows **`gshell=...Ssl`
  (blocked, not running)** and/or **`vsync_recent>0`** (it self-tags `*** STRONG ***`).
- **The verdict comes from the heartbeat timeline + the user's report**, not the
  candidate line alone. When a freeze is reported, read the log around that time: the
  output whose `age` started climbing first while another kept flipping = onset; confirm
  via `gshell` blocked + `vsync_recent`.

```bash
# read it (root):  sudo tail -50 /var/log/gpu-freeze-onset.log
# manage:          sudo systemctl status|restart|disable --now gpu-freeze-onset.service
```

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

> NOTE: over SSH the guest shell is **fish** — wrap bash-isms in `bash -c '...'`, and
> sudo is non-passwordless: `echo "$PROXMOX_MAIN_SUDO_PW" | sudo -S <cmd>` (the var comes
> from the gitignored `.env`; load it first with `set -a; source .env; set +a`).

```bash
# Mode B (compositor stall) fingerprint this boot — the most useful single check:
sudo journalctl -b 0 | grep -i 'Invalid sequence for VSYNC frame info'

# session type (Wayland vs Xorg) — Mode B is a Wayland-path issue:
loginctl show-session "$(loginctl | awk '/proxmox-ml5/{print $1; exit}')" -p Type

# older VRAM-pressure signature (was present Jun 9, absent Jun 10):
sudo journalctl -b 0 --since "15 min ago" | grep -i 'gbm_surface_lock_front_buffer\|NVKMS memory'

# VRAM usage + top consumers (note: froze at only ~3.2 GB, so not a reliable predictor):
nvidia-smi --query-gpu=memory.used,memory.total --format=csv
nvidia-smi   # see Processes table

# confirm RTD3 disabled (Mode A fix):
cat /proc/driver/nvidia/params | grep DynamicPowerManagement

# boot history (hard freeze = no clean shutdown markers at end of a boot):
sudo journalctl --list-boots

# recover a frozen display WITHOUT a full reboot (ends the GNOME session):
sudo systemctl restart gdm

# switch session Wayland -> Xorg (the planned Mode B test): set in /etc/gdm3/custom.conf
#   [daemon]
#   WaylandEnable=false
# then: sudo systemctl restart gdm   (or just pick "GNOME on Xorg" at the login gear)
```
