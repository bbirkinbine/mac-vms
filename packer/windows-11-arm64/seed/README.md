# Per-VM seed for the Windows 11 ARM64 base image

The Windows base qcow2 ships with a first-boot consumer
(`FirstBootSeed`, installed by
[`../provision/30-install-firstboot-seed.ps1`](../provision/30-install-firstboot-seed.ps1))
that reads a seed off an attached CD-ROM and injects a working login.
This is the ARM-native stand-in for cloudbase-init, which has no
official ARM64 build — see
[`../../../docs/cloning-windows.md`](../../../docs/cloning-windows.md)
for the why.

## Flow

1. Copy [`lab-seed.example.json`](lab-seed.example.json) to
   `lab-seed.json` (gitignored) and fill it in.
2. `./build-cidata.sh` — produces `output-cidata/cidata.iso`.
3. Boot a clone of the base qcow2 with `cidata.iso` attached as a
   CD-ROM (UTM: Drives → New → CD/DVD → import; or `qemu` with a
   second `usb-storage` CD). On first boot, `FirstBootSeed` finds
   `windows-seed.json` on the CD, creates the user, and only then does
   `PackerBuildCleanup` lock down the build-time Administrator.
4. Log in (console / RDP / SSH) as the seeded user.

If no seed CD is attached, `FirstBootSeed` records `NO-SEED` and
`PackerBuildCleanup` deliberately **leaves the build Administrator
active** rather than bricking the clone — see the warning it writes to
`C:\Windows\Setup\Scripts\packer-cleanup.log`. The seeded path is the
supported one.

## Why JSON, not cloud-config YAML

The homelab x86_64 pipeline uses cloudbase-init, whose seed is
`#cloud-config` YAML. We don't have cloudbase-init here, so the
in-guest consumer is hand-rolled PowerShell — and Windows PowerShell
5.1 has no built-in YAML parser. JSON parses natively via
`ConvertFrom-Json`, so the seed is JSON. This is the one deliberate
divergence from the homelab seed shape.

## Fields

| Field | Required | Notes |
| --- | --- | --- |
| `hostname` | no | NetBIOS name, **<=15 chars** (the cap is a runtime validator, not the XSD — see `windows-build-attempts.md`). Applied with `Rename-Computer`; takes effect on the clone's next reboot. Omit to keep the generalized name. |
| `username` | yes | The local account to create (or update if it already exists). |
| `password` | yes | **Plaintext.** Handed to `New-LocalUser`, which hashes it. Do **not** put a `$6$...`/`$2y$...` hash here — it becomes the literal password and locks you out. Same gotcha as the homelab Windows seed. |
| `groups` | no | Defaults to `["Administrators"]`. |
| `ssh_authorized_keys` | no | For an Administrators member, written to `C:\ProgramData\ssh\administrators_authorized_keys` with the ACL OpenSSH requires (Administrators + SYSTEM only); for a standard user, to that user's `.ssh\authorized_keys`. OpenSSH Server is already enabled by `provision/20-harden.ps1`. |

## Hygiene

Real seeds carry SSH pubkeys and a password — they are gitignored
(`packer/*/seed/*.json`, with `*.example.json` whitelisted). The
generated `cidata.iso` is ignored by the global `*.iso` rule. Never
commit either.
