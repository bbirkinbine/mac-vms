#!/usr/bin/env bash
# qemu-manual-boot.sh — boot the Windows 11 ARM64 ISO under the same
# QEMU + swtpm + UEFI + ramfb + USB plumbing the build uses, but WITHOUT
# Packer. Use this when:
#
#   - The build fails at "no installable hard drives found" (or similar)
#     and you want to drop to cmd.exe via Shift+F10 and probe directly.
#   - You want to confirm what drive letter WinPE assigned to which
#     attached CD (diskpart → list vol).
#   - You want to test `drvload <path>` on a specific driver INF to see
#     whether it loads under Secure Boot before tweaking Autounattend.xml.
#   - You want to verify a candidate ARM64 storage controller (-device
#     ahci, -device nvme, etc.) before wiring it into the build.
#
# This script does NOT attach the unattend CD — that's deliberate. You
# get the stock Win11 installer with manual control. To test the build's
# unattend behaviour end-to-end use `just build-windows` instead.
#
# A blank scratch disk is created at packer/windows-11-arm64/packer_cache/
# manual-boot/scratch.qcow2 so you can experiment with install attempts
# without trashing the Packer output.
#
# Required env (typically from .env.local):
#   WINDOWS_ISO_PATH        — absolute path to Win11_24H2_English_Arm64.iso
#   VIRTIO_WIN_ISO_PATH     — absolute path to virtio-win.iso (attached as
#                             the second CD-ROM, identical to the build)
#
# Usage: ./scripts/qemu-manual-boot.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKER_DIR="${REPO_ROOT}/packer/windows-11-arm64"
ENV_FILE="${REPO_ROOT}/.env.local"
WORK_DIR="${PACKER_DIR}/packer_cache/manual-boot"

if [[ -f "${ENV_FILE}" ]]; then
  set -o allexport
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +o allexport
fi

for v in WINDOWS_ISO_PATH VIRTIO_WIN_ISO_PATH; do
  if [[ -z "${!v:-}" ]]; then
    echo "ERROR: ${v} not set. Set it in .env.local." >&2
    exit 1
  fi
  if [[ ! -f "${!v}" ]]; then
    echo "ERROR: ${v} points to a missing file: ${!v}" >&2
    exit 1
  fi
done

for c in qemu-system-aarch64 swtpm qemu-img; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: $c not on PATH" >&2; exit 1; }
done

EFI_CODE="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
EFI_VARS_TEMPLATE="/opt/homebrew/share/qemu/edk2-arm-vars.fd"
for f in "${EFI_CODE}" "${EFI_VARS_TEMPLATE}"; do
  [[ -f "$f" ]] || { echo "ERROR: EFI firmware not found at $f" >&2; exit 1; }
done

mkdir -p "${WORK_DIR}"

# Per-session NVRAM copy so EFI variable writes don't trash the template.
EFI_VARS="${WORK_DIR}/efi-vars.fd"
[[ -f "${EFI_VARS}" ]] || cp "${EFI_VARS_TEMPLATE}" "${EFI_VARS}"

# Scratch disk — preserved across runs by default; pass --fresh-disk to
# wipe. 100 GiB matches the build VM's spec.
SCRATCH="${WORK_DIR}/scratch.qcow2"
if [[ "${1:-}" == "--fresh-disk" ]] || [[ ! -f "${SCRATCH}" ]]; then
  echo "==> creating fresh scratch disk: ${SCRATCH}"
  rm -f "${SCRATCH}"
  qemu-img create -f qcow2 "${SCRATCH}" 100G >/dev/null
fi

# swtpm — fresh per session. macOS Unix-socket path limit is 104 bytes
# (sun_path), and ${WORK_DIR}/swtpm/sock under the repo's packer_cache
# tree blows that limit on most user $HOME paths ("Path for UnioIO socket
# is too long" from swtpm). Live in /tmp instead — short, ephemeral,
# trapped for cleanup.
SWTPM_DIR="$(mktemp -d -t macvms.XXXXXX)"
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

echo "==> booting Win11 ARM64 ISO under qemu-system-aarch64"
echo "    Tips:"
echo "      - Shift+F10 at the Setup screen drops to cmd.exe"
echo "      - diskpart → list vol      enumerates attached storage + drive letters"
echo "        (expect D:=Win11 ISO, E:=virtio-win.iso, X:=WinPE RAM disk; no"
echo "         hard disks visible until viostor loads)"
echo
echo "      Storage driver — interactive Setup path:"
echo "        Click Load Driver → Browse → CD Drive (E:) virtio-win → viostor → w11 → ARM64"
echo "        After it loads, the qcow2 scratch disk appears in the partition list."
echo "        (\"D:\\drivers\\staging\" does NOT exist on this path — that tree is built"
echo "         into the unattend CD by 'just build-windows' only. For manual-boot"
echo "         you go straight at virtio-win.iso on E:.)"
echo
echo "      Other diagnostics:"
echo "        drvload E:\\viostor\\w11\\ARM64\\viostor.inf  — test Secure Boot accept"
echo "        diskpart → rescan → list disk             — re-probe disks after drvload"
echo "        wpeutil reboot                            — cleanly restart WinPE"
echo
echo "    Hardware-requirements bypass (cpu host advertises Apple Silicon,"
echo "    which isn't on Microsoft's Win11 supported-CPU list — Setup halts"
echo "    with 'This PC doesn't currently meet Windows 11 system requirements'"
echo "    right after the product-key step). Shift+F10 → cmd, then:"
echo "      reg add HKLM\\System\\Setup\\LabConfig /v BypassTPMCheck         /t REG_DWORD /d 1 /f"
echo "      reg add HKLM\\System\\Setup\\LabConfig /v BypassSecureBootCheck  /t REG_DWORD /d 1 /f"
echo "      reg add HKLM\\System\\Setup\\LabConfig /v BypassRAMCheck         /t REG_DWORD /d 1 /f"
echo "      reg add HKLM\\System\\Setup\\LabConfig /v BypassCPUCheck         /t REG_DWORD /d 1 /f"
echo "      reg add HKLM\\System\\Setup\\LabConfig /v BypassStorageCheck     /t REG_DWORD /d 1 /f"
echo "    Then exit cmd and click Back → Next to retry the check. The Packer"
echo "    build path applies these via Autounattend.xml's RunSynchronous block,"
echo "    so 'just build-windows' doesn't need this workaround."
echo

# Mirrors the args Packer + scripts/qemu-with-tpm.sh generate for the build,
# minus the Packer-built unattend CD. Keep this list in lockstep with
# packer/windows-11-arm64/windows.pkr.hcl + scripts/qemu-with-tpm.sh; if the
# build picks up a new device, mirror it here so manual diagnostics use the
# same platform shape.
#
# CD-ROMs attach via usb-storage, not bare `media=cdrom`. QEMU's ARM `virt`
# machine has no IDE/SATA controller; a bare cdrom drive lands on a bus
# WinPE has no in-box driver for and the CD never becomes readable. ARM
# Win11 WinPE has the in-box xHCI/USB stack (we already attach qemu-xhci
# for the keyboard/tablet) so usb-storage CDs Just Work. This is the
# attachment pattern documented at
# https://virtio-win.github.io/Knowledge-Base/Windows-arm64-vm-using-qemu.html
# and the canonical Vogtinator gist.
exec qemu-system-aarch64 \
  -machine virt,gic-version=max \
  -accel hvf \
  -cpu host \
  -smp 4 -m 8192 \
  -drive "if=pflash,format=raw,readonly=on,file=${EFI_CODE}" \
  -drive "if=pflash,format=raw,file=${EFI_VARS}" \
  -chardev "socket,id=chrtpm,path=${SWTPM_SOCK}" \
  -tpmdev "emulator,id=tpm0,chardev=chrtpm" \
  -device "tpm-tis-device,tpmdev=tpm0" \
  -device "ramfb" \
  -device "qemu-xhci,id=usb" \
  -device "usb-kbd,bus=usb.0" \
  -device "usb-tablet,bus=usb.0" \
  -drive "file=${SCRATCH},if=virtio,format=qcow2" \
  -device "virtio-net-pci,netdev=net0" \
  -netdev "user,id=net0" \
  -drive "file=${WINDOWS_ISO_PATH},media=cdrom,if=none,id=cd-install" \
  -device "usb-storage,drive=cd-install,bus=usb.0" \
  -drive "file=${VIRTIO_WIN_ISO_PATH},media=cdrom,if=none,id=cd-virtio" \
  -device "usb-storage,drive=cd-virtio,bus=usb.0" \
  -display cocoa,zoom-to-fit=on \
  -boot menu=on
