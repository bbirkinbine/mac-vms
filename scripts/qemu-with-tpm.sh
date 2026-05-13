#!/usr/bin/env bash
# qemu-with-tpm.sh — wrapper around qemu-system-aarch64 that fills in the
# gaps Packer's qemu plugin can't generate for an ARM Win11 build.
#
# Packer's qemu plugin treats `qemuargs` as a *replacement* for all auto-
# generated args, not an append — that killed an earlier attempt that lost
# the disk/CD/net/EFI setup. So instead of qemuargs, we use a wrapper:
# Packer invokes us as if we were qemu, we forward every arg verbatim
# (sometimes with surgical edits) and append our additions at the end.
#
# What we add / rewrite:
#
#   1. TPM 2.0 via swtpm Unix socket (Win11 system requirement).
#   2. `ramfb` simple linear framebuffer. ARM `virt` machines don't ship a
#      graphics card by default; without one you only see the QEMU monitor
#      console, not the VM frame. We use ramfb rather than virtio-gpu-pci
#      because EFI firmware writes directly to ramfb (via GOP) — virtio-gpu
#      requires guest drivers, which the Windows installer doesn't have
#      until well into Setup, so the install runs blind on virtio-gpu.
#   3. USB controller + keyboard + tablet. Same reason — no input devices
#      otherwise. usb-tablet (not usb-mouse) gives absolute pointing.
#   4. virtio-win.iso attached as a third CD (if VIRTIO_WIN_ISO_PATH is
#      set). Win11 ARM's WinPE doesn't ship usable in-box drivers for any
#      of QEMU's emulated storage controllers (virtio-blk, NVMe, AHCI all
#      failed in testing). The path forward is the same as homelab x86:
#      Microsoft-signed virtio drivers, loaded by WinPE via the
#      Microsoft-Windows-PnpCustomizationsWinPE block in Autounattend.xml.
#      virtio-win.iso is the canonical source; recent releases include
#      arm64 binaries.
#
# Required env (exported by scripts/build-windows.sh):
#   SWTPM_SOCK — absolute path to the swtpm Unix socket

set -euo pipefail

if [[ -z "${SWTPM_SOCK:-}" ]]; then
  echo "ERROR: SWTPM_SOCK not set; scripts/build-windows.sh must export it." >&2
  exit 1
fi

if [[ ! -S "${SWTPM_SOCK}" ]]; then
  echo "ERROR: SWTPM_SOCK=${SWTPM_SOCK} is not a Unix socket. Is swtpm running?" >&2
  exit 1
fi

# Build the extras list — devices we always add (TPM, ramfb, USB) plus
# (optionally) the virtio-win driver CD if VIRTIO_WIN_ISO_PATH is set.
extras=(
  -chardev "socket,id=chrtpm,path=${SWTPM_SOCK}"
  -tpmdev "emulator,id=tpm0,chardev=chrtpm"
  -device "tpm-tis-device,tpmdev=tpm0"
  -device "ramfb"
  -device "qemu-xhci,id=usb"
  -device "usb-kbd,bus=usb.0"
  -device "usb-tablet,bus=usb.0"
)

if [[ -n "${VIRTIO_WIN_ISO_PATH:-}" ]]; then
  if [[ ! -f "${VIRTIO_WIN_ISO_PATH}" ]]; then
    echo "ERROR: VIRTIO_WIN_ISO_PATH=${VIRTIO_WIN_ISO_PATH} does not exist." >&2
    exit 1
  fi
  extras+=(-drive "file=${VIRTIO_WIN_ISO_PATH},media=cdrom")
fi

exec qemu-system-aarch64 "$@" "${extras[@]}"
