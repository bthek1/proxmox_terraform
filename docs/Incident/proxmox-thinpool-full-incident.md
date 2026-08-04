# Proxmox Thin-Pool 100% Full — Outage & Recovery (2026-08-02/03)

**TL;DR:** the `pve/data` LVM thin pool (794 G) silently filled to **100%** some days
after sitting at 98%. Thin volumes could no longer allocate blocks, so every guest write
needing a new block returned **EIO** — for days. Symptoms cascaded: containers failed to
mount at boot, VM 109's root filesystem was corrupted so the guest wouldn't boot (QEMU
"running", screen dark, no network — looked like a dead machine), and *after* recovery a
second wave of guest-side damage surfaced (corrupted `libssl` broke sudo/DNS/Firefox
inside VM 109). Root cause of the fill: **nothing ever trims** — thin pools never get
freed blocks back unless guests run `fstrim`, PVE doesn't do it automatically, and the VG
has only 16 G free so the pool cannot autoextend. Recovery: `pct fstrim` freed ~460 GiB
(100% → 91.6%); VM 109 needed an offline `e2fsck` plus, the next day, surgical package
repair via the QEMU-agent root channel.

Related: [proxmox-vm109-gpu-freeze-incident.md](proxmox-vm109-gpu-freeze-incident.md)
(Mode E explains the *previous* outage on 2026-07-24 — unrelated cause, similar symptom
of "host up, guests broken", and the boot-crash-loop diagnosis gotchas).

---

## Timeline

| When (2026) | Event |
|---|---|
| Jul 24 | Pool observed at **98.1%** during the Mode E recovery; cleanup recommended, deferred. `dmeventd` warns at every boot from here on. |
| ~Jul 29–Aug 1 | Pool reaches **100%** (`lvs` attr `twi-aotzD-`, `D` = out of data space). Guest ext4 filesystems start logging `I/O error 3` / "potential data loss" on writes. Nothing user-visible yet — reads and rewrites of allocated blocks still work. |
| Aug 2 ~17:54 | Guests visibly malfunctioning; host rebooted (three times, 17:55 / 18:23 / 18:27) — reboots can't help and make it worse: each boot, CTs **100/103/107/203 fail to start** (`lxc.hook.pre-start` exit 32 = ext4 mount failure), CT 205 fails for an unrelated reason (see below), and **VM 109's guest OS fails to boot** off its damaged root fs while `qm status` says "running" (with `vga: none` there is no virtual console — no screendump possible, physical monitor only). |
| Aug 2 ~18:55 | Recovery: `pct fstrim` on every running CT frees ~205 GiB → pool **91.8%**, out-of-space flag clears. Failed CTs start, trimmed too (frigate's media volume alone returned 177 GiB). |
| Aug 2 ~19:00 | VM 109 still dead after `qm reset` → stopped, disk loop-mounted, **`e2fsck -fy`** on the root partition (orphaned inodes, corrupt orphan lists — moderate, recoverable). VM boots, agent responds. |
| Aug 2 ~22:40 | Full host reboot as end-to-end test: clean boot, all 12 guests up, zero failed units. |
| Aug 3 ~00:00 | Second wave found inside VM 109: "Firefox won't open, no internet". Guest-side corruption repaired (below). All units green by ~00:20. |

---

## Root cause

- Thin volumes only ever *grow* their allocation: guest-side file deletion frees blocks in
  the guest fs but **never returns them to the pool** without an explicit
  `fstrim`/discard. No CT was ever trimmed; VM 109 has `discard=on` but the guest never
  ran `fstrim` either.
- The VG (`pve`, 930 G) has only **16 G free**, so the pool's autoextend has nowhere to
  go even if enabled. At 794 G allocated the pool was hard-capped.
- When a thin pool is out of data space, writes needing new blocks fail with EIO after a
  60 s queue. Ext4 inside the guests kept running on already-allocated blocks — which is
  why the system *appeared* to work for days while quietly corrupting anything that
  wrote to fresh blocks.

## Why VM 109 looked completely dead

`qm status 109` said `running` but there was no display output, no network, no agent.
The guest OS was failing early in boot on a damaged root fs. Key facts for next time:

- **`vga: none`** (GPU passthrough): there is **no virtual console** — `qm monitor`
  `screendump` errors with "no console"; the only display is the physical monitor.
- `serial0` exists but the guest doesn't put a console on it — silence proves nothing.
- The reliable liveness signals are: guest-agent ping, ICMP to `.109`, and (for boot
  failure) nothing else — go straight to offline fsck:

```bash
qm stop 109
LOOP=$(losetup -fP --show /dev/pve/vm-109-disk-1)   # kpartx is NOT installed on the host
# p1 = 1G vfat EFI, p2 = 254.9G ext4 root
e2fsck -fn ${LOOP}p2     # read-only assessment first
e2fsck -fy ${LOOP}p2     # repair
losetup -d $LOOP
qm start 109
```

---

## Guest-side aftermath inside VM 109 (the second wave)

Files being (re)written during the EIO window were left **zero-filled** — the corruption
clustered around an OpenSSL package update that was evidently in flight when the pool
filled. Reported as "Firefox isn't opening and internet isn't working":

| Casualty | Symptom |
|---|---|
| `/lib/x86_64-linux-gnu/libssl.so.3` | "invalid ELF header" → `systemd-resolved`, `upower`, `wpa_supplicant`, `mosquitto` all failed — **and `sudo` itself** (`sudoers.so` links libssl), plus `wget`/`curl` |
| `/etc/resolv.conf` (symlink) | gone → no DNS → "no internet" while IP routing was fine (gateway/8.8.8.8 pinged OK) |
| `/usr/lib/firefox/firefox` | `file` says `data` → `Exec format error` — Firefox never launches |
| `/var/lib/dpkg/info/openssl.list` | 12 534 bytes of NULs → **dpkg refuses all installs** ("files list file for package 'openssl' is missing final newline") |
| 44 more openssl-family files (`/usr/include/openssl/*.h` etc.) | md5 mismatches, found by `dpkg -V` |
| `/var/lib/mosquitto/mosquitto.db` | "Unrecognised file format" — moved aside (regenerates; retained MQTT messages lost) |
| `/var/cache/man` index | man-db.service failing — purged and rebuilt |

### Recovery recipe (order matters)

1. **Root channel without sudo:** `qm guest exec 109 -- <cmd>` from the host — the QEMU
   guest agent runs as root and does not link libssl. This was the only root access.
2. **Get a clean libssl in:** download the exact installed version on a healthy machine
   (`http://archive.ubuntu.com/ubuntu/pool/main/o/openssl/libssl3t64_<ver>_amd64.deb`),
   `scp` to the guest (`dpkg`/`apt` binaries don't link libssl; `wget`/`curl` do and were
   dead).
3. **Rebuild the corrupted dpkg file-list** before dpkg will run:
   ```bash
   dpkg-deb --fsys-tarfile openssl_<ver>_amd64.deb | tar tf - \
     | sed -e 's,^\.,,' -e 's,/$,,' -e 's,^$,/.,' > openssl.list   # → /var/lib/dpkg/info/
   ```
4. `dpkg -i libssl3t64_<ver>.deb` → **sudo/apt/curl instantly resurrect**.
5. Restore DNS: `ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf`,
   restart `systemd-resolved`, restart the other libssl-victim services.
6. Sweep for the rest: `dpkg -V > /tmp/dpkg-verify.out`, map `..5` mismatches to
   packages, `apt-get install --reinstall` them (here: `firefox openssl libssl-dev
   systemd gdm3 procps mosquitto`).
7. **`dpkg -V` caveats:** `/etc` conffile hits are usually *legitimate user edits* —
   check with `file` before "fixing" (here `custom.conf`, `sysctl.conf`, `logind.conf`,
   `mosquitto.conf` were all healthy hand-edits). Empty `linux-image-*.list` files are
   normal for removed kernels. Detect NUL-corrupt lists with `grep -L / …/info/*.list`
   + non-zero size (a pure-NUL file has no `/`).

---

## Side quests fixed during the same incident

- **nginx failed at every host boot** (cert `/etc/pve/local/pve-ssl.pem` not yet mounted
  when nginx starts). A drop-in was added on Jul 24 **but was written as a 0-byte file**
  (shell stdin-plumbing bug: `printf … | (echo PW | sudo -S tee …)` — the inner pipe
  replaces stdin, tee writes nothing; the same trap later ate a `qm monitor` command).
  Real fix now in place and verified across two boots:
  `/etc/systemd/system/nginx.service.d/wait-for-pve.conf` with
  `After=pve-cluster.service`, `Wants=pve-cluster.service`, `Restart=on-failure`,
  `RestartSec=5`.
- **CT 205 (knowledge-lab) autostart broke silently**: it device-passes the UGREEN
  camera mic as `/dev/snd/pcmC?D0c`, and **ALSA card numbers shift between boots** (this
  boot NVIDIA HDA took card 0; the UGREEN moved 0→2). Start fails with "Device
  /dev/snd/pcmC0D0c does not exist" — and note `pve-container@205` did **not** appear in
  `systemctl --failed` (the failure happens in the pvesh startall task, not the unit).
  Config updated to `controlC2`/`pcmC2D0c`. Durable fix if it recurs: pin the USB card
  with `options snd_usb_audio index=` in host modprobe.d, or re-check
  `/proc/asound/cards` after any host reboot / camera replug.

---

## Prevention (state as of 2026-08-03)

Current pool level after recovery: **~91.6%** — functional but still close to the edge.

- [ ] **Periodic trim (the actual fix):** weekly timer running `pct fstrim <id>` for all
  running CTs + `qm guest cmd 109 fstrim` (agent must be up; `scsi0` already has
  `discard=on`). This incident cannot recur if trims run.
- [ ] Delete stale snapshots still holding space: `snap_vm-100-disk-0_new`,
  `snap_vm-100-disk-0_test_snap`.
- [ ] Offline `pct fsck` for the CTs that recorded ext4 error counts during the EIO
  window (at least 100, 103 + two others — kernel logged "error count since last fsck"
  on dm-6/10/14/16). They run fine; the counts persist until fsck'd.
- [ ] Capacity: consider shrinking/relocating the big consumers (VM 109 ~180 G
  allocated, CT 205's 300 G volume, CT 111 gh-runner at ~98% of its 64 G — CI artifact
  growth) or moving bulk data to the 2 TB disk (`/mnt/pve/backup-2tb`).
- **Watch:** `lvs pve/data` — treat Data% ≥ 95% as an outage already in progress. The
  `D` in attr `twi-aotzD-` means it has happened.

## Quick diagnostic reference

```bash
# pool state (the number that matters):
ssh proxmox sudo lvs pve/data          # Data% + attr; 'D' flag = out of space

# who's holding the space (inactive volumes hide their Data%):
sudo lvs -a --units g -o lv_name,lv_size,data_percent,pool_lv,origin --sort -data_percent

# reclaim space (running guests):
sudo pct fstrim <ctid>                 # per running CT
sudo qm guest cmd 109 fstrim          # VM, needs agent + discard=on

# CT won't start with "Script exited with status 32" → its fs can't mount (pool full or fs damage)
# VM "running" but dead with vga:none → no console exists; check agent/ping, then offline e2fsck (above)

# guest root shell when sudo is broken inside VM 109:
sudo qm guest exec 109 -- sh -c '<commands>'   # agent runs as root
```
