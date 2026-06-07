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
#     ~/.ssh/id_*.pub, a generated password written to ~/.env.windows-vms —
#     not stdout, via build-cidata.sh --env),
#   - networking: by default qemu user-mode NAT with per-instance host-port
#     forwards (SSH 2222+, RDP 13389+) — no privileges needed. With --bridged
#     each VM instead gets its OWN IP via macOS vmnet (reachable on the normal
#     :22 / :3389, like the Tart Linux VMs) — but vmnet needs root, so
#     --bridged must run under sudo.
#   - display: a window per VM by default so you can watch first boot (it
#     takes a few minutes). --headless opens no window and serves a VNC
#     display (5950+) instead — better for batches / remote use.
#   - swtpm + qemu process, tracked by pidfiles under the instance dir.
#
# Usage:
#   ./scripts/spawn-windows.sh                 # windows-<next-free-N> (shows a window)
#   ./scripts/spawn-windows.sh -c 3            # three at once
#   ./scripts/spawn-windows.sh -n devbox       # explicit name (no auto-increment)
#   ./scripts/spawn-windows.sh --headless      # no window; VNC display instead
#   ./scripts/spawn-windows.sh -i ~/.ssh/k.pub # explicit pubkey (repeatable)
#   ./scripts/spawn-windows.sh --seed s.json   # base seed; hostname is overridden per instance
#   sudo ./scripts/spawn-windows.sh --bridged  # per-VM IP on :22 (vmnet; needs root)
#   ./scripts/spawn-windows.sh --cpus 8        # vCPUs per instance (default 4)
#   ./scripts/spawn-windows.sh --mem 32G       # RAM per instance, qemu -m form (default 16384 MiB)
#   ./scripts/spawn-windows.sh --disk-size 128G # grow each COW disk (qemu-img resize; needs in-Windows extend)
#   ./scripts/spawn-windows.sh --start devbox  # RESUME a stopped instance (no new clone/seed; --cpus/--mem ok)
#   ./scripts/spawn-windows.sh -h
#
# Stop a running instance: scripts/stop-windows.sh -n <name> (or `just stop <name>`).
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
ENV_FILE="${HOME}/.env.windows-vms"
EFI_CODE="/opt/homebrew/share/qemu/edk2-aarch64-code.fd"

SSH_BASE=2222
RDP_BASE=13389
VNC_PORT_BASE=5950   # VNC display N => TCP 5900+N
# Per-instance hardware. CPUS -> qemu -smp; MEM is passed straight to qemu -m
# (a bare number is MiB, so 16384 == 16 GiB; "16G" also works). DISK_SIZE empty
# means "inherit the base image's virtual size"; set it (e.g. 128G) to qemu-img
# resize each COW overlay after creation — see the spawn_one note.
CPUS=4
MEM=16384
DISK_SIZE=""

COUNT=1
EXPLICIT_NAME=""
SEED_FILE=""
BRIDGED=false
HEADLESS=false
START_NAME=""   # set by --start <name>: resume an existing instance, don't create
declare -a EXPLICIT_KEY_FLAGS=()

usage() {
  sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
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
    --headless) HEADLESS=true ;;
    --cpus)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --cpus requires a number" >&2; exit 1; }
      CPUS="$1"
      ;;
    --cpus=*) CPUS="${1#--cpus=}" ;;
    --mem)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --mem requires a value" >&2; exit 1; }
      MEM="$1"
      ;;
    --mem=*) MEM="${1#--mem=}" ;;
    --disk-size)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --disk-size requires a value (e.g. 128G)" >&2; exit 1; }
      DISK_SIZE="$1"
      ;;
    --disk-size=*) DISK_SIZE="${1#--disk-size=}" ;;
    --start)
      shift
      [[ $# -gt 0 ]] || { echo "ERROR: --start requires an instance name" >&2; exit 1; }
      START_NAME="$1"
      ;;
    --start=*) START_NAME="${1#--start=}" ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
    *) echo "ERROR: unexpected argument: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

# --start resumes an existing instance: the create-time knobs don't apply. Only
# --cpus/--mem (qemu launch params) may ride along to re-shape hardware on boot.
if [[ -n "$START_NAME" ]]; then
  if [[ "$COUNT" -gt 1 || -n "$EXPLICIT_NAME" || -n "$SEED_FILE" || "$BRIDGED" == "true" \
        || "$HEADLESS" == "true" || -n "$DISK_SIZE" || ${#EXPLICIT_KEY_FLAGS[@]} -gt 0 ]]; then
    echo "ERROR: --start <name> only accepts --cpus/--mem; the create-time flags" >&2
    echo "       (-c/-n/-i/--seed/--bridged/--headless/--disk-size) don't apply to a" >&2
    echo "       resume — networking + display are restored from the instance's meta." >&2
    exit 1
  fi
fi
if [[ -n "$EXPLICIT_NAME" && "$COUNT" -gt 1 ]]; then
  echo "ERROR: -n <name> is incompatible with -c <count > 1>." >&2
  exit 1
fi
if [[ -n "$SEED_FILE" && ! -f "$SEED_FILE" ]]; then
  echo "ERROR: --seed file not found: $SEED_FILE" >&2
  exit 1
fi
# Hardware-spec validation. CPUS: positive int. MEM: digits + optional M/G
# (qemu -m form). DISK_SIZE: qemu-img size, absolute (128G) or relative (+64G);
# a unit is required so an unsuffixed number isn't mistaken for bytes.
# qemu/qemu-img want a single-letter unit, so strip a trailing "B" first —
# accept the natural "32GB"/"512MB" form and hand qemu "32G"/"512M".
[[ "$CPUS" =~ ^[0-9]+$ && "$CPUS" -ge 1 ]] || { echo "ERROR: --cpus must be a positive integer (got '$CPUS')" >&2; exit 1; }
MEM="${MEM%[Bb]}"
[[ "$MEM" =~ ^[0-9]+[MGmg]?$ ]] || { echo "ERROR: --mem must be a qemu -m value, e.g. 8192, 16G, or 16GB (got '$MEM')" >&2; exit 1; }
if [[ -n "$DISK_SIZE" ]]; then
  DISK_SIZE="${DISK_SIZE%[Bb]}"
  [[ "$DISK_SIZE" =~ ^\+?[0-9]+[MGTmgt]$ ]] || { echo "ERROR: --disk-size must carry a unit, e.g. 128G, 128GB, or +64G (got '$DISK_SIZE')" >&2; exit 1; }
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
[[ -f "$EFI_CODE" ]] || { echo "ERROR: EFI code not found: $EFI_CODE (brew install qemu)" >&2; exit 1; }
# The base image + seed builder are only needed to CREATE an instance. A --start
# resume boots the instance's own disk/NVRAM, so don't require the base (it may
# have been `just clean`ed away while instances live on under run/).
if [[ -z "$START_NAME" ]]; then
  [[ -f "$BASE_QCOW2" ]]  || { echo "ERROR: base qcow2 not found: $BASE_QCOW2 (run: just build-windows)" >&2; exit 1; }
  [[ -f "$BASE_EFIVARS" ]] || { echo "ERROR: base NVRAM not found: $BASE_EFIVARS" >&2; exit 1; }
  [[ -x "${PIPELINE_DIR}/seed/build-cidata.sh" ]] || { echo "ERROR: seed/build-cidata.sh missing/not executable" >&2; exit 1; }
fi

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

# boot_instance — start swtpm + qemu for an instance whose disk/NVRAM already
# exist on disk, write its meta, and append an access line to SPAWNED_LINES.
# Shared by the fresh-spawn path (spawn_one) and the resume path (start_one) so
# the qemu command lives in exactly one place — no drift between boot and reboot.
#   boot_instance <name> <dir> <mode> <ssh_port> <rdp_port> <mac> <vnc_disp> <attach_seed>
#     mode:        nat | bridged
#     vnc_disp:    "" => windowed (cocoa); a number => headless VNC on that display
#     attach_seed: true on first spawn (the cidata CD); false on resume (the
#                  in-image FirstBootSeed task is one-shot — already consumed)
boot_instance() {
  local name="$1" dir="$2" mode="$3" ssh_port="$4" rdp_port="$5" mac="$6" vnc_disp="$7" attach_seed="$8"

  local -a DISPLAY_ARGS=()
  if [[ -n "$vnc_disp" ]]; then
    DISPLAY_ARGS=(-vnc "127.0.0.1:${vnc_disp}")
  else
    DISPLAY_ARGS=(-display "cocoa,zoom-to-fit=on")
  fi

  local NET_DEVICE
  local -a NETDEV_ARGS=()
  if [[ "$mode" == "bridged" ]]; then
    # vmnet-shared: each VM gets its own IP on a shared, host-reachable subnet
    # (internet via NAT), reachable on the normal :22 / :3389. The MAC is
    # derived from the name so the IP stays findable across reboots.
    NET_DEVICE="virtio-net-pci,netdev=net0,mac=${mac}"
    NETDEV_ARGS=(-netdev "vmnet-shared,id=net0")
  else
    # NAT + per-instance host-port forwards (no privileges needed).
    NET_DEVICE="virtio-net-pci,netdev=net0"
    NETDEV_ARGS=(-netdev "user,id=net0,hostfwd=tcp::${ssh_port}-:22,hostfwd=tcp::${rdp_port}-:3389")
  fi

  # Seed CD only on first spawn. On resume the FirstBootSeed/cleanup tasks have
  # already run, so re-attaching it is pointless (and a footgun if it re-ran).
  local -a SEED_ARGS=()
  if [[ "$attach_seed" == "true" ]]; then
    SEED_ARGS=(
      -drive "file=${dir}/cidata.iso,media=cdrom,if=none,id=seedcd"
      -device "usb-storage,drive=seedcd,bus=usb.0"
    )
  fi

  # swtpm + QMP sockets live in /tmp: macOS sun_path is 104 bytes and the deep
  # instance dir under the repo blows it. State + pidfiles stay in the dir.
  local sock="/tmp/wvm-${name}.tpm.sock"
  local qmp_sock="/tmp/wvm-${name}.qmp.sock"
  # Kill any stale swtpm for this instance (e.g. a graceful stop left it up) and
  # clear stale sockets so the fresh swtpm/qemu can bind their paths.
  [[ -f "${dir}/swtpm.pid" ]] && kill "$(cat "${dir}/swtpm.pid")" 2>/dev/null || true
  rm -f "$sock" "$qmp_sock" 2>/dev/null || true
  swtpm socket --tpmstate "dir=${dir}/tpm" --ctrl "type=unixio,path=${sock}" \
    --pid "file=${dir}/swtpm.pid" --tpm2 --daemon
  for _ in 1 2 3 4 5; do [[ -S "$sock" ]] && break; sleep 1; done
  [[ -S "$sock" ]] || { echo "ERROR: [${name}] swtpm socket did not appear" >&2; return 1; }

  local view; if [[ -n "$vnc_disp" ]]; then view="headless, VNC :${vnc_disp}"; else view="window"; fi
  if [[ "$mode" == "bridged" ]]; then
    echo "==> [${name}] booting (${view}; vmnet, mac ${mac})"
  else
    echo "==> [${name}] booting (${view}; SSH :${ssh_port}, RDP :${rdp_port})"
  fi
  # -qmp on a /tmp unix socket is the control channel `just stop` drives for a
  # graceful ACPI power-off (system_powerdown). Disk tuning on the main qcow2
  # (cache=writeback,aio=threads,discard=unmap): writeback lets the host page
  # cache absorb writes (throughput win; fine for a throwaway clone), aio=threads
  # is the macOS-supported AIO backend, discard=unmap lets the overlay reclaim
  # space as Windows TRIMs. Not applied to the seed CD.
  nohup qemu-system-aarch64 \
    -name "winvm-${name}" \
    -machine virt,gic-version=max -accel hvf -cpu host \
    -smp "$CPUS" -m "$MEM" \
    -qmp "unix:${qmp_sock},server=on,wait=off" \
    -drive "if=pflash,format=raw,readonly=on,file=${EFI_CODE}" \
    -drive "if=pflash,format=raw,file=${dir}/vars.fd" \
    -chardev "socket,id=chrtpm,path=${sock}" \
    -tpmdev "emulator,id=tpm0,chardev=chrtpm" \
    -device tpm-tis-device,tpmdev=tpm0 \
    -device ramfb \
    -device qemu-xhci,id=usb -device usb-kbd,bus=usb.0 -device usb-tablet,bus=usb.0 \
    -drive "file=${dir}/disk.qcow2,if=virtio,format=qcow2,cache=writeback,aio=threads,discard=unmap" \
    "${SEED_ARGS[@]}" \
    -device "$NET_DEVICE" \
    "${NETDEV_ARGS[@]}" \
    "${DISPLAY_ARGS[@]}" \
    < /dev/null > "${dir}/qemu.log" 2>&1 &
  echo $! > "${dir}/qemu.pid"
  disown

  # Record instance metadata for cleanup/listing/restart. Refreshed every boot —
  # ports may differ from last time if a recorded one got reused (see start_one).
  {
    printf 'name=%s\n' "$name"
    printf 'mode=%s\n' "$mode"
    printf 'ssh_port=%s\n' "$ssh_port"
    printf 'rdp_port=%s\n' "$rdp_port"
    printf 'mac=%s\n' "$mac"
    printf 'vnc_display=%s\n' "$vnc_disp"
    printf 'tpm_sock=%s\n' "$sock"
    printf 'qmp_sock=%s\n' "$qmp_sock"
  } > "${dir}/meta"

  local viewhint
  if [[ -n "$vnc_disp" ]]; then viewhint="VNC :${vnc_disp}"; else viewhint="window open"; fi
  if [[ "$mode" == "bridged" ]]; then
    SPAWNED_LINES+=("  ${name} → own IP via vmnet (mac ${mac}); find it from the console (ipconfig) or arp, then ssh admin@<ip>   [${viewhint}]")
  else
    SPAWNED_LINES+=("  ${name} → ssh admin@127.0.0.1 -p ${ssh_port}   (RDP 127.0.0.1:${rdp_port})   [${viewhint}]")
  fi

  # If invoked under sudo (--bridged), hand the instance files back to the
  # invoking user so the repo doesn't fill with root-owned state.
  if [[ -n "${SUDO_USER:-}" ]]; then chown -R "$SUDO_USER" "$dir" 2>/dev/null || true; fi
}

# spawn_one <name> — create a brand-new instance (seed CD, COW disk, NVRAM) and
# boot it.
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
  # Optional bigger disk: grow the OVERLAY (not the base — the base stays
  # untouched and reusable). Windows still sees the extra space as unallocated;
  # extend the partition in-guest (diskpart `extend`, or Disk Management).
  if [[ -n "$DISK_SIZE" ]]; then
    echo "==> [${name}] resizing COW disk (${DISK_SIZE}; extend the partition in-Windows)"
    qemu-img resize "${dir}/disk.qcow2" "$DISK_SIZE" >/dev/null
  fi
  cp "$BASE_EFIVARS" "${dir}/vars.fd"

  # Resolve runtime networking/display, allocating fresh host ports.
  local vnc_disp="" mode ssh_port="" rdp_port="" mac=""
  if [[ "$HEADLESS" == "true" ]]; then
    local vnc_port; vnc_port="$(alloc_port "$VNC_PORT_BASE")"; vnc_disp=$((vnc_port - 5900))
  fi
  if [[ "$BRIDGED" == "true" ]]; then
    mode="bridged"
    mac="52:54:00:$(printf '%s' "$name" | shasum | cut -c1-6 | sed 's/\(..\)\(..\)\(..\)/\1:\2:\3/')"
  else
    mode="nat"
    ssh_port="$(alloc_port "$SSH_BASE")"
    rdp_port="$(alloc_port "$RDP_BASE")"
  fi

  boot_instance "$name" "$dir" "$mode" "$ssh_port" "$rdp_port" "$mac" "$vnc_disp" true
}

# start_one <name> — resume a STOPPED existing instance from its persisted
# disk.qcow2 / vars.fd / tpm state. No new COW, NVRAM, or seed CD; the recorded
# networking + display are reused (reallocating any host port that's since been
# taken). This is the counterpart to `just stop` / a guest power-off.
start_one() {
  local name="$1"
  local dir="${INSTANCES_DIR}/${name}"
  [[ -d "$dir" ]] || { echo "ERROR: no such Windows instance: ${name}" >&2; return 1; }
  [[ -f "${dir}/disk.qcow2" && -f "${dir}/vars.fd" ]] \
    || { echo "ERROR: ${name} is missing disk.qcow2/vars.fd — can't resume." >&2; return 1; }

  # Already running? Nothing to do.
  local pid=""
  [[ -f "${dir}/qemu.pid" ]] && pid="$(cat "${dir}/qemu.pid" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    echo "==> [${name}] already running (pid ${pid})"; return 0
  fi

  # Recover the recorded networking/display from meta.
  local mode="nat" ssh_port="" rdp_port="" mac="" vnc_disp=""
  if [[ -f "${dir}/meta" ]]; then
    mode="$(sed -n 's/^mode=//p' "${dir}/meta")"
    ssh_port="$(sed -n 's/^ssh_port=//p' "${dir}/meta")"
    rdp_port="$(sed -n 's/^rdp_port=//p' "${dir}/meta")"
    mac="$(sed -n 's/^mac=//p' "${dir}/meta")"
    vnc_disp="$(sed -n 's/^vnc_display=//p' "${dir}/meta")"
  fi
  [[ -n "$mode" ]] || mode="nat"

  # --cpus/--mem on `just start` would override hardware; otherwise CPUS/MEM keep
  # their defaults (so a resume defaults to the same shape as a fresh spawn).
  if [[ "$mode" == "nat" ]]; then
    # Reuse the recorded ports if still free; reallocate any that got taken while
    # this VM was stopped, so the relaunch can't collide.
    if [[ -z "$ssh_port" ]] || port_listening "$ssh_port"; then ssh_port="$(alloc_port "$SSH_BASE")"; fi
    if [[ -z "$rdp_port" ]] || port_listening "$rdp_port"; then rdp_port="$(alloc_port "$RDP_BASE")"; fi
  fi
  if [[ -n "$vnc_disp" ]]; then
    local vnc_port=$((5900 + vnc_disp))
    if port_listening "$vnc_port"; then vnc_port="$(alloc_port "$VNC_PORT_BASE")"; vnc_disp=$((vnc_port - 5900)); fi
  fi

  boot_instance "$name" "$dir" "$mode" "$ssh_port" "$rdp_port" "$mac" "$vnc_disp" false
}

# ---- dispatch ---------------------------------------------------------------

ACTION="spawned"
if [[ -n "$START_NAME" ]]; then
  ACTION="started"
  start_one "$START_NAME"
elif [[ -n "$EXPLICIT_NAME" ]]; then
  instance_exists "$EXPLICIT_NAME" && { echo "ERROR: instance '${EXPLICIT_NAME}' already exists." >&2; exit 1; }
  spawn_one "$EXPLICIT_NAME"
else
  for ((i = 0; i < COUNT; i++)); do
    spawn_one "windows-$(next_free_index)"
  done
fi

echo
echo "==> ${ACTION} ${#SPAWNED_LINES[@]} Windows instance(s):"
for line in "${SPAWNED_LINES[@]}"; do echo "$line"; done
echo
if [[ "$ACTION" == "spawned" ]]; then
  echo "First boot runs mini-setup + FirstBootSeed; SSH/RDP come up in a few minutes."
else
  echo "Resumed from existing disk; SSH/RDP return once Windows finishes booting."
fi
echo
echo "admin passwords:  ${ENV_FILE}"
echo "  (one WINVM_<NAME>_PASSWORD line per VM, appended; key login also works.)"
echo "Per-instance state + logs: ${INSTANCES_DIR}/<name>/"
echo "Stop (keep):  just stop <name>     Resume:  just start <name>"
echo "Teardown:     just cleanup-windows-vms   (or scripts/cleanup-windows-vms.sh)"

# Hand the env file back to the invoking user when run under sudo (--bridged).
if [[ -n "${SUDO_USER:-}" && -f "${ENV_FILE}" ]]; then chown "$SUDO_USER" "${ENV_FILE}" 2>/dev/null || true; fi
