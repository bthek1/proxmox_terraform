# Proxmox Terraform — Agent Instructions

This project uses Python (via `uv`) to automate **Terraform** workflows for provisioning and configuring **Proxmox VE** infrastructure. It is also used as a general scratch/testing environment.

## Project Setup

- **Package manager**: [`uv`](https://docs.astral.sh/uv/) — use `uv` for all Python tasks, never `pip` directly
- **Python version**: 3.14 (see `.python-version`)
- **Virtual environment**: `.venv/` — auto-activated via `.envrc` (direnv)
- **Entry point**: `main.py`

### Common Commands

```bash
# Install dependencies
uv add <package>

# Run the project
uv run main.py

# Run tests (once a test suite exists)
uv run pytest

# Sync dependencies from lockfile
uv sync
```

## Terraform / Proxmox Conventions

- Terraform config lives in `terraform/lxc/` and uses the [bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox/latest/docs) provider (`~> 0.75`); see [docs/PROXMOX_LXC_TERRAFORM_GUIDE.md](docs/PROXMOX_LXC_TERRAFORM_GUIDE.md)
- Drive Terraform via the `justfile` recipes (`just plan`, `just apply`, `just destroy`, …) rather than raw commands
- The Terraform CLI is **not installed on this workstation** — `plan`/`apply` run on the **gh-runner LXC (111)** via CI. To act on a live guest from here, SSH to the node and use `pct` (see `.github/instructions/proxmox.instructions.md`)
- As of 2026-06-17 the repo manages **no live guest** (its template container 108/terraCT was destroyed); see [docs/PROXMOX_INVENTORY.md](docs/PROXMOX_INVENTORY.md)
- **This workstation is VM 109 ("Main") on the Proxmox host.** The **GPU (all functions, incl. HDMI audio)** and an AMD audio controller reach it via PCIe passthrough (`hostpci0`=`0000:08:00`, `hostpci1`=`0000:10:00.6`); the **keyboard, mouse, webcam, and Bluetooth reach it via per-device USB redirection** (`usb1`=BT, `usb2`=keyboard, `usb4`=mouse, `usb5`=Logitech Brio 500 webcam `046d:0943` — the sole VM camera) — see [docs/109_PERIPHERAL_PASSTHROUGH.md](docs/109_PERIPHERAL_PASSTHROUGH.md). The UGREEN 2K cam (`1bcf:2284`) lives in **LXC 205** instead (host-owned, video + mic device-passed as `dev5`–`dev9`). ⚠️ **Only ONE camera may stream 1080p at a time in VM 109** — all forwards share one emulated 480M controller; a second simultaneous 1080p stream green-screens MJPEG (verified 2026-07-25). Webcams must use MJPEG, never YUYV above ~480p. The whole-USB-controller (`0c:00.0`) passthrough tried on 2026-07-22 was **reverted** (it made the mouse stick); all these controllers stay on the host and redirection matches by device ID, so the dongles/webcams can be plugged into **any** host-owned port. ⛔ **Never pass the AMD Raphael CPU xHCI controllers (IDs `1022:15b6`/`1022:15b7`) to any guest** — tried 2026-07-24, it **hard-reset the entire Proxmox host** on VM start and crash-looped every boot until reverted (incident doc, Mode E). They were at `10:00.3`/`10:00.4` then; since the 4 TB NVMe was added (2026-08-04) they're at `11:00.3`/`11:00.4` — identify by ID, not address: **PCI addresses shift when drives are added** (that same shift moved the audio `hostpci1` `10:00.6`→`11:00.6` and blocked VM 109 from starting until its config was updated). ⚠️ **Webcam history: the MX Brio was refunded 2026-07-24** after every path to its SuperSpeed modes failed (SS-over-redirection delivers no frames; both controller-passthrough attempts failed, one host-fatally — "Brio resolution ceiling" in the incident doc). Its successors are native USB 2.0: the interim **C922** (removed 2026-07-25, kept as spare) and the current **Brio 500** (`usb5`) — verified sustained 1080p30 MJPEG even in dim light (RightLight 4) with a clean mic under load. General lesson stands: webcams on this box are USB2/MJPEG, one 1080p stream at a time — don't chase SuperSpeed. `hostpci` changes need a host-side `qm reboot 109` (guest reboot does not apply them, and it kills any session running here); `usb*` redirection entries hot-plug on `qm set`. ⚠️ VM 109 **won't start if a redirected dongle/webcam is unplugged** — replug or `qm set 109 --delete usbN` first. Do **not** blacklist `nvidia` on the host (boot hang); the GPU's tiny `i2c_nvidia_gpu`/`i2c_ccgx_ucsi` helpers **are** blacklisted so `qm start` doesn't deadlock unbinding `08:00.3` (incident doc, Mode D)
- ⚠️ **Host storage: the `pve/data` thin pool filled to 100% on 2026-08-02** and silently corrupted guest filesystems for days (VM 109 unbootable, CTs failing to mount). Nothing trims automatically and the VG has no headroom to autoextend — when touching the node, glance at `lvs pve/data`; **Data% ≥ 95% is an emergency** (recover with `pct fstrim` per CT / `qm guest cmd 109 fstrim`). If sudo/DNS/binaries inside VM 109 ever break mysteriously, suspect zero-filled files from an EIO window — `qm guest exec 109` on the host is a root channel that bypasses broken guest sudo. Full playbook: [docs/Incident/proxmox-thinpool-full-incident.md](docs/Incident/proxmox-thinpool-full-incident.md)
- Motherboard RGB is driven by **OpenRGB as a host systemd service** (`192.168.2.70:6742`, open LAN-wide) for Home Assistant / any client — see [docs/OPENRGB_SERVER_SETUP.md](docs/OPENRGB_SERVER_SETUP.md). Do **not** USB-pass the Aura controller (`0b05:19af`) to a VM; it breaks host RGB control. The Aura **addressable** headers detect as 0 LEDs and must be resized — an `ExecStartPost` hook (`apply-boot-state.sh`) does this on every boot, else the case lights run a stuck rainbow
- Sensitive values (API tokens, passwords) must use **environment variables** or a `.tfvars` file — never hardcode credentials
- `.tfvars` files and `*.tfstate*` files must be in `.gitignore`

## Python / Scripting Conventions

- Python scripts are used to drive or wrap Terraform (e.g., templating, automation, test harnesses)
- Keep dependencies minimal; add to `pyproject.toml` via `uv add`
- No framework required for scripts — prefer stdlib where possible

## Testing

- This repo doubles as a **testing sandbox** — experimental code is expected
- Add tests under `tests/` using `pytest` when validating automation logic

## Security

- Never commit API tokens, passwords, or `.tfstate` files
- Use `TF_VAR_*` env vars or a gitignored `.tfvars` file for secrets
- `.envrc` should only activate the venv — do not store secrets there
