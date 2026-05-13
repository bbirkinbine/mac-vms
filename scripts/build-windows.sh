#!/usr/bin/env bash
# build-windows.sh — wrapper around `packer init/validate/build` for the
# Windows 11 ARM64 base image.
#
# Differs from build-ubuntu.sh in two material ways:
#   - The Windows ISO is bring-your-own (Microsoft doesn't permit
#     redistribution). The wrapper validates the path you provide via
#     WINDOWS_ISO_PATH and optionally verifies SHA256.
#   - The build needs TPM 2.0 + UEFI Secure Boot for Win11 system-requirements
#     check. We use Packer's qemu source with swtpm providing the TPM and
#     edk2 providing the UEFI firmware. The wrapper starts swtpm in the
#     background, exports its socket path, then cleans up on exit.
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

require_cmd packer             "brew install packer"
require_cmd qemu-system-aarch64 "brew install qemu"
require_cmd swtpm              "brew install swtpm"
require_cmd xmllint            "comes with macOS; should already be present"

# ---- env vars ---------------------------------------------------------------

if [[ -f "${ENV_FILE}" ]]; then
  echo "==> loading ${ENV_FILE}"
  set -o allexport
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +o allexport
fi

if [[ -z "${WINDOWS_ISO_PATH:-}" ]]; then
  echo "ERROR: WINDOWS_ISO_PATH is not set." >&2
  echo "       Download the Windows 11 ARM64 ISO from" >&2
  echo "       https://www.microsoft.com/software-download/windows11arm64 and set" >&2
  echo "       WINDOWS_ISO_PATH in .env.local. See packer/windows-11-arm64/README.md." >&2
  exit 1
fi

if [[ ! -f "${WINDOWS_ISO_PATH}" ]]; then
  echo "ERROR: WINDOWS_ISO_PATH points to a file that doesn't exist: ${WINDOWS_ISO_PATH}" >&2
  exit 1
fi

# Optional SHA256 verification. Microsoft publishes the hash on the download
# page; if the user pasted it into WINDOWS_ISO_SHA256, verify before sinking
# ~20 minutes into a build against a corrupt file. Lower-cased and stripped
# of any whitespace to be forgiving about copy-paste shape.
if [[ -n "${WINDOWS_ISO_SHA256:-}" ]]; then
  EXPECTED_SHA="$(echo "${WINDOWS_ISO_SHA256}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  echo "==> verifying SHA256 of ${WINDOWS_ISO_PATH##*/}"
  ACTUAL_SHA="$(shasum -a 256 "${WINDOWS_ISO_PATH}" | awk '{print $1}')"
  if [[ "${EXPECTED_SHA}" != "${ACTUAL_SHA}" ]]; then
    echo "ERROR: SHA256 mismatch for ${WINDOWS_ISO_PATH}" >&2
    echo "  expected: ${EXPECTED_SHA}" >&2
    echo "  actual:   ${ACTUAL_SHA}" >&2
    echo "  Re-download the ISO, or update WINDOWS_ISO_SHA256 in .env.local." >&2
    exit 1
  fi
else
  echo "WARN: WINDOWS_ISO_SHA256 unset — proceeding without integrity check." >&2
  echo "      Paste Microsoft's published SHA256 into .env.local to enable verification." >&2
fi

export PKR_VAR_iso_path="${WINDOWS_ISO_PATH}"
[[ -n "${WINDOWS_VM_NAME:-}"      ]] && export PKR_VAR_vm_name="${WINDOWS_VM_NAME}"
[[ -n "${WINDOWS_CPU_COUNT:-}"    ]] && export PKR_VAR_cpu_count="${WINDOWS_CPU_COUNT}"
[[ -n "${WINDOWS_MEMORY_GB:-}"    ]] && export PKR_VAR_memory_gb="${WINDOWS_MEMORY_GB}"
[[ -n "${WINDOWS_DISK_SIZE_GB:-}" ]] && export PKR_VAR_disk_size_gb="${WINDOWS_DISK_SIZE_GB}"

# ---- swtpm (TPM 2.0 emulator) ----------------------------------------------
#
# Windows 11 system-requirements check refuses to install without a TPM 2.0.
# swtpm provides one over a Unix socket; QEMU connects to it (we wire the
# qemu args in windows.pkr.hcl). Start it before Packer and ensure it gets
# torn down on any exit path.

SWTPM_DIR="${PACKER_DIR}/packer_cache/swtpm"
SWTPM_SOCK="${SWTPM_DIR}/sock"
SWTPM_LOG="${SWTPM_DIR}/log"
SWTPM_PIDFILE="${SWTPM_DIR}/pid"

cleanup_swtpm() {
  if [[ -f "${SWTPM_PIDFILE}" ]]; then
    kill "$(cat "${SWTPM_PIDFILE}")" 2>/dev/null || true
    rm -f "${SWTPM_PIDFILE}"
  fi
}
trap cleanup_swtpm EXIT

mkdir -p "${SWTPM_DIR}"
# Wipe any stale state from prior runs — TPM state is per-build for our
# purposes, not something to carry forward.
rm -f "${SWTPM_SOCK}" "${SWTPM_PIDFILE}"
rm -rf "${SWTPM_DIR}/tpm2-00.permall" 2>/dev/null || true

echo "==> starting swtpm (TPM 2.0 emulator)"
swtpm socket \
  --tpmstate "dir=${SWTPM_DIR}" \
  --ctrl "type=unixio,path=${SWTPM_SOCK}" \
  --log "file=${SWTPM_LOG},level=20" \
  --pid "file=${SWTPM_PIDFILE}" \
  --tpm2 \
  --daemon

# Sanity: did it actually come up?
sleep 1
if [[ ! -S "${SWTPM_SOCK}" ]]; then
  echo "ERROR: swtpm socket ${SWTPM_SOCK} did not appear. Check ${SWTPM_LOG}." >&2
  exit 1
fi

# The qemu wrapper script reads SWTPM_SOCK from its env and appends the
# TPM args to whatever Packer generates. PKR_VAR_qemu_binary points
# Packer at the wrapper instead of qemu-system-aarch64 directly.
export SWTPM_SOCK
export PKR_VAR_qemu_binary="${REPO_ROOT}/scripts/qemu-with-tpm.sh"

# Optional virtio-win driver ISO. Win11 ARM's WinPE has no in-box drivers
# for QEMU's emulated storage; the installer can't see the disk without
# Microsoft-signed virtio drivers loaded via Autounattend.xml's
# Microsoft-Windows-PnpCustomizationsWinPE block. The wrapper attaches
# this ISO as a third CD-ROM when set, so the unattend file can reference
# its driver paths.
if [[ -n "${VIRTIO_WIN_ISO_PATH:-}" ]]; then
  if [[ ! -f "${VIRTIO_WIN_ISO_PATH}" ]]; then
    echo "ERROR: VIRTIO_WIN_ISO_PATH points to a file that doesn't exist: ${VIRTIO_WIN_ISO_PATH}" >&2
    exit 1
  fi
  echo "==> virtio-win driver ISO: ${VIRTIO_WIN_ISO_PATH##*/}"
  export VIRTIO_WIN_ISO_PATH
else
  echo "WARN: VIRTIO_WIN_ISO_PATH unset. Win11 ARM Setup will not see the disk." >&2
  echo "      Download https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso" >&2
  echo "      and set VIRTIO_WIN_ISO_PATH in .env.local. See packer/windows-11-arm64/README.md." >&2
fi

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
# Don't `exec` — we want the EXIT trap to fire and tear down swtpm.
packer build -on-error=ask .
