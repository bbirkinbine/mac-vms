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

require_cmd tart    "brew install --cask tart"
require_cmd packer  "brew install packer"
require_cmd xorriso "brew install xorriso"

# ---- env vars ---------------------------------------------------------------

if [[ -f "${ENV_FILE}" ]]; then
  echo "==> loading ${ENV_FILE}"
  set -o allexport
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +o allexport
fi

# Forward optional UBUNTU_* vars to PKR_VAR_*. Anything unset falls back to
# the defaults declared in variables.pkr.hcl.
[[ -n "${UBUNTU_VM_NAME:-}"      ]] && export PKR_VAR_vm_name="${UBUNTU_VM_NAME}"
[[ -n "${UBUNTU_CPU_COUNT:-}"    ]] && export PKR_VAR_cpu_count="${UBUNTU_CPU_COUNT}"
[[ -n "${UBUNTU_MEMORY_GB:-}"    ]] && export PKR_VAR_memory_gb="${UBUNTU_MEMORY_GB}"
[[ -n "${UBUNTU_DISK_SIZE_GB:-}" ]] && export PKR_VAR_disk_size_gb="${UBUNTU_DISK_SIZE_GB}"

# ---- ISO cache + verify -----------------------------------------------------
#
# The tart-cli builder's from_iso requires a local absolute path, not a URL.
# Download once into packer_cache/iso/ and verify the SHA256 from the
# upstream SHA256SUMS before handing the path to Packer.

UBUNTU_ISO_URL="${UBUNTU_ISO_URL:-https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.4-live-server-arm64.iso}"
UBUNTU_ISO_SHA256SUMS_URL="${UBUNTU_ISO_SHA256SUMS_URL:-https://cdimage.ubuntu.com/releases/24.04/release/SHA256SUMS}"

ISO_CACHE_DIR="${PACKER_DIR}/packer_cache/iso"
ISO_FILENAME="$(basename "${UBUNTU_ISO_URL}")"
ISO_PATH="${ISO_CACHE_DIR}/${ISO_FILENAME}"

mkdir -p "${ISO_CACHE_DIR}"

if [[ ! -f "${ISO_PATH}" ]]; then
  echo "==> downloading ${ISO_FILENAME}"
  echo "    from ${UBUNTU_ISO_URL}"
  curl -fL --retry 3 --retry-delay 5 -o "${ISO_PATH}.partial" "${UBUNTU_ISO_URL}"
  mv "${ISO_PATH}.partial" "${ISO_PATH}"
else
  echo "==> using cached ${ISO_PATH}"
fi

echo "==> verifying SHA256 of ${ISO_FILENAME}"
# SHA256SUMS lines look like: "<hash> *<filename>"; awk strips the leading '*'.
EXPECTED_SHA="$(curl -fsL "${UBUNTU_ISO_SHA256SUMS_URL}" \
  | awk -v f="${ISO_FILENAME}" '{ sub(/^\*/, "", $2); if ($2 == f) print $1 }')"
if [[ -z "${EXPECTED_SHA}" ]]; then
  echo "ERROR: no SHA256 entry for ${ISO_FILENAME} in ${UBUNTU_ISO_SHA256SUMS_URL}" >&2
  echo "       Check that UBUNTU_ISO_URL and UBUNTU_ISO_SHA256SUMS_URL point to the same release dir." >&2
  exit 1
fi
ACTUAL_SHA="$(shasum -a 256 "${ISO_PATH}" | awk '{print $1}')"
if [[ "${EXPECTED_SHA}" != "${ACTUAL_SHA}" ]]; then
  echo "ERROR: SHA256 mismatch for ${ISO_PATH}" >&2
  echo "  expected: ${EXPECTED_SHA}" >&2
  echo "  actual:   ${ACTUAL_SHA}" >&2
  echo "  Delete the file and re-run to redownload, or correct UBUNTU_ISO_URL." >&2
  exit 1
fi

# ---- ISO repack: autoinstall grub.cfg + NoCloud seed ------------------------
#
# Tuning Packer's boot_command keystrokes against ARM64 GRUB over VNC is a
# coin-flip exercise: timing depends on firmware-to-GRUB handoff, GRUB
# autoboot can fire before keystrokes land, and VNC keysym mapping varies.
#
# Instead we repack the upstream ISO once: replace boot/grub/grub.cfg with
# a minimal config that autoboots straight into autoinstall mode, and bake
# the contents of packer/.../http/ as a NoCloud seed at /nocloud/ on the
# ISO. The kernel cmdline points at ds=nocloud\;s=/cdrom/nocloud/ — no
# Packer HTTP server, no keystrokes, deterministic.

REPACK_ISO_PATH="${ISO_CACHE_DIR}/${ISO_FILENAME%.iso}-autoinstall.iso"
REPACK_TMP="$(mktemp -d -t mac-vms-iso-repack.XXXXXX)"
# Clean up the temp dir on any exit. Don't remove the cached output ISO.
trap 'rm -rf "${REPACK_TMP}"' EXIT

echo "==> staging NoCloud seed from ${PACKER_DIR}/http/"
mkdir -p "${REPACK_TMP}/nocloud"
cp "${PACKER_DIR}/http/user-data" "${REPACK_TMP}/nocloud/user-data"
cp "${PACKER_DIR}/http/meta-data" "${REPACK_TMP}/nocloud/meta-data"

# Minimal grub.cfg: timeout=2 so the build doesn't stall in the menu, one
# entry that autoboots into autoinstall with the NoCloud datasource pointed
# at the on-ISO seed dir. The '\;' escapes the GRUB command separator so
# the whole ds=... string reaches the kernel cmdline intact.
echo "==> writing autoinstall grub.cfg"
cat > "${REPACK_TMP}/grub.cfg" <<'GRUB_EOF'
set timeout=2
set default=0

menuentry "Ubuntu Server 24.04 autoinstall (mac-vms)" {
    set gfxpayload=keep
    linux  /casper/vmlinuz quiet autoinstall ds=nocloud\;s=/cdrom/nocloud/ --- console=tty0
    initrd /casper/initrd
}
GRUB_EOF

echo "==> repacking ISO with xorriso → ${REPACK_ISO_PATH##*/}"
# `-boot_image any keep` preserves the upstream boot records (EFI + GPT)
# so the new ISO still boots under Apple Virtualization.framework. `-map`
# replaces or adds individual files without re-encoding the rest.
rm -f "${REPACK_ISO_PATH}.partial"
xorriso \
  -indev  "${ISO_PATH}" \
  -outdev "${REPACK_ISO_PATH}.partial" \
  -boot_image any keep \
  -map "${REPACK_TMP}/grub.cfg"          /boot/grub/grub.cfg \
  -map "${REPACK_TMP}/nocloud/user-data" /nocloud/user-data \
  -map "${REPACK_TMP}/nocloud/meta-data" /nocloud/meta-data \
  >/dev/null 2>&1
mv "${REPACK_ISO_PATH}.partial" "${REPACK_ISO_PATH}"

export PKR_VAR_iso_path="${REPACK_ISO_PATH}"

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
