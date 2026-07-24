# VM 109 — Peripheral Passthrough Map

Full map of how the Proxmox host's peripherals reach VM 109 ("Main" — this workstation) and the LXC containers. Verified live against `qm config 109`, `pct config`, `lspci`/`lsusb` on host and guest on **2026-07-22**.

Companion docs: [109_GPU_PASSTHROUGH.md](109_GPU_PASSTHROUGH.md) (GPU/display stack detail), [PROXMOX_INVENTORY.md](PROXMOX_INVENTORY.md), [Incident/proxmox-vm109-gpu-freeze-incident.md](Incident/proxmox-vm109-gpu-freeze-incident.md) (why the USB controller is passed whole).

---

## Forwarded to VM 109

| Peripheral | Host address / USB ID | Method | Config entry | Appears in guest as |
|---|---|---|---|---|
| NVIDIA GTX 1660 SUPER (all functions: VGA + HDMI audio + USB-C + UCSI) | PCI `08:00.0`–`.3` | PCIe passthrough, primary GPU (`x-vga=1`) | `hostpci0: 0000:08:00` | `01:00.x` |
| AMD HD Audio controller | PCI `10:00.6` | PCIe passthrough | `hostpci1` | `02:00.0` (PipeWire analog-stereo sink) |
| Kensington 2.4G dongle (kb/mouse) | `047d:8188` | Per-device USB redirection (QEMU emulated) | `usb2` | emulated bus |
| Logitech MX Brio 4K webcam | `046d:0944` | Per-device USB redirection — **MJPEG only**. Physically in the rear USB-C port (C-to-C cable) whose SuperSpeed lanes are deliberately disabled host-side (see Gotchas) so it links USB 2.0 | `usb3` | emulated bus |
| Card reader (MR-K013) | `25a7:fa61` | Per-device USB redirection (QEMU emulated) | `usb4` | emulated bus |
| Bluetooth radio (IMC/Realtek) | `13d3:3571` | Per-device USB redirection (QEMU emulated) | `usb1` | emulated bus, `hci0` |

> **UGREEN 2K webcam (`1bcf:2284`)**: unplugged 2026-07-23; its `usb5` entry was removed so the VM can still cold-start (QEMU refuses to boot with a `usb-host` entry whose device is absent). To restore when replugged: `sudo qm set 109 -usb5 host=1bcf:2284`.

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
- **QEMU refuses to start if a `usb-host` entry's device is unplugged.** Keep entries only for permanently attached devices; hot-plug anything else via the web UI.
- **QEMU forwards a device at whatever speed the HOST negotiated — and cannot downgrade it.** Verified 2026-07-23: removing/adding the `usb3=1` flag does not change the attachment; a host-SS device always attaches SS in the guest. And **QEMU's emulated xHCI (even QEMU 11.0 / PVE 9.2.3) cannot carry a SuperSpeed UVC isochronous stream**: at SS attachment, 1080p and even 640×480 MJPEG deliver 0 frames with `not part of TD` floods; 320×240 delivers frames but still logs ring errors (matches the earlier green-frames observation). The `uvcvideo` `FIX_BANDWIDTH` quirk (128) does not help. There is no config-level fix — SS through the forward is a dead end.
- **Workaround in place — rear USB-C port is forced to USB 2.0:** host udev rule `/etc/udev/rules.d/90-usbc-port-force-usb2.rules` writes `disable=1` to the chipset 20G root hub's port 1 (`usb2-port1`), so the Brio's C-to-C connection falls back to a 480M link, where 1080p30 MJPEG is verified clean (29.3 fps sustained, 0 errors). Manual re-apply: `echo 1 > /sys/bus/usb/devices/usb2/2-0:1.0/usb2-port1/disable`.
- **UVC probe stalls (`-32`/`-110`, EIO on open) after an attach**: re-running `qm set 109 -usb3 host=046d:0944` (live re-attach) clears it. Also seen: one physical port (host 1-3) had degraded iso bandwidth (~19 fps at 1080p) — moving ports fixed it.
- **Planned native-SS path (cable on order, ETA 2026-07-24):** CPU controllers `10:00.3`/`10:00.4` (Raphael xHCI) are each alone in their IOMMU group (40/41) with working `pm` reset — ideal whole-controller passthrough candidates, unlike the chipset. Their rear sockets linked the Brio only at 480M with a USB2-only C-to-A cable; retest with a proper USB3 cable, and if SS comes up, pass `10:00.4` as `hostpci2` (card reader rides along), delete the `usb3`/`usb4` forwards, `qm reboot` — restores 4K/YUYV/clean-mic-at-1080p.
- **UGREEN cam is a native USB2 device** — 480M is its ceiling; MJPEG 2K fine.
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
lsusb                      # Kensington, Brio, card reader, BT, UGREEN — all on emulated buses
nvidia-smi                 # GTX 1660 SUPER
lspci | grep -i audio      # AMD audio at 02:00.0 (+ NVIDIA audio at 01:00.1 after all-functions reboot)
hciconfig                  # hci0 UP RUNNING
ls /dev/video*             # both cameras
```
