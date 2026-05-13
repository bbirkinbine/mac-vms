#!/usr/bin/env bash
# build-windows.sh — wrapper around `packer init/validate/build` for the
# Windows 11 ARM64 base image.
#
# Same shape as build-ubuntu.sh. Sibling wrapper rather than a dispatcher
# because preconditions diverge (Windows needs a user-supplied VHDX path;
# Ubuntu fetches its ISO).
#
# Usage: ./scripts/build-windows.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKER_DIR="${REPO_ROOT}/packer/windows-11-arm64"
ENV_FILE="${REPO_ROOT}/.env.local"

# ---- host preconditions -----------------------------------------------------

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "ERROR: this build runs on macOS only." >&2
  exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "ERROR: this build requires Apple Silicon." >&2
  exit 1
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command '$1' not found on PATH." >&2
    echo "       Install with: $2" >&2
    exit 1
  }
}

require_cmd tart    "brew install --cask tart"
require_cmd packer  "brew install packer"
require_cmd xmllint "comes with macOS; should already be present"

# ---- env vars ---------------------------------------------------------------

if [[ -f "${ENV_FILE}" ]]; then
  echo "==> loading ${ENV_FILE}"
  set -o allexport
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +o allexport
fi

if [[ -z "${WINDOWS_VHDX_PATH:-}" ]]; then
  echo "ERROR: WINDOWS_VHDX_PATH is not set." >&2
  echo "       Download the Windows 11 ARM64 VHDX from the Microsoft Insider site" >&2
  echo "       and set WINDOWS_VHDX_PATH in .env.local. See" >&2
  echo "       packer/windows-11-arm64/README.md for details." >&2
  exit 1
fi

if [[ ! -f "${WINDOWS_VHDX_PATH}" ]]; then
  echo "ERROR: WINDOWS_VHDX_PATH points to a file that doesn't exist: ${WINDOWS_VHDX_PATH}" >&2
  exit 1
fi

export PKR_VAR_vhdx_path="${WINDOWS_VHDX_PATH}"
[[ -n "${WINDOWS_VM_NAME:-}"      ]] && export PKR_VAR_vm_name="${WINDOWS_VM_NAME}"
[[ -n "${WINDOWS_CPU_COUNT:-}"    ]] && export PKR_VAR_cpu_count="${WINDOWS_CPU_COUNT}"
[[ -n "${WINDOWS_MEMORY_GB:-}"    ]] && export PKR_VAR_memory_gb="${WINDOWS_MEMORY_GB}"
[[ -n "${WINDOWS_DISK_SIZE_GB:-}" ]] && export PKR_VAR_disk_size_gb="${WINDOWS_DISK_SIZE_GB}"

# ---- packer pipeline --------------------------------------------------------

cd "${PACKER_DIR}"

echo "==> xmllint Autounattend.xml"
xmllint --noout Autounattend.xml

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
