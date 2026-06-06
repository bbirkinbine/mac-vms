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

Build a base image once; after that, `just spawn` launches throwaway
clones on demand — no rebuild needed to fire one up. Works for all three
OSes:

```bash
just build-ubuntu              # or: build-kali / build-windows   (build once)
just spawn ubuntu              # or: spawn kali / spawn windows; -c <N> for batches
just cleanup-vms ubuntu        # stop + delete that OS's clones
```

**Already have a base image and just want a VM to test on?** Skip the
build — `just spawn <os>` is the whole happy path. (Windows clones run
under QEMU rather than Tart, so they're reached on forwarded ports — see
the [Windows clone runbook](docs/cloning-windows.md) — but the spawn /
cleanup verbs are the same.)

`just` with no args lists every recipe. Per-pipeline detail
(prerequisites, env vars, build status, gotchas) lives in the per-OS
READMEs:

- [`packer/ubuntu-24-04-arm64/README.md`](packer/ubuntu-24-04-arm64/README.md)
- [`packer/kali-rolling-arm64/README.md`](packer/kali-rolling-arm64/README.md)
- [`packer/windows-11-arm64/README.md`](packer/windows-11-arm64/README.md)

Per-VM identity (hostname, user, SSH key) is injected on first boot from
a seed — handled automatically by `just spawn` for all three OSes (the
Linux pipelines use a cloud-init NoCloud seed; Windows uses an equivalent
first-boot seed consumer, since cloudbase-init has no ARM64 build). Per-OS
clone runbooks: [Ubuntu](docs/cloning-ubuntu.md),
[Kali](docs/cloning-kali.md), [Windows](docs/cloning-windows.md).

## Repository layout

- [`packer/`](packer/) — one Packer config per pipeline.
- [`scripts/`](scripts/) — env-driven wrappers called by the Justfile
  (build, spawn, cleanup, list per OS).
- [`docs/`](docs/) — operator runbooks (cloning per OS, build-attempt
  retrospectives, Tart IP-discovery quirk, UTM consumption).
- [`Justfile`](Justfile) — top-level orchestration.
- [`CLAUDE.md`](CLAUDE.md) — project context and tool-choice rationale.
- [`TODO.md`](TODO.md) — open work and known gaps.

## Acknowledgements

Developed with the assistance of AI tools.
