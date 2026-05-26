# Kali vs Ubuntu: what's the same and what's different

Both pipelines produce an ARM64 Linux base image runnable under Tart on
Apple Silicon, with cloud-init present, a NoCloud-locked datasource, and
a deferred packer-cleanup one-shot that removes the build user on first
boot of any clone. The Justfile target, the cidata seed mechanism, and
the validation gates are the same shape across both.

The pipelines differ where the *install path* diverges: Ubuntu uses
subiquity (cloud-init shape) and Kali uses Debian Installer (debconf
preseed). Translating subiquity's `user-data` to a Debian `preseed.cfg`
is the only non-trivial port.

## What stays the same

- **Builder**: `tart-cli` source under Apple Virtualization.framework.
  Same `cpu_count` / `memory_gb` / `disk_size_gb` defaults (4 / 8 / 40).
- **ISO repack**: `xorriso` replaces `/boot/grub/grub.cfg` with a minimal
  autoboot entry and bakes the seed onto the ISO. No `boot_command`
  keystrokes, no Packer HTTP server.
- **Provisioner scripts**: `00-baseline.sh` and `99-cleanup.sh` are
  copied across with no behavioural change. The dpkg-lock wait, the
  cloud-init datasource lock (`[NoCloud, None]`), the DHCP-by-MAC
  cloud.cfg.d snippet, the systemd-networkd-wait-online 30s timeout
  drop-in, and the `packer-cleanup.service` one-shot ordering
  (`DefaultDependencies=no` + `WantedBy=sysinit.target` +
  `Before=cloud-init-local.service`) are identical.
- **Per-VM identity**: `seed/build-cidata.sh` builds a NoCloud cidata.iso
  attached via `tart run --disk=…:ro <vm>`. The script is distro-agnostic
  beyond the example yaml's default hostname (`lab` → `kali-lab`).
- **Build-time credentials**: same `packer` / `packer-build-only` build
  user, same SHA-512 crypt hash. The cleanup one-shot deletes the user
  on first boot of any clone.
- **Validation gates**: `packer init / fmt -check / validate` plus
  `bash -n` on provisioners. `just validate` runs both pipelines.

## What's different

- **Install spec format**: subiquity's `http/user-data` (cloud-init YAML)
  vs Debian Installer's `http/preseed.cfg` (debconf key/value). Not
  interchangeable.
- **Kernel/initrd path on the ISO**: Ubuntu's live ISO ships kernel under
  `/casper/`; Kali's installer ISO uses `/install.a64/` (d-i ARM64
  convention). The wrapper grub.cfg differs accordingly.
- **Seed path on the ISO**: Ubuntu bakes the NoCloud seed at `/nocloud/`
  (kernel cmdline `ds=nocloud;s=/cdrom/nocloud/`); Kali bakes the
  preseed at `/preseed/preseed.cfg` (kernel cmdline
  `preseed/file=/cdrom/preseed/preseed.cfg`).
- **cloud-init opt-in**: Kali's installer does not include cloud-init by
  default. The preseed's `d-i pkgsel/include` must list it explicitly.
  `99-cleanup.sh` fails loud if `cloud-init` isn't found.
- **SSH timeout**: 60 minutes for Kali (vs Ubuntu's 45). The default
  `kali-linux-headless` meta-package pulls more bytes than Ubuntu
  Server's stock task; a slow mirror should not fail the build.
- **Meta-package selection**: Kali has a `KALI_META_PKG` env var
  (default `kali-linux-headless`) that the wrapper sed-substitutes into
  the staged preseed before xorriso. This isn't a Packer variable —
  Packer never sees the preseed once it's baked into the ISO.
- **Apt mirror**: `http.kali.org/kali` instead of
  `ports.ubuntu.com/ubuntu-ports`.
- **ISO source**: `cdimage.kali.org/current/` (a symlink bumped on each
  point release) vs `cdimage.ubuntu.com/releases/24.04/release/` (a
  fixed point release).

## The translation table

How each subiquity directive maps to its Debian preseed equivalent:

| Concern         | Ubuntu `user-data`                              | Kali `preseed.cfg`                                                                  |
| ---             | ---                                             | ---                                                                                 |
| Locale          | `locale: en_US.UTF-8`                           | `d-i debian-installer/locale string en_US.UTF-8`                                    |
| Keyboard        | `keyboard.layout: us`                           | `d-i keyboard-configuration/xkb-keymap select us`                                   |
| Hostname        | inside `identity:`                              | `d-i netcfg/get_hostname string kali-rolling-arm64-base`                            |
| Domain          | (none)                                          | `d-i netcfg/get_domain string unassigned-domain`                                    |
| Apt mirror      | `apt.primary[...].uri`                          | `d-i mirror/http/hostname` + `d-i mirror/http/directory`                            |
| User            | `identity.username` + `password`                | `d-i passwd/username` + `passwd/user-password-crypted`                              |
| Sudo NOPASSWD   | `late-commands:` echo to sudoers.d              | `d-i preseed/late_command string` — same idea, different syntax                     |
| SSH server      | `ssh.install-server: true`                      | `d-i pkgsel/include string openssh-server cloud-init …`                             |
| Disk layout     | `storage.layout.name: direct`                   | `d-i partman-auto/method string regular` + `partman-auto/choose_recipe select atomic` |
| Disable root    | `user-data.disable_root: true`                  | `d-i passwd/root-login boolean false`                                               |
| Tasks           | (none — subiquity is server-only)               | `tasksel tasksel/first multiselect standard` + meta-package in `pkgsel/include`     |
| Late command    | `late-commands:`                                | `d-i preseed/late_command string in-target sh -c '…'`                               |

## Where to look upstream

- [Kali preseeding guide](https://www.kali.org/docs/general-use/kali-preseeding/)
  — official reference for the Kali side.
- [`d-i` preseed appendix](https://www.debian.org/releases/stable/amd64/apb.en.html)
  — Debian Installer's full debconf key reference. Architecture-agnostic
  even though it lives under `amd64/` in the URL.
- [Ubuntu autoinstall reference](https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html)
  — for the other side of the translation table.
