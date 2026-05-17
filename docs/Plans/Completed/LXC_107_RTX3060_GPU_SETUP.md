# LXC 107 RTX 3060 GPU Setup Plan

**Machine**: LXC 107 (`proxmox_rag`) — Ubuntu 24.04.4 LTS  
**GPU**: NVIDIA GeForce RTX 3060 LHR (host PCI `01:00.0`, passed through via device node mount)  
**Goal**: Get GPU fully operational inside the container (nvidia-smi working, Docker GPU access via nvidia runtime).

---

## Final State (2026-05-17) — COMPLETE ✅

| Component                     | Status                                  |
| ----------------------------- | --------------------------------------- |
| Device nodes (`/dev/nvidia*`) | ✅ Passed through — all 5 nodes present |
| Host kernel driver            | ✅ `595.71.05`                          |
| Container NVML userspace      | ✅ `595.71.05` — version match          |
| `nvidia-smi` inside container | ✅ Shows RTX 3060, no errors            |
| `nvidia-container-toolkit`    | ✅ `1.19.0`, CDI config regenerated     |
| Docker nvidia runtime         | ✅ `--runtime=nvidia` works, CDI mode   |

**Root cause fixed**: The 580.x userspace libraries were installed manually (not tracked by dpkg) and were incompatible with the host kernel module at 595.71.05. Removed all 580.x libs and reinstalled userspace-only with `--no-kernel-module`.

---

## Phase 1: Fix NVIDIA Driver/Library Version Mismatch ✅

**Status**: Complete

**Goal**: Replace the stale 580.x userspace libraries inside LXC 107 with ones that match the host kernel module version (595.71.05), so `nvidia-smi` works.

**Context**: The NVIDIA `.run` installer supports `--no-kernel-module` to install only userspace libraries. This is the correct approach for LXC containers — the kernel module lives on the host.

**Completed steps**:

- [x] Removed all 580.x NVIDIA userspace libraries from `/usr/lib/x86_64-linux-gnu/` and `/usr/lib32/` (run as root via `ssh root@192.168.2.28`)
- [x] Downloaded `NVIDIA-Linux-x86_64-595.71.05.run` (404 MB)
- [x] Installed with `--no-kernel-module --silent --no-drm --no-backup --no-x-check --no-nouveau-check`
- [x] `nvidia-smi` shows RTX 3060, driver 595.71.05, CUDA 13.2 — no errors

**Note**: `sudo` requires a password for user `bthek1` inside the container. Use `ssh root@192.168.2.28` directly for root access.

---

## Phase 2: Regenerate CDI Config & Verify Docker GPU Access ✅

**Status**: Complete

**Completed steps**:

- [x] `nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` — CDI spec regenerated with 595.x paths
- [x] Switched `nvidia-container-runtime` mode from `auto` → `cdi` in `/etc/nvidia-container-runtime/config.toml` (required in LXC — BPF cgroup device filters are not permitted)
- [x] `docker run --rm --runtime=nvidia -e NVIDIA_VISIBLE_DEVICES=all nvidia/cuda:12.6.3-base-ubuntu24.04 nvidia-smi` — shows RTX 3060 ✅

**Note**: In LXC, use `--runtime=nvidia -e NVIDIA_VISIBLE_DEVICES=all` instead of `--gpus all`. The `--gpus all` flag triggers the legacy hook which requires BPF cgroup permissions not available in unprivileged LXC.
