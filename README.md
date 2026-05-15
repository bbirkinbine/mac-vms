# mac-vms

> ## Status
>
> Published as a personal-lab reference, not an actively maintained product.
> Issues and PRs are welcome but won't get fast turnaround. The
> [`docs/`](docs/) runbooks — especially
> [`docs/windows-build-attempts.md`](docs/windows-build-attempts.md), the
> diagnostic history of the Windows ARM64 install — and the per-component
> READMEs under [`packer/*/`](packer/) are the parts most likely to be
> useful to others.
>
> **Ubuntu pipeline** is verified end-to-end on an M2 Max — clean `just
> build-ubuntu`, clone, cidata seed, SSH in, all canary checks green
> including `tart ip <vm>`. **Windows pipeline** builds end-to-end but
> the per-VM identity step (the cloud-init equivalent for Windows) is
> not yet implemented — a clone is currently identical to the base
> image. See [`TODO.md`](TODO.md) for the open Windows gap. Pin a commit
> if you depend on a snapshot.

Reproducible **Ubuntu 24.04 ARM64** and **Windows 11 ARM64** VM images for
Apple Silicon Macs, both built with [Packer](https://www.packer.io). Ubuntu
runs under [Tart](https://github.com/cirruslabs/tart) (Apple
Virtualization.framework). Windows runs under QEMU + `swtpm` because AVF
doesn't expose TPM 2.0 or UEFI Secure Boot to non-macOS guests, and ARM
WinPE can't read the AVF virtio buses — see
[`docs/windows-build-attempts.md`](docs/windows-build-attempts.md) §1 for
the full analysis. Each pipeline outputs a versioned base image meant to
be cloned for downstream use; per-VM identity (hostname, admin user, SSH
key) is injected on first boot via a cloud-init NoCloud seed — see
[`docs/cloning-and-cloud-init.md`](docs/cloning-and-cloud-init.md).

Companion to the x86_64
[`homelab`](https://github.com/bbirkinbine/homelab) repo (Proxmox
cluster). The two inform each other but the architectures diverge;
cross-arch builds aren't in scope here.

## Quick start

Apple Silicon Mac, macOS 13 Ventura or newer. Install the toolchain:

```bash
brew install --cask tart
brew install packer just xorriso qemu swtpm
```

Then:

```bash
just build-ubuntu          # ~6 min — Tart image at ~/.tart/vms/ubuntu-24-04-arm64-base
just build-windows         # ~16 min — qcow2 in packer/windows-11-arm64/output-windows-11-arm64/
```

Per-pipeline detail (prerequisites, env vars, post-build run/clone) lives
in the per-OS READMEs:

- [`packer/ubuntu-24-04-arm64/README.md`](packer/ubuntu-24-04-arm64/README.md)
- [`packer/windows-11-arm64/README.md`](packer/windows-11-arm64/README.md)

## Repository layout

- [`packer/`](packer/) — one Packer config per pipeline.
- [`scripts/`](scripts/) — env-driven wrappers called by the Justfile.
- [`docs/`](docs/) — operator runbooks (cloning, Windows build history,
  UTM consumption, Tart IP-discovery quirk).
- [`Justfile`](Justfile) — top-level orchestration (`just build-ubuntu`,
  `just validate`, `just clean`).
- [`CLAUDE.md`](CLAUDE.md) — project context and tool-choice rationale.
  Read before suggesting structural changes.
- [`TODO.md`](TODO.md) — open work and known gaps.

## Acknowledgements

Developed with the assistance of AI tools.
