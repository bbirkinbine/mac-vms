# mac-vms

> **Status.** Personal-lab reference, not an actively maintained product.
> Issues and PRs welcome but won't get fast turnaround. Per-pipeline
> status (verified end-to-end, builds-but-untested, etc.) lives at the
> top of each pipeline's README — check there before depending on a
> snapshot, and pin a commit if you do.

Reproducible **Ubuntu 24.04 ARM64**, **Kali rolling ARM64**, and
**Windows 11 ARM64** VM images for Apple Silicon Macs. All built with
[Packer](https://www.packer.io); the Linux pipelines run under
[Tart](https://github.com/cirruslabs/tart) (Apple
Virtualization.framework), Windows runs under QEMU + `swtpm` (Tart
can't host Windows on ARM — TPM/Secure Boot, plus a virtio-bus issue
documented in [`docs/windows-build-attempts.md`](docs/windows-build-attempts.md)).
Each pipeline outputs a versioned base image designed to be cloned
for downstream use.

Companion to the x86_64
[`homelab`](https://github.com/bbirkinbine/homelab) repo (Proxmox
cluster).

## Quick start

Apple Silicon Mac, macOS 13 Ventura or newer. Install the toolchain:

```bash
brew install --cask tart
brew install packer just xorriso qemu swtpm
```

Build a base image, then spawn throwaway clones from it:

```bash
just build-ubuntu              # or: build-kali, build-windows
just spawn ubuntu              # or: spawn kali; -c <N> for batches
just cleanup-vms ubuntu        # stop + delete every <distro>-* clone
```

`just` with no args lists every recipe. Per-pipeline detail
(prerequisites, env vars, build status, gotchas) lives in the per-OS
READMEs:

- [`packer/ubuntu-24-04-arm64/README.md`](packer/ubuntu-24-04-arm64/README.md)
- [`packer/kali-rolling-arm64/README.md`](packer/kali-rolling-arm64/README.md)
- [`packer/windows-11-arm64/README.md`](packer/windows-11-arm64/README.md)

Per-VM identity (hostname, admin user, SSH key) is injected on first
boot via a cloud-init NoCloud seed on Linux, or interactively via
OOBE-mini on Windows. Per-OS clone runbooks:
[Ubuntu](docs/cloning-ubuntu.md), [Kali](docs/cloning-kali.md),
[Windows](docs/cloning-windows.md).

## Repository layout

- [`packer/`](packer/) — one Packer config per pipeline.
- [`scripts/`](scripts/) — env-driven wrappers called by the Justfile
  (`build-*`, `spawn-vm`, `cleanup-vms`).
- [`docs/`](docs/) — operator runbooks (cloning per OS, build-attempt
  retrospectives, Tart IP-discovery quirk, UTM consumption).
- [`Justfile`](Justfile) — top-level orchestration.
- [`CLAUDE.md`](CLAUDE.md) — project context and tool-choice rationale.
- [`TODO.md`](TODO.md) — open work and known gaps.

## Acknowledgements

Developed with the assistance of AI tools.
