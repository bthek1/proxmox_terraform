#!/usr/bin/env bash
# plan-apply.sh — Run terraform plan and optionally apply for Proxmox infra
# Usage: plan-apply.sh <plan|apply> [terraform-dir] [extra terraform flags...]
set -euo pipefail

MODE="${1:-plan}"
TF_DIR="${2:-terraform}"
shift 2 2>/dev/null || true
EXTRA_FLAGS=("$@")

# Validate mode
if [[ "$MODE" != "plan" && "$MODE" != "apply" ]]; then
  echo "ERROR: first argument must be 'plan' or 'apply', got: $MODE" >&2
  exit 1
fi

# Validate required env vars
MISSING=()
for var in PROXMOX_VE_ENDPOINT; do
  [[ -z "${!var:-}" ]] && MISSING+=("$var")
done
if [[ -z "${PROXMOX_VE_PASSWORD:-}" && -z "${PROXMOX_VE_API_TOKEN:-}" ]]; then
  MISSING+=("PROXMOX_VE_PASSWORD or PROXMOX_VE_API_TOKEN")
fi
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "ERROR: missing required environment variables:" >&2
  printf '  %s\n' "${MISSING[@]}" >&2
  exit 1
fi

cd "$TF_DIR"

# Init if .terraform directory doesn't exist
if [[ ! -d ".terraform" ]]; then
  echo "==> terraform init"
  terraform init
fi

echo "==> terraform plan"
terraform plan -out=tfplan "${EXTRA_FLAGS[@]}"

if [[ "$MODE" == "apply" ]]; then
  echo ""
  echo "==> terraform apply"
  terraform apply tfplan
  echo ""
  echo "==> terraform output"
  terraform output
fi
