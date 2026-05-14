# Cloning a base image and injecting per-VM identity

This is the runbook for what happens **after** Packer finishes building a
base image — how to clone it into a usable VM and how the clone gets a
per-VM hostname, admin user, and SSH key on first boot.

The sibling `homelab` repo's
[`docs/cloning-templates.md`](https://github.com/brianbirkinbine/homelab/blob/main/docs/cloning-templates.md)
covers the same ground for Proxmox + `bpg/proxmox` + `cloudbase-init`. The
mental model carries over; the mechanism is different because Tart doesn't
attach a cloud-init drive for you. Read this doc for the Tart-specific
plumbing and that doc for the deeper rationale.

## Mental model — three layers

| Layer | What | Where | Re-runnable? |
| --- | --- | --- | --- |
| 1. **Packer** | Baseline OS + hardening baked into a versioned Tart image | [`packer/ubuntu-24-04-arm64/`](../packer/ubuntu-24-04-arm64/), [`packer/windows-11-arm64/`](../packer/windows-11-arm64/) | Rarely — only OS/base changes |
| 2. **Tart clone** | A copy-on-write VM with its own disk and identity | `tart clone <base> <newvm>` | Every new VM |
| 3. **cloud-init seed** | Per-VM hostname, user, SSH key, network — injected on first boot | NoCloud seed ISO attached at `tart run` time | Once per VM instance |

The seam to internalise: Tart does **not** read your cloud-init data and
hand it to the guest. You build a small seed ISO; cloud-init inside the
guest discovers it on first boot.

## Ubuntu — the working path

The Ubuntu base image (built by `just build-ubuntu`) ships with
`cloud-init` installed and configured to honour the `NoCloud` datasource.
Anything you put on a seed ISO with filesystem label `CIDATA` and the
expected file names will be applied on first boot.

### 1. Write your user-data

```yaml
#cloud-config
hostname: my-dev-vm
manage_etc_hosts: true

users:
  - name: brian
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... brian@laptop
    # Optional. mkpasswd -m sha-512 (Linux expects a hash, NOT plaintext).
    # passwd: '$6$...'
```

The build-time `packer` user is already removed on the clone's first boot
by a systemd one-shot installed at image-build time
(see [`packer/ubuntu-24-04-arm64/provision/99-cleanup.sh`](../packer/ubuntu-24-04-arm64/provision/99-cleanup.sh)).
You don't need to clean it up from your cloud-init.

Save as `user-data` (no extension) in a working directory, alongside a
`meta-data` file containing at minimum:

```yaml
instance-id: my-dev-vm-001
local-hostname: my-dev-vm
```

### 2. Build the NoCloud seed ISO

macOS ships `hdiutil`, which produces an ISO 9660 image with a settable
volume label:

```bash
hdiutil makehybrid -o /tmp/seed.iso -hfs -joliet -iso \
  -default-volume-name CIDATA \
  -joliet-volume-name CIDATA \
  -hfs-volume-name CIDATA \
  ./cloud-init-dir
```

`cloud-init-dir/` is the working directory containing `user-data` and
`meta-data`. The volume label **must be `CIDATA`** (or `cidata`) — that's
how cloud-init's NoCloud datasource auto-detects the seed.

If you prefer `mkisofs`-style tooling, `brew install cdrtools` and:

```bash
mkisofs -output /tmp/seed.iso -volid CIDATA -joliet -rock ./cloud-init-dir
```

### 3. Clone the base and run with the seed attached

```bash
tart clone ubuntu-24-04-arm64-base my-dev-vm
tart run --disk=/tmp/seed.iso:ro my-dev-vm
```

On first boot, cloud-init mounts the CD-ROM, reads `user-data` +
`meta-data`, and applies them. Subsequent boots are no-ops as long as the
`instance-id` doesn't change. After the first successful boot you can drop
the `--disk` flag — the seed is only needed once per identity.

### 4. SSH in

```bash
tart ip my-dev-vm
ssh brian@$(tart ip my-dev-vm)
```

If cloud-init didn't apply (no IP, hostname unchanged), see "Debugging" at
the bottom.

## Windows — base image works, per-VM identity injection is the open question

The Tart-based path is impossible (no TPM/Secure Boot). The
Packer+QEMU+swtpm pipeline under
[`../packer/windows-11-arm64/`](../packer/windows-11-arm64/) builds a
sysprep'd qcow2 in ~16 min on M2 Max — see
[`../packer/windows-11-arm64/README.md`](../packer/windows-11-arm64/README.md).
Consumption is via UTM or `qemu-system-aarch64` directly
([`windows-utm.md`](windows-utm.md)).

The seam where the Ubuntu story has cloud-init + NoCloud seed, the
Windows story doesn't have an equivalent yet: cloudbase-init has no
official ARM64 installer at [cloudbase.it/downloads/](https://cloudbase.it/downloads/)
as of 2026-05, so the qcow2 boots into OOBE-mini and you create the
local user interactively. The `PackerBuildCleanup` scheduled task does
fire at first boot (rotating + disabling the build Administrator
account) so clones are not reachable via the build-time credentials,
but there's no automatic per-VM hostname / SSH-key / user-account
injection yet.

Two viable paths if you need that automation before cloudbase-init
ships ARM64:

1. **Build cloudbase-init from source** — Python wheel + pythonized
   service wrapper. Non-trivial but tractable; the
   [cloudbase-init repo](https://github.com/cloudbase/cloudbase-init)
   is pure Python.
2. **NoCloud-style PowerShell bootstrap** — a scheduled task at first
   boot reads `user-data` from an attached unattend ISO and applies it.
   Bespoke, but matches the existing `PackerBuildCleanup` mechanism.

Either way, the Windows-side gotchas to keep in mind when you do wire
it up: `passwd:` is plaintext (not a hash) on Windows, hostname change
forces a reboot, NetBIOS computer names are capped at 15 characters
(the unattend XML enforces this inside its own validator, not via XSD —
see [windows-build-attempts.md](windows-build-attempts.md) for the
diagnostic story).

## What NOT to do

Three traps mostly inherited from the homelab doc — same advice, same
reasons.

1. **Don't rely on the build-time `packer` user.** It's deleted on first
   boot of any clone by `packer-cleanup.service`, ordered
   `Before=cloud-init-local.service`. The build creds are gone before
   networking comes up — there's no window where the clone is reachable
   with a known-password account.
2. **Don't bake a permanent admin password into the base.** Every clone
   inherits it, and rotating it means rebuilding the base AND every
   existing VM. cloud-init seeds are the per-clone seam — use them.
3. **Don't put plaintext where a hash belongs (Linux), or a hash where
   plaintext belongs (Windows).** cloud-init compares `passwd:` against
   a hashed shadow entry on Linux; cloudbase-init takes plaintext on
   Windows and hashes it itself.

## Debugging the first boot

When a clone comes up but cloud-init clearly didn't apply (wrong
hostname, no user, no key), in order of likelihood:

```bash
# Did Tart actually attach the seed?
tart ip my-dev-vm                       # is the VM up at all?
# Inside the VM:
sudo cloud-init status --long            # 'error' is the usual failure mode
sudo cloud-init query --all              # what cloud-init thinks the metadata is
ls /run/cloud-init/                      # has it run?
journalctl -u cloud-init -u cloud-init-local --no-pager | tail -100
```

Common causes:

- **Wrong volume label on the seed ISO.** `CIDATA` (uppercase) is the
  canonical label. Verify with `isoinfo -d -i /tmp/seed.iso | grep -i
  'Volume id'`.
- **`instance-id` reused from a previous run.** cloud-init treats the
  same `instance-id` as "already applied" and no-ops. Bump it when
  changing user-data on a VM that already booted.
- **Seed ISO not attached read-only.** Always use `--disk=...:ro` — Tart
  treats writable attachments differently in some versions; the read-only
  hint is also a useful breadcrumb that this isn't a state volume.
- **Cloud-init datasource lookup is wrong.** The Ubuntu base ships with
  the stock datasource list. If you tighten it (e.g. for a clone that
  goes air-gapped after first boot), see the homelab provisioner
  [`30-cloud-init-config.sh`](https://github.com/brianbirkinbine/homelab/blob/main/packer/ubuntu-24-04-base/provision/30-cloud-init-config.sh)
  for the pattern.

## Where context lives

- Project context: [`../CLAUDE.md`](../CLAUDE.md)
- Per-OS Packer notes:
  [`packer/ubuntu-24-04-arm64/README.md`](../packer/ubuntu-24-04-arm64/README.md),
  [`packer/windows-11-arm64/README.md`](../packer/windows-11-arm64/README.md)
- Homelab equivalent (Proxmox, deeper coverage):
  [`homelab/docs/cloning-templates.md`](https://github.com/brianbirkinbine/homelab/blob/main/docs/cloning-templates.md)
