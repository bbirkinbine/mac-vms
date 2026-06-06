#!/usr/bin/env bash
# spawn-windows.sh — clone the Windows 11 ARM64 base qcow2 into one or more
# named, seeded instances and boot each headless in the background under qemu.
#
# This is the Windows analogue of spawn-vm.sh. spawn-vm.sh uses Tart, which
# manages VM instances natively but can't host Windows; here qemu is the
# hypervisor and there's no instance manager underneath, so this script IS
# the manager. Each instance gets its own:
#   - COW disk + NVRAM (the base qcow2 stays sysprep-fresh),
#   - seed CD (hostname = instance name, user 'admin', auto-injected
#     ~/.ssh/id_*.pub, a generated password written to .env.windows-vms — not
#     stdout, via build-cidata.sh --env),
#   - networking: by default qemu user-mode NAT with per-instance host-port
#     forwards (SSH 2222+, RDP 13389+) — no privileges needed. With --bridged
#     each VM instead gets its OWN IP via macOS vmnet (reachable on the normal
#     :22 / :3389, like the Tart Linux VMs) — but vmnet needs root, so
#     --bridged must run under sudo. A VNC display (5950+) is allocated either way.
#   - swtpm + qemu process, tracked by pidfiles under the instance dir.
#
# Usage:
#   ./scripts/spawn-windows.sh                 # windows-<next-free-N>
#   ./scripts/spawn-windows.sh -c 3            # three at once
#   ./scripts/spawn-windows.sh -n devbox       # explicit name (no auto-increment)
#   ./scripts/spawn-windows.sh -i ~/.ssh/k.pub # explicit pubkey (repeatable)
#   ./scripts/spawn-windows.sh --seed s.json   # base seed; hostname is overridden per instance
#   sudo ./scripts/spawn-windows.sh --bridged  # per-VM IP on :22 (vmnet; needs root)
#   ./scripts/spawn-windows.sh -h
#
# Teardown: scripts/cleanup-windows-vms.sh (or `just cleanup-windows-vms`).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIPELINE_DIR="${REPO_ROOT}/packer/windows-11-arm64"
OUTPUT_DIR="${PIPELINE_DIR}/output-windows-11-arm64"
BASE_QCOW2="${OUTPUT_DIR}/windows-11-arm64-base.qcow2"
BASE_EFIVARS="${OUTPUT_DIR}/efivars.fd"
# Instances live under run/, NOT the Packer output dir, so `just build-windows`
# (which clears output-*) can't destroy a running fleet.
INSTANCES_DIR="${PIPELINE_DIR}/run/instances"
ENV_FILE="${REPO_ROOT}/.env.windows-vms"
EFI_CODE="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"

SSH_BASE=2222
RDP_BASE=13389
VNC_PORT_BASE=5950   # VNC display N => TCP 5900+N
CPUS=4
MEM_MB=8192

COUNT=1
EXPLICIT_NAME=""
SEED_FILE=""
BRIDGED=false
declare -a EXPLICIT_KEY_FLAGS=()

usage() {
  sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'
}

# ---- argument parsing -------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: -c requires a number" >&2; exit 1; }
      COUNT="$1"
      [[ "$COUNT" =~ ^[0-9]+$ && "$COUNT" -ge 1 ]] || { echo "ERROR: -c must be a positive integer" >&2; exit 1; }
      ;;
    -n)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: -n requires a name" >&2; exit 1; }
      EXPLICIT_NAME="$1"
      ;;
    -i)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: -i requires a path" >&2; exit 1; }
      EXPLICIT_KEY_FLAGS+=("-i" "$1")
      ;;
    --seed)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --seed requires a path" >&2; exit 1; }
      SEED_FILE="$1"
      ;;
    --seed=*) SEED_FILE="${1#--seed=}" ;;
    --bridged) BRIDGED=true ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) echo "ERROR: unexpected argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

if [[ -n "$EXPLICIT_NAME" && "$COUNT" -gt 1 ]]; then
  echo "ERROR: -n <name> is incompatible with -c <count > 1>." >&2
  exit 1
fi
if [[ -n "$SEED_FILE" && ! -f "$SEED_FILE" ]]; then
  echo "ERROR: --seed file not found: $SEED_FILE" >&2
  exit 1
fi

# ---- preconditions ----------------------------------------------------------

for c in qemu-system-aarch64 swtpm qemu-img plutil nc; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: '$c' not on PATH" >&2; exit 1; }
done

# --bridged uses macOS vmnet, which qemu can only open as root.
if [[ "$BRIDGED" == "true" && "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: --bridged uses vmnet, which requires root." >&2
  echo "       Re-run under sudo, e.g.:" >&2
  echo "         sudo ./scripts/spawn-windows.sh --bridged ${*:-}" >&2
  echo "       (Or drop --bridged to use NAT + per-instance host ports, no sudo.)" >&2
  exit 1
fi
[[ -f "$BASE_QCOW2" ]]  || { echo "ERROR: base qcow2 not found: $BASE_QCOW2 (run: just build-windows)" >&2; exit 1; }
[[ -f "$BASE_EFIVARS" ]] || { echo "ERROR: base NVRAM not found: $BASE_EFIVARS" >&2; exit 1; }
[[ -f "$EFI_CODE" ]]    || { echo "ERROR: EFI code not found: $EFI_CODE (brew install qemu)" >&2; exit 1; }
[[ -x "${PIPELINE_DIR}/seed/build-cidata.sh" ]] || { echo "ERROR: seed/build-cidata.sh missing/not executable" >&2; exit 1; }

mkdir -p "$INSTANCES_DIR"

# ---- helpers ----------------------------------------------------------------

instance_exists() { [[ -d "${INSTANCES_DIR}/$1" ]]; }

next_free_index() {
  local n=1
  while instance_exists "windows-${n}"; do n=$((n + 1)); done
  echo "$n"
}

# Free = nothing is currently listening on it. -G1 caps the connect probe at 1s.
port_listening() { nc -z -G1 127.0.0.1 "$1" >/dev/null 2>&1; }

declare -a USED_PORTS=()
port_taken_in_batch() {
  local p="$1" u
  for u in "${USED_PORTS[@]:-}"; do [[ "$u" == "$p" ]] && return 0; done
  return 1
}
alloc_port() {  # alloc_port <start> -> first free port at/after <start>
  local p="$1"
  while port_taken_in_batch "$p" || port_listening "$p"; do p=$((p + 1)); done
  USED_PORTS+=("$p")
  echo "$p"
}

declare -a SPAWNED_LINES=()

# spawn_one <name>
spawn_one() {
  local name="$1"
  local dir="${INSTANCES_DIR}/${name}"
  mkdir -p "${dir}/tpm"

  # Per-instance seed: start from --seed (if given) or a minimal default, then
  # force hostname = instance name so NetBIOS names don't collide.
  local tmp_seed; tmp_seed="$(mktemp -t "winseed-${name}.XXXXXX")"
  trap 'rm -f "${tmp_seed}"' RETURN
  if [[ -n "$SEED_FILE" ]]; then
    cp "$SEED_FILE" "$tmp_seed"
  else
    printf '{"username":"admin","groups":["Administrators"]}\n' > "$tmp_seed"
  fi
  plutil -remove hostname "$tmp_seed" >/dev/null 2>&1 || true
  plutil -insert hostname -string "$name" "$tmp_seed" >/dev/null

  echo "==> [${name}] building seed CD"
  if [[ ${#EXPLICIT_KEY_FLAGS[@]} -gt 0 ]]; then
    "${PIPELINE_DIR}/seed/build-cidata.sh" -o "${dir}/cidata.iso" --env="${ENV_FILE}" \
      "${EXPLICIT_KEY_FLAGS[@]}" "$tmp_seed" > "${dir}/cidata-build.log" 2>&1
  else
    "${PIPELINE_DIR}/seed/build-cidata.sh" -o "${dir}/cidata.iso" --env="${ENV_FILE}" \
      "$tmp_seed" > "${dir}/cidata-build.log" 2>&1
  fi

  # COW disk + NVRAM (base stays sysprep-fresh).
  qemu-img create -f qcow2 -b "$BASE_QCOW2" -F qcow2 "${dir}/disk.qcow2" >/dev/null
  cp "$BASE_EFIVARS" "${dir}/vars.fd"

  # Networking. VNC display is always allocated (headless inspection).
  local vnc_port vnc_disp ssh_port="" rdp_port="" mac=""
  vnc_port="$(alloc_port "$VNC_PORT_BASE")"
  vnc_disp=$((vnc_port - 5900))

  local -a NETDEV_ARGS=()
  local NET_DEVICE
  if [[ "$BRIDGED" == "true" ]]; then
    # vmnet-shared: each VM gets its own IP on a shared, host-reachable
    # subnet (internet via NAT), no host-port juggling — reachable on the
    # normal :22 / :3389. Deterministic per-name MAC so the IP is findable.
    mac="52:54:00:$(printf '%s' "$name" | shasum | cut -c1-6 | sed 's/\(..\)\(..\)\(..\)/\1:\2:\3/')"
    NET_DEVICE="virtio-net-pci,netdev=net0,mac=${mac}"
    NETDEV_ARGS=(-netdev "vmnet-shared,id=net0")
  else
    # NAT + per-instance host-port forwards (no privileges needed).
    ssh_port="$(alloc_port "$SSH_BASE")"
    rdp_port="$(alloc_port "$RDP_BASE")"
    NET_DEVICE="virtio-net-pci,netdev=net0"
    NETDEV_ARGS=(-netdev "user,id=net0,hostfwd=tcp::${ssh_port}-:22,hostfwd=tcp::${rdp_port}-:3389")
  fi

  # swtpm: socket lives in /tmp (macOS sun_path 104-byte limit; the deep
  # instance dir under the repo blows it). State + pidfile stay in the dir.
  local sock="/tmp/wvm-${name}.tpm.sock"
  swtpm socket --tpmstate "dir=${dir}/tpm" --ctrl "type=unixio,path=${sock}" \
    --pid "file=${dir}/swtpm.pid" --tpm2 --daemon
  for _ in 1 2 3 4 5; do [[ -S "$sock" ]] && break; sleep 1; done
  [[ -S "$sock" ]] || { echo "ERROR: [${name}] swtpm socket did not appear" >&2; exit 1; }

  if [[ "$BRIDGED" == "true" ]]; then
    echo "==> [${name}] booting headless (vmnet, mac ${mac}, VNC :${vnc_disp})"
  else
    echo "==> [${name}] booting headless (SSH :${ssh_port}, RDP :${rdp_port}, VNC :${vnc_disp})"
  fi
  nohup qemu-system-aarch64 \
    -name "winvm-${name}" \
    -machine virt,gic-version=max -accel hvf -cpu host \
    -smp "$CPUS" -m "$MEM_MB" \
    -drive "if=pflash,format=raw,readonly=on,file=${EFI_CODE}" \
    -drive "if=pflash,format=raw,file=${dir}/vars.fd" \
    -chardev "socket,id=chrtpm,path=${sock}" \
    -tpmdev "emulator,id=tpm0,chardev=chrtpm" \
    -device tpm-tis-device,tpmdev=tpm0 \
    -device ramfb \
    -device qemu-xhci,id=usb -device usb-kbd,bus=usb.0 -device usb-tablet,bus=usb.0 \
    -drive "file=${dir}/disk.qcow2,if=virtio,format=qcow2" \
    -drive "file=${dir}/cidata.iso,media=cdrom,if=none,id=seedcd" \
    -device usb-storage,drive=seedcd,bus=usb.0 \
    -device "$NET_DEVICE" \
    "${NETDEV_ARGS[@]}" \
    -vnc "127.0.0.1:${vnc_disp}" \
    < /dev/null > "${dir}/qemu.log" 2>&1 &
  echo $! > "${dir}/qemu.pid"
  disown

  # Record instance metadata for cleanup/listing.
  {
    printf 'name=%s\n' "$name"
    printf 'mode=%s\n' "$([[ "$BRIDGED" == "true" ]] && echo bridged || echo nat)"
    printf 'ssh_port=%s\n' "$ssh_port"
    printf 'rdp_port=%s\n' "$rdp_port"
    printf 'mac=%s\n' "$mac"
    printf 'vnc_display=%s\n' "$vnc_disp"
    printf 'tpm_sock=%s\n' "$sock"
  } > "${dir}/meta"

  if [[ "$BRIDGED" == "true" ]]; then
    SPAWNED_LINES+=("  ${name} → own IP via vmnet (mac ${mac}); find it from the VNC console (ipconfig) or arp, then: ssh admin@<ip>   (VNC :${vnc_disp})")
  else
    SPAWNED_LINES+=("  ${name} → ssh admin@127.0.0.1 -p ${ssh_port}   (RDP 127.0.0.1:${rdp_port}, VNC :${vnc_disp})")
  fi

  # If invoked under sudo (--bridged), hand the instance files back to the
  # invoking user so the repo doesn't fill with root-owned state.
  if [[ -n "${SUDO_USER:-}" ]]; then chown -R "$SUDO_USER" "$dir" 2>/dev/null || true; fi
}

# ---- spawn loop -------------------------------------------------------------

if [[ -n "$EXPLICIT_NAME" ]]; then
  instance_exists "$EXPLICIT_NAME" && { echo "ERROR: instance '${EXPLICIT_NAME}' already exists." >&2; exit 1; }
  spawn_one "$EXPLICIT_NAME"
else
  for ((i = 0; i < COUNT; i++)); do
    spawn_one "windows-$(next_free_index)"
  done
fi

echo
echo "==> spawned ${#SPAWNED_LINES[@]} Windows instance(s):"
for line in "${SPAWNED_LINES[@]}"; do echo "$line"; done
echo
echo "First boot runs mini-setup + FirstBootSeed; SSH/RDP come up in a few minutes."
echo "admin passwords were written to ${ENV_FILE}"
echo "Per-instance state + logs: ${INSTANCES_DIR}/<name>/"
echo "Teardown: just cleanup-windows-vms   (or scripts/cleanup-windows-vms.sh)"

# Hand the env file back to the invoking user when run under sudo (--bridged).
if [[ -n "${SUDO_USER:-}" && -f "${ENV_FILE}" ]]; then chown "$SUDO_USER" "${ENV_FILE}" 2>/dev/null || true; fi
