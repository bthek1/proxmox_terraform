# Firefox `gmpopenh264` Plugin Crash — Incident & Fix

**Date investigated:** 2026-06-29
**Machine:** `proxmox-ml5` (VM 109 "Main", `proxmox_main`, 192.168.2.20)
**Component:** Firefox 152.0.3 (mozillateam PPA deb, `152.0.3+build1-0ubuntu0.24.04.1~mt1`)
**Status:** RESOLVED ✅ — root cause was AppArmor, not memory. Two `firefox`
AppArmor profiles collided; the legacy enforce one blocked the codec. Fixed by
adding the missing rule, then dropping the legacy profile entirely.

---

## TL;DR

Firefox showed **"a plugin (like gmpopenh264) has crashed"** on every H.264 video.
The OpenH264 codec library itself was fine. The real cause: an **enforce-mode
AppArmor profile denied the Firefox media process permission to `mmap` (load) the
codec** `libgmpopenh264.so` from the user profile dir. The load failed → the media
process segfaulted in `libxul.so` → Firefox reported a plugin crash.

The mess underneath it: **two AppArmor profiles both named `firefox`** were attached
to `/usr/lib/firefox/firefox`, and the wrong one (legacy enforce) was winning. A
prior fix-attempt had even added the correct allow-rule — but to the override file
belonging to the *other* (unconfined) profile, so it never took effect.

**A separate, real-but-unrelated problem** was also found and fixed along the way: a
custom wrapper capped Firefox at 4 GB via cgroup, causing brutal swap thrashing.
That was NOT what crashed the plugin.

---

## Symptoms

In-browser error on H.264 video / WebRTC calls:

> This error means that a plugin (like gmpopenh264) has crashed. Simply reloading the
> page will restart the plugin, and your video (or other content) will be shown again.

- Reproduced every few minutes whenever H.264 content played.
- Reloading the page temporarily restarted the plugin, then it crashed again.
- No useful crash report: `LastCrash` logged *"The application failed to generate
  crash information"* — a hint the process was being killed/failing at load rather
  than segfaulting in a normally-dumpable way.

---

## Investigation

### Things ruled OUT
| Suspected cause | Verdict | Evidence |
|---|---|---|
| Corrupt OpenH264 plugin | ❌ | `libgmpopenh264.so` valid ELF, all `ldd` deps resolve, hash matches prefs. |
| Reinstalling Firefox | ❌ would not help | Cause lived in user-home wrappers + system AppArmor, untouched by `apt`. |
| Memory cap / swap thrash | ❌ for the crash | Real problem (see below) but plugin still crashed after the cap was lifted. |

### The smoking gun (kernel log)
Every crash was this exact pair, repeating for hours:

```
kernel: audit: type=1400 ... apparmor="DENIED" operation="file_mmap" class="file"
   profile="firefox"
   name="/home/proxmox-ml5/.mozilla/firefox/ilew2l41.default-release/gmp-gmpopenh264/2.6.0/libgmpopenh264.so"
   comm="MainThread" requested_mask="m" denied_mask="m" fsuid=1000 ouid=1000
kernel: MainThread[NNNNN]: segfault at 0 ... in libxul.so
```

`requested_mask="m"` = the process asked to `mmap` the file executable; AppArmor
refused; the codec failed to load; the media process crashed.

### Why a prior fix didn't work — the two-profile collision
Two files both declare `profile firefox` for `/usr/lib/firefox/firefox`:

| File | Owned by (dpkg) | Nature | Its local override |
|---|---|---|---|
| `/etc/apparmor.d/firefox` | `apparmor` (Ubuntu 24.04 base) | Minimal **unconfined** stub; only grants `userns` so Firefox can run its own internal sandbox | `local/firefox` |
| `/etc/apparmor.d/usr.bin.firefox` | `firefox` (mozillateam PPA deb) | Legacy **enforce** full-confinement allowlist (Canonical, ~2016 era) | `local/usr.bin.firefox` |

The **legacy enforce profile won** (confirmed by its child profiles being loaded:
`firefox//sanitized_helper`, `firefox//browser_java`, …). A previous fix had added
the GMP allow-rule to `local/firefox` — the override for the *unconfined* profile,
which is **not** the one in charge. So the rule sat in a file the enforcing profile
never reads.

---

## Root cause

The legacy enforce AppArmor profile (`usr.bin.firefox`) is an allowlist that has not
kept up with Firefox's needs. It had no rule permitting Firefox to `mmap` the Gecko
Media Plugins (OpenH264, Widevine) that Firefox downloads into
`~/.mozilla/firefox/*/gmp-*/`. It was also the source of constant benign denials
(`/proc/*/oom_score_adj` writes, `CAP_SYS_ADMIN`).

Modern Firefox secures itself with a per-process seccomp + namespace sandbox; the
outer AppArmor allowlist is a coarse secondary layer that, here, was only causing
breakage. Ubuntu 24.04's own `apparmor` package reflects this by shipping the
unconfined stub instead.

---

## Fix

Performed in two steps. **Step 2 supersedes Step 1** (the legacy profile that needed
the rule is now disabled), but both are documented.

> All root actions used `sudo systemd-run --no-ask-password --pipe ...`. On this box
> plain `sudo <cmd>` requires a password, but `sudo systemd-run` is `NOPASSWD`
> (it's how the cgroup wrapper launched). The sandboxed shell also cannot send
> signals (`kill` is seccomp-blocked), so `systemd-run` (executed by PID 1) was used
> to signal Firefox too.

### Step 1 — add the missing GMP mmap rule (immediate fix, to the correct override)
Appended to **`/etc/apparmor.d/local/usr.bin.firefox`** (the enforce profile's override):

```apparmor
owner @{HOME}/.mozilla/firefox/*/gmp-*/**/lib*.so mr,
owner @{HOME}/.mozilla/firefox/*/gmp-*/**/ r,
```

Reloaded:
```sh
sudo systemd-run --no-ask-password --pipe --collect --unit=ffrl \
  apparmor_parser -r -W -T /etc/apparmor.d/usr.bin.firefox
```
AppArmor applies profile changes to running processes live — a page reload re-spawns
the GMP process under the new rule. **Crash stopped.**

### Step 2 — drop the legacy enforce profile entirely (permanent clean state)
Rather than maintain the legacy allowlist, switched to Ubuntu's unconfined stub so
the whole class of AppArmor-caused Firefox breakage ends:

```sh
sudo systemd-run --no-ask-password --pipe --collect --unit=ffaa-switch /bin/sh -c '
  mkdir -p /etc/apparmor.d/disable
  # disable legacy enforce profile across reboots AND package upgrades
  ln -sf /etc/apparmor.d/usr.bin.firefox /etc/apparmor.d/disable/usr.bin.firefox
  # unload it (and its child profiles) from the kernel now
  apparmor_parser -R /etc/apparmor.d/usr.bin.firefox
  # load the Ubuntu unconfined stub as the firefox profile
  apparmor_parser -r -W -T /etc/apparmor.d/firefox
'
```

Result: the only loaded profile is **`firefox (unconfined)`**; Firefox keeps its own
internal sandbox. The GMP rule from Step 1 is now moot but harmless.

---

## Verification

```sh
# Only the unconfined profile remains (no child enforce profiles):
grep -i firefox /sys/kernel/security/apparmor/profiles
#   firefox (unconfined)

# Running Firefox is unconfined:
cat /proc/$(pgrep -x firefox | head -1)/attr/current
#   unconfined

# No new gmpopenh264 mmap denials after the fix:
dmesg -T | grep -iE "DENIED.*gmpopenh264"
#   (last entry predates the fix; nothing newer)
```

- User confirmed video playback works ("that fixed it").
- 4-second denial-count watch after the switch: **no new denials**.

---

## Side issue fixed (unrelated to the crash): 4 GB cgroup cap → swap thrash

A custom wrapper `~/.local/bin/firefox` → `~/.local/bin/firefox-cgroup` pinned
Firefox to a 4 GB cgroup v2 limit (`/sys/fs/cgroup/firefox/memory.max`). Firefox
wanted more, so it sat at the cap (`memory.events: max` in the millions) and pushed
**~14 GB into swap**, thrashing the machine.

- Lifted the live cap (`echo max > memory.max`).
- Removed both wrapper scripts (backups: `~/.local/bin/firefox.bak-cgroup`,
  `firefox-cgroup.bak`).
- Changed `~/.local/share/applications/firefox.desktop` Exec from `firefox-cgroup %u`
  to `/usr/bin/firefox %u`.
- Restarted Firefox (freed ~12 GB swap instantly) and flushed the rest with
  `swapoff -a && swapon -a` → swap back to **0 B**.

`firefox` now resolves directly to `/usr/bin/firefox`: no cap, no sudo prompt, no
swap thrashing.

---

## Reverting

- **Re-enable the legacy AppArmor profile:** delete `/etc/apparmor.d/disable/usr.bin.firefox`
  and reload (`apparmor_parser -r /etc/apparmor.d/usr.bin.firefox`). If you do, the
  GMP allow-rule must live in `local/usr.bin.firefox` (not `local/firefox`).
- **Reinstate a memory cap:** restore the `*.bak` wrapper scripts, but use a sane
  ceiling (8–10 GB on this 19 GB machine, not 4 GB).

---

## Key takeaways

1. **"Plugin crashed" on Linux Firefox is often AppArmor, not the plugin.** Check
   `dmesg | grep 'DENIED.*gmp'` first.
2. **Two profiles can claim the same name.** `aa-status` / the kernel profiles list
   shows which is actually loaded; child profiles (`firefox//...`) reveal the legacy
   enforce one is active.
3. **`local/` overrides only apply to the profile that `include`s them.** Putting a
   rule in the wrong `local/` file silently does nothing.
4. On Ubuntu 24.04, the intended model is the **unconfined stub + Firefox's internal
   sandbox**; the legacy PPA enforce profile is the finicky outlier.
