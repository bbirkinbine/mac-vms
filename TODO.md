# TODO

Open work and known gaps in mac-vms. Keep this short — entries should either
get fixed or move into a doc with proper background.

## Windows — per-VM seed flow (verified 2026-06-06)

Per-VM identity injection for Windows (the cloudbase-init analogue) is
implemented and verified end-to-end: `provision/30-install-firstboot-seed.ps1`
installs a `FirstBootSeed` scheduled task that reads a JSON seed off an
attached CD, `seed/build-cidata.sh` produces that CD on the Mac, and
`provision/99-sysprep.ps1` gates the Administrator lockdown on a seed
login existing. `just run-windows --seed <file>` drives clone + seed +
boot. Verified on a clean build: seeded user created in Administrators,
SSH key injected, build Administrator disabled, both tasks self-destruct,
SSH login works. See [`docs/cloning-windows.md`](docs/cloning-windows.md)
and [`packer/windows-11-arm64/seed/README.md`](packer/windows-11-arm64/seed/README.md).

Known limitation:

- **Standard (non-admin) seed users:** SSH keys are only applied if the
  profile already exists at first boot (it usually won't). Admin users
  use `administrators_authorized_keys` and are unaffected. Revisit if a
  non-admin seed user is ever needed.

## `tart push` / OCI distribution not wired up

Neither Linux pipeline pushes its base image to an OCI registry. To run
the same base on a second Mac you currently re-run `just build-<distro>`
on it. The `tart push` / `tart pull` commands exist; the gap is wrapper
plumbing + a registry choice (ghcr.io? self-hosted?) + auth handling.
Applies to both Ubuntu and Kali.

## Kali — postgresql log truncate warning during cleanup

`provision/99-cleanup.sh`'s log-truncate pass emits a non-fatal
`Permission denied` on `/var/log/postgresql/postgresql-18-main.log` —
`kali-linux-headless` pulls in PostgreSQL (Metasploit/sqlmap backend)
and its log appears to have `chattr +i` or unusual ACLs. The
`find … || true` swallows the failure cleanly; the warning is
cosmetic. Fix would be an `lsattr` + `chattr -i` pass before truncate,
or a targeted stderr suppress for that path.
