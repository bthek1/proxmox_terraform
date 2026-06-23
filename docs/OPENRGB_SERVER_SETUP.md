# OpenRGB Server on the Proxmox Host

Control the motherboard RGB over the network. OpenRGB runs as a systemd service on
the Proxmox **host** (`bthek1`, 192.168.2.70) and exposes a TCP server on **:6742**.
Any client — Home Assistant, VM 109, a laptop — connects over the LAN; nothing needs
USB passthrough. **Set up and verified live on 2026-06-23.**

## What's on this host

- **Board:** ASUS PRIME X670-P WIFI.
- **RGB controllers OpenRGB drives (3):**
  - `0: ENE DRAM` — SMBus, `/dev/i2c-2` @ 0x71 (RGB RAM stick)
  - `1: ENE DRAM` — SMBus, `/dev/i2c-2` @ 0x73 (RGB RAM stick)
  - `2: ASUS PRIME X670-P WIFI` — ASUS **Aura** USB controller `0b05:19af`, via `/dev/hidraw0`
- **OS:** Debian 13 (trixie). `openrgb` is **not** in this host's apt repos, so we run
  the upstream **AppImage** (extracted to `/opt/openrgb/squashfs-root`, bundles Qt — no
  trixie dependency issues).

## Why on the host (not a VM/LXC)

The Aura controller is a USB HID device the host owns. A **VM** can only get it via
*exclusive* USB passthrough (it was passed to VM 109 originally — that's why the host
couldn't see it). Running OpenRGB on the host keeps the device shared and lets every
client reach it over the network. Contrast with exclusive PCI passthrough in
[109_GPU_PASSTHROUGH.md](109_GPU_PASSTHROUGH.md).

> **Do not USB-pass the Aura controller (`0b05:19af`) to VM 109 again.** If you do,
> QEMU claims it via `usbfs`, the host's `usbhid` can't bind it, no `/dev/hidraw`
> node appears, and OpenRGB sees only the DRAM. It was removed from 109 on 2026-06-23.

## The usbhid gotcha (why there's a bind hook)

OpenRGB's Aura driver needs a `/dev/hidraw` node, which only exists when the kernel's
`usbhid` driver is bound to the controller's HID interface (class 03). If anything
ever detaches it (a prior VM passthrough, a manual libusb grab), the interface is left
unbound and no hidraw node returns on its own. So the service runs
[scripts/bind-aura-hid.sh](../scripts/bind-aura-hid.sh) as `ExecStartPre` — it finds
`0b05:19af` and (re)binds its HID interface to `usbhid` before the server launches.
Idempotent; a no-op once correctly bound (the normal state after a clean boot with no
passthrough).

## Install

```bash
scp scripts/openrgb_server_setup.sh scripts/bind-aura-hid.sh scripts/apply-boot-state.sh root@192.168.2.70:/tmp/
ssh root@192.168.2.70 'cd /tmp && bash openrgb_server_setup.sh'
```

Installs the AppImage + bind helper + boot-state hook to `/opt/openrgb`, loads
`i2c-dev`, writes `/etc/systemd/system/openrgb.service` (with the `ExecStartPost` that
sizes the addressable headers — see below), enables and starts it.

## Verify / control from the CLI

```bash
ssh root@192.168.2.70 'systemctl status openrgb'
ssh root@192.168.2.70 '/opt/openrgb/squashfs-root/AppRun --list-devices'   # expect 3 devices
# quick visible test — all RGB green, then off:
ssh root@192.168.2.70 '/opt/openrgb/squashfs-root/AppRun --mode static --color 00FF00'
ssh root@192.168.2.70 '/opt/openrgb/squashfs-root/AppRun --mode static --color 000000'
```

## The addressable-RGB gotcha (why there's a boot-state hook)

**Verified 2026-06-23:** the RAM lit up but the case/"PC" lights ran a rainbow no
client command could override. Cause: on the Aura controller (device 2) the **three
addressable headers** (`Aura Addressable 1/2/3`) detect as **0 LEDs** at startup, so
OpenRGB never sends them data and the ARGB strips fall back to their hardware-default
rainbow. The 12V `Aura Mainboard` zone (2 LEDs) works out of the box; the addressable
zones must be **resized** to the strip's LED count first:

```bash
AppRun -d 2 -z 1 -s 100      # size addressable header 1 to 100 LEDs (extras are ignored)
AppRun -d 2 -z 2 -s 100
AppRun -d 2 -z 3 -s 100
AppRun -d 2 --mode direct --color FFFFFF   # NOW it responds
```

Two quirks: (1) the sizes live only in the server's memory and are **lost on restart**
— they are NOT written to `OpenRGB.json`. (2) Combining a resize and a color set in one
`AppRun` call **segfaults**; do the `-s` resize and the `--color` apply as separate
calls. (3) The server-side `--profile <name>` flag in `ExecStart` **crashes the server**
(exit 1) — do not use it.

So [scripts/apply-boot-state.sh](../scripts/apply-boot-state.sh) runs as the service's
`ExecStartPost`: it waits for `:6742` to bind, resizes the three addressable zones to
100, then sets device 2 to a neutral OFF (Direct/black) so a client — Home Assistant —
sets the real colors. This makes the addressable lights controllable on every boot.

## Connect from Home Assistant

OpenRGB integration → **host `192.168.2.70`, port `6742`**. (No HA guest exists in
[PROXMOX_INVENTORY.md](PROXMOX_INVENTORY.md) yet; the server is ready for one.) HA can
connect from **any LAN IP** — the firewall was opened LAN-wide (see below). Devices HA
will see: `0/1: ENE DRAM` (RAM), `2: ASUS PRIME X670-P WIFI` (board + addressable
headers, pre-sized to 100 LEDs by the boot hook).

## Security note

`openrgb --server` has **no authentication** and binds `0.0.0.0:6742`. Access is gated
by the **Proxmox cluster firewall** (`/etc/pve/firewall/cluster.fw`), not iptables.
As of 2026-06-23 it allows the whole LAN via `vmbr0`:

```
IN ACCEPT -i vmbr0 -p tcp -dport 6742 -log nolog
```

To restrict it back to a single host (e.g. only the HA box), add `-source <HA_IP>` to
that rule and `pve-firewall restart`. WireGuard (`wg0`) and WAN are not granted 6742.

## Default lighting at boot (optional)

The server only relays control; LEDs change when a client sets them. To apply a saved
profile on boot, create it once (`AppRun --profile <name> ...` or the GUI), then add
`--profile <name>` to `ExecStart` in the unit and `systemctl daemon-reload && systemctl restart openrgb`.
