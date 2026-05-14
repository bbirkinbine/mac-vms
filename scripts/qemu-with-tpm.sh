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
#   4. virtio-win.iso attached as a third CD-ROM via usb-storage. The ARM64
#      driver subset WinPE needs at install time is bundled into the
#      unattend CD by the build wrapper (see scripts/build-windows.sh) —
#      Setup loads those via Microsoft-Windows-PnpCustomizationsWinPE
#      before the disk probe. This separate CD is still attached so
#      FirstLogonCommands can install virtio-win-guest-tools-arm64.msi
#      after Setup completes, which registers the full virtio driver
#      suite (including vioser for the qemu guest agent) in the installed
#      OS's driver store.
#   5. Rewrite of Packer-generated CD-ROM drives to usb-storage. QEMU's
#      ARM `virt` machine has no IDE/SATA controller, and Packer's
#      cdrom_interface default of `virtio` requires a driver WinPE doesn't
#      have at the disk-probe stage — so the install ISO and the unattend
#      CD that Packer auto-generates are both unreadable to WinPE under
#      the default attachment. Win11 ARM64 WinPE does include the in-box
#      xHCI/USB stack, so usb-storage CDs are visible immediately. This
#      block walks $@ and rewrites any `-drive ...,media=cdrom` to
#      `if=none,id=cd<N>` form, appending matching `-device usb-storage,
#      drive=cd<N>` entries. Verified against the canonical recipes at
#      https://virtio-win.github.io/Knowledge-Base/Windows-arm64-vm-using-qemu.html
#      and https://gist.github.com/Vogtinator/293c4f90c5e92838f7e72610725905fd.
#
# Required env (exported by scripts/build-windows.sh):
#   SWTPM_SOCK              — absolute path to the swtpm Unix socket
#   VIRTIO_WIN_ISO_PATH     — absolute path to virtio-win.iso

set -euo pipefail

if [[ -z "${SWTPM_SOCK:-}" ]]; then
  echo "ERROR: SWTPM_SOCK not set; scripts/build-windows.sh must export it." >&2
  exit 1
fi

if [[ ! -S "${SWTPM_SOCK}" ]]; then
  echo "ERROR: SWTPM_SOCK=${SWTPM_SOCK} is not a Unix socket. Is swtpm running?" >&2
  exit 1
fi

if [[ -z "${VIRTIO_WIN_ISO_PATH:-}" ]]; then
  echo "ERROR: VIRTIO_WIN_ISO_PATH not set; scripts/build-windows.sh must export it." >&2
  exit 1
fi

if [[ ! -f "${VIRTIO_WIN_ISO_PATH}" ]]; then
  echo "ERROR: VIRTIO_WIN_ISO_PATH=${VIRTIO_WIN_ISO_PATH} does not exist." >&2
  exit 1
fi

# ---- rewrite Packer-generated CD-ROM drives to usb-storage -----------------
#
# Walk $@: for every `-drive` whose value contains `media=cdrom`, strip the
# `if=...` and `index=...` keys, append `if=none,id=cd<N>`, and emit a
# matching `-device usb-storage,drive=cd<N>` after all argument rewriting
# is done. Non-cdrom drives (notably `if=pflash` for EFI firmware/vars and
# `if=virtio` for the qcow2 system disk) pass through untouched.

rewritten_args=()
device_appends=()
cd_counter=0

args=("$@")
i=0
while (( i < ${#args[@]} )); do
  arg="${args[$i]}"
  if [[ "$arg" == "-drive" ]] && (( i + 1 < ${#args[@]} )); then
    val="${args[$((i + 1))]}"
    if [[ "$val" == *"media=cdrom"* ]]; then
      stripped="$(printf '%s' "$val" \
        | sed -E 's/(^|,)if=[^,]*//g; s/(^|,)index=[^,]*//g; s/^,+//; s/,,+/,/g; s/,$//')"
      cd_id="cd-pkr-${cd_counter}"
      cd_counter=$((cd_counter + 1))
      rewritten_args+=("-drive" "${stripped},if=none,id=${cd_id}")
      # bus=usb.0 explicit: the xhci controller defined in `extras` below
      # is the only USB bus on this VM, but unqualified `-device usb-storage`
      # at parse time can fail-fast on "no usb bus" because qemu resolves
      # device buses in argv order on ARM virt. Naming the bus dodges that.
      device_appends+=("-device" "usb-storage,drive=${cd_id},bus=usb.0")
      i=$((i + 2))
      continue
    fi
  fi
  rewritten_args+=("$arg")
  i=$((i + 1))
done

# ---- our own appends -------------------------------------------------------
#
# Ordering is load-bearing for two independent reasons:
#
#   1. qemu-xhci MUST come before any usb-storage entries (both the
#      rewritten Packer cdroms in device_appends and our own virtio-win
#      attach below). On ARM virt, qemu's device-graph resolution can fail
#      at parse time if a usb-* device is seen before its bus exists.
#
#   2. The Packer install ISO's usb-storage device MUST enumerate before
#      virtio-win.iso's. EDK2 on ARM virt walks USB devices in argv order
#      looking for `\EFI\Boot\bootaa64.efi` to auto-boot. virtio-win.iso
#      has no such bootloader, so if it enumerates first EDK2 bails to
#      the EFI Shell instead of booting Windows Setup, and Packer's
#      <enter>-spam boot_command lands harmlessly in the Shell prompt.
#      (Verified failure: the build hits "Press ESC to skip startup.nsh"
#      and never reaches the installer.)
#
# So the argv layout is split into two extras chunks:
#   - bus_extras (xhci + input + tpm + ramfb) — defines USB bus
#   - virtio_win_storage (our virtio-win.iso usb-storage) — emitted LAST
# with device_appends (Packer's CDs as usb-storage) wedged between, so
# usb enumeration order becomes: install ISO, unattend CD, virtio-win.

bus_extras=(
  -chardev "socket,id=chrtpm,path=${SWTPM_SOCK}"
  -tpmdev "emulator,id=tpm0,chardev=chrtpm"
  -device "tpm-tis-device,tpmdev=tpm0"
  -device "ramfb"
  -device "qemu-xhci,id=usb"
  -device "usb-kbd,bus=usb.0"
  -device "usb-tablet,bus=usb.0"
)

virtio_win_storage=(
  -drive "file=${VIRTIO_WIN_ISO_PATH},media=cdrom,if=none,id=cd-virtio-win"
  -device "usb-storage,drive=cd-virtio-win,bus=usb.0"
)

final_argv=(
  "${rewritten_args[@]}"
  "${bus_extras[@]}"
  "${device_appends[@]}"
  "${virtio_win_storage[@]}"
)

# Log the final qemu invocation so future "Qemu failed to start" errors are
# debuggable without PACKER_LOG=1. Path matches what build-windows.sh
# creates for swtpm so the log lives with the rest of the build state.
SWTPM_DIR_FROM_SOCK="$(dirname "${SWTPM_SOCK}")"
QEMU_LOG="${SWTPM_DIR_FROM_SOCK}/../qemu-with-tpm.cmd.log"
{
  echo "==> $(date -u +%FT%TZ) qemu-system-aarch64 invocation"
  printf '  %q\n' qemu-system-aarch64 "${final_argv[@]}"
} >"${QEMU_LOG}" 2>/dev/null || true

exec qemu-system-aarch64 "${final_argv[@]}"
