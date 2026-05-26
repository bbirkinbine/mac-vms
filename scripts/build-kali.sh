#!/usr/bin/env bash
# build-kali.sh — wrapper around `packer init/validate/build` for the
# Kali rolling ARM64 base image.
#
# - Sources .env.local (gitignored) if present, for var overrides.
# - Validates Tart, Packer, and xorriso are on PATH.
# - Confirms host is Apple Silicon (Tart requirement).
# - Downloads + verifies the Kali installer ISO against upstream SHA256SUMS.
# - sed-substitutes KALI_META_PKG into a staged copy of http/preseed.cfg.
# - Repacks the ISO with a preseed-autoboot grub.cfg + the staged preseed
#   baked in at /preseed/preseed.cfg.
# - Exports PKR_VAR_* env vars from any KALI_* values in .env.local.
# - Runs packer init, fmt -check, validate, build.
#
# Usage: ./scripts/build-kali.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKER_DIR="${REPO_ROOT}/packer/kali-rolling-arm64"
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

# Forward optional KALI_* vars to PKR_VAR_*. Anything unset falls back to
# the defaults declared in variables.pkr.hcl.
[[ -n "${KALI_VM_NAME:-}"      ]] && export PKR_VAR_vm_name="${KALI_VM_NAME}"
[[ -n "${KALI_CPU_COUNT:-}"    ]] && export PKR_VAR_cpu_count="${KALI_CPU_COUNT}"
[[ -n "${KALI_MEMORY_GB:-}"    ]] && export PKR_VAR_memory_gb="${KALI_MEMORY_GB}"
[[ -n "${KALI_DISK_SIZE_GB:-}" ]] && export PKR_VAR_disk_size_gb="${KALI_DISK_SIZE_GB}"

# KALI_META_PKG is NOT forwarded as PKR_VAR — it's consumed by the
# sed-substitute pass below, since the preseed is xorriso-baked into the
# ISO and Packer never templates it. See docs/kali-vs-ubuntu.md.
KALI_META_PKG="${KALI_META_PKG:-kali-linux-headless}"

# Allowlist the legal values rather than letting a typo silently produce a
# preseed referencing a non-existent metapackage (which would fail mid-
# install ~30 minutes in).
case "${KALI_META_PKG}" in
  kali-linux-core|kali-linux-headless|kali-linux-default|kali-linux-everything) ;;
  *)
    echo "ERROR: KALI_META_PKG='${KALI_META_PKG}' is not a recognized Kali meta-package." >&2
    echo "       Valid values: kali-linux-core, kali-linux-headless, kali-linux-default, kali-linux-everything." >&2
    exit 1
    ;;
esac

# ---- ISO cache + verify -----------------------------------------------------
#
# The tart-cli builder's from_iso requires a local absolute path, not a URL.
# Download once into packer_cache/iso/ and verify the SHA256 from the
# upstream SHA256SUMS before handing the path to Packer.
#
# Kali's cdimage layout is "version-stamped filenames inside a 'current/'
# symlinked directory" — i.e. there's no `kali-linux-current-installer-
# arm64.iso` alias, only `kali-linux-2026.1-installer-arm64.iso`-style
# filenames. To keep the default URL valid across point releases, when
# the user hasn't pinned KALI_ISO_URL we parse the upstream SHA256SUMS
# and pick the first non-netinst installer-arm64 entry.

KALI_ISO_BASE_URL="${KALI_ISO_BASE_URL:-https://cdimage.kali.org/current/}"
# Normalize: ensure trailing slash for clean concatenation below.
KALI_ISO_BASE_URL="${KALI_ISO_BASE_URL%/}/"
KALI_ISO_SHA256SUMS_URL="${KALI_ISO_SHA256SUMS_URL:-${KALI_ISO_BASE_URL}SHA256SUMS}"

if [[ -z "${KALI_ISO_URL:-}" ]]; then
  echo "==> resolving Kali installer ISO filename from ${KALI_ISO_SHA256SUMS_URL}"
  # Prefer the full installer (offline package set) over the netinst, which
  # is the more conservative choice if a Kali mirror is slow during the
  # build. The regex matches `kali-linux-<version>-installer-arm64.iso`
  # exactly, excluding `-installer-netinst-arm64.iso` and `-live-arm64.iso`.
  ISO_FILENAME="$(curl -fsL "${KALI_ISO_SHA256SUMS_URL}" \
    | awk '{ sub(/^\*/, "", $2); if ($2 ~ /^kali-linux-[0-9][^ ]*-installer-arm64\.iso$/) { print $2; exit } }')"
  if [[ -z "${ISO_FILENAME}" ]]; then
    echo "ERROR: could not find a kali-linux-*-installer-arm64.iso entry in ${KALI_ISO_SHA256SUMS_URL}" >&2
    echo "       Kali may have changed the filename convention. Set KALI_ISO_URL explicitly to override." >&2
    exit 1
  fi
  KALI_ISO_URL="${KALI_ISO_BASE_URL}${ISO_FILENAME}"
  echo "    selected ${ISO_FILENAME}"
fi

ISO_CACHE_DIR="${PACKER_DIR}/packer_cache/iso"
ISO_FILENAME="$(basename "${KALI_ISO_URL}")"
ISO_PATH="${ISO_CACHE_DIR}/${ISO_FILENAME}"

mkdir -p "${ISO_CACHE_DIR}"

if [[ ! -f "${ISO_PATH}" ]]; then
  echo "==> downloading ${ISO_FILENAME}"
  echo "    from ${KALI_ISO_URL}"
  curl -fL --retry 3 --retry-delay 5 -o "${ISO_PATH}.partial" "${KALI_ISO_URL}"
  mv "${ISO_PATH}.partial" "${ISO_PATH}"
else
  echo "==> using cached ${ISO_PATH}"
fi

echo "==> verifying SHA256 of ${ISO_FILENAME}"
# Kali's SHA256SUMS lines look like: "<hash>  <filename>" (no leading '*').
# Strip a leading '*' on $2 anyway so the same parser handles both
# conventions, matching the Ubuntu wrapper.
EXPECTED_SHA="$(curl -fsL "${KALI_ISO_SHA256SUMS_URL}" \
  | awk -v f="${ISO_FILENAME}" '{ sub(/^\*/, "", $2); if ($2 == f) print $1 }')"
if [[ -z "${EXPECTED_SHA}" ]]; then
  echo "ERROR: no SHA256 entry for ${ISO_FILENAME} in ${KALI_ISO_SHA256SUMS_URL}" >&2
  echo "       Check that KALI_ISO_URL and KALI_ISO_SHA256SUMS_URL point to the same release dir." >&2
  exit 1
fi
ACTUAL_SHA="$(shasum -a 256 "${ISO_PATH}" | awk '{print $1}')"
if [[ "${EXPECTED_SHA}" != "${ACTUAL_SHA}" ]]; then
  echo "ERROR: SHA256 mismatch for ${ISO_PATH}" >&2
  echo "  expected: ${EXPECTED_SHA}" >&2
  echo "  actual:   ${ACTUAL_SHA}" >&2
  echo "  Delete the file and re-run to redownload, or correct KALI_ISO_URL." >&2
  exit 1
fi

# ---- ISO repack: autoinstall grub.cfg + preseed ----------------------------
#
# Same shape as the Ubuntu wrapper: tuning Packer boot_command keystrokes
# against ARM64 GRUB over VNC is fragile, so we repack the upstream ISO
# once with a deterministic preseed entry. Differences from Ubuntu:
#   - The preseed lives at /preseed/preseed.cfg on the ISO (not under
#     /nocloud/ — that path is for cloud-init's NoCloud).
#   - The kernel cmdline points d-i at the preseed via
#     preseed/file=/cdrom/preseed/preseed.cfg, not via cloud-init's
#     ds=nocloud;s=/cdrom/nocloud/.
#   - The kernel/initrd live under /install.a64/ (d-i ARM64 convention),
#     not /casper/ (Ubuntu live ISO).
#   - KALI_META_PKG is sed-substituted into the staged preseed before the
#     repack — Packer never sees the preseed, so this is the only template
#     pass.

REPACK_ISO_PATH="${ISO_CACHE_DIR}/${ISO_FILENAME%.iso}-autoinstall.iso"
REPACK_TMP="$(mktemp -d -t mac-vms-iso-repack.XXXXXX)"
trap 'rm -rf "${REPACK_TMP}"' EXIT

echo "==> staging preseed.cfg with KALI_META_PKG=${KALI_META_PKG}"
mkdir -p "${REPACK_TMP}/preseed"
PRESEED_SRC="${PACKER_DIR}/http/preseed.cfg"
PRESEED_STAGED="${REPACK_TMP}/preseed/preseed.cfg"
cp "${PRESEED_SRC}" "${PRESEED_STAGED}"

# Confirm the placeholder is present before we sed it. If someone edits
# preseed.cfg and accidentally removes __KALI_META_PKG__, we want a loud
# failure here, not a silent install of whatever-was-left.
if ! grep -q '__KALI_META_PKG__' "${PRESEED_STAGED}"; then
  echo "ERROR: placeholder __KALI_META_PKG__ not found in ${PRESEED_SRC}" >&2
  echo "       The wrapper expects this token in the d-i pkgsel/include line." >&2
  exit 1
fi
# In-place substitute. macOS sed needs an explicit empty suffix for -i.
sed -i '' "s/__KALI_META_PKG__/${KALI_META_PKG}/g" "${PRESEED_STAGED}"

# Sanity: the placeholder must be GONE post-sed (catches an unusual KALI_META_PKG
# that re-introduces it, e.g. if someone sets a value containing the literal token).
if grep -q '__KALI_META_PKG__' "${PRESEED_STAGED}"; then
  echo "ERROR: __KALI_META_PKG__ placeholder still present in staged preseed after substitution." >&2
  echo "       Inspect ${PRESEED_STAGED} — the value of KALI_META_PKG may contain the token." >&2
  exit 1
fi

# Minimal grub.cfg: timeout=2 so the build doesn't stall in the menu, one
# entry that autoboots into d-i preseed mode pointed at the on-ISO seed
# file. auto=true + priority=critical suppress every non-critical prompt;
# the preseed answers the critical ones.
echo "==> writing autoinstall grub.cfg"
cat > "${REPACK_TMP}/grub.cfg" <<'GRUB_EOF'
set timeout=2
set default=0

menuentry "Kali rolling autoinstall (mac-vms)" {
    set gfxpayload=keep
    linux  /install.a64/vmlinuz auto=true priority=critical preseed/file=/cdrom/preseed/preseed.cfg --- quiet
    initrd /install.a64/initrd.gz
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
  -map "${REPACK_TMP}/grub.cfg"      /boot/grub/grub.cfg \
  -map "${PRESEED_STAGED}"           /preseed/preseed.cfg \
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
