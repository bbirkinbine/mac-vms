# Kali rolling ARM64 build — attempt log

> **Purpose.** This doc is for whoever (or whichever LLM session) picks up
> the Kali pipeline next. It captures what we tried, what failed and
> why, the dead-ends ruled out, and the rationale behind the current
> shape. Read this before changing
> [`../packer/kali-rolling-arm64/`](../packer/kali-rolling-arm64/) —
> most of the obvious-looking moves have already been explored.
>
> **Status (2026-05-26): green for the Packer build, pending for the
> clone flow.** `just build-kali` produces a sealed
> `kali-rolling-arm64-base` Tart image in ~7m30s wall-clock on M2 Max.
> The cidata-driven clone + SSH-in flow described in
> [`cloning-kali.md`](cloning-kali.md) has **not been walked through
> end-to-end yet** — same shape as the Ubuntu pipeline so it should
> work, but treat that as the next verification step.
>
> The closing diagnostic session resolved three distinct walls in
> sequence, each gated on fixing the previous one. In order:
>
> 1. **Made-up ISO filename + wrong partman-efi answer.** First build
>    failed at `curl 404`: the wrapper's default URL pointed at
>    `kali-linux-current-installer-arm64.iso`, an alias that doesn't
>    exist on cdimage.kali.org. Kali version-stamps the filename
>    (`kali-linux-2026.1-installer-arm64.iso`) inside a `current/`
>    symlinked **directory**. Same patch also dropped a wrong
>    `partman-efi/non_efi_system boolean true` line that would have
>    forced a BIOS-style install on the EFI-booted AVF VM.
> 2. **pkgsel failed with "cloud-init not available."** The preseed
>    set `mirror/http/hostname` and `/directory` but not `mirror/suite`,
>    so d-i fell back to its built-in default suite (a Debian name not
>    present on http.kali.org/kali). Apt built a sources.list pointing
>    at a 404'ing Release file and every package in `pkgsel/include`
>    came up as "not available, but referred to by another package."
>    Fix: pin `mirror/suite kali-rolling`, plus empty
>    `apt-setup/services-select` and `apt-setup/security_host` so apt
>    doesn't try to add a 404'ing `security.debian.org` line on top.
> 3. **Post-install: NIC down, sshd disabled, no DHCP client.** Install
>    completed, system rebooted to login prompt, packer SSH timeout
>    eventually fired. Three independent problems compounded: (a) d-i
>    wrote `/etc/network/interfaces` for `enp0s1` but the installed
>    kernel renames it `eth0`; (b) Kali rolling dropped
>    `isc-dhcp-client` from the standard task, so even a matching
>    ifupdown stanza would have had no DHCP backend; (c) Kali ships
>    `ssh.service` with `preset: disabled` (pentest distro default).
>    Fix: switch the base off ifupdown entirely — drop a
>    systemd-networkd `[Match] Name=en* eth*` config in
>    `preseed/late_command`, enable systemd-networkd + ssh, disable
>    `networking`.
>
> One non-fatal warning on the cleanup pass that's worth knowing about:
> `truncate: cannot open /var/log/postgresql/postgresql-18-main.log:
> Permission denied`. `kali-linux-headless` pulls in PostgreSQL
> (Metasploit / sqlmap backend); its log appears to have either the
> immutable flag or an unusual ACL. The `find … || true` in
> `provision/99-cleanup.sh` handled it cleanly; just cosmetic.

---

## Original plan (pre-implementation)

These decisions were made in the design session before any code
landed. Most of them survived contact with the build; a few were
overtaken by what the build actually needed.

### Decisions kept

- **Installer ISO + d-i preseed (Path A)** over GenericCloud raw disk
  import (Path B). Mirrors the existing Ubuntu xorriso-repack pattern;
  build wrapper, validate gates, and provisioner pattern all carry
  over. Verified: they do, with the caveats below about cloud-init
  opt-in and systemd-networkd opt-in. Cost of porting subiquity
  `user-data` to Debian preseed `preseed.cfg` was finite — one file.
  The translation table from the spec survived intact and now lives
  in [`kali-vs-ubuntu.md`](kali-vs-ubuntu.md).
- **`kali-linux-headless` as the default meta-package.** Right middle
  between `kali-linux-core` (no tools) and `kali-linux-default`
  (desktop). `kali-linux-everything` is huge.
- **Wrapper-level meta-pkg substitution, not a Packer variable.** The
  preseed is xorriso-baked into the ISO before Packer sees it, so
  Packer can't template it. `KALI_META_PKG` env var → wrapper
  sed-substitutes the `__KALI_META_PKG__` placeholder in a staged
  copy of `http/preseed.cfg`.

### Decisions overtaken by build reality

- **"Lifted with no behavioural change from the Ubuntu equivalents."**
  Spec assumed `00-baseline.sh` and `99-cleanup.sh` would copy across
  cleanly. They mostly did — the only Kali-specific edit needed at
  cleanup-time was the `command -v cloud-init` sanity check (since
  Kali's installer doesn't include cloud-init by default). But the
  spec didn't anticipate that the **preseed** itself needed
  significantly more work than the Ubuntu user-data, because Kali
  diverges from Ubuntu Server in three load-bearing defaults — see
  the three walls above.
- **"Mirror hostname + directory is enough."** Spec listed
  `d-i mirror/http/hostname` and `/directory` but not `/suite`. d-i's
  default suite fallback is Debian-flavored and breaks on Kali (Wall
  2).
- **ISO URL syntax.** Spec defaulted to
  `https://cdimage.kali.org/current/kali-linux-current-installer-arm64.iso`,
  inferring a `kali-linux-current-*` alias by symmetry with the
  `current/` directory. That filename doesn't exist. The wrapper now
  discovers the real filename from SHA256SUMS at run time so the
  default follows each point release without code changes (Wall 1).

---

## Wall 1 — made-up ISO filename + EFI confusion (2026-05-26)

**Symptom.** First `just build-kali` exited at the curl step:

```text
==> downloading kali-linux-current-installer-arm64.iso
    from https://cdimage.kali.org/current/kali-linux-current-installer-arm64.iso
curl: (22) The requested URL returned error: 404
```

**Diagnosis.** `cdimage.kali.org/current/` is a symlinked **directory**
(currently pointing at `kali-2026.1/`), not a filename alias. The
files inside are version-stamped. Listing the directory:

```sh
curl -fsSL https://cdimage.kali.org/current/ | grep -oE 'href="[^"]+\.iso"'
# href="kali-linux-2026.1-installer-arm64.iso"
# href="kali-linux-2026.1-installer-netinst-arm64.iso"
# href="kali-linux-2026.1-live-arm64.iso"
```

**Fix.** [`scripts/build-kali.sh`](../scripts/build-kali.sh) now parses
the upstream `SHA256SUMS` and picks the first entry matching
`^kali-linux-[0-9][^ ]*-installer-arm64\.iso$` — excluding netinst and
live variants — so the default URL bumps automatically across point
releases:

```bash
ISO_FILENAME="$(curl -fsL "${KALI_ISO_SHA256SUMS_URL}" \
  | awk '{ sub(/^\*/, "", $2); if ($2 ~ /^kali-linux-[0-9][^ ]*-installer-arm64\.iso$/) { print $2; exit } }')"
```

**Same patch:** removed a guessed-at `d-i partman-efi/non_efi_system
boolean true` line from the preseed. That value means "treat as
non-EFI system" — which on Apple Virtualization.framework (always
boots ARM64 in EFI mode) forces a BIOS-style install and produces an
unbootable disk. d-i's default behaviour is the right one; no
preseed answer needed.

---

## Wall 2 — pkgsel failure on "cloud-init not available" (2026-05-26)

**Symptom.** Second build got through install media boot, network
config, partitioning, base-system install — then failed at "Select
and install software" (the pkgsel step). From `/var/log/syslog` on
the installer (Alt+F2 inside d-i → "Execute a shell"):

```text
in-target: Package cloud-init is not available, but is referred to by another package.
pkgsel: installing additional packages
WARNING **: Configuring 'pkgsel' failed with error code 100
```

**Diagnosis.** `cloud-init` is in `kali-rolling`
([pkg.kali.org/pkg/cloud-init](https://pkg.kali.org/pkg/cloud-init)
confirmed). The message "X is not available, but referred to by
another package" from apt means apt's index *mentions* the package
(via a Recommends or Depends from some other entry) but cannot
*resolve* a candidate version — which on a fresh d-i install almost
always means the configured suite has no `Packages` index containing
the package.

The preseed had:

```text
d-i mirror/http/hostname string http.kali.org
d-i mirror/http/directory string /kali
d-i mirror/http/proxy string
```

…and no `mirror/suite`. d-i defaults that field to its built-in suite
name (`stable`, `testing`, or similar — Debian-flavored), which
doesn't exist on `http.kali.org/kali/dists/`. Kali ships
`kali-rolling`, `kali-dev`, `kali-bleeding-edge`,
`kali-last-snapshot`, etc. — none of which are the d-i default. Apt
fetched a 404'ing Release file, came up with an empty cache, and
pkgsel exited 100.

**Fix.** Pin the suite explicitly:

```text
d-i mirror/suite string kali-rolling
d-i mirror/codename string kali-rolling
d-i mirror/udeb/suite string kali-rolling
d-i mirror/udeb/components multiselect main, contrib, non-free, non-free-firmware
```

**Belt and suspenders:** also suppress the Debian-default security
mirror. Kali rolling has no separate security/updates suite, and
`apt-setup` will otherwise add a `security.debian.org` line that
404s on every later `apt update`:

```text
d-i apt-setup/services-select multiselect
d-i apt-setup/security_host string
d-i apt-setup/use_mirror boolean true
```

---

## Wall 3 — post-install: NIC down, sshd off, no DHCP client (2026-05-26)

**Symptom.** Third build got all the way through install + reboot.
The post-install login prompt appeared on the Tart VNC console
(`Kali GNU/Linux Rolling kali-rolling-arm64-base tty1`), but
`packer build` was still polling for SSH and showed no progress. From
the host:

```console
$ tart ip kali-rolling-arm64-base
192.168.64.23
$ nc -zv 192.168.64.23 22
nc: connectx to 192.168.64.23 port 22 (tcp) failed: Host is down
$ arp -n 192.168.64.23
? (192.168.64.23) at (incomplete) on bridge102 ifscope [bridge]
```

`tart ip` returned an IP from a stale DHCP lease (acquired during
d-i install). The host couldn't ARP to it — the VM was no longer
answering. Logging in on the VNC console as `packer` and diagnosing
inside the guest:

```console
$ ip -br link
lo               UNKNOWN        00:00:00:00:00:00
eth0             DOWN           8a:11:6c:d1:0c:32

$ cat /etc/network/interfaces
auto lo
iface lo inet loopback

allow-hotplug enp0s1
iface enp0s1 inet dhcp

$ systemctl is-active networking NetworkManager systemd-networkd
active
inactive
inactive

$ sudo dhclient -v eth0
sudo: dhclient: command not found

$ sudo systemctl status ssh.service
* ssh.service - OpenBSD Secure Shell server
   Loaded: loaded (/usr/lib/systemd/system/ssh.service; disabled; preset: disabled)
   Active: inactive (dead)
```

**Three independent failures stacked:**

1. **Interface name mismatch.** d-i wrote
   `/etc/network/interfaces` for `enp0s1` (the name its installer
   kernel saw the virtio-net device as), but the installed kernel
   names the same device `eth0`. ifupdown is active, sees no matching
   stanza for `eth0`, does nothing. NIC stays DOWN.
2. **No DHCP client.** Kali rolling dropped `isc-dhcp-client` from
   the standard tasksel task. `dhclient` isn't installed. Even if
   the `/etc/network/interfaces` stanza matched, ifupdown would have
   nothing to call.
3. **Sshd disabled by default.** Kali ships `ssh.service` with
   `preset: disabled` — Kali is a pentest distro, no listening daemon
   out of the box. `pkgsel/include openssh-server` installs the
   package but doesn't enable the service. The Ubuntu pipeline
   doesn't hit this because Ubuntu Server's `openssh-server.postinst`
   auto-enables on install.

**Fix.** Move the base off ifupdown entirely and onto
systemd-networkd, which is what the cidata-seed flow and
`99-cleanup.sh`'s cloud-init DHCP-by-MAC snippet already assume.
[`preseed.cfg`](../packer/kali-rolling-arm64/http/preseed.cfg)'s
`late_command` now drops a wildcard-match `.network` config, enables
systemd-networkd + ssh, and disables `networking`:

```text
d-i preseed/late_command string \
    mkdir -p /target/etc/systemd/network ; \
    printf '%s\n' \
      '[Match]' 'Name=en* eth*' '' \
      '[Network]' 'DHCP=yes' '' \
      '[DHCPv4]' 'ClientIdentifier=mac' \
      > /target/etc/systemd/network/10-en-eth.network ; \
    in-target systemctl enable systemd-networkd ssh ; \
    in-target systemctl disable networking || true ; \
    echo 'packer ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/99-packer-build ; \
    chmod 0440 /target/etc/sudoers.d/99-packer-build
```

`Name=en* eth*` covers `enp0s1` (en\*), `eth0` (eth\*), `ens3`,
`eno1`, and `enx<mac>` — every common Linux interface naming variant.
`ClientIdentifier=mac` is the same DHCP-identifier fix the Ubuntu
99-cleanup.sh applies via cloud-init.

---

## Current design (post-2026-05-26)

The build flow as it stands:

1. [`scripts/build-kali.sh`](../scripts/build-kali.sh) resolves the
   current Kali installer ISO filename from upstream `SHA256SUMS`,
   downloads + SHA-verifies it, then sed-substitutes
   `__KALI_META_PKG__` into a staged copy of `http/preseed.cfg` and
   xorriso-repacks the ISO with a preseed-autoboot grub.cfg + the
   preseed at `/preseed/preseed.cfg`.
2. Packer's `tart-cli` source boots the repacked ISO; d-i runs
   unattended against the preseed.
3. d-i's `late_command` lays down the systemd-networkd `.network`
   file, enables systemd-networkd + ssh, disables `networking`, and
   installs the `packer` sudoers entry.
4. d-i reboots into the installed system; systemd-networkd brings up
   `eth0` via DHCP-by-MAC; sshd starts.
5. Packer's SSH provisioner connects and runs
   [`00-baseline.sh`](../packer/kali-rolling-arm64/provision/00-baseline.sh)
   (apt-get update + upgrade) and
   [`99-cleanup.sh`](../packer/kali-rolling-arm64/provision/99-cleanup.sh)
   (image sealing + cloud-init lock + deferred packer-cleanup
   one-shot).
6. tart-cli triggers graceful shutdown; the sealed VM lands at
   `~/.tart/vms/kali-rolling-arm64-base`.

Wall-clock budget on M2 Max + a fast mirror: ~7m30s. The d-i install
itself is ~5 min; the rest is xorriso repack + Packer overhead +
provisioners + fstrim.

---

## What's confirmed (2026-05-26 closing run)

- ISO discovery, SHA256 verify, xorriso repack all clean.
- d-i preseed install runs to completion; no manual intervention.
- Post-install reboot to login prompt is reliable.
- systemd-networkd brings up `eth0` with DHCP-by-MAC on boot.
- sshd starts and listens on :22.
- Packer SSH provisioner connects and runs both provisioners.
- `00-baseline.sh` apt update + upgrade completes.
- `99-cleanup.sh` lays down the cloud-init datasource lock + DHCP-by-MAC
  cloud.cfg.d snippet + systemd-networkd-wait-online timeout + the
  deferred `packer-cleanup.service` one-shot.
- Final fstrim reclaims unused blocks.
- Graceful shutdown; build returns success.

## Open work

- **End-to-end cidata clone flow.** The repo's "Validation gates"
  third bullet (`tart clone` + cidata seed + SSH-in as the
  cidata-seeded user) has not been walked through against the
  freshly-built base yet. Same mechanism as Ubuntu so it should work;
  treat as the next verification.
- **postgresql log truncate noise.** Non-fatal `Permission denied` on
  `/var/log/postgresql/postgresql-18-main.log` during
  `99-cleanup.sh`'s log-truncate pass. `kali-linux-headless` pulls in
  PostgreSQL; the log appears to have `chattr +i` or unusual ACLs.
  `|| true` handles it but the warning is cosmetic noise — a future
  fix would be to `lsattr` + `chattr -i` before truncate, or just
  silence the stderr for this specific path.
- **`tart push` distribution.** Same gap as the Ubuntu pipeline; not
  Kali-specific.

---

## What's preserved in the repo

- [`../packer/kali-rolling-arm64/http/preseed.cfg`](../packer/kali-rolling-arm64/http/preseed.cfg)
  — the working preseed, with comments explaining the three walls
  above next to the relevant directives.
- [`../scripts/build-kali.sh`](../scripts/build-kali.sh)
  — the wrapper, with the SHA256SUMS-driven ISO filename discovery
  and the `__KALI_META_PKG__` substitution + sanity check.
- [`../packer/kali-rolling-arm64/provision/99-cleanup.sh`](../packer/kali-rolling-arm64/provision/99-cleanup.sh)
  — the cleanup script, with the `command -v cloud-init` sanity gate
  that flags Wall-2-class failures loudly if a future preseed edit
  accidentally drops `cloud-init` from `pkgsel/include`.

## How to read this with another Claude session

If you're starting fresh on this pipeline, the load-bearing context
is:

1. **CLAUDE.md** for repo norms.
2. **This doc** for what's already been tried.
3. **[`kali-vs-ubuntu.md`](kali-vs-ubuntu.md)** for the subiquity →
   debconf-preseed translation table.
4. **[`cloning-kali.md`](cloning-kali.md)** for the
   post-build consumption flow (cidata seed → tart clone → SSH).
5. The per-pipeline READMEs for prerequisites and gotchas.

The most common failure mode when iterating: a preseed edit drops or
mistypes one of the four `mirror/*` or `apt-setup/*` lines from Wall
2 and pkgsel fails at install time. Boot into the d-i shell on tty2
(menu → "Execute a shell") and `tail /var/log/syslog | grep -iE
'apt|pkgsel|mirror|404'` — that's where the truth lives. The
installer dialog itself just says "Installation step failed."
