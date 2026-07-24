# VM 109 — Peripheral Passthrough Map

Full map of how the Proxmox host's peripherals reach VM 109 ("Main" — this workstation) and the LXC containers. Verified live against `qm config 109`, `lspci`/`lsusb` on host and guest on **2026-07-24** (webcam swap day: MX Brio refunded → Logitech C922).

Companion docs: [109_GPU_PASSTHROUGH.md](109_GPU_PASSTHROUGH.md) (GPU/display stack detail), [PROXMOX_INVENTORY.md](PROXMOX_INVENTORY.md), [Incident/proxmox-vm109-gpu-freeze-incident.md](Incident/proxmox-vm109-gpu-freeze-incident.md) (Modes C–E: every controller-passthrough failure), [ports.md](../ports.md) (rear socket → controller map).

---

## Forwarded to VM 109

| Peripheral | Host address / USB ID | Method | Config entry | Appears in guest as |
|---|---|---|---|---|
| NVIDIA GTX 1660 SUPER (all functions: VGA + HDMI audio + USB-C + UCSI) | PCI `08:00.0`–`.3` | PCIe passthrough, primary GPU (`x-vga=1`) | `hostpci0: 0000:08:00` | `01:00.x` |
| AMD HD Audio controller | PCI `10:00.6` | PCIe passthrough | `hostpci1` | `02:00.0` (PipeWire analog-stereo sink) |
| **Keyboard** — Kensington 2.4G dongle | `047d:8188` | Per-device USB redirection (QEMU emulated) | `usb2` | emulated bus |
| Webcam — **Logitech C922 Pro Stream** (replaces the MX Brio, refunded 2026-07-24) | `046d:085c` | Per-device USB redirection. Native USB 2.0 device (1080p30 / 720p60 MJPEG, stereo mic @32 kHz) — no SuperSpeed modes exist to go wrong. **Forwarded & verified 2026-07-24**: video streams; mic measured CLEAN under sustained 1080p load (sample jumps ≤631, peaks −27 dB — no iso-contention corruption, unlike the Brio). Low light halves fps via auto-exposure (~15–20 fps) — add light or fix exposure for 30 fps | `usb3` | emulated bus |
| **Mouse** — Compx 2.4G receiver (lsusb mislabels it "MR-K013 Multicard Reader"; it's a HID input device, user-confirmed mouse 2026-07-24 — there is no card reader on this machine) | `25a7:fa61` | Per-device USB redirection (QEMU emulated) | `usb4` | emulated bus |
| Bluetooth radio (IMC/Realtek) | `13d3:3571` | Per-device USB redirection (QEMU emulated) | `usb1` | emulated bus, `hci0` |

| ~~UGREEN 2K webcam~~ → **moved to LXC 205** (2026-07-24 evening) | `1bcf:2284` | Host owns it (`uvcvideo`); its `/dev/video0`/`video1` nodes are device-passed into **LXC 205 (knowledge-lab)** as `dev5`/`dev6` (`mode=0666`, hotplugged into the running CT, capture verified). VM 109's `usb5` entry deleted. ⚠️ Host video indices can renumber if cameras are re-plugged — re-check `dev5`/`dev6` paths then | `pct` `dev5`/`dev6` on CT 205 | `/dev/video0`/`video1` in CT 205 |

## Stays on the Proxmox host

| Peripheral | Why |
|---|---|
| NVIDIA RTX 3060 (`01:00.0`, `/dev/nvidia0`) | Shared into LXCs 106/107/202/205 via `dev0:`–`dev4:` entries (`nvidia0`, `nvidiactl`, `nvidia-uvm`, `nvidia-uvm-tools`, `nvidia-modeset`, all `mode=0666`) |
| ASUS AURA LED controller (`0b05:19af`) | Host OpenRGB service — must **never** be passed to a VM ([OPENRGB_SERVER_SETUP.md](OPENRGB_SERVER_SETUP.md)) |
| USB 3.2 controller (AMD 600 chipset, `0c:00.0`, ID `1022:43f7`) | **Was** passed whole as `hostpci2` until 2026-07-22. Removed: its event ring corrupted repeatedly under passthrough (dmesg `not part of TD` floods → dead camera streams, stuck mouse), unrecoverable from the guest. Desk devices on its ports are now forwarded per-device instead. |

---

## Design rationale

- **Everything is per-device redirection now (2026-07-22, second revision).** The whole-controller passthrough of `0c:00.0` was tried first (native 5 Gbps, needed for raw YUYV/4K on the Brio) but the controller's xHCI event ring corrupted repeatedly under vfio (`not part of TD` floods; stuck mouse; camera streams returning 0 frames), and no guest-side reset recovers it — only a full VM STOP+START or host reboot. Since only 1080p30 is needed (fits MJPEG over the emulated 480 Mbps path, the same path where BT + UGREEN have been stable), the controller passthrough was dropped in favor of `usb2`–`usb4` forwards.
- **Brio format caveat over emulated USB:** use **MJPEG** (1080p30, 1080p60). Raw YUYV 1080p and 4K modes need more than 480 Mbps and will not work. An earlier incident (Mode C display freeze) happened under emulated redirection while GPU passthrough was also unstable; if freezes recur, see the incident doc before blaming the webcam.
- **`hostpci` must be address-based, not ID-based** (relevant if the controller passthrough is ever restored). `0c:00.0` and the AURA's controller `0e:00.0` share PCI ID `1022:43f7` — adding that ID to `vfio.conf` would steal the AURA controller from the host.
- **All-functions GPU passthrough (2026-07-22):** `hostpci0` changed from `0000:08:00.0` (VGA only) to `0000:08:00` so the guest also gets the HDMI/DP audio function (`08:00.1`, was already vfio-bound and unused) plus the card's USB-C controller (`.2`, no devices attached) and UCSI (`.3`). Enables monitor-speaker audio. Applies on the next **QEMU restart** (see below). Rollback: `sudo qm set 109 -hostpci0 0000:08:00.0,pcie=1,x-vga=1`.

---

## Gotchas

- **`hostpci`/`usb` config changes need a QEMU restart, not a guest reboot.** Use the Proxmox UI *Reboot* button or `sudo qm reboot 109` on the host. A `reboot` from inside the guest restarts the OS but not the QEMU process, so pending changes do not apply.
- **QEMU refuses to start if a `usb-host` entry's device is unplugged.** Keep entries only for permanently attached devices; hot-plug anything else via the web UI. (Bit us during the Brio→C922 swap: the stale `046d:0944` entry was a cold-start blocker until replaced with `host=046d:085c` on 2026-07-24.)
- **QEMU forwards a device at whatever speed the HOST negotiated — and cannot downgrade it.** Verified 2026-07-23: removing/adding the `usb3=1` flag does not change the attachment; a host-SS device always attaches SS in the guest. And **QEMU's emulated xHCI (even QEMU 11.0 / PVE 9.2.3) cannot carry a SuperSpeed UVC isochronous stream**: at SS attachment, 1080p and even 640×480 MJPEG deliver 0 frames with `not part of TD` floods; 320×240 delivers frames but still logs ring errors (matches the earlier green-frames observation). The `uvcvideo` `FIX_BANDWIDTH` quirk (128) does not help. There is no config-level fix — SS through the forward is a dead end.
- **Workaround in place — rear USB-C port is forced to USB 2.0:** host udev rule `/etc/udev/rules.d/90-usbc-port-force-usb2.rules` writes `disable=1` to the chipset 20G root hub's port 1 (`usb2-port1`), so the Brio's C-to-C connection falls back to a 480M link, where 1080p30 MJPEG is verified clean (29.3 fps sustained, 0 errors). Manual re-apply: `echo 1 > /sys/bus/usb/devices/usb2/2-0:1.0/usb2-port1/disable`.
- **UVC probe stalls (`-32`/`-110`, EIO on open) after an attach**: re-running `qm set 109 -usb3 host=046d:0944` (live re-attach) clears it. Also seen: one physical port (host 1-3) had degraded iso bandwidth (~19 fps at 1080p) — moving ports fixed it.
- ⛔ **CPU controllers `10:00.3`/`10:00.4` (Raphael xHCI) must NEVER be passed to a guest — tried 2026-07-24, instant HOST hard-reset.** The earlier plan here ("alone in IOMMU group, working `pm` reset → ideal candidates") was wrong: the advertised reset is broken in hardware, and `hostpci2: 0000:10:00.4` + `qm reboot 109` power-cycled the whole host with no log trace, then **crash-looped the host on every boot** while `startall` retried VM 109 (`onboot`). Reverted same day (`--delete hostpci2`, `usb3` forward restored). The native-SuperSpeed path for the Brio is fully exhausted (chipset `0c:00.0` reset-loops the Brio; CPU xHCIs kill the host) — 1080p30 MJPEG over USB 2.0 redirection is permanent. Full write-up: [incident doc, Mode E](Incident/proxmox-vm109-gpu-freeze-incident.md#update--2026-07-24-mode-e-cpu-xhci-10004-passthrough--instant-host-hard-reset--boot-crash-loop--reverted-do-not-retry).
- **UGREEN cam is a native USB2 device** — 480M is its ceiling; MJPEG 2K fine.
- **Historical (Brio refunded 2026-07-24 — kept for the general lesson): mic crackles while 1080p video streams over an emulated forward.** Watch for the same effect on the C922: its mic + 1080p30 MJPEG share one 480M iso pipe through the same QEMU xHCI, so test audio under sustained video + typing load before trusting it (clean reference: sample-jump ≤~4k, peaks well below −10 dB; corruption signature: bursts peaking ~−1 dB). Original finding follows.
- **Brio mic crackles while 1080p video streams** (verified 2026-07-23): 1080p30 MJPEG saturates the 480M iso pipe and audio packets corrupt (near-full-scale clicks). Clean with 720p video or audio-only. The Brio is the ONLY USB mic in the guest (UGREEN is unplugged; when it was forwarded it exposed no capture device here — do not plan around its mic). Alternatives for 1080p-video-plus-mic: ALC897 analog jack (`hostpci1` audio) or a BT headset — or drop to 720p when the Brio mic is needed (video-call apps use ≤720p anyway). A SuperSpeed link is NOT a fix — see above, green frames. **Update 2026-07-24:** a proper USB 3.0 cable didn't change the link (still 480M on that port) and sustained-load retests show the corruption is intermittent at BOTH 1080p and 720p (bursts of clicks peaking at exactly −1.0 dB — a deterministic digital artifact). Short tests right after stream start look clean; always test with video running 30 s+. Practical rule: video from the Brio, audio from anything else.

---

## Verification

```bash
# Host side (ssh proxmox)
sudo qm config 109 | grep -E 'hostpci|usb'   # hostpci0/1 only; usb1-usb5 entries
lspci -k -s 08:00.0        # expect: vfio-pci
lspci -k -s 0c:00.0        # expect: xhci_hcd (back on host since 2026-07-22)
lsusb                      # all five forwarded devices visible (usbfs), plus AURA LED

# Guest side (this machine)
lsusb                      # keyboard, mouse, BT, C922 (046d:085c) — all on emulated buses
nvidia-smi                 # GTX 1660 SUPER
lspci | grep -i audio      # AMD audio at 02:00.0 (+ NVIDIA audio at 01:00.1 after all-functions reboot)
hciconfig                  # hci0 UP RUNNING
ls /dev/video*             # both cameras
```
