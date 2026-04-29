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

- Terraform files go in `terraform/` (create if needed), organized by resource type or environment
- Use the [Telmate/proxmox](https://registry.terraform.io/providers/Telmate/proxmox/latest/docs) or [bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox/latest/docs) provider
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
