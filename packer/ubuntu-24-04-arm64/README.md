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
- ~20 GB free disk for the build (ISO download + final image).

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
logged into directly. After cloning, supply real cloud-init user-data:

```bash
tart clone ubuntu-24-04-arm64-base my-dev-vm
tart run --dir=cloud-init:./my-cloud-init my-dev-vm
```

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

- The `boot_command` keystrokes in `ubuntu.pkr.hcl` are a starting point.
  ARM64 Ubuntu live boots into GRUB rather than the old BIOS boot prompt, and
  the exact edit sequence depends on the current ISO's grub menu layout.
  Expect to refine this on the first successful build.
- ISO checksum handling: the `tart-cli` builder's behavior around
  `iso_checksum` should be verified against the plugin README — left
  commented out in the HCL for now.
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
