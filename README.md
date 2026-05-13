# mac-vms

Reproducible Ubuntu 24.04 ARM64 and Windows 11 ARM64 VM images for Apple Silicon
MacBooks. Built with [Packer](https://www.packer.io/) using the
[`tart-cli`](https://tart.run/) builder, runtime is
[Tart](https://github.com/cirruslabs/tart) on Apple Silicon.

Companion to the x86_64 [`homelab`](https://github.com/brianbirkinbine/homelab)
repo (Proxmox cluster). That repo handles the cluster side; this one handles
day-to-day laptop VMs.

## Hosts

| Host | Model | RAM | Notes |
| --- | --- | --- | --- |
| Personal | MacBook Pro M2 Max | 96 GiB | Primary build host; larger memory ceiling for heavier guests. |
| Work     | MacBook Pro M4 Max | 64 GiB | Secondary; verify MDM allows hypervisor install before assuming Parallels/Fusion is usable. |

Both are Apple Silicon (ARM64). x86_64 guests are out of scope here — use the
`homelab` Proxmox cluster for those.

## What it produces

- **`ubuntu-24-04-arm64-base`** — Ubuntu Server 24.04 LTS, cloud-init enabled,
  minimal package set, qemu-guest-agent equivalent installed. Suitable as a
  parent image for downstream dev VMs.
- **`windows-11-arm64-base`** — Windows 11 Pro ARM64 from the Microsoft Insider
  build, sysprepped at the end of the build. Bring-your-own-VHDX (Microsoft
  doesn't permit redistribution — see the Windows runbook for the download
  step).

Both images live in `~/.tart/vms/` after build; push to an OCI registry with
`tart push` to share between the two machines or with CI.

## Prerequisites

Install on each MacBook you'll build from:

```bash
brew install --cask tart
brew install packer just
packer plugins install github.com/cirruslabs/tart
```

Verify:

```bash
tart --version
packer version
just --version
```

Exclude Tart's image store from Time Machine:

```bash
sudo tmutil addexclusion -p ~/.tart
```

## Quick start

```bash
# Copy the env template (gitignored).
cp .env.local.example .env.local
# Edit .env.local with any overrides (defaults are usually fine).

# Build the Ubuntu base.
just build-ubuntu

# Build the Windows base (requires the Insider VHDX — see packer/windows-11-arm64/README.md).
just build-windows

# Run a built image.
tart run ubuntu-24-04-arm64-base
```

## Repository layout

- `packer/ubuntu-24-04-arm64/` — Packer config for the Ubuntu base.
  See [its README](packer/ubuntu-24-04-arm64/README.md).
- `packer/windows-11-arm64/` — Packer config for the Windows base. Bring your
  own VHDX. See [its README](packer/windows-11-arm64/README.md).
- `scripts/` — `build-ubuntu.sh` and `build-windows.sh` wrappers. Env-driven,
  validate preconditions up front. Called by the `Justfile`.
- `Justfile` — Top-level orchestration (`just build-ubuntu`, `just validate`,
  `just clean`).
- `docs/` — Component-level documentation (empty for now; the READMEs cover
  first-time setup).
- `CLAUDE.md` — Project context for Claude Code working in this repo. Read
  before suggesting structural changes.

## Validation

Before claiming a build change is ready:

```bash
just validate          # packer fmt -check + packer validate
bash -n scripts/*.sh   # syntax-check the wrappers
```

## Why these tool choices

See [`CLAUDE.md`](CLAUDE.md) for the rationale. Short version: Tart's the only
Apple-Silicon-native builder with a first-class Packer plugin and OCI-registry
distribution. UTM and Parallels are valid alternatives but earn their keep at
different points in the workflow.
