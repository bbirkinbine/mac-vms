# Cloning Ubuntu base images and injecting per-VM identity

This is the runbook for what happens **after** `just build-ubuntu`
finishes — how to clone `ubuntu-24-04-arm64-base` into a usable VM
and how the clone gets a per-VM hostname, admin user, and SSH key on
first boot.

The sibling docs cover the same ground for Kali
([`cloning-kali.md`](cloning-kali.md)) and Windows
([`cloning-windows.md`](cloning-windows.md)). Ubuntu and Kali share
the cloud-init / cidata mechanism; Windows is structurally different.

## Mental model — three layers

| Layer | What | Where | Re-runnable? |
| --- | --- | --- | --- |
| 1. **Packer** | Baseline OS baked into a versioned Tart image | [`packer/ubuntu-24-04-arm64/`](../packer/ubuntu-24-04-arm64/) | Rarely — only OS/base changes |
| 2. **Tart clone** | A copy-on-write VM with its own disk and identity | `tart clone <base> <newvm>` | Every new VM |
| 3. **cloud-init seed** | Per-VM hostname, user, SSH key, network — injected on first boot | NoCloud seed ISO attached at `tart run` time | Once per VM instance |

The seam to internalise: Tart does **not** read your cloud-init data and
hand it to the guest. You build a small seed ISO; cloud-init inside the
guest discovers it on first boot via the NoCloud datasource (volume
label `cidata`).

## Quick start (test VM in three commands)

```bash
cd packer/ubuntu-24-04-arm64

# 1. Copy the example seed. You can usually skip editing it — build-cidata.sh
#    auto-injects every ~/.ssh/id_*.pub on the host. Edit only if you want a
#    non-default hostname, username, or password hash. See the example yaml
#    comments for the field semantics.
cp seed/lab-seed.example.yaml seed/lab-seed.yaml

# 2. Build the cidata.iso (volume label "cidata", contains user-data + meta-data).
#    By default, auto-injects ~/.ssh/id_*.pub. Pass `-i <key>.pub` (repeatable)
#    to use an explicit set instead.
./seed/build-cidata.sh

# 3. Clone the base and boot with the seed attached.
tart clone ubuntu-24-04-arm64-base test-vm
tart run --disk=$(pwd)/output-seed/cidata.iso:ro test-vm
```

Then in another terminal:

```bash
ssh ubuntu@$(tart ip test-vm)
```

(The `ubuntu` user is what the example yaml creates — change
`users[0].name` in `seed/lab-seed.yaml` to use a different login.)

After the first successful boot you can drop the `--disk` flag — the
seed is only consulted while `instance-id` stays the same. The script
derives `instance-id` from a hash of the user-data, so edits force
re-application on the next boot and identical seeds are no-ops.

## What's in the seed

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
    # SSH pubkeys: build-cidata.sh auto-injects ~/.ssh/id_*.pub by
    # default (deduped against anything explicit here). Pass
    # -i <path>.pub to use an explicit set instead. Leave as `[]`
    # to delegate entirely to auto-detect or -i.
    ssh_authorized_keys: []
    # Optional. SHA-512 crypt hash, NOT plaintext. Generate with:
    #   openssl passwd -6 'YOURPASS'        (macOS + Linux)
    # Do NOT use python3 -c "import crypt" on macOS — Darwin's libc
    # crypt(3) is DES-only, so METHOD_SHA512 silently returns garbage.
    # passwd: '$6$<salt>$<hash>'
```

The build-time `packer` user is already removed on the clone's first
boot by a systemd one-shot installed at image-build time (see
[`packer/ubuntu-24-04-arm64/provision/99-cleanup.sh`](../packer/ubuntu-24-04-arm64/provision/99-cleanup.sh)).
You don't need to clean it up from your cloud-init.

## Choosing which SSH keys land on the clone

`build-cidata.sh` merges keys from three sources, in priority order:

1. **Anything you list explicitly under `ssh_authorized_keys:` in the
   yaml.** Always included.
2. **`-i <path>.pub` arguments to `build-cidata.sh` (repeatable).**
   Validated like any other key. Passing any `-i` **suppresses
   step 3** — be explicit when you want to be.
3. **Default: every `~/.ssh/id_*.pub` on the host.** Auto-detected
   when no `-i` is passed. Useful for the common case ("put my
   regular SSH keys on this throwaway VM").

All three paths run the same validation pipeline:

- Reject anything containing a `-----BEGIN ... PRIVATE KEY-----`
  block.
- Reject paths that don't end in `.pub` (belt-and-suspenders against
  passing `~/.ssh/id_ed25519` instead of `~/.ssh/id_ed25519.pub`).
- `ssh-keygen -l` sanity check on every candidate.
- Deduplicate by `<algo> <base64>` token, ignoring the comment field
  — same key with different `user@host` labels still dedupes.

Examples:

```bash
./seed/build-cidata.sh                                 # auto-detect ~/.ssh
./seed/build-cidata.sh -i ~/.ssh/work.pub              # explicit, suppresses auto
./seed/build-cidata.sh -i k1.pub -i k2.pub             # multiple explicit
./seed/build-cidata.sh seed/other.yaml                 # different yaml
./seed/build-cidata.sh -h                              # usage
```

The script prints the resulting per-source breakdown before xorriso:

```text
==> SSH key sources beyond seed/lab-seed.yaml: auto-detected from /Users/you/.ssh/
    + id_ed25519.pub SHA256:... (ED25519)
    = id_rsa.pub (already present in seed/lab-seed.yaml — skipped)
==> SSH keys in user-data: 2 (yaml: 1, injected: 1)
```

## Manual recipe (skip the script)

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

The volume label **must be `cidata`** (case-insensitive — `CIDATA`
works too) — that's how cloud-init's NoCloud datasource auto-detects
the seed.

Earlier iterations of `seed/build-cidata.sh` used `hdiutil makehybrid`
instead of `xorriso`. Don't do that. macOS's hybrid format prepends an
Apple_partition_scheme + HFS+ wrapper to the ISO9660 data, which
Linux's `blkid` in the guest can't see past — cloud-init then fails to
find the seed and falls through to `DataSourceNone`. xorriso produces
a flat ISO9660 that blkid reads cleanly.

## What NOT to do

1. **Don't rely on the build-time `packer` user.** It's deleted on
   first boot of any clone by `packer-cleanup.service`, ordered
   `Before=cloud-init-local.service`. The build creds are gone before
   networking comes up — there's no window where the clone is
   reachable with a known-password account.
2. **Don't bake a permanent admin password into the base.** Every
   clone inherits it, and rotating it means rebuilding the base AND
   every existing VM. cloud-init seeds are the per-clone seam — use
   them.
3. **Don't put plaintext where a hash belongs.** cloud-init compares
   `passwd:` against a hashed shadow entry on Linux. A plaintext
   string in `passwd:` becomes the stored hash verbatim and locks the
   account.

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

- **Wrong volume label on the seed ISO.** Must be `cidata`
  (case-insensitive). Verify with `file
  packer/ubuntu-24-04-arm64/output-seed/cidata.iso` — expect `ISO 9660
  CD-ROM filesystem data 'cidata'`. If you see "DOS/MBR boot sector"
  or Apple_partition_scheme references, the ISO is in the wrong
  format.
- **`instance-id` reused from a previous run.** cloud-init treats the
  same `instance-id` as "already applied" and no-ops. The
  `seed/build-cidata.sh` script derives instance-id from a sha256 of
  the seed yaml, so edits force re-application automatically; if
  you're using the manual recipe, bump `instance-id` in `meta-data`
  when changing user-data on a VM that already booted.
- **Seed ISO not attached read-only.** Always use `--disk=...:ro` —
  Tart treats writable attachments differently in some versions; the
  read-only hint is also a useful breadcrumb that this isn't a state
  volume.
- **Cloud-init datasource lookup picked the wrong source.** The base
  ships with `/etc/cloud/cloud.cfg.d/99-mac-vms-datasource.cfg`
  pinning `datasource_list: [NoCloud, None]` — installed by
  `provision/99-cleanup.sh`. If you add a clone path that uses a
  different datasource (e.g. ConfigDrive on Proxmox), extend the list
  there.
- **`tart ip <vm>` returns "no IP address found" even after boot.**
  Separate problem — Ubuntu 24.04's systemd-networkd reports a
  DUID-based DHCP client identifier that Tart's lease-lookup doesn't
  understand. See [`tart-ip-discovery.md`](tart-ip-discovery.md).

## Where context lives

- Project context: [`../CLAUDE.md`](../CLAUDE.md)
- Ubuntu Packer pipeline: [`../packer/ubuntu-24-04-arm64/README.md`](../packer/ubuntu-24-04-arm64/README.md)
- Sibling cloning docs: [Kali](cloning-kali.md), [Windows](cloning-windows.md)
