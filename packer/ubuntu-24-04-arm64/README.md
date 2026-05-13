# Ubuntu 24.04 ARM64 base image

Packer config that produces `ubuntu-24-04-arm64-base` in `~/.tart/vms/`. Boots
the Ubuntu Server 24.04 ARM64 live ISO under Tart, runs subiquity in
autoinstall mode against the `http/user-data` config, then runs a minimal
shell-provisioner baseline.

## Prerequisites

- Apple Silicon Mac (M-series). x86_64 Macs will not run this — the builder
  uses Apple's Virtualization.framework.
- Tart installed: `brew install --cask tart`
- Packer + the Tart plugin: `brew install packer && packer plugins install github.com/cirruslabs/tart`
- `xorriso` for the ISO repack step: `brew install xorriso`
- ~20 GB free disk for the build (ISO download + repacked ISO + final image).

## Build

From the repo root:

```bash
just build-ubuntu
```

Or directly:

```bash
./scripts/build-ubuntu.sh
```

The wrapper sources `.env.local` (if present) for overrides, validates Tart
and Packer are on PATH, then runs `packer init / fmt -check / validate / build`
inside this directory.

## Run

```bash
tart run ubuntu-24-04-arm64-base
```

Default credentials (build-only, kept on the image for first login):

- username: `packer`
- password: `packer-build-only`

The base image is intended to be **cloned** for downstream use rather than
logged into directly. After cloning, attach a NoCloud seed ISO with your
per-VM user-data:

```bash
tart clone ubuntu-24-04-arm64-base my-dev-vm
tart run --disk=/tmp/seed.iso:ro my-dev-vm
```

See [`docs/cloning-and-cloud-init.md`](../../docs/cloning-and-cloud-init.md)
for how to build the seed ISO (hostname, admin user, SSH key) and what
cloud-init does on first boot.

## Distributing between machines

Push to an OCI registry from the build host, pull on the other Mac:

```bash
# On the build host:
tart push ubuntu-24-04-arm64-base ghcr.io/you/ubuntu-24-04-arm64-base:latest

# On the other host:
tart pull ghcr.io/you/ubuntu-24-04-arm64-base:latest
```

## Validation gates

Before claiming a change is ready, from this directory:

```bash
packer init .
packer fmt -check .
packer validate .
bash -n provision/*.sh
```

## Gotchas / open questions

- **ISO is repacked, not handed in raw.** `scripts/build-ubuntu.sh` downloads
  the upstream ARM64 live ISO, verifies SHA256 against the upstream
  `SHA256SUMS`, then uses `xorriso` to replace `/boot/grub/grub.cfg` with a
  minimal entry that autoboots into autoinstall mode and bakes the contents
  of `./http/` as a NoCloud seed at `/nocloud/` on the ISO. The repacked ISO
  lands at `packer_cache/iso/<name>-autoinstall.iso` and is what Packer
  consumes. No `boot_command` keystrokes, no Packer HTTP server. If you bump
  the upstream ISO version, delete both cached files in `packer_cache/iso/`
  so the wrapper redownloads and repacks.
- **The `http/` directory is misnamed but kept.** It used to be served over
  HTTP by Packer; now it's the source for the on-ISO NoCloud seed. Same files,
  different delivery. Rename if you mind, but the contents are still
  `user-data` + `meta-data` in cloud-init shape.
- **ISO source: cdimage, not releases.** ARM64 ISOs live at
  `cdimage.ubuntu.com/releases/24.04/release/`, not `releases.ubuntu.com`
  (which is amd64-only). The wrapper script's defaults are correct; just
  flagging it because it bit us once.
- The password hash in `http/user-data` must match `var.build_password` in
  `variables.pkr.hcl`. Both default to `packer-build-only`. Regenerate the
  hash if you change the plaintext:

  ```bash
  python3 -c "import crypt; print(crypt.crypt('NEWPASS', crypt.mksalt(crypt.METHOD_SHA512)))"
  ```

- The `apt.primary.arches` list is `[arm64]` (different from the sibling
  `homelab` Ubuntu config, which is `[amd64]`). Don't sync that field across.

## Where context lives

- Project-level: [`../../CLAUDE.md`](../../CLAUDE.md)
- Sibling x86_64 build (for reference): `homelab/packer/ubuntu-24-04-base/`
