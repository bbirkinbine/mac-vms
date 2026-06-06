# mac-vms Justfile — wraps the per-OS build scripts and validation gates.
#
# Why a Justfile (vs Make): no tab-vs-space pitfalls, no implicit rules, one
# binary install. Parity with the sibling homelab repo so muscle memory
# carries over.
#
# Each recipe carries a [doc('...')] one-liner so `just --list` reads as a
# clean menu (just otherwise shows the last comment line, which lands on a
# sub-detail for multi-line comments). Backing recipes for the unified verbs
# are [private] — they still run, just don't clutter the menu.

[private]
default:
    @just --list

# --- builds ------------------------------------------------------------------

[doc('Build the Ubuntu 24.04 ARM64 base image')]
build-ubuntu:
    @./scripts/build-ubuntu.sh

# Same Tart-based shape as the Ubuntu build; uses Debian Installer preseed
# instead of subiquity. See packer/kali-rolling-arm64/README.md.
[doc('Build the Kali rolling ARM64 base image')]
build-kali:
    @./scripts/build-kali.sh

# Via QEMU + swtpm (Tart can't expose TPM/Secure Boot). Requires the Win11
# ARM64 ISO path in .env.local — see packer/windows-11-arm64/README.md.
[doc('Build the Windows 11 ARM64 base image (QEMU + swtpm)')]
build-windows:
    @./scripts/build-windows.sh

# --- spawn / cleanup ---------------------------------------------------------

# Clone + boot throwaway VMs. ubuntu/kali run under Tart; `spawn windows`
# delegates to the qemu fleet manager. Flags: -c <count>, -n <name>,
# -i <pubkey>; Windows also takes --seed and --bridged.
#   just spawn ubuntu                # ubuntu-<N>
#   just spawn kali -c 3             # kali-<N>, kali-<N+1>, kali-<N+2>
#   just spawn windows -n devbox     # explicit name; no iteration
[doc('Clone + boot throwaway VMs: spawn <ubuntu|kali|windows> [-c N|-n name|-i key]')]
spawn distro *FLAGS:
    @./scripts/spawn-vm.sh {{distro}} {{FLAGS}}

# Interactive confirmation; pass -y to skip, --dry-run to preview. `cleanup-vms
# windows` delegates to the qemu teardown. Named one-off Tart clones (spawn -n)
# are NOT matched; delete those with `just delete <name>`.
[doc("Stop + delete an OS's clones: cleanup-vms <ubuntu|kali|windows>")]
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

# Boot the built Windows qcow2 directly under qemu (same TPM + EFI + ramfb +
# USB plumbing the build used). The "did the artifact come out good" probe,
# and the single-VM seeded path. Defaults to a COW clone so the base stays
# sysprep-fresh.
#   just run-windows                              # COW clone (reuses run.qcow2)
#   just run-windows --fresh                      # wipe COW + NVRAM, start clean
#   just run-windows --base                       # boot base qcow2 directly (dirties it)
#   just run-windows --seed seed/lab-seed.json    # attach a seed CD; inject a login
[doc('Boot the built Windows qcow2 under qemu (probe / single seeded VM)')]
run-windows *FLAGS:
    @./scripts/run-windows.sh {{FLAGS}}

# --- validation --------------------------------------------------------------

# Feeds the Windows source dummy var values so the HCL parses without a real
# ISO present.
[doc('packer fmt-check + validate across all pipelines (pre-commit gate)')]
validate:
    cd packer/ubuntu-24-04-arm64 && packer init . && packer fmt -check . && PKR_VAR_iso_path=/tmp/fake.iso packer validate .
    cd packer/kali-rolling-arm64 && packer init . && packer fmt -check . && PKR_VAR_iso_path=/tmp/fake.iso packer validate .
    cd packer/windows-11-arm64   && packer init . && packer fmt -check . && PKR_VAR_iso_path=/tmp/fake.iso PKR_VAR_virtio_win_iso_path=/tmp/fake-virtio.iso PKR_VAR_qemu_binary=/usr/bin/true PKR_VAR_output_directory=/tmp/pkr-validate-windows-out packer validate .

[doc('packer fmt -recursive (fix HCL formatting drift)')]
fmt:
    packer fmt -recursive packer/

# shellcheck must be on PATH.
[doc('bash -n + shellcheck the wrapper scripts (pre-commit gate)')]
shell-lint:
    bash -n scripts/*.sh packer/*/seed/*.sh
    shellcheck scripts/*.sh packer/*/seed/*.sh

# Parses the outer scripts AND the embedded here-string bodies that get
# written to clones. Skips gracefully if pwsh isn't installed.
[doc('Parse-check the Windows PowerShell provisioners (pre-commit gate)')]
ps-lint:
    @if command -v pwsh >/dev/null 2>&1; then \
        pwsh -NoProfile -File scripts/lint-powershell.ps1; \
    else \
        echo "pwsh not installed — skipping PowerShell parse-check (brew install powershell)"; \
    fi

# --- housekeeping ------------------------------------------------------------

[doc('List everything running: Tart VMs (ubuntu/kali) + Windows qemu instances')]
list:
    @tart list
    @echo
    @./scripts/list-windows-vms.sh

# Windows VMs aren't Tart-managed, so `tart list` can't see them.
[doc('List the Windows fleet instances (name, state, ssh/RDP access)')]
list-windows:
    @./scripts/list-windows-vms.sh

# Dispatches by name: a Windows fleet instance (qemu) is stopped + removed; a
# Tart VM/image (ubuntu/kali bases + clones) is `tart delete`d. The Windows
# base qcow2 is a file, not a managed VM — the message points you at `just clean`.
#   just delete ubuntu-24-04-arm64-base   # Tart image
#   just delete windows-3                 # Windows fleet instance
[doc('Delete a Tart VM/image or a Windows fleet instance, by name')]
delete name:
    #!/usr/bin/env bash
    set -euo pipefail
    name='{{name}}'
    if [[ -d "packer/windows-11-arm64/run/instances/${name}" ]]; then
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

# Does NOT touch ~/.tart (use `just delete` / `tart delete` for VM images).
[doc('Wipe Packer caches + output-*/ dirs (incl. the Windows base qcow2)')]
clean:
    rm -rf packer/*/packer_cache packer/*/output-*
