#!/usr/bin/env bash
# cleanup-windows-vms.sh — stop and delete Windows instances created by
# scripts/spawn-windows.sh. Sibling of cleanup-vms.sh (which is Tart/Linux).
#
# For each instance under
# packer/windows-11-arm64/output-windows-11-arm64/instances/<name>/ it kills
# the qemu and swtpm processes (from their pidfiles), removes the swtpm
# socket, deletes the instance directory, and prunes the instance's password
# line from .env.windows-vms.
#
# Usage:
#   ./scripts/cleanup-windows-vms.sh                 # interactive confirm, all instances
#   ./scripts/cleanup-windows-vms.sh -n win-2        # just one instance
#   ./scripts/cleanup-windows-vms.sh --dry-run       # show what would be removed
#   ./scripts/cleanup-windows-vms.sh -y              # skip confirmation
#   ./scripts/cleanup-windows-vms.sh -h

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTANCES_DIR="${REPO_ROOT}/packer/windows-11-arm64/output-windows-11-arm64/instances"
ENV_FILE="${REPO_ROOT}/.env.windows-vms"

DRY_RUN=false
YES=false
ONLY_NAME=""

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    -y|--yes)  YES=true ;;
    -n)        shift; [[ $# -gt 0 ]] || { echo "ERROR: -n requires a name" >&2; exit 1; }; ONLY_NAME="$1" ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)  echo "ERROR: unexpected argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

if [[ ! -d "$INSTANCES_DIR" ]]; then
  echo "No instances directory. Nothing to do."
  exit 0
fi

# Collect instance names.
declare -a TARGETS=()
if [[ -n "$ONLY_NAME" ]]; then
  [[ -d "${INSTANCES_DIR}/${ONLY_NAME}" ]] || { echo "ERROR: no such instance: ${ONLY_NAME}" >&2; exit 1; }
  TARGETS=("$ONLY_NAME")
else
  for d in "${INSTANCES_DIR}"/*/; do
    [[ -d "$d" ]] || continue
    TARGETS+=("$(basename "$d")")
  done
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "No Windows instances found. Nothing to do."
  exit 0
fi

# Show status (alive/dead) + ports per instance. With --dry-run this doubles
# as a fleet listing.
echo "Found ${#TARGETS[@]} Windows instance(s):"
for name in "${TARGETS[@]}"; do
  meta="${INSTANCES_DIR}/${name}/meta"
  pid="$(cat "${INSTANCES_DIR}/${name}/qemu.pid" 2>/dev/null || true)"
  state="stopped"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && state="running (pid ${pid})"
  mode="$(sed -n 's/^mode=//p' "$meta" 2>/dev/null || true)"
  if [[ "$mode" == "bridged" ]]; then
    mac="$(sed -n 's/^mac=//p' "$meta" 2>/dev/null || true)"
    echo "  ${name} — ${state}   bridged (mac ${mac}; own IP, ssh admin@<ip>)"
  else
    sshp="$(sed -n 's/^ssh_port=//p' "$meta" 2>/dev/null || true)"
    rdpp="$(sed -n 's/^rdp_port=//p' "$meta" 2>/dev/null || true)"
    echo "  ${name} — ${state}   ssh admin@127.0.0.1 -p ${sshp:-?}  (RDP :${rdpp:-?})"
  fi
done

if [[ "$DRY_RUN" == "true" ]]; then
  echo
  echo "(dry-run — nothing removed. Drop --dry-run to delete.)"
  exit 0
fi

if [[ "$YES" != "true" ]]; then
  echo
  read -r -p "Stop and delete these? [y/N] " resp
  case "$resp" in y|Y|yes|YES) ;; *) echo "aborted."; exit 1 ;; esac
fi

kill_pidfile() {  # kill_pidfile <path>
  local pf="$1" pid
  [[ -f "$pf" ]] || return 0
  pid="$(cat "$pf" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 0
  kill "$pid" 2>/dev/null || true
  # SIGTERM isn't instant — give qemu/swtpm a few seconds to exit, then
  # escalate to SIGKILL. Only warn if it's STILL alive after that, which
  # means it's genuinely unkillable by us (a --bridged instance's qemu
  # runs as root; a non-root cleanup can't kill it).
  local _
  for _ in 1 2 3 4 5 6; do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.5; done
  kill -9 "$pid" 2>/dev/null || true
  sleep 0.5
  if kill -0 "$pid" 2>/dev/null; then
    echo "   WARN: pid ${pid} still running (root-owned? re-run cleanup under sudo)" >&2
  fi
}

for name in "${TARGETS[@]}"; do
  dir="${INSTANCES_DIR}/${name}"
  echo "==> stopping + deleting ${name}"
  kill_pidfile "${dir}/qemu.pid"
  kill_pidfile "${dir}/swtpm.pid"
  # Remove the swtpm socket recorded in meta (best effort).
  sock="$(sed -n 's/^tpm_sock=//p' "${dir}/meta" 2>/dev/null || true)"
  [[ -n "$sock" ]] && rm -f "$sock"
  # Prune this instance's password entry from the env file (comment + line).
  if [[ -f "$ENV_FILE" ]]; then
    token="$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"; token="${token%_}"
    grep -v -e "^# ${name} /" -e "^WINVM_${token}_PASSWORD=" "$ENV_FILE" > "${ENV_FILE}.tmp" 2>/dev/null || true
    mv "${ENV_FILE}.tmp" "$ENV_FILE"
  fi
  rm -rf "$dir"
done

# Drop the instances dir if now empty, and the env file if now blank.
rmdir "$INSTANCES_DIR" 2>/dev/null || true
[[ -f "$ENV_FILE" && ! -s "$ENV_FILE" ]] && rm -f "$ENV_FILE"

echo
echo "Removed ${#TARGETS[@]} instance(s)."
