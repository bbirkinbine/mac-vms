#!/usr/bin/env bash
# stop-windows.sh — gracefully power off a running Windows fleet instance,
# leaving its disk/NVRAM/TPM on disk so `just start <name>` can resume it.
# The counterpart to spawn-windows.sh --start; the Windows analogue of
# `tart stop` (which spawn-vm.sh's Linux clones get for free).
#
# Default path is an ACPI shutdown via the instance's qemu QMP control socket
# (the clean equivalent of choosing Shut Down inside Windows). --force instead
# SIGTERMs qemu — a hard power-off Windows dislikes (chkdsk next boot), for when
# the guest is wedged or predates QMP support.
#
# Usage:
#   ./scripts/stop-windows.sh -n devbox            # graceful ACPI power-off, wait for exit
#   ./scripts/stop-windows.sh -n devbox --force    # hard SIGTERM (last resort)
#   ./scripts/stop-windows.sh -n devbox --timeout 180
#   ./scripts/stop-windows.sh -h

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTANCES_DIR="${REPO_ROOT}/packer/windows-11-arm64/run/instances"

NAME=""
FORCE=false
TIMEOUT=120   # seconds to wait for a graceful power-off before warning

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) shift; [[ $# -gt 0 ]] || { echo "ERROR: -n requires a name" >&2; exit 2; }; NAME="$1" ;;
    -n=*|--name=*) NAME="${1#*=}" ;;
    --force) FORCE=true ;;
    --timeout) shift; [[ $# -gt 0 ]] || { echo "ERROR: --timeout requires seconds" >&2; exit 2; }; TIMEOUT="$1" ;;
    --timeout=*) TIMEOUT="${1#--timeout=}" ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)  echo "ERROR: unexpected argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[[ -n "$NAME" ]] || { echo "ERROR: -n <name> is required" >&2; usage >&2; exit 2; }
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] || { echo "ERROR: --timeout must be an integer (got '$TIMEOUT')" >&2; exit 2; }

dir="${INSTANCES_DIR}/${NAME}"
[[ -d "$dir" ]] || { echo "ERROR: no such Windows instance: ${NAME}" >&2; exit 1; }

command -v nc >/dev/null 2>&1 || { echo "ERROR: 'nc' not on PATH (needed to drive QMP)" >&2; exit 1; }

# Running? If the qemu pid is gone, there's nothing to stop — but still reap a
# leftover swtpm so we don't leak it.
pid=""
[[ -f "${dir}/qemu.pid" ]] && pid="$(cat "${dir}/qemu.pid" 2>/dev/null || true)"
if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
  echo "==> [${NAME}] not running (already stopped)"
  [[ -f "${dir}/swtpm.pid" ]] && kill "$(cat "${dir}/swtpm.pid")" 2>/dev/null || true
  exit 0
fi

qmp_sock=""
[[ -f "${dir}/meta" ]] && qmp_sock="$(sed -n 's/^qmp_sock=//p' "${dir}/meta")"

if [[ "$FORCE" == "true" ]]; then
  echo "==> [${NAME}] force stop: SIGTERM to qemu (pid ${pid}) — hard power-off"
  kill "$pid" 2>/dev/null || true
elif [[ -n "$qmp_sock" && -S "$qmp_sock" ]]; then
  echo "==> [${NAME}] ACPI shutdown via QMP (graceful)"
  # QMP requires capabilities negotiation before any command. Send both lines,
  # then hold the socket open briefly so qemu processes them before nc closes.
  { printf '{"execute":"qmp_capabilities"}\n{"execute":"system_powerdown"}\n'; sleep 0.5; } \
    | nc -U "$qmp_sock" >/dev/null 2>&1 || true
else
  echo "ERROR: [${NAME}] no usable QMP socket — this instance predates graceful-stop" >&2
  echo "       support. Shut down from inside Windows, or re-run with --force to" >&2
  echo "       hard power-off (SIGTERM)." >&2
  exit 1
fi

# Wait for qemu to exit (the guest takes time to flush + power down). When it
# does, reap swtpm and drop the stale /tmp sockets.
echo "==> [${NAME}] waiting up to ${TIMEOUT}s for power-off"
for ((i = 0; i < TIMEOUT; i++)); do
  if ! kill -0 "$pid" 2>/dev/null; then
    [[ -f "${dir}/swtpm.pid" ]] && kill "$(cat "${dir}/swtpm.pid")" 2>/dev/null || true
    tpm_sock="$(sed -n 's/^tpm_sock=//p' "${dir}/meta" 2>/dev/null || true)"
    [[ -n "$tpm_sock" ]] && rm -f "$tpm_sock"
    [[ -n "$qmp_sock" ]] && rm -f "$qmp_sock"
    echo "==> [${NAME}] stopped. Resume with: just start ${NAME}"
    exit 0
  fi
  sleep 1
done

echo "WARN: [${NAME}] still running after ${TIMEOUT}s — Windows may be mid-update." >&2
echo "      Give it longer and retry, or force a hard stop: $0 -n ${NAME} --force" >&2
exit 1
