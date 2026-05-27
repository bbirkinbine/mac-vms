#!/usr/bin/env bash
# cleanup-vms.sh — stop and delete every Tart clone whose name starts
# with `<distro>-` (excluding the canonical `<distro>-...-base` image).
# Sibling of scripts/spawn-vm.sh.
#
# Usage:
#   ./scripts/cleanup-vms.sh ubuntu             # interactive confirm
#   ./scripts/cleanup-vms.sh kali --dry-run     # show what would be deleted
#   ./scripts/cleanup-vms.sh ubuntu -y          # skip confirmation
#   ./scripts/cleanup-vms.sh -h
#
# Only clones with the `<distro>-` prefix are eligible — explicitly
# named one-offs (e.g. spawned via `spawn-vm.sh -n webhost`) are NOT
# matched and must be removed manually with `tart delete <name>`. This
# is deliberate: cleanup-vms.sh is for batch-wiping the
# auto-incremented `ubuntu-1`/`ubuntu-2`/etc. set, not arbitrary VMs.

set -euo pipefail

DISTRO=""
DRY_RUN=false
YES=false

usage() {
  cat <<USAGE
Usage: $0 <distro> [--dry-run|-y|--yes]

  distro       Required. One of: ubuntu, kali.
  --dry-run    List matching VMs without deleting them.
  -y, --yes    Skip the interactive confirmation prompt.
  -h, --help   This message.

Matches \`<distro>-*\` clones, excluding the canonical base image
(\`ubuntu-24-04-arm64-base\` / \`kali-rolling-arm64-base\`). Named one-offs
(spawn-vm.sh -n) are not touched — delete those manually with
\`tart delete <name>\`.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    -y|--yes)  YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$DISTRO" ]]; then
        echo "ERROR: distro already set to '$DISTRO'; unexpected '$1'" >&2
        exit 1
      fi
      DISTRO="$1"
      shift
      ;;
  esac
done

[[ -z "$DISTRO" ]] && { echo "ERROR: distro is required (ubuntu | kali)" >&2; usage >&2; exit 1; }

case "$DISTRO" in
  ubuntu) BASE_VM="ubuntu-24-04-arm64-base" ;;
  kali)   BASE_VM="kali-rolling-arm64-base" ;;
  *)
    echo "ERROR: unsupported distro '$DISTRO'. Supported: ubuntu, kali." >&2
    exit 1
    ;;
esac

command -v tart >/dev/null 2>&1 || { echo "ERROR: tart not on PATH" >&2; exit 1; }

# Collect candidate VMs: name starts with `<distro>-`, not equal to BASE_VM.
# `tart list` columns: Source Name Disk Size Accessed State.
declare -a TARGETS=()
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  [[ "$name" == "$BASE_VM" ]] && continue
  case "$name" in
    "${DISTRO}-"*) TARGETS+=("$name") ;;
  esac
done < <(tart list 2>/dev/null | awk 'NR>1 {print $2}')

if [[ ${#TARGETS[@]} -eq 0 ]]; then
  echo "No ${DISTRO}-* clones found. Nothing to do."
  exit 0
fi

echo "Found ${#TARGETS[@]} ${DISTRO}-* clone(s):"
for vm in "${TARGETS[@]}"; do
  echo "  $vm"
done

if [[ "$DRY_RUN" == "true" ]]; then
  echo
  echo "(dry-run — no VMs deleted. Drop --dry-run to actually delete.)"
  exit 0
fi

if [[ "$YES" != "true" ]]; then
  echo
  read -r -p "Delete all of these? [y/N] " resp
  case "$resp" in
    y|Y|yes|YES) ;;
    *) echo "aborted."; exit 1 ;;
  esac
fi

# Stop (if running) then delete each VM. `tart stop` returns non-zero
# if the VM isn't running — tolerate that with `|| true`.
for vm in "${TARGETS[@]}"; do
  echo "==> stopping + deleting $vm"
  tart stop "$vm" >/dev/null 2>&1 || true
  tart delete "$vm"
done

echo
echo "Deleted ${#TARGETS[@]} VM(s)."
