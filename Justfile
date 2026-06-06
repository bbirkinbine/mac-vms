# mac-vms Justfile — wraps the per-OS build scripts and validation gates.
#
# Why a Justfile (vs Make): no tab-vs-space pitfalls, no implicit rules, one
# binary install. Parity with the sibling homelab repo so muscle memory
# carries over.

default:
    @just --list

# --- builds ------------------------------------------------------------------

# Build the Ubuntu 24.04 ARM64 base image.
build-ubuntu:
    @./scripts/build-ubuntu.sh

# Build the Kali rolling ARM64 base image. Same Tart-based shape as the
# Ubuntu build; uses Debian Installer preseed instead of subiquity. See
# packer/kali-rolling-arm64/README.md and docs/kali-vs-ubuntu.md.
build-kali:
    @./scripts/build-kali.sh

# Build the Windows 11 ARM64 base image via QEMU + swtpm (Tart doesn't
# expose TPM/Secure Boot). Requires the Win11 ARM64 ISO path set in
# .env.local — see packer/windows-11-arm64/README.md for the download.
build-windows:
    @./scripts/build-windows.sh

# --- spawn / cleanup ---------------------------------------------------------

# Spawn one or more ubuntu/kali clones from the corresponding base image.
# Default: spawn one VM, auto-named `<distro>-N` for the next free N. Pass
# extra args verbatim to scripts/spawn-vm.sh: -c <count>, -n <name>, -i
# <pubkey-path>. Examples:
#   just spawn ubuntu                # ubuntu-<N>
#   just spawn kali -c 3             # kali-<N>, kali-<N+1>, kali-<N+2>
#   just spawn ubuntu -n webhost     # explicit name; no iteration
spawn distro *FLAGS:
    @./scripts/spawn-vm.sh {{distro}} {{FLAGS}}

# Stop + delete every `<distro>-*` clone (excluding the canonical base
# image). Interactive confirmation; pass -y to skip, --dry-run to preview.
# Named one-offs (spawn-vm.sh -n) are NOT matched; delete those manually
# with `tart delete <name>`.
cleanup-vms distro *FLAGS:
    @./scripts/cleanup-vms.sh {{distro}} {{FLAGS}}

# Backing recipe for `just spawn windows` — use that; this is [private] (hidden
# from `just --list`) but still callable. Spawns Windows 11 clones from the base
# qcow2, each headless under qemu with its own COW disk, seed CD, and
# SSH/RDP/VNC ports. Generated admin passwords go to .env.windows-vms, not stdout.
#   just spawn windows               # windows-<N>
#   just spawn windows -c 3          # three at once
#   just spawn windows -n devbox     # explicit name
#   just spawn windows --seed packer/windows-11-arm64/seed/lab-seed.json
[private]
spawn-windows *FLAGS:
    @./scripts/spawn-windows.sh {{FLAGS}}

# Backing recipe for `just cleanup-vms windows` — use that; this is [private].
# Stop + delete Windows instances created by spawn. Interactive confirmation;
# -y to skip, --dry-run to preview, -n <name> for a single instance.
[private]
cleanup-windows-vms *FLAGS:
    @./scripts/cleanup-windows-vms.sh {{FLAGS}}

# Boot the built Windows qcow2 directly under qemu-system-aarch64 with the
# same TPM + EFI + ramfb + USB plumbing the build used. Probes whether the
# artifact is good without UTM in the way. Defaults to a COW clone so the
# base qcow2 stays sysprep-fresh.
#
#   just run-windows                              # COW clone (reuses run.qcow2 if present)
#   just run-windows --fresh                      # wipe COW + NVRAM, start clean
#   just run-windows --base                       # boot base qcow2 directly (dirties it)
#   just run-windows --seed seed/lab-seed.json    # attach a seed CD; FirstBootSeed
#                                                 # injects the login (SSH on host :2222,
#                                                 # RDP on :13389). Seeded analogue of
#                                                 # `just spawn` for Linux.
run-windows *FLAGS:
    @./scripts/run-windows.sh {{FLAGS}}

# --- validation --------------------------------------------------------------

# `packer fmt -check` + `packer validate` across every Packer dir. The
# Windows source's required variables (iso_path, swtpm_socket_path) don't
# have defaults; feed validate dummy values so the HCL parses without us
# needing a real ISO present.
validate:
    cd packer/ubuntu-24-04-arm64 && packer init . && packer fmt -check . && PKR_VAR_iso_path=/tmp/fake.iso packer validate .
    cd packer/kali-rolling-arm64 && packer init . && packer fmt -check . && PKR_VAR_iso_path=/tmp/fake.iso packer validate .
    cd packer/windows-11-arm64   && packer init . && packer fmt -check . && PKR_VAR_iso_path=/tmp/fake.iso PKR_VAR_virtio_win_iso_path=/tmp/fake-virtio.iso PKR_VAR_qemu_binary=/usr/bin/true packer validate .

# `packer fmt -recursive` to fix formatting drift.
fmt:
    packer fmt -recursive packer/

# Syntax-check the wrapper scripts. shellcheck must be on PATH.
shell-lint:
    bash -n scripts/*.sh packer/*/seed/*.sh
    shellcheck scripts/*.sh packer/*/seed/*.sh

# Parse-check the Windows PowerShell provisioners (incl. the embedded
# here-string bodies that get written to clones). Skips gracefully if pwsh
# isn't installed — `brew install powershell` to enable. See
# scripts/lint-powershell.ps1.
ps-lint:
    @if command -v pwsh >/dev/null 2>&1; then \
        pwsh -NoProfile -File scripts/lint-powershell.ps1; \
    else \
        echo "pwsh not installed — skipping PowerShell parse-check (brew install powershell)"; \
    fi

# --- housekeeping ------------------------------------------------------------

# List everything running: Tart VMs (ubuntu/kali) + Windows qemu instances.
list:
    @tart list
    @echo
    @./scripts/list-windows-vms.sh

# List just the Windows qemu instances (name, running state, ssh/RDP access).
# Windows VMs aren't Tart-managed, so `tart list` can't see them.
list-windows:
    @./scripts/list-windows-vms.sh

# Delete by name — aware of both backends. A Windows fleet instance (qemu)
# is stopped + removed; a Tart VM/image (ubuntu/kali bases + clones) is
# `tart delete`d. The Windows base qcow2 is a file, not a managed VM — the
# message points you at `just clean` for that.
#   just delete ubuntu-24-04-arm64-base   # Tart image
#   just delete windows-3                 # Windows fleet instance
[doc('Delete a Tart VM/image or a Windows fleet instance, by name')]
delete name:
    #!/usr/bin/env bash
    set -euo pipefail
    name='{{name}}'
    if [[ -d "packer/windows-11-arm64/output-windows-11-arm64/instances/${name}" ]]; then
        ./scripts/cleanup-windows-vms.sh -n "${name}" -y
    elif tart list 2>/dev/null | awk 'NR>1 {print $2}' | grep -qx "${name}"; then
        tart delete "${name}"
    else
        echo "ERROR: '${name}' is neither a Windows fleet instance nor a Tart VM/image." >&2
        echo "  Tart VMs/images:     just list        (ubuntu/kali bases + clones)" >&2
        echo "  Windows instances:   just list-windows" >&2
        echo "  Windows base qcow2:  it's a file, not a managed VM — remove with 'just clean'" >&2
        echo "                       (wipes all output-*/) or rm the qcow2 directly." >&2
        exit 1
    fi

# Wipe Packer caches and any output-* directories. Does NOT touch ~/.tart
# (use `just delete` or `tart delete` for VM images).
clean:
    rm -rf packer/*/packer_cache packer/*/output-*
