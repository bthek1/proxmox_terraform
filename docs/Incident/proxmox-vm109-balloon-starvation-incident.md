# VM 109 balloon starvation: incident write-up and host overcommit remediation

**Target**: VM 109 "Main" (`proxmox_main`, hostname `proxmox-ml5`, `192.168.2.109`) on the Proxmox host
`bthek1` / `192.168.2.70`.

**Written**: 2026-09-01. Every number below was read off the live host during the incident and the
recovery, not reconstructed afterwards.

**One line**: the host ran out of RAM, PVE auto-ballooning squeezed VM 109 from 20 GB down to 816 MB,
the guest thrashed itself to a hard hang, and the balloon gave none of that memory back to the host
because VFIO had it pinned. Fixed by removing the balloon device from VM 109.

## Progress at a Glance

| Phase | Status |
|-------|--------|
| 0 Diagnosis | **Done 2026-09-01** - root cause confirmed from QMP balloon stats, not inferred |
| 1 Recovery of VM 109 | **Done 2026-09-01 22:2x** - stop, `--balloon 0`, start; guest verified healthy |
| 2 Audit other passthrough VMs | **Done 2026-09-01** - 109 was the only VM with passthrough + balloon |
| 3 Reclaim host swap | **Not started** - swap was 100% full; recovering on its own but not clean |
| 4 Bring guest memory limits under the host | **Not started** - 117 GB configured on 62 GB of RAM |
| 5 Soak / confirm no recurrence | **Not started** - depends on Phase 4 |

Phases 0-2 are the incident. Phases 3-5 are the unresolved cause, which is still live.

---

## 1. What was observed

Operator report, 2026-09-01 evening:

- The screens on `proxmox_main` went off.
- RAM usage in the Proxmox UI dropped to **under 1 GB**.
- A reboot from the UI failed with:

```
QEMU Guest Agent is not running - VM 109 qga command 'guest-ping' failed - got timeout
TASK ERROR: VM quit/powerdown failed - got timeout
```

The PVE task log confirms it: `qmreboot` was issued **22:10:58 AEST** and gave up at **22:12:01**,
exactly 63 seconds later.

This looks like the earlier VM 109 hangs catalogued in
[proxmox-vm109-gpu-freeze-incident.md](proxmox-vm109-gpu-freeze-incident.md) (Modes A-E) and it is not
any of them. That doc's Mode A is RTD3 GPU resume and Mode B is the mutter VRAM leak; neither touches
memory accounting.
The tell is the RAM figure: a GPU-mode hang leaves memory usage where it was.

## 2. Evidence

### 2a. The guest was starved, not crashed

`sudo qm monitor 109 <<< "info balloon"`:

```
balloon: actual=1884  max_mem=20480  total_mem=816  free_mem=88
         mem_swapped_out=126997151744   (118 GiB)
         mem_swapped_in=95095824384     (88 GiB)
         major_page_faults=14953976
         minor_page_faults=2161340508
         last_update=1788264103
```

A VM configured for 20480 MB was seeing **816 MB**, and had swapped **118 GiB** out to survive it.
15 million major page faults is a machine doing nothing but paging.

### 2b. The guest kernel was wedged, not merely slow

`last_update=1788264103` decodes to **2026-09-01 22:01:43 AEST**. Read again 13 minutes later, and
again 100 seconds after that, it had **not moved**. The guest's virtio-balloon driver had stopped
updating entirely. Meanwhile the QEMU process sat at **100% CPU with RES 20.0g**. No ping on
`192.168.2.109`.

This is the single most useful check in the whole incident: **read `info balloon` twice.** A stale
`last_update` means no live deflate will land and you are going to have to stop the VM.

### 2c. The host was out of memory

```
Committed_AS:  91 GB    against 62 GB of RAM
SwapFree:      2120 kB  of 8 GB          <- 99.97% full
MemFree:       1.5 GB
```

Live usage at the time:

| Guest | Kind | Using |
|-------|------|-------|
| 109 Main | VM | 20.9 GB |
| 106 `test` | LXC | 10.3 GB |
| 100 `work` | LXC | 6.9 GB |
| 206 nextcloud | VM | 4.5 GB |
| 103 `work2` | LXC | 3.8 GB |
| 204 homeassistant | VM | 1.6 GB |
| 205 knowledge-lab | LXC | 1.6 GB |
| 203, 202, 111, 200, 201, 107 | LXC | ~4.4 GB combined |

About **54 GB of 62 GB** before host overhead. ZFS ARC was **not** involved - `arcstats size` was
5760 bytes.

### 2d. The host GPU errors were a symptom, not the fault

`journalctl -k` showed, on the host:

```
Aug 31 22:42:55  NVRM: GPU0 ... Out of memory [NV_ERR_NO_MEMORY] ... _memdescAllocInternal
Sep 01 21:55:39  NVRM: GPU0 ... Out of memory [NV_ERR_NO_MEMORY] ... _memdescAllocInternal
```

That is the **host** NVIDIA driver failing to allocate **system** memory, roughly 20 minutes before
the hang was noticed. It is the same RAM exhaustion showing up somewhere else. It is not a GPU fault,
and chasing it as one wastes the evening.

## 3. Root cause

Two things had to be true at once.

**(a) The host was massively overcommitted.** 117 GB of configured guest memory on 62 GB of RAM, with
8 GB of swap standing in for the difference. Under load the host had nowhere to go.

**(b) VM 109 had `balloon: 1024` alongside `hostpci0`/`hostpci1`.** PVE's auto-ballooning responded to
host pressure by inflating the balloon toward that 1024 MB floor.

The second is the part that turned a squeeze into a hang:

> **Ballooning a VM with PCI passthrough is pure loss.** VFIO pins all guest RAM for DMA, so QEMU
> cannot release the pages the balloon reclaims. The QEMU RSS stayed at **20.9 GB** the whole time.
> The balloon took 19 GB away from the guest and returned **nothing** to the host.

So the pressure never dropped, so pvestatd kept inflating, so the guest went all the way to the floor.
There is no equilibrium in that loop. The proof is in the recovery: stopping VM 109 took host free
memory from **1.5 Gi to 25 Gi instantly**, memory the balloon had spent an hour failing to liberate.

## 4. Why the reboot failed

`qmreboot` asks the guest to shut down cleanly, via the guest agent and then ACPI. Both need the guest
kernel to schedule a process. With 88 MB free and every page fault hitting disk, nothing ran. Hence
`guest-ping ... got timeout` and then `VM quit/powerdown failed - got timeout`.

The reboot failing was not a second fault. It was the same fault, reported from a different angle.

## 5. Recovery performed

```bash
# 1. Free attempt first: deflate the balloon live. Costs the host nothing - the RAM is already pinned.
sudo qm monitor 109 <<< "balloon 20480"
```

It did not take. Polled for 100 seconds; `actual` stayed at 1884 and `last_update` never advanced,
confirming 2b. So:

```bash
# 2. Hard stop. Unclean, but the guest kernel was not going to come back.
sudo qm stop 109

# 3. Remove the balloon device entirely.
sudo qm set 109 --balloon 0

# 4. Start.
sudo qm start 109
```

Measured effect of the stop alone:

| | Before | After stop |
|---|---|---|
| Host `free` | 1.5 Gi | 25 Gi |
| Host `used` | 50 Gi | 31 Gi |

The start logged `kvm: vfio: Cannot reset device 0000:11:00.6, depends on group 39 which is not owned`.
That is the usual benign IOMMU-group warning for the second passthrough device. The GPU came up fine.

The unclean stop cost nothing visible: ext4 replayed without complaint and the desktop came back.

## 6. Verification

Guest, three minutes after boot:

```
Mem:   15Gi total   6.0Gi used   5.6Gi free      (was 816 MB total)
Swap:  31Gi total   0B used                      (was 118 GiB swapped out)
GPU:   NVIDIA GeForce GTX 1660 SUPER, 3501/6144 MiB, driver 595.84
gdm:   active
ping 192.168.2.109: 3/3, 0% loss
```

Host side:

```
$ sudo qm monitor 109 <<< "info balloon"
Error: No balloon device has been activated
```

That error **is** the fix. The device is gone from the VM, so pvestatd has nothing to inflate and
cannot squeeze this guest again regardless of host pressure.

`qm status 109 --verbose` reports `maxmem: 17179869184` (16384 MiB) with `mem` tracking it - the full
fixed allocation, no balloon in the path. Note the VM now runs at **16 GB**, not the 20 GB it was
running before the hang; the config had already been trimmed to `memory: 16384` at some earlier point
and that took effect on this start.

## 7. Audit of the other guests

Checked every VM for the same passthrough + balloon combination:

| VMID | Name | memory | balloon | hostpci | Verdict |
|------|------|--------|---------|---------|---------|
| 109 | Main | 16384 | **0** (fixed) | 2 | was the only bad one |
| 204 | homeassistant | 4096 | unset (on) | 0 | fine - nothing pins its RAM, ballooning works normally |
| 206 | nextcloud | 8192 | 0 | 0 | already correct |

**Rule to keep**: any VM with a `hostpci*` line gets `balloon: 0`. There is no case where ballooning a
passthrough VM helps, and this incident is what it costs.

## 8. Triage playbook

Screens off plus guest-agent timeout is ambiguous against the guest-freeze modes in
[proxmox-vm109-gpu-freeze-incident.md](proxmox-vm109-gpu-freeze-incident.md). Check in this order.

| # | Check | Reading |
|---|-------|---------|
| 1 | `sudo qm monitor 109 <<< "info balloon"` | `total_mem` far below `max_mem`, or `mem_swapped_out` in the tens of GiB -> **balloon starvation** (this document) |
| 2 | Same command again, ~1 min later | `last_update` unchanged -> guest kernel wedged, a live deflate will not land, go straight to `qm stop` |
| 3 | `free -h` and `grep -E "MemFree\|SwapFree\|Committed_AS" /proc/meminfo` on the host | confirms whether the host is the one under pressure |
| 4 | SSH into the guest still works? | yes -> **Mode B**, the mutter VRAM leak; `sudo systemctl restart gdm`, no reboot needed |
| 5 | SSH dead, no logs anywhere, memory usage normal | -> **Mode A**, RTD3 / GPU resume |

Host NVRM `NV_ERR_NO_MEMORY` lines are a symptom of check 3, never the primary finding.

Access notes that cost time this round: on the PVE host, `ben` has **passwordless sudo for `qm` and
`pct` only**. `sudo grep`, `sudo journalctl` and `sudo awk` all need the password piped in via `sudo -S`, and
without `-S` they fail with an error that is easy to miss inside a loop - producing empty columns that
look like real data. Two of the numbers in the first pass of this investigation were wrong for exactly
that reason.

---

## Phase 3: Reclaim host swap

**Status**: Not started

**Goal**: Get the host out of the degraded state the incident left it in.

Host swap was **100% full** (2120 kB free of 8 GB) during the incident and still 6.6 Gi used
afterwards. It is draining slowly on its own but nothing forces it, so pages that belong to live
processes stay on disk and the host stays sluggish.

**Deliverables**:

- [ ] Confirm free RAM comfortably exceeds swap in use (`free -h`)
- [ ] `sudo swapoff -a && sudo swapon -a`
- [ ] Re-check `SwapFree` is back to ~8 GB and `MemFree` did not collapse

**Stability Criteria**: `swapoff` completes without the host going into reclaim; all guests stay
running throughout.

**Notes**: `swapoff` has to page everything back into RAM at once. Do not run it while free RAM is
below what is currently swapped. At the time of writing that means waiting for or making ~7 GB of
headroom.

## Phase 4: Bring configured guest memory under the host's RAM

**Status**: Not started

**Goal**: Remove the overcommit that caused the incident, so the next memory spike has somewhere to go.

This is the actual unresolved problem. `balloon: 0` stops VM 109 being the victim; it does not stop the
host running out of memory. The next squeeze lands on something else, most likely the OOM killer.

Measured 2026-09-01:

| | Configured | Host has |
|---|---|---|
| VMs (109 + 204 + 206) | 28,672 MB | |
| LXCs (10 containers) | 91,320 MB | |
| **Total** | **119,992 MB (117 GB)** | **62 GB RAM + 8 GB swap** |

That is about **1.9x overcommit**. LXC swap allowances make it worse: they total roughly **41 GB
against 8 GB of host swap**.

Per-container detail, limits versus what they actually use:

| CTID | Hostname | limit MB | swap MB | using MB | Headroom being reserved for nothing |
|------|----------|----------|---------|----------|--------------------------------------|
| 205 | knowledge-lab | 20000 | 4096 | 1581 | 18.4 GB |
| 106 | `test` | 15000 | 8192 | 9637 | 5.4 GB |
| 100 | `work` | 11264 | 8192 | 6890 | 4.4 GB |
| 103 | `work2` | 10240 | 8192 | 3788 | 6.5 GB |
| 107 | `rag` | 8192 | 8192 | 157 | 8.0 GB |
| 111 | `gh-runner` | 8192 | 1024 | 708 | 7.5 GB |
| 202 | `ollama-202` | 8192 | 2048 | 1030 | 7.2 GB |
| 200 | `stockmarket` | 4096 | 2048 | 676 | 3.4 GB |
| 203 | `frigate` | 4096 | 512 | 1500 | 2.6 GB |
| 201 | `stockmarket-db` | 2048 | 512 | 291 | 1.8 GB |

**Deliverables**:

- [ ] Decide a target: configured total at or below ~62 GB, or an accepted overcommit ratio with a
      written justification
- [ ] Trim the limits with the largest unused headroom first - `107 rag` (8 GB limit, 157 MB used),
      `111 gh-runner`, `202 ollama-202`, and `205 knowledge-lab` are the obvious candidates
- [ ] Reduce LXC swap allowances so their total is a sane multiple of the host's 8 GB, not 5x it
- [ ] Decide whether `106 test` at ~10 GB live is doing something that needs to keep running

**Tests**:

- [ ] `free -h` on the host shows a working set with headroom under sustained normal load
- [ ] `Committed_AS` no longer exceeds `MemTotal` by a large margin

**Stability Criteria**: every guest still starts and runs at its new limit; no container hits its cgroup
limit under its normal workload.

**Notes**: cutting a limit is not free - a container that hits its cgroup limit OOMs inside itself.
Trim toward observed usage plus a real margin, not toward the minimum seen once. `205 knowledge-lab` is
deliberately sized for ML work - the `Knowledge` repo's `CLAUDE.md` documents 20 GB / 4 vCPU / 12 GB
VRAM as the budget its DL notebooks are written against - so its limit is the least safe one to cut
despite showing the largest headroom.

## Phase 5: Soak

**Status**: Not started

**Goal**: Confirm the incident does not recur once Phase 4 lands.

**Deliverables**:

- [ ] 72 hours with VM 109 up and no hard resets
- [ ] Host `SwapFree` stays healthy across the window
- [ ] No host NVRM `NV_ERR_NO_MEMORY` lines in `journalctl -k`

**Stability Criteria**: VM 109 uptime unbroken for the window, host swap never below ~50% free.

---

## Corrections to earlier notes

Recorded because each of these would have misled the next investigation.

1. **The VM is `192.168.2.109`, not `192.168.2.20`.** The static IP moved during the 26.04 upgrade
   (documented in the `Knowledge` repo at
   `docs/Plans/In_progress/PROXMOX_MAIN_UBUNTU_26_04_UPGRADE_PLAN.md`). Pings to `.20` fail for the
   wrong reason and look like the VM is down when it is not.
2. **The guest is Ubuntu 26.04.1 LTS on kernel 7.0.0-30-generic.** The old note pinning boot to kernel
   6.17.0-29 as a stability fix is fully superseded by the distro upgrade.
3. **Configured VM memory is 28.7 GB, not 70 GB.** A first pass summed `memory:` lines with `awk`
   straight over `/etc/pve/qemu-server/*.conf`, which also counts the `memory:` inside VM 109's
   `pre-resolute` snapshot section. Use `qm config <id>` instead, which reports the live config only.
   The LXC figure of 91,320 MB was unaffected and is correct.
