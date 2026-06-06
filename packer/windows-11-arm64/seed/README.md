# Per-VM seed for the Windows 11 ARM64 base image

The Windows base qcow2 ships with a first-boot consumer
(`FirstBootSeed`, installed by
[`../provision/30-install-firstboot-seed.ps1`](../provision/30-install-firstboot-seed.ps1))
that reads a seed off an attached CD-ROM and injects a working login.
This is the ARM-native stand-in for cloudbase-init, which has no
official ARM64 build — see
[`../../../docs/cloning-windows.md`](../../../docs/cloning-windows.md)
for the why.

## Sensible defaults

Every field is optional. This mirrors the Linux pipelines, where
`just spawn ubuntu` gives you a working `ssh ubuntu@<ip>` with zero
edits. The Windows equivalents:

- **username** defaults to `admin` — the runtime user. (The build-time
  `Administrator` is disabled on first boot of a seeded clone, the way
  the Linux build user `packer` is removed.)
- **hostname** defaults to `windows`.
- **SSH keys**: `build-cidata.sh` auto-injects every `~/.ssh/id_*.pub`
  on your host (override with `-i <pubkey>`, repeatable), exactly like
  the Linux `build-cidata.sh`.
- **password** — a Windows account needs one for console/RDP, so unlike
  the Linux key-only default a password is **always set**. Omit it from
  the seed and `build-cidata.sh` generates a strong random one and
  **prints it at build time**; set `"password"` to choose your own.

So the fastest path needs no seed file at all:

```bash
just run-windows --seed          # user 'admin', your ~/.ssh keys, random password (printed)
# then: ssh admin@127.0.0.1 -p 2222   (or RDP 127.0.0.1:13389 with the printed password)
```

## Flow

1. (Optional) copy [`lab-seed.example.json`](lab-seed.example.json) to
   `lab-seed.json` (gitignored) and adjust — or skip this and take the
   defaults above.
2. `./build-cidata.sh [seed.json]` — produces `output-cidata/cidata.iso`.
   (`just run-windows --seed [seed.json]` runs this for you and boots.)
3. Boot a clone of the base qcow2 with `cidata.iso` attached as a
   CD-ROM. On first boot, `FirstBootSeed` finds `windows-seed.json` on
   the CD, creates the user, and only then does `PackerBuildCleanup`
   lock down the build-time Administrator.
4. Log in (SSH / RDP / console) as the seeded user.

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
| `hostname` | no | Defaults to `windows`. NetBIOS name, **<=15 chars** (the cap is a runtime validator, not the XSD — see `windows-build-attempts.md`). Applied with `Rename-Computer`; takes effect on the clone's next reboot. |
| `username` | no | Defaults to `admin`. The local account to create (or update if it already exists). |
| `password` | no | Plaintext; handed to `New-LocalUser`, which hashes it. **Omit and `build-cidata.sh` generates a strong random one and prints it.** Do **not** put a `$6$...`/`$2y$...` hash here — it becomes the literal password and locks you out. |
| `groups` | no | Defaults to `["Administrators"]`. |
| `ssh_authorized_keys` | no | Auto-injected from `~/.ssh/id_*.pub` by `build-cidata.sh` (override with `-i`). For an Administrators member, written to `C:\ProgramData\ssh\administrators_authorized_keys` with the ACL OpenSSH requires (Administrators + SYSTEM only); for a standard user, to that user's `.ssh\authorized_keys`. OpenSSH Server is enabled by `provision/20-harden.ps1`. |

## Hygiene

Real seeds carry SSH pubkeys and a password — they are gitignored
(`packer/*/seed/*.json`, with `*.example.json` whitelisted). The
generated `cidata.iso` is ignored by the global `*.iso` rule. Never
commit either.
