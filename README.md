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

### Host requirements

- Apple Silicon Mac (M-series). x86_64 Macs cannot run Tart — it relies on
  Apple's Virtualization.framework on ARM.
- **macOS 13 Ventura or newer.** Tart requires the Virtualization.framework
  APIs introduced in Ventura; macOS 14+ recommended for Windows guests.
- Xcode Command Line Tools (provides `xmllint` and a usable `git`) —
  install with `xcode-select --install`.
- Free disk: ~20 GB for the Ubuntu build, ~30 GB for the Windows build (plus
  the ~11 GB VHDX you supply yourself).
- [Homebrew](https://brew.sh) for installing everything below.

### Required tools

```bash
brew install --cask tart
brew install packer just xorriso qemu swtpm
```

- `tart` runs the Ubuntu build (Apple Virtualization.framework).
- `qemu` and `swtpm` run the Windows build (Tart can't host Win11 — no
  TPM/Secure Boot). `qemu-system-aarch64` boots the install with HVF
  acceleration; `swtpm` provides the virtual TPM 2.0 the Win11 installer
  requires.
- `xorriso` is used by the Ubuntu build wrapper to repack the live ISO with
  an autoinstall `grub.cfg` and a NoCloud seed — that's what makes the
  Ubuntu build unattended instead of needing keystroke-tuning at the GRUB
  menu.

Packer plugins (`tart`, `qemu`) are pulled in automatically by `packer init`
(run by the build wrappers). If you'd rather install them ahead of time
(offline / CI):

```bash
packer plugins install github.com/cirruslabs/tart
packer plugins install github.com/hashicorp/qemu
```

### Optional tools

```bash
brew install shellcheck   # used by `just shell-lint`
```

### Verify

```bash
tart --version
packer version
just --version
xorriso -version 2>&1 | head -2
xmllint --version 2>&1 | head -1
shellcheck --version 2>/dev/null | head -2 || echo "shellcheck not installed (optional)"
```

### Exclude Tart's image store from Time Machine

VM images are large, mutable, and pointless to back up — Time Machine will
churn forever otherwise.

```bash
sudo tmutil addexclusion -p ~/.tart
```

## Quick start

```bash
# Optional: copy the env template if you want to override any defaults
# (ISO URLs, VM specs, output names). Ubuntu builds without it; Windows
# needs WINDOWS_ISO_PATH set to point at your downloaded ISO.
cp .env.local.example .env.local   # gitignored

# Build the Ubuntu base (runs under Tart).
just build-ubuntu
tart run ubuntu-24-04-arm64-base

# Windows is currently UTM-only — the Packer qemu pipeline gets stopped
# at Win11 24H2 Setup's "no disks found" screen due to a WinPE driver
# gap (no in-box driver matches QEMU's emulated controllers, and 24H2
# Setup ignores the Autounattend driver-injection block). The Packer
# scaffolding is preserved in packer/windows-11-arm64/ in case the
# upstream story changes. See docs/windows-utm.md for the active path.
```

The two pipelines diverge because Tart can't host Windows 11 (no TPM 2.0
or Secure Boot, both Win11 requirements). Ubuntu builds + runs entirely
under Tart; Windows runs under UTM, with a Packer+QEMU+swtpm pipeline
scaffolded but blocked at the WinPE driver wall — see
[`packer/windows-11-arm64/README.md`](packer/windows-11-arm64/README.md)
for the full story.

## Repository layout

- `packer/ubuntu-24-04-arm64/` — Tart-based Packer config for the Ubuntu
  base. See [its README](packer/ubuntu-24-04-arm64/README.md).
- `packer/windows-11-arm64/` — QEMU+swtpm-based Packer config for the
  Windows 11 ARM64 base; outputs a qcow2. See
  [its README](packer/windows-11-arm64/README.md).
- `scripts/` — `build-ubuntu.sh` and `build-windows.sh` wrappers.
  Env-driven, validate preconditions up front. Called by the `Justfile`.
- `Justfile` — Top-level orchestration (`just build-ubuntu`, `just validate`,
  `just clean`).
- `docs/` — Operator runbooks. Start with
  [`docs/cloning-and-cloud-init.md`](docs/cloning-and-cloud-init.md) for how
  to clone a base image and inject per-VM identity (hostname, admin user,
  SSH key) on first boot.
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

## Acknowledgements

This project was developed with the assistance of AI tools.
