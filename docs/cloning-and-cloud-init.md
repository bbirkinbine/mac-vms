# Cloning a base image and injecting per-VM identity

This is the runbook for what happens **after** Packer finishes building a
base image — how to clone it into a usable VM and how the clone gets a
per-VM hostname, admin user, and SSH key on first boot.

The sibling [`homelab`](https://github.com/bbirkinbine/homelab) repo
covers the same ground for Proxmox with `bpg/proxmox` and
`cloudbase-init`. The mental model carries over;
the mechanism is different because neither Tart nor QEMU attaches a
cloud-init drive for you. This doc handles the mac-vms-specific plumbing.

## Mental model — three layers (Ubuntu path)

For Ubuntu, the three-layer model is fully wired:

| Layer | What | Where | Re-runnable? |
| --- | --- | --- | --- |
| 1. **Packer** | Baseline OS + hardening baked into a versioned Tart image | [`packer/ubuntu-24-04-arm64/`](../packer/ubuntu-24-04-arm64/) | Rarely — only OS/base changes |
| 2. **Tart clone** | A copy-on-write VM with its own disk and identity | `tart clone <base> <newvm>` | Every new VM |
| 3. **cloud-init seed** | Per-VM hostname, user, SSH key, network — injected on first boot | NoCloud seed ISO attached at `tart run` time | Once per VM instance |

The seam to internalise: Tart does **not** read your cloud-init data and
hand it to the guest. You build a small seed ISO; cloud-init inside the
guest discovers it on first boot.

For Windows the analogous layers exist but layer 3 is the open question
— see the "Windows" section below.

## Ubuntu — the working path

The Ubuntu base image (built by `just build-ubuntu`) ships with
`cloud-init` installed and configured to honour the `NoCloud` datasource.
Anything you put on a seed ISO with filesystem label `cidata` and the
expected file names will be applied on first boot.

[`packer/ubuntu-24-04-arm64/seed/build-cidata.sh`](../packer/ubuntu-24-04-arm64/seed/build-cidata.sh)
wraps the recipe below — that's the fast path for a quick test VM. Use it
unless you have a reason to do the steps manually.

### Quick start (test VM in three commands)

```bash
cd packer/ubuntu-24-04-arm64

# 1. Copy the example seed, fill in your SSH key (and optionally a password hash).
cp seed/lab-seed.example.yaml seed/lab-seed.yaml
${EDITOR:-vim} seed/lab-seed.yaml

# 2. Build the cidata.iso (volume label "cidata", contains user-data + meta-data).
./seed/build-cidata.sh

# 3. Clone the base and boot with the seed attached.
tart clone ubuntu-24-04-arm64-base test-vm
tart run --disk=$(pwd)/output-seed/cidata.iso:ro test-vm
```

Then in another terminal:

```bash
ssh lab@$(tart ip test-vm)
```

(The `lab` user is what the example yaml creates — change `users[0].name`
in `seed/lab-seed.yaml` to use a different login.)

After the first successful boot you can drop the `--disk` flag — the seed
is only consulted while `instance-id` stays the same. The script derives
`instance-id` from a hash of the user-data, so edits force re-application
on the next boot and identical seeds are no-ops.

### What's in the seed

The example at [`seed/lab-seed.example.yaml`](../packer/ubuntu-24-04-arm64/seed/lab-seed.example.yaml)
shows the minimum useful shape. The semantically important fields:

```yaml
#cloud-config
# Quote hostname and user `name` so values that look like YAML
# reserved words ('null', 'true', a pure digit, etc.) still parse
# as strings — see the field-semantics block in the example yaml.
hostname: 'my-dev-vm'
manage_etc_hosts: true

users:
  - name: 'brian'
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-ed25519 AAAA... brian@laptop
    # Optional. SHA-512 crypt hash, NOT plaintext. Generate with:
    #   openssl passwd -6 'YOURPASS'        (macOS + Linux)
    # Do NOT use python3 -c "import crypt" on macOS — Darwin's libc
    # crypt(3) is DES-only, so METHOD_SHA512 silently returns garbage.
    # passwd: '$6$<salt>$<hash>'
```

The build-time `packer` user is already removed on the clone's first boot
by a systemd one-shot installed at image-build time
(see [`packer/ubuntu-24-04-arm64/provision/99-cleanup.sh`](../packer/ubuntu-24-04-arm64/provision/99-cleanup.sh)).
You don't need to clean it up from your cloud-init.

### Manual recipe (skip the script)

If you want to build the cidata ISO by hand, e.g. to integrate with a
different workflow:

```bash
mkdir cloud-init-dir
cat > cloud-init-dir/user-data <<'EOF'
#cloud-config
# ... (same shape as above)
EOF
cat > cloud-init-dir/meta-data <<'EOF'
instance-id: my-dev-vm-001
local-hostname: 'my-dev-vm'
EOF

xorriso -as mkisofs \
  -V cidata \
  -joliet -rock \
  -o /tmp/seed.iso \
  ./cloud-init-dir

tart clone ubuntu-24-04-arm64-base my-dev-vm
tart run --disk=/tmp/seed.iso:ro my-dev-vm
```

Verify the ISO has the right shape before booting:

```bash
file /tmp/seed.iso     # expect: "ISO 9660 CD-ROM filesystem data 'cidata'"
```

The volume label **must be `cidata`** (case-insensitive — `CIDATA` works
too) — that's how cloud-init's NoCloud datasource auto-detects the seed.

Earlier iterations of `seed/build-cidata.sh` used `hdiutil makehybrid`
instead of `xorriso`. Don't do that. macOS's hybrid format prepends an
Apple_partition_scheme + HFS+ wrapper to the ISO9660 data, which Linux's
blkid in the guest can't see past — cloud-init then fails to find the
seed and falls through to `DataSourceNone`. xorriso produces a flat
ISO9660 that blkid reads cleanly.

If cloud-init didn't apply (no IP, hostname unchanged), see "Debugging" at
the bottom.

## Windows — base image works, per-VM identity injection is the open question

The Tart-based path isn't viable (three layered blockers — see
[`windows-build-attempts.md`](windows-build-attempts.md) §1). The
Packer+QEMU+swtpm pipeline under
[`../packer/windows-11-arm64/`](../packer/windows-11-arm64/) builds a
sysprep'd qcow2 in ~16 min on M2 Max — see
[`../packer/windows-11-arm64/README.md`](../packer/windows-11-arm64/README.md).
Consumption is via UTM or `qemu-system-aarch64` directly
([`windows-utm.md`](windows-utm.md)). The three-layer model maps to:

| Layer | Ubuntu | Windows |
| --- | --- | --- |
| 1. Packer | Tart image (`~/.tart/vms/<name>`) | qcow2 (`packer/windows-11-arm64/output-windows-11-arm64/<name>`) |
| 2. Clone | `tart clone` | UTM clone, or `qemu-img create -b <base>.qcow2 -F qcow2 new.qcow2` |
| 3. Seed | NoCloud ISO + cloud-init | **No automated mechanism yet** — see below |

The seam where the Ubuntu story has cloud-init + NoCloud seed, the
Windows story doesn't have an equivalent yet: cloudbase-init has no
official ARM64 installer at [cloudbase.it/downloads/](https://cloudbase.it/downloads/)
as of 2026-05, so the qcow2 boots into OOBE-mini and you create the
local user **interactively** on first boot. The `PackerBuildCleanup`
scheduled task does fire at first boot (rotating + disabling the build
Administrator account) so clones are not reachable via the build-time
credentials, but there's no automatic per-VM hostname / SSH-key /
user-account injection yet.

### Quick start (test VM with interactive account creation)

UTM path — easiest:

```bash
just build-windows   # if you haven't already
open -a UTM
# File → New → Virtualize → Other → Skip ISO Boot
# Edit VM → System: ARM64 / QEMU virt / 8 GiB / 4 cores; TPM + Secure Boot on
# Drives → Import → point at output-windows-11-arm64/windows-11-arm64-base
# Play.
```

Or terminal path — see [`windows-utm.md`](windows-utm.md#running-the-qcow2-directly-via-qemu)
for the full `qemu-system-aarch64` invocation.

Either way, first boot lands at OOBE-mini. Walk through:

1. Region / keyboard layout → Next, Next.
2. Network — pick "I don't have internet" if it shows up (the bypass is
   already in the unattend but 24H2 sometimes re-prompts). If that
   option is missing, press `Shift+F10` → `OOBE\BYPASSNRO` → VM reboots
   and you'll get the local-account form.
3. Enter a test account name + password — that's your login. The build
   Administrator is already disabled by `PackerBuildCleanup`; only this
   new account works.
4. Decline the data / Recall / Copilot opt-ins.

Once the desktop loads, you've got a usable test VM. Snapshot from UTM
(**VM toolbar → More → Save Snapshot**) so you can roll back to a clean
state without rerunning OOBE.

Why no automated equivalent of the Ubuntu cidata script yet: a CIDATA
ISO would be valid, but the qcow2 has no NoCloud consumer installed
(see `provision/30-install-cloudbase-init.ps1` — still a stub). Adding
a seed-builder script for Windows is scaffolding for when one of the
two consumers below exists.

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

- **Wrong volume label on the seed ISO.** Must be `cidata` (case-insensitive
  — the script writes lowercase, but `CIDATA` works too). Verify with
  `file packer/ubuntu-24-04-arm64/output-seed/cidata.iso` — expect
  `ISO 9660 CD-ROM filesystem data 'cidata'`. If you see "DOS/MBR boot
  sector" or Apple_partition_scheme references, the ISO is in the wrong
  format and Linux blkid won't find the label.
- **`instance-id` reused from a previous run.** cloud-init treats the
  same `instance-id` as "already applied" and no-ops. The
  `seed/build-cidata.sh` script derives instance-id from a sha256 of the
  seed yaml, so edits force re-application automatically; if you're
  using the manual recipe, bump `instance-id` in `meta-data` when
  changing user-data on a VM that already booted.
- **Seed ISO not attached read-only.** Always use `--disk=...:ro` — Tart
  treats writable attachments differently in some versions; the read-only
  hint is also a useful breadcrumb that this isn't a state volume.
- **Cloud-init datasource lookup picked the wrong source.** The Ubuntu
  base ships with `/etc/cloud/cloud.cfg.d/99-mac-vms-datasource.cfg`
  pinning `datasource_list: [NoCloud, None]` — installed by
  `provision/99-cleanup.sh`. If you add a clone path that uses a
  different datasource (e.g. ConfigDrive on Proxmox), extend the list
  there.
- **`tart ip <vm>` returns "no IP address found" even after boot.**
  Separate problem — Ubuntu 24.04's systemd-networkd reports a
  DUID-based DHCP client identifier that Tart's lease-lookup doesn't
  understand. The VM actually has an IP; you just have to find it from
  the macOS lease database. See [`tart-ip-discovery.md`](tart-ip-discovery.md).

## Where context lives

- Project context: [`../CLAUDE.md`](../CLAUDE.md)
- Per-OS Packer notes:
  [`packer/ubuntu-24-04-arm64/README.md`](../packer/ubuntu-24-04-arm64/README.md),
  [`packer/windows-11-arm64/README.md`](../packer/windows-11-arm64/README.md)
