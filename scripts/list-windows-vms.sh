#!/usr/bin/env bash
# list-windows-vms.sh — show the Windows instances created by
# scripts/spawn-windows.sh and whether each is running. Windows VMs are plain
# qemu processes (no Tart), so `tart list` / `just list` can't see them; this
# is their equivalent.
#
# Usage: ./scripts/list-windows-vms.sh   (or `just list-windows`)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTANCES_DIR="${REPO_ROOT}/packer/windows-11-arm64/run/instances"

echo "Windows instances (qemu):"

if [[ ! -d "$INSTANCES_DIR" ]] || [[ -z "$(ls -A "$INSTANCES_DIR" 2>/dev/null)" ]]; then
  echo "  (none — spawn with: just spawn windows)"
  exit 0
fi

for d in "${INSTANCES_DIR}"/*/; do
  [[ -d "$d" ]] || continue
  name="$(basename "$d")"
  meta="${d}meta"

  pid="$(cat "${d}qemu.pid" 2>/dev/null || true)"
  state="stopped"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && state="running (pid ${pid})"

  mode="$(sed -n 's/^mode=//p' "$meta" 2>/dev/null || true)"
  vnc="$(sed -n 's/^vnc_display=//p' "$meta" 2>/dev/null || true)"
  if [[ "$mode" == "bridged" ]]; then
    mac="$(sed -n 's/^mac=//p' "$meta" 2>/dev/null || true)"
    access="own IP via vmnet (mac ${mac}); ssh admin@<ip>"
  else
    sshp="$(sed -n 's/^ssh_port=//p' "$meta" 2>/dev/null || true)"
    rdpp="$(sed -n 's/^rdp_port=//p' "$meta" 2>/dev/null || true)"
    access="ssh admin@127.0.0.1 -p ${sshp:-?}  (RDP :${rdpp:-?})"
  fi

  printf '  %-16s %-20s %s  [VNC :%s]\n' "$name" "$state" "$access" "${vnc:-?}"
done

echo
echo "Passwords: ${REPO_ROOT}/.env.windows-vms   (key login also works)"
