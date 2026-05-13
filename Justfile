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

# Build the Windows 11 ARM64 base image. Requires the Insider VHDX present
# at the path configured in .env.local — see packer/windows-11-arm64/README.md.
build-windows:
    @./scripts/build-windows.sh

# --- validation --------------------------------------------------------------

# `packer fmt -check` + `packer validate` across every Packer dir.
validate:
    cd packer/ubuntu-24-04-arm64 && packer init . && packer fmt -check . && packer validate .
    cd packer/windows-11-arm64   && packer init . && packer fmt -check . && packer validate .

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
