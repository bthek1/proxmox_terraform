# justfile — Terraform commands for Proxmox LXC management
# Usage: just <recipe>  (run `just` or `just --list` to see all recipes)

tf_dir := "terraform/lxc"

# List all available recipes
default:
    @just --list

# ── Init ────────────────────────────────────────────────────────────────────

# Initialise Terraform (download providers)
init:
    terraform -chdir={{ tf_dir }} init

# Upgrade providers to latest allowed versions
upgrade:
    terraform -chdir={{ tf_dir }} init -upgrade

# ── Plan / Apply / Destroy ───────────────────────────────────────────────────

# Show execution plan
plan:
    terraform -chdir={{ tf_dir }} plan -var-file=terraform.tfvars

# Apply changes (prompts for confirmation)
apply:
    terraform -chdir={{ tf_dir }} apply -var-file=terraform.tfvars

# Apply without interactive prompt
apply-auto:
    terraform -chdir={{ tf_dir }} apply -var-file=terraform.tfvars -auto-approve

# Destroy all resources (prompts for confirmation)
destroy:
    terraform -chdir={{ tf_dir }} destroy -var-file=terraform.tfvars

# Destroy without interactive prompt
destroy-auto:
    terraform -chdir={{ tf_dir }} destroy -var-file=terraform.tfvars -auto-approve

# ── Inspect ──────────────────────────────────────────────────────────────────

# Show current Terraform state
show:
    terraform -chdir={{ tf_dir }} show

# List resources in state
state:
    terraform -chdir={{ tf_dir }} state list

# Show outputs
output:
    terraform -chdir={{ tf_dir }} output

# ── Validate / Format ────────────────────────────────────────────────────────

# Validate configuration files
validate:
    terraform -chdir={{ tf_dir }} validate

# Format all .tf files
fmt:
    terraform -chdir={{ tf_dir }} fmt -recursive

# Check formatting without writing (CI-safe)
fmt-check:
    terraform -chdir={{ tf_dir }} fmt -recursive -check

# ── Convenience ──────────────────────────────────────────────────────────────

# init → validate → plan
check: init validate plan

# init → validate → apply-auto
deploy: init validate apply-auto
