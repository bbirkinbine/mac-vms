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

# Build the Windows 11 ARM64 base image via QEMU + swtpm (Tart doesn't
# expose TPM/Secure Boot). Requires the Win11 ARM64 ISO path set in
# .env.local — see packer/windows-11-arm64/README.md for the download.
build-windows:
    @./scripts/build-windows.sh

# Boot the built Windows qcow2 directly under qemu-system-aarch64 with the
# same TPM + EFI + ramfb + USB plumbing the build used. Probes whether the
# artifact is good without UTM in the way. Defaults to a COW clone so the
# base qcow2 stays sysprep-fresh.
#
#   just run-windows          # COW clone (reuses run.qcow2 if present)
#   just run-windows --fresh  # wipe COW + NVRAM, start clean
#   just run-windows --base   # boot base qcow2 directly (dirties it)
run-windows *FLAGS:
    @./scripts/run-windows.sh {{FLAGS}}

# --- validation --------------------------------------------------------------

# `packer fmt -check` + `packer validate` across every Packer dir. The
# Windows source's required variables (iso_path, swtpm_socket_path) don't
# have defaults; feed validate dummy values so the HCL parses without us
# needing a real ISO present.
validate:
    cd packer/ubuntu-24-04-arm64 && packer init . && packer fmt -check . && PKR_VAR_iso_path=/tmp/fake.iso packer validate .
    cd packer/windows-11-arm64   && packer init . && packer fmt -check . && PKR_VAR_iso_path=/tmp/fake.iso PKR_VAR_virtio_win_iso_path=/tmp/fake-virtio.iso PKR_VAR_qemu_binary=/usr/bin/true packer validate .

# `packer fmt -recursive` to fix formatting drift.
fmt:
    packer fmt -recursive packer/

# Syntax-check the wrapper scripts. shellcheck must be on PATH.
shell-lint:
    bash -n scripts/*.sh
    shellcheck scripts/*.sh

# --- housekeeping ------------------------------------------------------------

# List Tart VMs (built images + local working copies).
list:
    tart list

# Delete a built image by name. Usage: just delete ubuntu-24-04-arm64-base
delete name:
    tart delete {{name}}

# Wipe Packer caches and any output-* directories. Does NOT touch ~/.tart
# (use `just delete` or `tart delete` for VM images).
clean:
    rm -rf packer/*/packer_cache packer/*/output-*
