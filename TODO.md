# TODO

Open work and known gaps in mac-vms. Keep this short — entries should either
get fixed or move into a doc with proper background.

## Windows — seed flow built, needs an end-to-end verification run

Per-VM identity injection is now implemented for Windows (the
cloudbase-init analogue): `provision/30-install-firstboot-seed.ps1`
installs a `FirstBootSeed` scheduled task that reads a JSON seed off an
attached CD, and `seed/build-cidata.sh` produces that CD on the Mac.
`provision/99-sysprep.ps1` gates the Administrator lockdown on a seed
login existing. See [`docs/cloning-windows.md`](docs/cloning-windows.md)
and [`packer/windows-11-arm64/seed/README.md`](packer/windows-11-arm64/seed/README.md).

What's left:

- **No end-to-end verification yet.** `just clean && just build-windows`,
  then clone + attach a `cidata.iso` + boot + confirm the seeded user
  logs in (console/RDP/SSH) and the build Administrator is disabled. The
  scripts are written and `packer validate` passes, but the first real
  run will likely need debugging — the `FirstBootSeed` ↔
  `PackerBuildCleanup` AtStartup handshake and the CD enumeration timing
  are the most likely soft spots.
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
