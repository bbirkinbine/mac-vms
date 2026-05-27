# TODO

Open work and known gaps in mac-vms. Keep this short — entries should either
get fixed or move into a doc with proper background.

## Windows — cloud-init-equivalent path not implemented or tested

The Windows pipeline produces a sysprep'd qcow2 (see
[`docs/windows-build-attempts.md`](docs/windows-build-attempts.md)) and an
interactive UTM consumption path. What's missing:

- No equivalent of `seed/build-cidata.sh` for Windows. Per-VM identity
  injection (hostname, admin user, RDP credentials) is not implemented.
- The intended mechanism — `cloudbase-init` (Windows analogue of cloud-init)
  reading a NoCloud-shaped seed disk — is referenced in
  [`docs/cloning-windows.md`](docs/cloning-windows.md) but the
  provisioner stub at
  [`packer/windows-11-arm64/provision/30-cloudbase-init.ps1`](packer/windows-11-arm64/provision/30-cloudbase-init.ps1)
  isn't fleshed out.
- No end-to-end clone-and-seed test loop has been run for Windows.

Likely current state: Windows builds, but a clone is identical to the base
image with no per-VM identity step. Acceptable for snapshots and throwaway
VMs, not yet at parity with the Linux flow.

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
