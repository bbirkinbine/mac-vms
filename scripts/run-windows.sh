#!/usr/bin/env bash
# run-windows.sh — boot the Packer-built Windows 11 ARM64 qcow2 directly
# under qemu-system-aarch64, using the same TPM + EFI + ramfb + USB plumbing
# the build used. No Packer, no UTM in the way.
#
# This is the "did the artifact actually come out working?" probe. If it
# boots here, the qcow2 is good and any subsequent UTM/Tart/distribution
# problem is downstream of this. If it doesn't boot here, the build is
# the place to look.
#
# Defaults to a copy-on-write clone (`run.qcow2`) and a per-session NVRAM
# copy (`run-vars.fd`) so reruns don't dirty the base artifact. The base
# qcow2 stays sysprep-fresh for cloning into other targets.
#
# Usage:
#   ./scripts/run-windows.sh             # boot existing or freshly-created COW
#   ./scripts/run-windows.sh --fresh     # wipe COW + NVRAM and start clean
#   ./scripts/run-windows.sh --base      # boot the base qcow2 directly (DIRTIES IT)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/packer/windows-11-arm64/output-windows-11-arm64"

BASE_QCOW2="${OUTPUT_DIR}/windows-11-arm64-base.qcow2"
BASE_EFIVARS="${OUTPUT_DIR}/efivars.fd"

# ---- argument parsing ------------------------------------------------------

mode="cow"
for arg in "$@"; do
  case "$arg" in
    --fresh) mode="fresh" ;;
    --base)  mode="base"  ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "ERROR: unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# ---- preconditions ---------------------------------------------------------

for c in qemu-system-aarch64 swtpm qemu-img; do
  command -v "$c" >/dev/null 2>&1 || {
    echo "ERROR: '$c' not on PATH" >&2; exit 1
  }
done

if [[ ! -f "${BASE_QCOW2}" ]]; then
  echo "ERROR: base qcow2 not found at ${BASE_QCOW2}" >&2
  echo "       Run 'just build-windows' first." >&2
  exit 1
fi

if [[ ! -f "${BASE_EFIVARS}" ]]; then
  echo "ERROR: NVRAM file not found at ${BASE_EFIVARS}" >&2
  echo "       Packer's qemu plugin should write this alongside the qcow2." >&2
  echo "       Without it the VM boots into firmware setup (empty BootOrder)." >&2
  exit 1
fi

EFI_CODE="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
if [[ ! -f "${EFI_CODE}" ]]; then
  echo "ERROR: EFI code not found at ${EFI_CODE}" >&2
  echo "       'brew install qemu' should put it there." >&2
  exit 1
fi

# ---- disk + NVRAM selection ------------------------------------------------

case "$mode" in
  base)
    QCOW2="${BASE_QCOW2}"
    EFIVARS="${BASE_EFIVARS}"
    echo "==> mode: base (booting and dirtying the build artifact directly)"
    echo "    NB: this consumes the sysprep'd state. Use --fresh next time"
    echo "        to restore a clean OOBE-first-boot experience."
    ;;
  fresh|cow)
    QCOW2="${OUTPUT_DIR}/run.qcow2"
    EFIVARS="${OUTPUT_DIR}/run-vars.fd"
    if [[ "$mode" == "fresh" ]]; then
      echo "==> mode: fresh (wiping COW + NVRAM)"
      rm -f "${QCOW2}" "${EFIVARS}"
    fi
    if [[ ! -f "${QCOW2}" ]]; then
      echo "==> creating copy-on-write clone of ${BASE_QCOW2##*/}"
      qemu-img create -f qcow2 \
        -b "${BASE_QCOW2}" -F qcow2 \
        "${QCOW2}" >/dev/null
    fi
    if [[ ! -f "${EFIVARS}" ]]; then
      echo "==> seeding NVRAM from ${BASE_EFIVARS##*/}"
      cp "${BASE_EFIVARS}" "${EFIVARS}"
    fi
    ;;
esac

# ---- swtpm -----------------------------------------------------------------
#
# macOS sun_path limit is 104 bytes. The OUTPUT_DIR path under the repo's
# packer/windows-11-arm64/output-windows-11-arm64/ blows that limit when
# $HOME is long. Live the swtpm state in /tmp — short, ephemeral, trapped.

SWTPM_DIR="$(mktemp -d -t macvms-run.XXXXXX)"
SWTPM_SOCK="${SWTPM_DIR}/s"
SWTPM_PIDFILE="${SWTPM_DIR}/p"

cleanup() {
  if [[ -f "${SWTPM_PIDFILE}" ]]; then
    kill "$(cat "${SWTPM_PIDFILE}")" 2>/dev/null || true
  fi
  rm -rf "${SWTPM_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> starting swtpm"
swtpm socket \
  --tpmstate "dir=${SWTPM_DIR}" \
  --ctrl "type=unixio,path=${SWTPM_SOCK}" \
  --pid "file=${SWTPM_PIDFILE}" \
  --tpm2 \
  --daemon

sleep 1
if [[ ! -S "${SWTPM_SOCK}" ]]; then
  echo "ERROR: swtpm socket did not appear" >&2
  exit 1
fi

echo "==> booting ${QCOW2##*/}"
echo "    NVRAM: ${EFIVARS##*/}"
echo
echo "    Ctrl+Cmd+F          full-screen toggle"
echo "    Ctrl+Alt+G          release captured mouse (rarely needed with usb-tablet)"
echo "    qemu monitor:       Ctrl+Alt+2  (Ctrl+Alt+1 to return to VM)"
echo

# Args mirror what scripts/qemu-with-tpm.sh produces during the build, minus
# the install ISO, the unattend CD, and the virtio-win.iso CD. The disk and
# NVRAM are the only thing changed; everything else (machine, accel, cpu,
# tpm, ramfb, USB, virtio-net) is identical so we don't introduce platform
# drift between "what built it" and "what runs it".
exec qemu-system-aarch64 \
  -machine "virt,gic-version=max" \
  -accel hvf \
  -cpu host \
  -smp 4 -m 8192 \
  -drive "if=pflash,format=raw,readonly=on,file=${EFI_CODE}" \
  -drive "if=pflash,format=raw,file=${EFIVARS}" \
  -chardev "socket,id=chrtpm,path=${SWTPM_SOCK}" \
  -tpmdev "emulator,id=tpm0,chardev=chrtpm" \
  -device "tpm-tis-device,tpmdev=tpm0" \
  -device "ramfb" \
  -device "qemu-xhci,id=usb" \
  -device "usb-kbd,bus=usb.0" \
  -device "usb-tablet,bus=usb.0" \
  -drive "file=${QCOW2},if=virtio,format=qcow2" \
  -device "virtio-net-pci,netdev=net0" \
  -netdev "user,id=net0" \
  -display "cocoa,zoom-to-fit=on"
