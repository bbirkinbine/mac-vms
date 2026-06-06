# Kali rolling ARM64 base image

> **Status (2026-05-26): verified end-to-end on M2 Max.**
> `just build-kali` produces the sealed image in ~7m30s wall-clock,
> and `just spawn kali` smoke-tested the clone + cidata + SSH-in
> flow successfully. The closing diagnostic session resolved three
> walls (ISO filename discovery + EFI confusion, pkgsel suite
> pinning, post-install systemd-networkd/sshd-enable) — captured in
> [`../../docs/kali-build-attempts.md`](../../docs/kali-build-attempts.md).
> Read that doc before changing anything in this directory; the
> obvious-looking moves have already been ruled out.

Packer config that produces `kali-rolling-arm64-base` in `~/.tart/vms/`. Boots
the Kali rolling ARM64 installer ISO under Tart, runs Debian Installer in
preseed mode against the `http/preseed.cfg` config, then runs a minimal
shell-provisioner baseline + seal pass.

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
just build-kali
```

Or directly:

```bash
./scripts/build-kali.sh
```

The wrapper sources `.env.local` (if present) for overrides, validates Tart
and Packer are on PATH, downloads the Kali installer ISO + verifies SHA256
against the upstream `SHA256SUMS`, sed-substitutes the configured Kali
meta-package into a staged copy of `http/preseed.cfg`, repacks the ISO via
`xorriso` (replacement grub.cfg + preseed at `/preseed/preseed.cfg`), then
runs `packer init / fmt -check / validate / build` inside this directory.

## Run

The base image is meant to be **cloned**, not logged into directly. The
fast path is `just spawn` — it generates a per-VM cidata.iso (hostname =
VM name, user `kali`, SSH keys auto-injected from `~/.ssh/id_*.pub`),
`tart clone`s the base, and boots headless in the background:

```bash
just spawn kali             # kali-N for the next free N
just spawn kali -c 3        # batch of three
just list                   # what's running (+ how to ssh in)
ssh kali@$(tart ip kali-1)
just cleanup-vms kali       # tear down all kali-* clones (or: just delete <name>)
```

Full cloning runbook (mental model, manual recipe, Kali-specific notes —
sshd-enable, systemd-networkd, the Kali meta-pkg, debugging when
cloud-init silently doesn't apply):
[`docs/cloning-kali.md`](../../docs/cloning-kali.md).

### Smoke-testing the base directly

To just confirm the build produced a bootable image, boot the base once
with `tart run kali-rolling-arm64-base`. Build-time credentials are
username `packer`, password `packer-build-only` —

> **These work exactly once, on the base, and only via `tart run`.** A
> `packer-cleanup.service` one-shot fires at the start of every boot
> (ordered `Before=cloud-init-local.service`), deletes the `packer` user,
> and self-destructs. So booting the base once uses up that credential,
> and on any **clone** the cleanup fires before network/sshd come up, so
> `packer` is never reachable. Don't depend on these beyond a one-off
> "did it boot?" check — real per-VM access comes from the cidata seed
> (the `just spawn` path above).

## Distributing between machines

Push to an OCI registry from the build host, pull on the other Mac:

```bash
# On the build host:
tart push kali-rolling-arm64-base ghcr.io/you/kali-rolling-arm64-base:latest

# On the other host:
tart pull ghcr.io/you/kali-rolling-arm64-base:latest
```

## Validation gates

Before claiming a change is ready, from this directory:

```bash
packer init .
packer fmt -check .
PKR_VAR_iso_path=/tmp/fake.iso packer validate .
bash -n provision/*.sh
```

## Gotchas / open questions

- **ISO is repacked, not handed in raw.** `scripts/build-kali.sh` downloads
  the upstream ARM64 installer ISO, verifies SHA256 against the upstream
  `SHA256SUMS`, then uses `xorriso` to replace `/boot/grub/grub.cfg` with a
  minimal entry that autoboots into preseed mode and bakes a templated copy
  of `./http/preseed.cfg` as `/preseed/preseed.cfg` on the ISO. The repacked
  ISO lands at `packer_cache/iso/<name>-autoinstall.iso` and is what Packer
  consumes. No `boot_command` keystrokes, no Packer HTTP server. If you bump
  the upstream ISO version, delete both cached files in `packer_cache/iso/`
  so the wrapper redownloads and repacks.
- **The `http/` directory is misnamed but kept.** It used to be served over
  HTTP by Packer; now it's the source for the on-ISO preseed. Same idea as
  the Ubuntu pipeline; rename if you mind.
- **The Kali meta-package is wrapper-templated, not a Packer variable.**
  `KALI_META_PKG` (default `kali-linux-headless`) is consumed by the wrapper
  to sed-substitute the `__KALI_META_PKG__` placeholder in a staged copy of
  `http/preseed.cfg` before xorriso. If you edit `preseed.cfg` directly,
  keep the placeholder intact — the wrapper fails loud if it can't find it.
  Meta-package options:
  - `kali-linux-core` — minimal, no tools beyond the shell.
  - `kali-linux-headless` (default) — full tool suite, no GUI. Right for a
    base meant to be cloned and SSH'd into.
  - `kali-linux-default` — desktop + tools. Large; only useful if you want
    a GUI in the base.
  - `kali-linux-everything` — full mirror. Huge; don't pick unless you
    have a reason.
- **ISO source is `cdimage.kali.org/current/`.** The `current/` directory
  is symlinked to each point release (2026.1 → 2026.2 → ...), but the
  filename inside is version-stamped (`kali-linux-2026.1-installer-arm64.iso`)
  — there's no version-less alias. By default the wrapper parses
  `SHA256SUMS` at build time and picks the first non-netinst
  `installer-arm64` entry, so the default tracks point releases
  automatically. Pin `KALI_ISO_URL` to a specific filename if you need
  reproducibility against a fixed release.
- **`pkgsel/include` must contain `cloud-init` explicitly.** Kali's
  installer does not include cloud-init by default (unlike Ubuntu Server).
  Without it, every clone falls through to `DataSourceNone` and no
  cidata seed applies. `provision/99-cleanup.sh` fails the build loud if
  `cloud-init` is missing.
- **The preseed kernel path is `/install.a64/`.** d-i's ARM64 convention.
  If Kali ever renames it, the wrapper's grub.cfg breaks at boot. Verify
  with `xorriso -indev <iso> -find /install.a64` after the wrapper
  downloads the ISO. This is the single most likely place a future Kali
  ISO bump breaks the build.
- The password hash in `http/preseed.cfg` must match `var.build_password` in
  `variables.pkr.hcl`. Both default to `packer-build-only`. Regenerate the
  hash if you change the plaintext:

  ```bash
  openssl passwd -6 'NEWPASS'
  ```

  Note: `python3 -c "import crypt; crypt.crypt(...)"` is broken on macOS —
  Darwin's libc only implements DES crypt, so `METHOD_SHA512` silently
  falls back and produces a ~13-char garbage string. Use `openssl` instead.

- **SSH timeout is 60m** (longer than Ubuntu's 45m). `kali-linux-headless`
  pulls down more than Ubuntu Server's stock task; a slow mirror should
  not fail the build. Bump higher if you set `KALI_META_PKG=kali-linux-everything`.
- **Clones get a 30s cap on `systemd-networkd-wait-online`.** Same drop-in
  as the Ubuntu pipeline; Debian-derived plumbing.
- **Cloud-init datasource is locked to `[NoCloud, None]`** via
  `/etc/cloud/cloud.cfg.d/99-mac-vms-datasource.cfg` (installed by
  `99-cleanup.sh`). Same as the Ubuntu pipeline.
- **DHCP client identifier is forced to MAC** via
  `/etc/cloud/cloud.cfg.d/99-mac-vms-dhcp.cfg` (also installed by
  `99-cleanup.sh`). Same as the Ubuntu pipeline — see
  [`docs/tart-ip-discovery.md`](../../docs/tart-ip-discovery.md) for why.
- **`packer-cleanup.service` ordering**: same `DefaultDependencies=no` +
  `WantedBy=sysinit.target` + `Before=cloud-init-local.service` shape as
  the Ubuntu pipeline. Don't "clean up" those directives — without them
  systemd silently deletes `cloud-init-local.service` to break an ordering
  cycle, and every clone falls through to `DataSourceNone`.

## Where context lives

- Project-level: [`../../CLAUDE.md`](../../CLAUDE.md)
- Diff vs the Ubuntu pipeline: [`../../docs/kali-vs-ubuntu.md`](../../docs/kali-vs-ubuntu.md)
- Sibling Ubuntu pipeline: [`../ubuntu-24-04-arm64/`](../ubuntu-24-04-arm64/)
