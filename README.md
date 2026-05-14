# mac-vms

> **Status:** Published as a personal-lab reference, not an actively
> maintained product. Issues and PRs are welcome but won't
> get fast turnaround. The [`docs/`](docs/) tree (especially
> [`docs/windows-build-attempts.md`](docs/windows-build-attempts.md), the
> diagnostic history of the Windows ARM64 install) is the most likely
> thing to be useful to others.

Reproducible Ubuntu 24.04 ARM64 and Windows 11 ARM64 VM images for Apple
Silicon MacBooks, both built with [Packer](https://www.packer.io/). The two
pipelines use different sources because Apple's Virtualization.framework
(what [Tart](https://github.com/cirruslabs/tart) is built on) doesn't
expose the devices Windows needs:

- **Ubuntu** — Packer's [`tart-cli`](https://tart.run/) source. Output
  is a versioned Tart image at `~/.tart/vms/ubuntu-24-04-arm64-base`,
  launched with `tart run`.
- **Windows** — Packer's `qemu` source on top of `qemu-system-aarch64` +
  `swtpm` + `edk2` (TPM 2.0 and UEFI Secure Boot, both Win11
  requirements, neither available via Tart). Output is a sysprep'd
  qcow2 at `packer/windows-11-arm64/output-windows-11-arm64/`,
  consumed by UTM or `qemu-system-aarch64` directly.

Companion to a private x86_64 `homelab` repo (Proxmox cluster). That repo
handles the cluster side; this one handles day-to-day laptop VMs.

## Host

Built and verified on a MacBook Pro M2 Max with 96 GiB RAM. Any
Apple Silicon Mac (M-series) running macOS 13 Ventura or later should
work — see Prerequisites below. x86_64 Macs are out of scope; use the
`homelab` Proxmox cluster for those.

## What it produces

- **`ubuntu-24-04-arm64-base`** — Ubuntu Server 24.04 LTS, cloud-init
  enabled, minimal package set, qemu-guest-agent equivalent installed.
  Suitable as a parent image for downstream dev VMs. Lives at
  `~/.tart/vms/ubuntu-24-04-arm64-base` after build; share between machines
  via `tart push <name> ghcr.io/you/<name>:tag`.
- **`windows-11-arm64-base`** — Windows 11 Pro ARM64 from Microsoft's public
  24H2 GA ISO, sysprepped + generalized at the end of the build. Bring your
  own ISO (Microsoft doesn't permit redistribution — see
  [`packer/windows-11-arm64/README.md`](packer/windows-11-arm64/README.md)
  for the download step). Output is a qcow2 at
  `packer/windows-11-arm64/output-windows-11-arm64/windows-11-arm64-base`
  (~12 GB after sysprep); consumed by UTM (`File → New → Virtualize → Import`)
  or `qemu-system-aarch64` directly — see
  [`docs/windows-utm.md`](docs/windows-utm.md).

## Prerequisites

### Host requirements

- Apple Silicon Mac (M-series). x86_64 Macs cannot run either pipeline —
  Tart needs the ARM-only Virtualization.framework, and the Windows build
  uses QEMU's `hvf` accelerator which is ARM Apple Silicon-only on macOS.
- **macOS 13 Ventura or newer** for Tart (Virtualization.framework APIs
  introduced in Ventura). QEMU + HVF is fine on older releases but if you
  want both pipelines on the same host, Ventura+ is the floor.
- Xcode Command Line Tools (provides `xmllint` and a usable `git`) —
  install with `xcode-select --install`.
- Free disk: ~20 GB for the Ubuntu build, ~40 GB for the Windows build
  (the qcow2 itself is ~12 GB after sysprep + a ~5 GB Win11 ISO + a ~700 MB
  virtio-win ISO + packer_cache during build).
- [Homebrew](https://brew.sh) for installing everything below.

### Required tools

```bash
brew install --cask tart
brew install packer just xorriso qemu swtpm
```

- `tart` runs the Ubuntu build (Apple Virtualization.framework).
- `qemu` and `swtpm` run the Windows build (Tart can't host Win11 — Apple
  Virtualization.framework lacks TPM and only exposes virtio buses that
  ARM WinPE can't read; see `docs/windows-build-attempts.md` §1).
  `qemu-system-aarch64` boots the install with HVF acceleration; `swtpm`
  provides the virtual TPM 2.0 the Win11 installer requires.
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

# Build the Windows base (runs under qemu-system-aarch64 + swtpm).
# Requires WINDOWS_ISO_PATH and VIRTIO_WIN_ISO_PATH in .env.local —
# see packer/windows-11-arm64/README.md for download steps.
just build-windows
# Output: packer/windows-11-arm64/output-windows-11-arm64/windows-11-arm64-base
# Import into UTM or boot directly with qemu-system-aarch64 — see
# docs/windows-utm.md for both consumption paths.
```

The two pipelines diverge because Tart can't host Windows 11. Three
layered blockers (no Windows VM configuration in Tart's source; no TPM
in Apple Virtualization.framework; AVF only exposes virtio buses and ARM
WinPE has no in-box virtio-blk driver) make even a single-ISO install
infeasible — see [`docs/windows-build-attempts.md`](docs/windows-build-attempts.md)
§1 for the full analysis. Ubuntu builds + runs entirely under Tart;
Windows builds under Packer's `qemu` source with `swtpm` for the TPM
and `edk2` for UEFI, then the resulting qcow2 runs under UTM or QEMU
directly. The Windows build resolved a multi-wall diagnostic sequence
(CD-ROM bus, USB enumeration order, hardware-requirements check,
NetBIOS name length, sysprep exit code) — captured in the same doc
for the next person who has to touch it.

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

See [`CLAUDE.md`](CLAUDE.md) for the longer rationale. Short version:

- **Ubuntu uses Tart** because it's the only Apple-Silicon-native builder
  with a first-class Packer plugin and OCI-registry distribution, and
  nothing Ubuntu needs is missing from Apple's Virtualization.framework.
- **Windows uses Packer's `qemu` source** because Apple's
  Virtualization.framework doesn't expose TPM 2.0 or UEFI Secure Boot to
  non-macOS guests (both Win11 requirements), and on top of that only
  exposes virtio buses — ARM Win11 WinPE has no in-box virtio-blk driver,
  so even with TPM the install would fail at the disk probe. QEMU sidesteps
  both via `swtpm` + `edk2` + `usb-storage` CD attach.
  [`docs/windows-build-attempts.md`](docs/windows-build-attempts.md) has
  the full analysis.
- **UTM and Parallels** are valid alternatives but earn their keep at
  different points in the workflow — UTM as an interactive front-end for
  the qcow2 the Windows build produces; Parallels as a paid-license
  fallback if QEMU+swtpm ever regresses.

## Acknowledgements

This project was developed with the assistance of AI tools.
