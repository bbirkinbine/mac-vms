#!/usr/bin/env bash
# build-ubuntu.sh — wrapper around `packer init/validate/build` for the
# Ubuntu 24.04 ARM64 base image.
#
# - Sources .env.local (gitignored) if present, for var overrides.
# - Validates Tart and Packer are on PATH.
# - Confirms host is Apple Silicon (Tart requirement).
# - Exports PKR_VAR_* env vars from any UBUNTU_* values found in .env.local.
# - Runs packer init, fmt -check, validate, build.
#
# Usage: ./scripts/build-ubuntu.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKER_DIR="${REPO_ROOT}/packer/ubuntu-24-04-arm64"
ENV_FILE="${REPO_ROOT}/.env.local"

# ---- host preconditions -----------------------------------------------------

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: this build runs on macOS only (Tart requires Apple Virtualization.framework)." >&2
  exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "ERROR: this build requires Apple Silicon (uname -m must be 'arm64'; got '$(uname -m)')." >&2
  exit 1
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command '$1' not found on PATH." >&2
    echo "       Install with: $2" >&2
    exit 1
  }
}

require_cmd tart   "brew install --cask tart"
require_cmd packer "brew install packer"

# ---- env vars ---------------------------------------------------------------

if [[ -f "${ENV_FILE}" ]]; then
  echo "==> loading ${ENV_FILE}"
  set -o allexport
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +o allexport
fi

# Forward UBUNTU_* vars to PKR_VAR_*. Anything unset falls back to the
# defaults declared in variables.pkr.hcl.
[[ -n "${UBUNTU_ISO_URL:-}"      ]] && export PKR_VAR_iso_url="${UBUNTU_ISO_URL}"
[[ -n "${UBUNTU_ISO_CHECKSUM:-}" ]] && export PKR_VAR_iso_checksum="${UBUNTU_ISO_CHECKSUM}"
[[ -n "${UBUNTU_VM_NAME:-}"      ]] && export PKR_VAR_vm_name="${UBUNTU_VM_NAME}"
[[ -n "${UBUNTU_CPU_COUNT:-}"    ]] && export PKR_VAR_cpu_count="${UBUNTU_CPU_COUNT}"
[[ -n "${UBUNTU_MEMORY_GB:-}"    ]] && export PKR_VAR_memory_gb="${UBUNTU_MEMORY_GB}"
[[ -n "${UBUNTU_DISK_SIZE_GB:-}" ]] && export PKR_VAR_disk_size_gb="${UBUNTU_DISK_SIZE_GB}"

# ---- packer pipeline --------------------------------------------------------

cd "${PACKER_DIR}"

echo "==> packer init"
packer init .

echo "==> packer fmt -check"
packer fmt -check . || {
  echo "WARN: 'packer fmt' would change formatting. Run 'packer fmt .' to fix." >&2
}

echo "==> packer validate"
packer validate .

echo "==> packer build"
exec packer build -on-error=ask .
