# TODO

Open work and known gaps in mac-vms. Keep this short — entries should either
get fixed or move into a doc with proper background.

## Ubuntu — full cycle not yet re-verified after `ubuntu-homelab-learnings`

The `ubuntu-homelab-learnings` branch ported the systemd ordering fix,
image-hygiene wipes, xorriso cidata builder, and password-hash documentation
from the sibling homelab repo. Canary checks on a single clone pass
end-to-end. What hasn't happened yet:

- The base image has not been rebuilt from scratch since the branch's
  provisioner changes landed. (Initial verification ran on a base built
  shortly before the branch — the new 99-cleanup directives have only
  been exercised on a single clone, not on a freshly-built base.)
- The full `just clean && just build-ubuntu → tart clone → seed → SSH`
  cycle has not been re-run from a clean slate.

Do not consider Ubuntu "fixed" until that clean cycle completes green.

## Windows — cloud-init-equivalent path not implemented or tested

The Windows pipeline produces a sysprep'd qcow2 (see
[`docs/windows-build-attempts.md`](docs/windows-build-attempts.md)) and an
interactive UTM consumption path. What's missing:

- No equivalent of `seed/build-cidata.sh` for Windows. Per-VM identity
  injection (hostname, admin user, RDP credentials) is not implemented.
- The intended mechanism — `cloudbase-init` (Windows analogue of cloud-init)
  reading a NoCloud-shaped seed disk — is referenced in
  [`docs/cloning-and-cloud-init.md`](docs/cloning-and-cloud-init.md) but the
  provisioner stub at
  [`packer/windows-11-arm64/provision/30-cloudbase-init.ps1`](packer/windows-11-arm64/provision/30-cloudbase-init.ps1)
  isn't fleshed out.
- No end-to-end clone-and-seed test loop has been run for Windows.

Likely current state: Windows builds, but a clone is identical to the base
image with no per-VM identity step. Acceptable for snapshots and throwaway
VMs, not yet at parity with the Ubuntu flow.

## Tart `tart ip` discovery on Ubuntu 24.04

See [`docs/tart-ip-discovery.md`](docs/tart-ip-discovery.md). Workaround is
documented; no permanent fix has been applied. Two possible paths described
in that doc (configure systemd-networkd ClientIdentifier=mac, or upstream
Tart fix). Punt unless this becomes a regular annoyance.
