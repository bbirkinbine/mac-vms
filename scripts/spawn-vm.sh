#!/usr/bin/env bash
# spawn-vm.sh — clone a base Tart image into one or more numbered VMs,
# generate per-VM cidata, and boot each headless in the background.
#
# Usage:
#   ./scripts/spawn-vm.sh ubuntu              # spawns ubuntu-<next-free-N>
#   ./scripts/spawn-vm.sh kali                # spawns kali-<next-free-N>
#   ./scripts/spawn-vm.sh ubuntu -c 3         # spawns 3 in one batch
#   ./scripts/spawn-vm.sh ubuntu -n webhost   # explicit name, no iteration
#   ./scripts/spawn-vm.sh -h                  # usage
#
# The per-VM cidata uses hostname = <vm-name> and a build-user named after
# the distro (ubuntu/kali). SSH pubkeys are auto-injected from
# ~/.ssh/id_*.pub by build-cidata.sh — same flow as the manual cidata
# build. Override with `-i <path>` (forwarded to build-cidata.sh) if
# you want an explicit set.
#
# Teardown is `tart delete <name>` per VM, or `cleanup-vms.sh <distro>`
# for a batch wipe of all <distro>-N clones.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Windows isn't a Tart distro (Tart can't host it), so it has its own
# qemu-based fleet manager. If 'windows' is the requested distro, hand off to
# scripts/spawn-windows.sh, forwarding every other flag untouched — including
# the Windows-only ones (--seed, --bridged) that this script doesn't know.
# -c/-n/-i each take a value, so skip the following token when scanning for
# the bare 'windows' positional.
_fwd=(); _skip=0; _is_win=0
for _a in "$@"; do
  if [[ "$_skip" -eq 1 ]]; then _fwd+=("$_a"); _skip=0; continue; fi
  case "$_a" in
    -c|-n|-i) _fwd+=("$_a"); _skip=1 ;;
    windows)  _is_win=1 ;;
    *)        _fwd+=("$_a") ;;
  esac
done
if [[ "$_is_win" -eq 1 ]]; then
  exec "${REPO_ROOT}/scripts/spawn-windows.sh" "${_fwd[@]}"
fi

DISTRO=""
COUNT=1
EXPLICIT_NAME=""
declare -a EXPLICIT_KEY_FLAGS=()

usage() {
  cat <<USAGE
Usage: $0 <distro> [-c <count>] [-n <name>] [-i <path>]...

  distro       Required. One of: ubuntu, kali, windows.
               (windows delegates to scripts/spawn-windows.sh — a qemu
               fleet manager, since Tart can't host Windows. It accepts
               the same -c/-n/-i plus Windows-only --seed/--bridged.)
  -c <count>   Number of VMs to spawn (default 1). Each gets the next
               free \`<distro>-N\` suffix. Incompatible with -n.
  -n <name>    Explicit VM name. Skips auto-increment; count implied 1.
  -i <path>    SSH pubkey path; forwarded to build-cidata.sh. Repeatable.
               If any -i is passed, auto-detect of ~/.ssh/id_*.pub is
               suppressed for the generated cidata.
  -h, --help   This message.

Examples:
  $0 ubuntu
  $0 kali -c 3
  $0 ubuntu -n webhost-01
  $0 kali -i ~/.ssh/recon.pub
  $0 windows -c 2          # -> spawn-windows.sh
USAGE
}

# ---- argument parsing -------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c)
      shift
      [[ $# -eq 0 ]] && { echo "ERROR: -c requires a number" >&2; exit 1; }
      COUNT="$1"
      [[ "$COUNT" =~ ^[0-9]+$ ]] || { echo "ERROR: -c value must be a positive integer (got '$COUNT')" >&2; exit 1; }
      [[ "$COUNT" -lt 1 ]] && { echo "ERROR: -c must be >= 1" >&2; exit 1; }
      shift
      ;;
    -n)
      shift
      [[ $# -eq 0 ]] && { echo "ERROR: -n requires a name" >&2; exit 1; }
      EXPLICIT_NAME="$1"
      shift
      ;;
    -i)
      shift
      [[ $# -eq 0 ]] && { echo "ERROR: -i requires a path" >&2; exit 1; }
      EXPLICIT_KEY_FLAGS+=("-i" "$1")
      shift
      ;;
    -h|--help)
      usage; exit 0
      ;;
    -*)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$DISTRO" ]]; then
        echo "ERROR: distro already set to '$DISTRO'; unexpected positional arg '$1'" >&2
        exit 1
      fi
      DISTRO="$1"
      shift
      ;;
  esac
done

if [[ -z "$DISTRO" ]]; then
  echo "ERROR: distro is required (ubuntu | kali)" >&2
  usage >&2
  exit 1
fi

if [[ -n "$EXPLICIT_NAME" && "$COUNT" -gt 1 ]]; then
  echo "ERROR: -n <name> is incompatible with -c <count > 1>." >&2
  echo "       Pick one: explicit name OR a batch." >&2
  exit 1
fi

# ---- distro lookup ----------------------------------------------------------

case "$DISTRO" in
  ubuntu)
    BASE_VM="ubuntu-24-04-arm64-base"
    PIPELINE_DIR="${REPO_ROOT}/packer/ubuntu-24-04-arm64"
    ;;
  kali)
    BASE_VM="kali-rolling-arm64-base"
    PIPELINE_DIR="${REPO_ROOT}/packer/kali-rolling-arm64"
    ;;
  *)
    echo "ERROR: unsupported distro '$DISTRO'." >&2
    echo "       Supported: ubuntu, kali, windows (windows is delegated to spawn-windows.sh)." >&2
    exit 1
    ;;
esac

# ---- preconditions ----------------------------------------------------------

command -v tart >/dev/null 2>&1 || { echo "ERROR: tart not on PATH. brew install --cask tart" >&2; exit 1; }
[[ -d "${PIPELINE_DIR}" ]] || { echo "ERROR: pipeline dir not found: ${PIPELINE_DIR}" >&2; exit 1; }
[[ -x "${PIPELINE_DIR}/seed/build-cidata.sh" ]] || { echo "ERROR: ${PIPELINE_DIR}/seed/build-cidata.sh missing or not executable" >&2; exit 1; }

if ! tart list 2>/dev/null | awk '{print $2}' | grep -qx "${BASE_VM}"; then
  echo "ERROR: base image '${BASE_VM}' not found in ~/.tart/vms/." >&2
  echo "       Build it first: just build-${DISTRO}" >&2
  exit 1
fi

# ---- helpers ----------------------------------------------------------------

# vm_exists <name> — true if a Tart VM with that name exists.
vm_exists() {
  tart list 2>/dev/null | awk '{print $2}' | grep -qx "$1"
}

# next_free_index <distro> — find the lowest N such that <distro>-N is
# not in `tart list`. Starts at 1; uses padded width=0 (no leading zeros).
next_free_index() {
  local distro="$1" n=1
  while vm_exists "${distro}-${n}"; do
    n=$((n + 1))
  done
  echo "$n"
}

# spawn_one <name> — generate cidata, clone, boot headless in background.
spawn_one() {
  local name="$1"
  local cidata_dir="${PIPELINE_DIR}/output-seed"
  local cidata_path="${cidata_dir}/${name}.iso"
  local tmp_yaml
  tmp_yaml="$(mktemp -t "spawn-vm-${name}.XXXXXX.yaml")"
  # On EXIT, clean up the tmp yaml. Don't clobber the outer trap (we
  # don't set one); spawn_one runs inside the main script's process.
  trap 'rm -f "${tmp_yaml}"' RETURN

  # Build the per-VM cloud-config: hostname = VM name, user = distro.
  # Authorized_keys is empty here; build-cidata.sh auto-injects
  # ~/.ssh/id_*.pub on top (or -i overrides).
  cat > "${tmp_yaml}" <<EOF
#cloud-config
# Auto-generated by scripts/spawn-vm.sh for VM '${name}'. Do not edit;
# this file is regenerated on every spawn and discarded after the
# cidata.iso is written.
hostname: '${name}'
manage_etc_hosts: true

users:
  - name: '${DISTRO}'
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    ssh_authorized_keys: []
EOF

  echo
  echo "==> [${name}] generating cidata"
  # build-cidata.sh expects to cd into its own packer dir; we pass an
  # absolute yaml path so it doesn't matter that the script chdir's.
  if ! "${PIPELINE_DIR}/seed/build-cidata.sh" \
        -o "${cidata_path}" \
        "${EXPLICIT_KEY_FLAGS[@]:-}" \
        "${tmp_yaml}" \
        > /tmp/spawn-vm-cidata.log 2>&1; then
    echo "ERROR: cidata build failed for ${name}. Last 20 lines of log:" >&2
    tail -20 /tmp/spawn-vm-cidata.log >&2
    exit 1
  fi

  echo "==> [${name}] tart clone ${BASE_VM} ${name}"
  tart clone "${BASE_VM}" "${name}"

  echo "==> [${name}] booting headless in background"
  # nohup + redirected stdio + & + disown: fully detach so the spawn
  # script can exit without killing the VM. Per-VM log lands in
  # ${cidata_dir}/<name>.log for post-mortem if a VM misbehaves.
  nohup tart run --no-graphics --disk="${cidata_path}:ro" "${name}" \
    < /dev/null > "${cidata_dir}/${name}.log" 2>&1 &
  disown

  # Wait briefly for the lease to land so we can print an SSH hint.
  # 60s × 1s is generous; cloud-init's first-boot is usually <30s.
  local ip="" i
  for i in $(seq 1 60); do
    ip="$(tart ip "${name}" 2>/dev/null || true)"
    [[ -n "${ip}" ]] && break
    sleep 1
  done
  if [[ -n "${ip}" ]]; then
    SPAWNED_LINES+=("  ${name} → ssh ${DISTRO}@${ip}")
  else
    SPAWNED_LINES+=("  ${name} (no IP yet; try 'tart ip ${name}' in a moment)")
  fi
}

# ---- spawn loop -------------------------------------------------------------

declare -a SPAWNED_LINES=()

if [[ -n "${EXPLICIT_NAME}" ]]; then
  if vm_exists "${EXPLICIT_NAME}"; then
    echo "ERROR: a VM named '${EXPLICIT_NAME}' already exists. Pick another -n." >&2
    exit 1
  fi
  spawn_one "${EXPLICIT_NAME}"
else
  for ((i = 0; i < COUNT; i++)); do
    n="$(next_free_index "${DISTRO}")"
    spawn_one "${DISTRO}-${n}"
  done
fi

echo
echo "==> spawned ${#SPAWNED_LINES[@]} VM(s):"
for line in "${SPAWNED_LINES[@]}"; do
  echo "${line}"
done
echo
echo "Per-VM logs at ${PIPELINE_DIR##*/}/output-seed/<name>.log"
echo "Teardown: tart delete <name>, or scripts/cleanup-vms.sh ${DISTRO}"
