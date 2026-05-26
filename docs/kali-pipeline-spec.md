# Spec: Kali rolling ARM64 base pipeline

> **Status:** draft handoff. Not implemented. Picked up in a future
> Claude Code session.
>
> Designed alongside the existing Ubuntu pipeline. The driving question
> was: can the existing Ubuntu pipeline's shape host a Kali sibling so
> downstream consumers can clone a fresh Kali ARM64 VM in Tart with the
> same per-VM identity flow (cidata seed + cleanup one-shot)? Answer:
> yes. This spec is the path from "yes in principle" to a working
> `just build-kali`.

## Goal

Add one new Packer pipeline to mac-vms:

- **`kali-rolling-arm64-base`** — a clean Kali rolling ARM64 base image
  in Tart, structurally identical to `ubuntu-24-04-arm64-base`
  (cloud-init present, SSH server, packer-cleanup one-shot,
  networkd-wait-online timeout, NoCloud-locked datasource,
  DHCP-by-MAC). Cloned per-VM via the same cidata seed mechanism the
  Ubuntu base uses.

## Non-goals

- Cross-arch (x86_64) Kali. Same reasoning as the rest of the repo —
  Apple Silicon only.
- A `tart push` / OCI distribution step in this spec. The Ubuntu
  pipeline has the same gap; treat it as a follow-up once this
  pipeline works.
- Building from Kali's GenericCloud raw disk image (Path B in the
  design session). Path A — installer ISO + d-i preseed — was chosen
  because it mirrors the Ubuntu pipeline's xorriso-repack shape exactly
  and keeps provenance under the repo's control. If Path A turns into
  a swamp during implementation, the GenericCloud path is documented
  as a fallback in the "Decision history" section below.

## Decisions already made

These came out of the design conversation. Don't relitigate without
surfacing the reason.

- **Installer ISO + d-i preseed (Path A)** over GenericCloud raw disk
  import (Path B). Reason: mirrors the existing Ubuntu xorriso-repack
  pattern; build wrapper, validate gates, and provisioner pattern all
  carry over. The cost — porting subiquity's `user-data` to Debian
  Installer's `preseed.cfg` — is finite and contained to one file.
- **`kali-linux-headless` as the default meta-package.**
  `kali-linux-core` is too minimal — no tools, defeats the point of
  Kali. `kali-linux-default` drags in a desktop environment that's
  wasted in a VM you'll SSH into. `kali-linux-everything` is huge and
  slow. Headless is the right middle.

## File tree to add

```
packer/
  kali-rolling-arm64/
    kali.pkr.hcl                      # tart-cli source, mirror of ubuntu.pkr.hcl
    variables.pkr.hcl                 # iso_path, vm_name, cpu/mem/disk, build user
    http/
      preseed.cfg                     # d-i preseed (Kali equivalent of user-data)
    provision/
      00-baseline.sh                  # apt wait + update/upgrade; copy from ubuntu/
      99-cleanup.sh                   # seal + cloud-init lock + packer-cleanup one-shot; copy from ubuntu/
    seed/
      build-cidata.sh                 # copy from ubuntu/; only the example yaml's hostname changes
      lab-seed.example.yaml           # copy from ubuntu/ with hostname default 'kali-lab'
    README.md                         # full quick-start, prereqs, validation, gotchas

scripts/
  build-kali.sh                       # wrapper, mirror of build-ubuntu.sh

Justfile                              # extend: build-kali; extend validate target
.env.local.example                    # extend: KALI_* section
README.md                             # add Kali rolling ARM64 pipeline to the landing page
docs/
  kali-vs-ubuntu.md                   # short doc: preseed-vs-subiquity diff, kali-specific gotchas
  kali-pipeline-spec.md               # THIS FILE; can be removed once implementation lands
```

## Per-file contracts

### `packer/kali-rolling-arm64/variables.pkr.hcl`

Same shape as `ubuntu-24-04-arm64/variables.pkr.hcl`. Defaults:

- `vm_name` → `kali-rolling-arm64-base`
- `cpu_count` → 4
- `memory_gb` → 8
- `disk_size_gb` → 40
- `build_username` → `packer`
- `build_password` → `packer-build-only` (sensitive, build-only;
  removed by the deferred-cleanup one-shot)
- `iso_path` — no default; supplied by the wrapper after download +
  SHA verify + xorriso repack

The Kali meta-package selection (`kali-linux-headless` vs
`kali-linux-core` vs `kali-linux-default` vs `kali-linux-everything`)
is wrapper-level: the wrapper sed-substitutes the value of
`KALI_META_PKG` into a placeholder in `http/preseed.cfg` before the
xorriso repack. The preseed is baked into the ISO; Packer never
templates it, so there's no pkr variable for the meta-package
(declaring one would be misleading).

### `packer/kali-rolling-arm64/kali.pkr.hcl`

Mirror of `ubuntu-24-04-arm64/ubuntu.pkr.hcl`. Same `packer { required_plugins
{ tart = ... } }` block. Same `source "tart-cli" "kali"` block with:

- `from_iso = [var.iso_path]`
- `ssh_username = var.build_username`
- `ssh_password = var.build_password`
- `ssh_timeout = "60m"` — longer than Ubuntu's 45m. Kali's full task
  install (`kali-linux-headless`) downloads more than Ubuntu Server's
  default package set; bump the timeout so a slow mirror doesn't fail
  the build.
- `boot_wait = "5s"`
- `boot_command = []` — the repacked ISO's grub.cfg autoboots into
  preseed mode; no keystrokes needed.

`build { provisioner "shell" { ... scripts = ["provision/00-baseline.sh",
"provision/99-cleanup.sh"] } }` — same pattern, same `execute_command`.

### `packer/kali-rolling-arm64/http/preseed.cfg`

This is the non-trivial file. The Ubuntu pipeline's `http/user-data`
is subiquity (cloud-init shape). Kali uses Debian Installer, which
uses debconf-style preseed. They are not interchangeable. The
translation:

| Concern | Ubuntu user-data | Kali preseed.cfg |
| --- | --- | --- |
| Locale | `locale: en_US.UTF-8` | `d-i debian-installer/locale string en_US.UTF-8` |
| Keyboard | `keyboard.layout: us` | `d-i keyboard-configuration/xkb-keymap select us` |
| Hostname | inside `identity:` | `d-i netcfg/get_hostname string kali-rolling-arm64-base` |
| Domain | (none) | `d-i netcfg/get_domain string unassigned-domain` |
| Apt mirror | `apt.primary[...].uri` | `d-i mirror/http/hostname` + `d-i mirror/http/directory` |
| User | `identity.username` + `password` | `d-i passwd/username` + `passwd-crypted` |
| Sudo NOPASSWD | `late-commands:` echo to sudoers.d | `d-i preseed/late_command string` — same idea, different syntax |
| SSH server | `ssh.install-server: true` | `d-i pkgsel/include string openssh-server cloud-init qemu-guest-agent ca-certificates curl sudo` |
| Disk layout | `storage.layout.name: direct` | `d-i partman-auto/method string regular` + `partman-auto/choose_recipe select atomic` |
| Disable root | `user-data.disable_root: true` | `d-i passwd/root-login boolean false` |
| Tasks | (none — subiquity is server-only) | `tasksel tasksel/first multiselect standard` + `d-i pkgsel/include string kali-linux-headless ...` |
| Late command | `late-commands` | `d-i preseed/late_command string in-target sh -c '...'` |

Critical contents to include:

1. **`d-i preseed/late_command`** must do two things, in this order:
   - `echo 'packer ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/99-packer-build`
   - `chmod 0440 /target/etc/sudoers.d/99-packer-build`

   (nothing else — the cleanup provisioner handles the rest)

2. **`d-i pkgsel/include`** must contain `cloud-init` explicitly.
   Kali's installer does not include cloud-init by default. The
   `99-cleanup.sh` provisioner writes
   `/etc/cloud/cloud.cfg.d/99-mac-vms-datasource.cfg` and
   `99-mac-vms-dhcp.cfg`, which require the `cloud-init` package to
   mean anything on a clone's first boot. The cleanup provisioner
   should `set -e` on `command -v cloud-init` as a sanity check.

3. **`d-i preseed/late_command`** must NOT try to delete the `packer`
   user or remove any sudo rule. The deferred-cleanup one-shot
   (installed by `99-cleanup.sh`) handles that on the first boot of
   any clone, same as Ubuntu.

4. **`d-i pkgsel/upgrade select none`** — repo memory says never use
   `full-upgrade` in unattended installs (it can remove packages).
   `00-baseline.sh` does an `apt-get upgrade` (safe-upgrade
   equivalent) after install, with the dpkg-lock wait loop. Let it
   own the upgrade.

5. **`d-i debian-installer/exit/reboot boolean true`** + **`d-i finish-install/reboot_in_progress note`** — both required so the
   installer reboots without prompting at the end.

6. **`d-i passwd/user-password-crypted password $6$...`** — SHA-512
   crypt hash matching `var.build_password`. Reuse the same hash
   `http/user-data` uses for `packer-build-only` (the values are
   identical). Regenerate with `openssl passwd -6 'packer-build-only'`
   on macOS; `python3 -c "import crypt; ..."` is broken on macOS (DES
   fallback).

7. **`d-i mirror/http/hostname string http.kali.org`** + **`d-i mirror/http/directory string /kali`** — Kali's primary HTTP mirror.

8. **`__KALI_META_PKG__`** — a literal placeholder token in the
   `pkgsel/include` line. `scripts/build-kali.sh` sed-substitutes the
   value of `KALI_META_PKG` (default `kali-linux-headless`) before
   xorriso bakes the file into the ISO.

There are good reference preseed.cfg files in the Kali docs. Do not
copy them verbatim — they're x86_64 and predate the cloud-init +
packer-cleanup story. Lift the structure, write the file fresh
against this spec.

### `packer/kali-rolling-arm64/provision/00-baseline.sh`

Copy from `ubuntu-24-04-arm64/provision/00-baseline.sh`. No changes.
The script's `cloud-init status --wait`, `fuser`-based dpkg lock wait,
and `apt-get update && upgrade` all work identically on Kali. The
one-line summary at the top should be updated to say "Kali" instead
of "Ubuntu", and the lifted-from comment should reference this repo's
ubuntu copy rather than the homelab repo.

### `packer/kali-rolling-arm64/provision/99-cleanup.sh`

Copy from `ubuntu-24-04-arm64/provision/99-cleanup.sh`. Edits:

1. The `install -m 0644 /dev/stdin /etc/cloud/cloud.cfg.d/99-mac-vms-datasource.cfg`
   heredoc keeps `datasource_list: [ NoCloud, None ]` — same as
   Ubuntu. Kali's installer doesn't install cloud-init by default,
   but the preseed includes it via `pkgsel/include`. If `command -v
   cloud-init` fails here, abort the script with a loud error pointing
   at the preseed — same root cause as the Ubuntu lesson, just
   reachable via a different path.

2. The `systemd-networkd-wait-online` drop-in is the same. Kali ships
   the same unit with the same defaults; Debian-derived plumbing.

3. The DHCP-by-MAC cloud.cfg.d snippet is the same. Kali's
   systemd-networkd has the same RFC 4361 DUID default that confuses
   `tart ip` discovery.

Everything else — log truncation, machine-id wipe, SSH host key wipe,
shell history wipe, cloud-init clean, netplan installer config wipe,
DHCP lease wipe, fstrim, deferred packer-cleanup systemd one-shot —
copies as-is.

### `packer/kali-rolling-arm64/seed/build-cidata.sh` and `lab-seed.example.yaml`

Copy from `ubuntu-24-04-arm64/seed/`. The only edit: change the
example yaml's `hostname:` default from `'lab'` to `'kali-lab'` and
update the tail comment block that mentions `ubuntu-24-04-arm64-base`
to say `kali-rolling-arm64-base`. The xorriso recipe, key-validation
logic, and NoCloud datasource handshake are distro-agnostic.

### `packer/kali-rolling-arm64/README.md`

Match the depth of the Ubuntu README. Required sections:

- **Header** — what this builds, what it produces.
- **Prerequisites** — Apple Silicon, Tart, Packer + plugin, xorriso,
  disk requirement (~20 GB).
- **Build** — `just build-kali` and direct script invocation.
- **Run** — `tart run kali-rolling-arm64-base`, build-time credentials
  warning (same as Ubuntu: one-shot, expires on first boot).
- **Cloning + cidata** — same shape as Ubuntu's section.
- **Distributing between machines** — same `tart push/pull` block as
  Ubuntu's.
- **Validation gates** — `packer init/fmt -check/validate`, `bash -n`
  on provisioners.
- **Gotchas / open questions** — copy the Ubuntu list with these
  Kali-specific entries added:
  - The ISO source is `cdimage.kali.org/current/` — the `current/`
    symlink is what gets bumped on each point release (2026.1 →
    2026.2 → ...). Pin via `KALI_ISO_URL` if you need
    reproducibility against a specific release.
  - `pkgsel/include` must contain `cloud-init` explicitly; Kali's
    installer does not include it by default (unlike Ubuntu Server).
  - The default `KALI_META_PKG` is `kali-linux-headless`, not
    `kali-linux-default`. The headless variant has the full tool
    suite without the desktop session manager / compositor — right
    for a base meant to be cloned and SSH'd into.
  - The wrapper sed-substitutes `__KALI_META_PKG__` in `preseed.cfg`
    before xorriso. If you edit `preseed.cfg` directly, keep the
    placeholder intact or the wrapper fails loud.

### `scripts/build-kali.sh`

Mirror of `scripts/build-ubuntu.sh`. Differences:

- Default `KALI_ISO_URL=https://cdimage.kali.org/current/kali-linux-current-installer-arm64.iso`.
- Default `KALI_ISO_SHA256SUMS_URL=https://cdimage.kali.org/current/SHA256SUMS`.
- Forward `KALI_*` env vars to `PKR_VAR_*`:
  - `KALI_VM_NAME` → `PKR_VAR_vm_name`
  - `KALI_CPU_COUNT` → `PKR_VAR_cpu_count`
  - `KALI_MEMORY_GB` → `PKR_VAR_memory_gb`
  - `KALI_DISK_SIZE_GB` → `PKR_VAR_disk_size_gb`
- `KALI_META_PKG` is **not** forwarded as a PKR_VAR — it's used inside
  the wrapper to sed-substitute the `__KALI_META_PKG__` placeholder
  in the staged copy of `http/preseed.cfg` before xorriso bakes it
  into the ISO.
- xorriso repack: the grub.cfg points at the preseed via
  `auto=true priority=critical preseed/file=/cdrom/preseed/preseed.cfg`.
  The repack writes the preseed at `/preseed/preseed.cfg` on the ISO
  (not under `/nocloud/` — that path is for cloud-init's NoCloud).

The grub.cfg the wrapper writes:

```
set timeout=2
set default=0

menuentry "Kali rolling autoinstall (mac-vms)" {
    set gfxpayload=keep
    linux  /install.a64/vmlinuz auto=true priority=critical preseed/file=/cdrom/preseed/preseed.cfg --- quiet
    initrd /install.a64/initrd.gz
}
```

The exact kernel path inside the ISO (`install.a64/vmlinuz` and
`install.a64/initrd.gz`) is the d-i convention for ARM64. Verify with
`xorriso -indev <iso> -find /install.a64` after the wrapper downloads
the ISO; if Kali ever renames the path, this is where the build will
break.

### `Justfile`

Add this target, slot in order:

```just
# Build the Kali rolling ARM64 base image.
build-kali:
    @./scripts/build-kali.sh
```

Extend the `validate` target to cover the new directory:

```just
validate:
    cd packer/ubuntu-24-04-arm64 && packer init . && packer fmt -check . && PKR_VAR_iso_path=/tmp/fake.iso packer validate .
    cd packer/kali-rolling-arm64 && packer init . && packer fmt -check . && PKR_VAR_iso_path=/tmp/fake.iso packer validate .
    cd packer/windows-11-arm64   && packer init . && packer fmt -check . && PKR_VAR_iso_path=/tmp/fake.iso PKR_VAR_virtio_win_iso_path=/tmp/fake-virtio.iso PKR_VAR_qemu_binary=/usr/bin/true packer validate .
```

### `.env.local.example`

Add a Kali section after the Ubuntu section:

```
# ---- Kali rolling ARM64 -----------------------------------------------------

# Kali installer ARM64 ISO. The build wrapper downloads to
# packer/kali-rolling-arm64/packer_cache/iso/ and verifies SHA256 against
# the upstream SHA256SUMS before handing the local path to Packer.
# Default: the 'current' symlink on cdimage.kali.org, which is bumped on
# each point release. Pin to a specific release for reproducibility.
# KALI_ISO_URL=https://cdimage.kali.org/current/kali-linux-current-installer-arm64.iso
# KALI_ISO_SHA256SUMS_URL=https://cdimage.kali.org/current/SHA256SUMS

# Build VM resources.
# KALI_CPU_COUNT=4
# KALI_MEMORY_GB=8
# KALI_DISK_SIZE_GB=40

# Output image name in ~/.tart/vms/.
# KALI_VM_NAME=kali-rolling-arm64-base

# Kali meta-package installed by preseed. Options:
#   kali-linux-core, kali-linux-headless (default), kali-linux-default,
#   kali-linux-everything. See packer/kali-rolling-arm64/README.md.
# KALI_META_PKG=kali-linux-headless
```

### `README.md` (repo root)

Insert a Kali bullet alongside the existing Ubuntu + Windows intro.
Keep it terse — full detail lives in the per-pipeline READMEs. Add
the Kali entry to the per-pipeline READMEs list and the `just
build-kali` line to the quick-start.

### `docs/kali-vs-ubuntu.md`

Short doc — half the length of `docs/cloning-ubuntu.md`.
Required sections:

- **Why two pipelines.** Both produce ARM64 Linux base images for
  Tart; the install paths differ because Ubuntu uses subiquity and
  Kali uses Debian Installer.
- **The translation table** — lift the markdown table from this
  spec's "preseed.cfg" section.
- **What stays the same.** Provisioner scripts, seed/cidata mechanism,
  cleanup one-shot, networkd-wait-online drop-in, DHCP-by-MAC.
- **What's different.** preseed.cfg vs user-data; explicit `cloud-init`
  in `pkgsel/include`; longer SSH timeout; `KALI_META_PKG` wrapper
  variable.
- **Pointer to upstream Kali preseed examples** —
  `kali.org/docs/general-use/kali-preseeding/`.

## Validation gates

Same as the repo-level standard. Don't claim done without all three:

1. **Packer validate.** From the repo root, `just validate` exits 0
   with the new directory in the loop.
2. **Shell syntax.** `bash -n scripts/*.sh` and `bash -n packer/*/provision/*.sh`
   over the new scripts exits 0.
3. **A clean `just build-kali`** end-to-end produces
   `kali-rolling-arm64-base` in `~/.tart/vms/`, and `tart run` boots
   it to a usable SSH state with the cidata seed flow.

Step 3 requires a real build on the M2 Max — it is the only proof
that the preseed actually parses and the wrapper paths actually
resolve.

## Decision history

Captured here so the next session doesn't redo the analysis:

- **Kali installer ISO vs GenericCloud image.** GenericCloud is
  ~half the work because cloud-init is preinstalled and there's no
  installer to automate. Rejected because (a) the existing Ubuntu
  pipeline's xorriso-repack pattern is already known to work
  end-to-end and (b) installer-based builds give us provenance over
  what's in the image. Revisit if preseed turns into a multi-day
  swamp.
- **`kali-linux-headless` as the default meta-package.**
  `kali-linux-core` is too minimal — no tools, defeats the point of
  Kali. `kali-linux-default` drags in a desktop environment that's
  wasted in a VM you'll SSH into. `kali-linux-everything` is huge and
  slow. Headless is the right middle.
- **Wrapper-level meta-pkg substitution, not a Packer variable.**
  The preseed is xorriso-baked into the ISO before Packer sees it,
  so Packer can't template it. Declaring a `kali_meta_pkg` pkr var
  that doesn't actually drive the install would be misleading. Keep
  the value as a `KALI_META_PKG` env var the wrapper sed-substitutes
  into the placeholder.

## Out of scope (do not add without asking)

- Pre-installing any specific tooling on top of the base. Anything
  beyond "a clean Kali rolling ARM64 with cloud-init + SSH + the
  default meta-pkg's tool suite" belongs in a downstream repo, not
  here. The base image is a foundation; consumers clone and
  specialize.
