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
# Driver injection strategy (2026-05 rewrite):
#   - The previous design attached virtio-win.iso as a third CD-ROM and the
#     Autounattend referenced F:\viostor\w11\ARM64. WinPE drive-letter
#     enumeration on ARM64 + QEMU + EFI is non-deterministic, and the build
#     repeatedly failed at "no installable hard drives found" because the
#     Pnp injection block resolved to a path that wasn't there. (It also
#     silently no-op'd when VIRTIO_WIN_ISO_PATH was unset, which was the
#     state in committed .env.local.example.)
#   - This wrapper now extracts the ARM64 viostor + NetKVM driver subset
#     from virtio-win.iso into packer/windows-11-arm64/drivers/staging/,
#     which the Packer source includes in the same CD that carries
#     Autounattend.xml. The unattend block references the drivers via the
#     same media WinPE just read the answer file from, eliminating the
#     drive-letter guessing game. virtio-win.iso is still attached as a
#     separate CD for FirstLogonCommands to pick up virtio-win-guest-tools
#     after install.
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

require_cmd packer              "brew install packer"
require_cmd qemu-system-aarch64 "brew install qemu"
require_cmd swtpm               "brew install swtpm"
require_cmd xmllint             "comes with macOS; should already be present"
require_cmd hdiutil             "comes with macOS; should already be present"

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

# virtio-win.iso is now load-bearing for the build (not optional). The ARM64
# driver subset gets extracted into the unattend CD; the full ISO is also
# attached as a runtime CD so FirstLogonCommands can install virtio-win-
# guest-tools-arm64.msi after Setup completes.
if [[ -z "${VIRTIO_WIN_ISO_PATH:-}" ]]; then
  echo "ERROR: VIRTIO_WIN_ISO_PATH is not set." >&2
  echo "       Win11 ARM64 WinPE has no in-box drivers for QEMU's emulated" >&2
  echo "       storage; the install will fail at the disk-selection screen" >&2
  echo "       without injected virtio drivers." >&2
  echo "       Download:" >&2
  echo "         https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso" >&2
  echo "       and set VIRTIO_WIN_ISO_PATH in .env.local. Releases 0.1.240+ ship ARM64 binaries." >&2
  exit 1
fi

if [[ ! -f "${VIRTIO_WIN_ISO_PATH}" ]]; then
  echo "ERROR: VIRTIO_WIN_ISO_PATH points to a file that doesn't exist: ${VIRTIO_WIN_ISO_PATH}" >&2
  exit 1
fi

export PKR_VAR_iso_path="${WINDOWS_ISO_PATH}"
export PKR_VAR_virtio_win_iso_path="${VIRTIO_WIN_ISO_PATH}"
[[ -n "${WINDOWS_VM_NAME:-}"      ]] && export PKR_VAR_vm_name="${WINDOWS_VM_NAME}"
[[ -n "${WINDOWS_CPU_COUNT:-}"    ]] && export PKR_VAR_cpu_count="${WINDOWS_CPU_COUNT}"
[[ -n "${WINDOWS_MEMORY_GB:-}"    ]] && export PKR_VAR_memory_gb="${WINDOWS_MEMORY_GB}"
[[ -n "${WINDOWS_DISK_SIZE_GB:-}" ]] && export PKR_VAR_disk_size_gb="${WINDOWS_DISK_SIZE_GB}"

# ---- driver staging: extract ARM64 virtio drivers into the unattend CD ----
#
# WinPE on ARM64 24H2 has no in-box driver for QEMU's emulated storage. The
# Autounattend's Microsoft-Windows-PnpCustomizationsWinPE block injects
# viostor (virtio-blk) and NetKVM (virtio-net) before Setup probes for
# disks. We stage those into ./drivers/staging/ on the build host; the
# Packer source then bundles ./drivers/ into the same CD as Autounattend.xml
# via cd_files, eliminating the WinPE-drive-letter guessing game that
# attached-as-separate-CD-ROM made unavoidable.

DRIVERS_DIR="${PACKER_DIR}/drivers"
DRIVERS_STAGING="${DRIVERS_DIR}/staging"

# Mount virtio-win.iso read-only via hdiutil. Detach on any exit path.
VIRTIO_MOUNT="$(mktemp -d -t mac-vms-virtio-win.XXXXXX)"
cleanup_virtio_mount() {
  # hdiutil detach prints to stdout — silence it. Failure here is harmless
  # (already detached) so suppress nonzero exit.
  hdiutil detach "${VIRTIO_MOUNT}" -quiet 2>/dev/null || true
  rmdir "${VIRTIO_MOUNT}" 2>/dev/null || true
}
trap cleanup_virtio_mount EXIT

echo "==> mounting ${VIRTIO_WIN_ISO_PATH##*/}"
hdiutil attach -nobrowse -readonly -mountpoint "${VIRTIO_MOUNT}" "${VIRTIO_WIN_ISO_PATH}" >/dev/null

# Wipe any previous staging so renamed/removed drivers don't leak into
# the new build's CD.
rm -rf "${DRIVERS_STAGING}"
mkdir -p "${DRIVERS_STAGING}"

# Drivers WinPE needs at install time (storage + NIC). vioscsi covers the
# QEMU virtio-scsi controller in case we ever swap disk_interface; harmless
# to include alongside viostor. NetKVM is the virtio-net driver — without
# it, the FirstLogonCommands network-setup step hangs forever waiting for
# a DHCP lease that no driver will service.
WINPE_DRIVERS=(viostor vioscsi NetKVM)

# Path layout inside virtio-win.iso (as of 0.1.240+):
#   /<driver>/w11/ARM64/<driver>.{cat,inf,sys}
# Where w11 is the Win11/Server 2022 driver class. The .cat file is the
# Microsoft-signed catalog — Secure Boot rejects the load without it.
echo "==> staging ARM64 drivers into ${DRIVERS_STAGING#${REPO_ROOT}/}"
missing=()
for d in "${WINPE_DRIVERS[@]}"; do
  src="${VIRTIO_MOUNT}/${d}/w11/ARM64"
  if [[ ! -d "${src}" ]]; then
    missing+=("${d}")
    continue
  fi
  # Use cp -R with /. so we copy contents into the destination, not the
  # ARM64 directory itself. Result: drivers/staging/viostor/viostor.{cat,inf,sys}.
  mkdir -p "${DRIVERS_STAGING}/${d}"
  cp -R "${src}/." "${DRIVERS_STAGING}/${d}/"
done

if (( ${#missing[@]} > 0 )); then
  echo "ERROR: ARM64 driver tree missing from virtio-win.iso for: ${missing[*]}" >&2
  echo "       Expected ${VIRTIO_MOUNT}/<driver>/w11/ARM64/ to exist." >&2
  echo "       Your virtio-win.iso may pre-date 0.1.240 (first release shipping" >&2
  echo "       ARM64 binaries). Upgrade and retry." >&2
  exit 1
fi

# Detach now — we won't need the iso mounted again before packer launches
# qemu (which uses VIRTIO_WIN_ISO_PATH directly, not the mount).
cleanup_virtio_mount
trap - EXIT

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
# The qemu wrapper also reads VIRTIO_WIN_ISO_PATH (re-export for clarity
# even though it's already exported from .env.local source above).
export VIRTIO_WIN_ISO_PATH

echo "==> virtio-win driver ISO: ${VIRTIO_WIN_ISO_PATH##*/}"

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
