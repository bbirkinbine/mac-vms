# Cloning Kali base images and injecting per-VM identity

This is the runbook for what happens **after** `just build-kali`
finishes — how to clone `kali-rolling-arm64-base` into a usable VM
and how the clone gets a per-VM hostname, admin user, and SSH key on
first boot.

Kali's clone flow is structurally identical to Ubuntu's
([`cloning-ubuntu.md`](cloning-ubuntu.md)) — same cloud-init NoCloud
datasource, same xorriso recipe, same cidata volume label. The
differences are minor and called out below. Windows is structurally
different — see [`cloning-windows.md`](cloning-windows.md).

## Mental model — three layers

| Layer | What | Where | Re-runnable? |
| --- | --- | --- | --- |
| 1. **Packer** | Baseline OS + Kali meta-pkg baked into a versioned Tart image | [`packer/kali-rolling-arm64/`](../packer/kali-rolling-arm64/) | Rarely — only OS/base changes |
| 2. **Tart clone** | A copy-on-write VM with its own disk and identity | `tart clone <base> <newvm>` | Every new VM |
| 3. **cloud-init seed** | Per-VM hostname, user, SSH key, network — injected on first boot | NoCloud seed ISO attached at `tart run` time | Once per VM instance |

Tart does **not** read your cloud-init data and hand it to the guest.
You build a small seed ISO; cloud-init inside the guest discovers it
on first boot via the NoCloud datasource (volume label `cidata`).

## Quick start (test VM in three commands)

```bash
cd packer/kali-rolling-arm64

# 1. Copy the example seed. You can usually skip editing it — build-cidata.sh
#    auto-injects every ~/.ssh/id_*.pub on the host. Edit only if you want a
#    non-default hostname, username, or password hash.
cp seed/lab-seed.example.yaml seed/lab-seed.yaml

# 2. Build the cidata.iso (volume label "cidata", contains user-data + meta-data).
#    By default, auto-injects ~/.ssh/id_*.pub. Pass `-i <key>.pub` (repeatable)
#    to use an explicit set instead.
./seed/build-cidata.sh

# 3. Clone the base and boot with the seed attached.
tart clone kali-rolling-arm64-base test-kali
tart run --disk=$(pwd)/output-seed/cidata.iso:ro test-kali
```

Then in another terminal:

```bash
ssh kali@$(tart ip test-kali)
```

(The `kali` user is what the example yaml creates — change
`users[0].name` in `seed/lab-seed.yaml` to use a different login.)

After the first successful boot you can drop the `--disk` flag — the
seed is only consulted while `instance-id` stays the same. The script
derives `instance-id` from a hash of the user-data, so edits force
re-application on the next boot and identical seeds are no-ops.

## What's in the seed

The example at [`seed/lab-seed.example.yaml`](../packer/kali-rolling-arm64/seed/lab-seed.example.yaml)
shows the minimum useful shape:

```yaml
#cloud-config
# Quote hostname and user `name` so values that look like YAML
# reserved words ('null', 'true', a pure digit, etc.) still parse
# as strings — see the field-semantics block in the example yaml.
hostname: 'my-kali-vm'
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
[`packer/kali-rolling-arm64/provision/99-cleanup.sh`](../packer/kali-rolling-arm64/provision/99-cleanup.sh)).
You don't need to clean it up from your cloud-init.

## Choosing which SSH keys land on the clone

`build-cidata.sh` merges keys from three sources, in priority order:

1. **Anything you list explicitly under `ssh_authorized_keys:` in the
   yaml.** Always included.
2. **`-i <path>.pub` arguments to `build-cidata.sh` (repeatable).**
   Validated like any other key. Passing any `-i` **suppresses
   step 3** — be explicit when you want to be.
3. **Default: every `~/.ssh/id_*.pub` on the host.** Auto-detected
   when no `-i` is passed.

All three paths run the same validation pipeline: reject
`-----BEGIN ... PRIVATE KEY-----` blocks, reject paths not ending in
`.pub`, `ssh-keygen -l` sanity check, dedupe by `<algo> <base64>`.

```bash
./seed/build-cidata.sh                                 # auto-detect ~/.ssh
./seed/build-cidata.sh -i ~/.ssh/work.pub              # explicit, suppresses auto
./seed/build-cidata.sh -i k1.pub -i k2.pub             # multiple explicit
./seed/build-cidata.sh -h                              # usage
```

Per-source breakdown printed before xorriso:

```text
==> SSH key sources beyond seed/lab-seed.yaml: auto-detected from /Users/you/.ssh/
    + id_ed25519.pub SHA256:... (ED25519)
    = id_rsa.pub (already present in seed/lab-seed.yaml — skipped)
==> SSH keys in user-data: 2 (yaml: 1, injected: 1)
```

## Kali-specific notes

These are the only differences from the Ubuntu flow:

- **`kali-linux-headless` tool suite is in the base.** Every clone
  ships with the full Kali tool suite minus the desktop session
  manager. If you built with `KALI_META_PKG=kali-linux-core` the
  clone is bare; `kali-linux-default` adds a GUI; `kali-linux-everything`
  adds everything (huge). See
  [`../packer/kali-rolling-arm64/README.md`](../packer/kali-rolling-arm64/README.md)
  for the meta-package options.
- **sshd is enabled in the base, not in stock Kali.** Stock Kali
  rolling ships `ssh.service` disabled by default (it's a pentest
  distro; no listening daemon out of the box). The Packer preseed's
  `late_command` runs `systemctl enable ssh` so the base — and every
  clone derived from it — has SSH listening on first boot. If you
  want a clone with no SSH, mask the service in the cidata seed via
  `runcmd: [systemctl disable --now ssh]`.
- **systemd-networkd, not ifupdown.** The Packer preseed switches the
  base to systemd-networkd with a `Match Name=en* eth*` config
  (Kali rolling dropped `isc-dhcp-client` from the standard task, so
  ifupdown has no DHCP backend). cidata seeds that override network
  config should write systemd-networkd-shaped YAML, not
  /etc/network/interfaces stanzas.
- **`http.kali.org/kali kali-rolling` is the apt source** baked in.
  If you need a different mirror in the clone, override via cidata
  `write_files`.

## Manual recipe (skip the script)

If you want to build the cidata ISO by hand:

```bash
mkdir cloud-init-dir
cat > cloud-init-dir/user-data <<'EOF'
#cloud-config
# ... (same shape as above)
EOF
cat > cloud-init-dir/meta-data <<'EOF'
instance-id: my-kali-vm-001
local-hostname: 'my-kali-vm'
EOF

xorriso -as mkisofs \
  -V cidata \
  -joliet -rock \
  -o /tmp/seed.iso \
  ./cloud-init-dir

tart clone kali-rolling-arm64-base my-kali-vm
tart run --disk=/tmp/seed.iso:ro my-kali-vm
```

The volume label **must be `cidata`** (case-insensitive). Verify with
`file /tmp/seed.iso` — expect `ISO 9660 CD-ROM filesystem data
'cidata'`.

Don't use `hdiutil makehybrid`. macOS's hybrid format prepends an
Apple_partition_scheme + HFS+ wrapper that Linux's `blkid` can't see
past, so cloud-init falls through to `DataSourceNone`. xorriso
produces a flat ISO9660 that blkid reads cleanly.

## What NOT to do

1. **Don't rely on the build-time `packer` user.** It's deleted on
   first boot of any clone by `packer-cleanup.service`. The build
   creds are gone before networking comes up.
2. **Don't bake a permanent admin password into the base.** Every
   clone inherits it; rotating means rebuilding the base AND every
   existing VM.
3. **Don't put plaintext where a hash belongs.** cloud-init compares
   `passwd:` against a hashed shadow entry. A plaintext string
   becomes the stored hash verbatim and locks the account.

## Debugging the first boot

```bash
# Inside the VM:
sudo cloud-init status --long            # 'error' is the usual failure mode
sudo cloud-init query --all              # what cloud-init thinks the metadata is
ls /run/cloud-init/                      # has it run?
journalctl -u cloud-init -u cloud-init-local --no-pager | tail -100

# Networking:
ip -br link ; ip -br addr                # is the interface up?
systemctl status systemd-networkd        # is networkd managing it?
```

Common causes — same as Ubuntu, with one extra:

- **Wrong volume label on the seed ISO.** Must be `cidata`.
- **`instance-id` reused.** Bump it in `meta-data` if you're using the
  manual recipe and changing user-data on a VM that already booted.
- **Seed ISO not attached read-only.** Always use `--disk=...:ro`.
- **Datasource list wrong.** The base pins `[NoCloud, None]` via
  `99-mac-vms-datasource.cfg`. If you add a clone path that uses a
  different datasource, extend the list there.
- **`tart ip <vm>` returns "no IP address found".** Same fix as Ubuntu
  — see [`tart-ip-discovery.md`](tart-ip-discovery.md). The base
  installs a cloud-init snippet forcing DHCP client identifier to MAC.
- **Networking didn't come up at all.** Check that the systemd-networkd
  config at `/etc/systemd/network/10-en-eth.network` survived cloning
  (it should — it's part of the base image). If it's missing, the base
  was built before the systemd-networkd switch — rebuild with
  `just build-kali`.

## Where context lives

- Project context: [`../CLAUDE.md`](../CLAUDE.md)
- Kali Packer pipeline: [`../packer/kali-rolling-arm64/README.md`](../packer/kali-rolling-arm64/README.md)
- Diff vs the Ubuntu pipeline: [`kali-vs-ubuntu.md`](kali-vs-ubuntu.md)
- Sibling cloning docs: [Ubuntu](cloning-ubuntu.md), [Windows](cloning-windows.md)
