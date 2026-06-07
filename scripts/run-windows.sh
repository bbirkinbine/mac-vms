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
# With --seed, builds a cidata.iso from a seed JSON (via seed/build-cidata.sh)
# and attaches it as a usb-storage CD so the in-image FirstBootSeed task
# injects the per-VM login on first boot. This is the seeded analogue of the
# Linux `just spawn` flow — see docs/cloning-windows.md. Host ports are
# forwarded for SSH (2222->22) and RDP (13389->3389) so a seeded clone is
# reachable without console access.
#
# Usage:
#   ./scripts/run-windows.sh                      # boot existing or fresh COW
#   ./scripts/run-windows.sh --fresh              # wipe COW + NVRAM, start clean
#   ./scripts/run-windows.sh --base               # boot base qcow2 directly (DIRTIES IT)
#   ./scripts/run-windows.sh --seed <seed.json>   # attach a seed CD (implies a clone)
#   ./scripts/run-windows.sh --fresh --seed seed/lab-seed.json
#   ./scripts/run-windows.sh --cpus 8             # vCPUs (default 4)
#   ./scripts/run-windows.sh --mem 32G            # RAM, qemu -m form (default 16384 MiB)
#   ./scripts/run-windows.sh --disk-size 128G     # grow the COW disk (ignored with --base)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/packer/windows-11-arm64/output-windows-11-arm64"
# Runtime state (COW + NVRAM) lives in run/, OUTSIDE the Packer output dir,
# so `just build-windows` (which clears output-*) doesn't blow it away.
RUN_DIR="${REPO_ROOT}/packer/windows-11-arm64/run"

BASE_QCOW2="${OUTPUT_DIR}/windows-11-arm64-base.qcow2"
BASE_EFIVARS="${OUTPUT_DIR}/efivars.fd"

# ---- argument parsing ------------------------------------------------------

mode="cow"
SEED=""
CPUS=4
MEM=16384      # qemu -m form: bare number is MiB; "16G" also works.
DISK_SIZE=""   # empty = inherit base virtual size; else qemu-img resize the COW.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fresh) mode="fresh" ;;
    --base)  mode="base"  ;;
    --seed)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --seed needs a path to a seed JSON" >&2; exit 2; }
      SEED="$1"
      ;;
    --seed=*) SEED="${1#--seed=}" ;;
    --cpus)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --cpus requires a number" >&2; exit 2; }
      CPUS="$1"
      ;;
    --cpus=*) CPUS="${1#--cpus=}" ;;
    --mem)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --mem requires a value" >&2; exit 2; }
      MEM="$1"
      ;;
    --mem=*) MEM="${1#--mem=}" ;;
    --disk-size)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --disk-size requires a value (e.g. 128G)" >&2; exit 2; }
      DISK_SIZE="$1"
      ;;
    --disk-size=*) DISK_SIZE="${1#--disk-size=}" ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# Hardware-spec validation (same rules as spawn-windows.sh). Strip a trailing
# "B" so the natural "32GB"/"512MB" form reaches qemu as "32G"/"512M".
[[ "$CPUS" =~ ^[0-9]+$ && "$CPUS" -ge 1 ]] || { echo "ERROR: --cpus must be a positive integer (got '$CPUS')" >&2; exit 2; }
MEM="${MEM%[Bb]}"
[[ "$MEM" =~ ^[0-9]+[MGmg]?$ ]] || { echo "ERROR: --mem must be a qemu -m value, e.g. 8192, 16G, or 16GB (got '$MEM')" >&2; exit 2; }
if [[ -n "$DISK_SIZE" ]]; then
  DISK_SIZE="${DISK_SIZE%[Bb]}"
  [[ "$DISK_SIZE" =~ ^\+?[0-9]+[MGTmgt]$ ]] || { echo "ERROR: --disk-size must carry a unit, e.g. 128G, 128GB, or +64G (got '$DISK_SIZE')" >&2; exit 2; }
fi
# --disk-size only applies to a COW clone; --base boots the artifact in place.
if [[ -n "$DISK_SIZE" && "$mode" == "base" ]]; then
  echo "ERROR: --disk-size cannot be combined with --base (it would grow the" >&2
  echo "       build artifact itself). Use the default COW clone." >&2
  exit 2
fi

# --seed against --base is a footgun: the seed's FirstBootSeed + cleanup run
# once on first boot, and --base dirties the sysprep'd artifact. Require a clone.
if [[ -n "$SEED" && "$mode" == "base" ]]; then
  echo "ERROR: --seed cannot be combined with --base (it would consume the" >&2
  echo "       sysprep'd base on first boot). Use --seed with the default COW" >&2
  echo "       clone, optionally with --fresh." >&2
  exit 2
fi

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
    mkdir -p "${RUN_DIR}"
    QCOW2="${RUN_DIR}/run.qcow2"
    EFIVARS="${RUN_DIR}/run-vars.fd"
    if [[ "$mode" == "fresh" ]]; then
      echo "==> mode: fresh (wiping COW + NVRAM)"
      rm -f "${QCOW2}" "${EFIVARS}"
    fi
    if [[ ! -f "${QCOW2}" ]]; then
      echo "==> creating copy-on-write clone of ${BASE_QCOW2##*/}"
      qemu-img create -f qcow2 \
        -b "${BASE_QCOW2}" -F qcow2 \
        "${QCOW2}" >/dev/null
      # Grow the overlay if asked. Only on creation — once run.qcow2 exists a
      # rerun reuses it as-is (use --fresh to recreate at a new size). Windows
      # sees the extra space unallocated; extend the partition in-guest.
      if [[ -n "$DISK_SIZE" ]]; then
        echo "==> resizing COW disk (${DISK_SIZE}; extend the partition in-Windows)"
        qemu-img resize "${QCOW2}" "$DISK_SIZE" >/dev/null
      fi
    elif [[ -n "$DISK_SIZE" ]]; then
      echo "==> note: ${QCOW2##*/} already exists; --disk-size ignored (use --fresh to recreate)"
    fi
    if [[ ! -f "${EFIVARS}" ]]; then
      echo "==> seeding NVRAM from ${BASE_EFIVARS##*/}"
      cp "${BASE_EFIVARS}" "${EFIVARS}"
    fi
    ;;
esac

# ---- seed CD (optional) ----------------------------------------------------
#
# Build a cidata.iso from the seed JSON and attach it as a usb-storage CD
# (ARM `virt` has no IDE/SATA, same constraint the build hit). The in-image
# FirstBootSeed task reads windows-seed.json off it on first boot. We also
# forward host ports for SSH/RDP so a seeded clone is reachable headlessly.

SEED_DEVICE_ARGS=()
HOSTFWD=""
if [[ -n "$SEED" ]]; then
  if [[ ! -f "$SEED" ]]; then
    echo "ERROR: seed file not found: $SEED" >&2
    exit 1
  fi
  SEED_ABS="$(cd "$(dirname "$SEED")" && pwd)/$(basename "$SEED")"
  echo "==> building cidata.iso from ${SEED}"
  # Don't swallow build-cidata's output: for a single interactive VM we want
  # its summary on the terminal — including "==> generated admin password: …"
  # when the seed omits a password (otherwise that password is unrecoverable;
  # only key login would work). Capture so a failure is still surfaced.
  bc_out="$("${REPO_ROOT}/packer/windows-11-arm64/seed/build-cidata.sh" "$SEED_ABS" 2>&1)" || {
    printf '%s\n' "$bc_out" >&2
    echo "ERROR: build-cidata.sh failed" >&2
    exit 1
  }
  printf '%s\n' "$bc_out" | grep -E '^==>' || true
  CIDATA="${REPO_ROOT}/packer/windows-11-arm64/output-cidata/cidata.iso"
  [[ -f "$CIDATA" ]] || { echo "ERROR: build-cidata.sh produced no ${CIDATA}" >&2; exit 1; }
  SEED_DEVICE_ARGS=(
    -drive "file=${CIDATA},media=cdrom,if=none,id=seedcd"
    -device "usb-storage,drive=seedcd,bus=usb.0"
  )
  HOSTFWD=",hostfwd=tcp::2222-:22,hostfwd=tcp::13389-:3389"
  echo "==> seed CD attached. After first boot:"
  echo "    ssh -p 2222 <seed-user>@127.0.0.1     (RDP: host port 13389)"
fi

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
#
# Disk tuning (cache=writeback,aio=threads,discard=unmap): writeback lets the
# host page cache absorb writes (big throughput win; acceptable for a throwaway
# VM — a host crash could lose unsynced writes); aio=threads is the AIO backend
# macOS supports (no io_uring); discard=unmap lets the qcow2 reclaim space as
# Windows TRIMs. Build-time uses defaults — this is a runtime-only speedup.
exec qemu-system-aarch64 \
  -machine "virt,gic-version=max" \
  -accel hvf \
  -cpu host \
  -smp "$CPUS" -m "$MEM" \
  -drive "if=pflash,format=raw,readonly=on,file=${EFI_CODE}" \
  -drive "if=pflash,format=raw,file=${EFIVARS}" \
  -chardev "socket,id=chrtpm,path=${SWTPM_SOCK}" \
  -tpmdev "emulator,id=tpm0,chardev=chrtpm" \
  -device "tpm-tis-device,tpmdev=tpm0" \
  -device "ramfb" \
  -device "qemu-xhci,id=usb" \
  -device "usb-kbd,bus=usb.0" \
  -device "usb-tablet,bus=usb.0" \
  -drive "file=${QCOW2},if=virtio,format=qcow2,cache=writeback,aio=threads,discard=unmap" \
  "${SEED_DEVICE_ARGS[@]}" \
  -device "virtio-net-pci,netdev=net0" \
  -netdev "user,id=net0${HOSTFWD}" \
  -display "cocoa,zoom-to-fit=on"
