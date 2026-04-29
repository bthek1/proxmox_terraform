---
description: "Use when writing, reviewing, or editing Terraform (.tf) files for Proxmox. Covers naming conventions, variable patterns, provider config, and state backend requirements."
applyTo: "**/*.tf"
---

# Terraform Conventions

## Naming
- All resource names, variable names, and output names use `snake_case`
- Resource names describe the thing, not the type: `web_server` not `proxmox_vm_web`
- Locals are prefixed with their purpose: `local.vm_tags`, `local.network_config`

## Variables
- Every configurable value must be a variable — no hardcoded IPs, node names, or IDs in resource blocks
- Sensitive variables (tokens, passwords) must set `sensitive = true`
- Variables without defaults are required inputs — only omit defaults for values that must be explicitly set per environment (e.g. `vm_id`, `proxmox_endpoint`)
- Use `description` on every variable and output

## Credentials / Secrets
- Never hardcode credentials in `.tf` files
- Use `TF_VAR_*` environment variables or a gitignored `terraform.tfvars` / `*.auto.tfvars` file
- `*.tfvars` and `*.tfstate*` must remain in `.gitignore`

## Provider: bpg/proxmox
- Preferred provider: [`bpg/proxmox`](https://registry.terraform.io/providers/bpg/proxmox/latest/docs)
- Credentials via env vars: `PROXMOX_VE_USERNAME`, `PROXMOX_VE_PASSWORD`, or `PROXMOX_VE_API_TOKEN`
- Pin to a minor version: `~> 0.75`

## File Layout (under `terraform/`)
| File | Purpose |
|------|---------|
| `provider.tf` | Provider + required_providers block |
| `versions.tf` | `terraform {}` block with `required_version` |
| `main.tf` | Primary resources |
| `variables.tf` | All input variables |
| `outputs.tf` | All outputs |
| `locals.tf` | Computed locals (optional) |

## State Backend
- Default: local state is fine for experiments
- For shared/persistent infra, configure a remote backend (e.g. S3, Terraform Cloud) in `provider.tf` or a separate `backend.tf`
- Never commit `terraform.tfstate` or `terraform.tfstate.backup`

## Formatting
- Run `terraform fmt` before committing
- Run `terraform validate` after any structural change
