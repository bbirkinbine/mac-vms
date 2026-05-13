# Windows 11 ARM64 base image — paused at WinPE driver wall

> **Status: scaffolding complete, end-to-end build blocked.** The Packer
> config parses, validates, and runs as far as Windows Setup's "no
> installable hard drives found" screen. We've verified that Win11
> 24H2 ARM64 WinPE has no in-box driver matching any of QEMU's emulated
> storage controllers (virtio-blk, NVMe, AHCI all return empty disk list),
> and the homelab x86 Packer build documents that **Win11 24H2 Setup
> ignores `Microsoft-Windows-PnpCustomizationsWinPE` driver injection** —
> meaning even an `arm64` virtio-win.iso wired in via Autounattend.xml
> probably won't help. The remaining viable path is a **custom-rolled
> install ISO** with virtio drivers pre-injected into `boot.wim` /
> `install.wim` via DISM, which is a significant ongoing project and not
> attempted here.
>
> **Active Windows path: UTM** — see
> [`../../docs/windows-utm.md`](../../docs/windows-utm.md). UTM handles
> the driver question by walking the user through it interactively, which
> is fine for the laptop-lab use case CLAUDE.md describes.
>
> Everything below documents the scaffolding's intent so this is
> resumable if either (a) Microsoft fixes the 24H2 unattend injection
> bug, or (b) someone undertakes the custom-ISO project.

Packer config that *would* produce `windows-11-arm64-base.qcow2` in
`./output-windows-11-arm64/`. Built via Packer's `qemu` source under
`qemu-system-aarch64` + `swtpm` on Apple Silicon's HVF accelerator — Tart
can't host Windows 11 (no TPM 2.0, no Secure Boot), so we use QEMU for the
build and UTM (or QEMU itself) for runtime consumption.

The output qcow2 was intended to be the equivalent of the Ubuntu base's
Tart image artifact: a sysprep'd, generalized image suitable for cloning
into per-VM identities downstream.

## Prerequisites

- Apple Silicon Mac (M-series).
- Packer + the qemu plugin: `brew install packer && packer plugins install github.com/hashicorp/qemu`
  (the build wrapper auto-installs the plugin via `packer init`).
- `qemu` for `qemu-system-aarch64`: `brew install qemu`
- `swtpm` for the virtual TPM 2.0: `brew install swtpm`
- **The Windows 11 ARM64 ISO from Microsoft.** Bring your own — Microsoft
  does not permit redistribution. Download steps:
  1. Visit [Download Windows 11 (ARM64)](https://www.microsoft.com/software-download/windows11arm64)
     and follow the prompts to generate a download link. The 24H2 release
     is the current GA. (No Insider login required.)
  2. Download the ISO — typically `Win11_24H2_English_Arm64.iso`, ~5 GB.
     The download page shows a SHA256 next to the file; copy it.
  3. Set `WINDOWS_ISO_PATH` in `.env.local` to its absolute path.
  4. Optionally set `WINDOWS_ISO_SHA256` in `.env.local` to the SHA256 from
     step 2; the build wrapper verifies before invoking Packer.

## Build

From the repo root:

```bash
just build-windows
```

Or directly:

```bash
WINDOWS_ISO_PATH=/path/to/Win11_24H2_English_Arm64.iso \
  ./scripts/build-windows.sh
```

The wrapper:

1. Verifies dependencies (`packer`, `qemu-system-aarch64`, `swtpm`, `xmllint`).
2. Verifies the ISO exists and (optionally) its SHA256.
3. Starts `swtpm` in the background, exposes its socket via
   `PKR_VAR_swtpm_socket_path`. Cleans up on any exit.
4. Runs `packer init`, `fmt -check`, `validate`, `build`.

Build duration: ~30-60 minutes for the install + provisioners + sysprep.
Apple HVF acceleration runs Windows 11 ARM64 at near-native speed; the
duration is mostly Windows Setup itself.

## Output

`./output-windows-11-arm64/windows-11-arm64-base.qcow2` — the sysprep'd
qcow2 disk image. ~12-15 GB typical after sysprep cleanup. Boots into
OOBE-mini on first run; the `PackerBuildCleanup` scheduled task rotates +
disables the build Administrator account before networking comes up.

## Consuming the output

### UTM

UTM imports qcow2 directly: **File → New → Virtualize → Other → Import**
and point at the qcow2. Configure System as ARM64 (aarch64) with TPM and
Secure Boot enabled. See [`../../docs/windows-utm.md`](../../docs/windows-utm.md)
for the full UTM workflow.

### QEMU directly

If you'd rather stay in terminal-land, copy-on-write clones from the
golden image and run with qemu-system-aarch64:

```bash
qemu-img create -f qcow2 \
  -b output-windows-11-arm64/windows-11-arm64-base.qcow2 \
  -F qcow2 mywork.qcow2

# Then qemu-system-aarch64 with TPM + UEFI similar to the build invocation.
```

## Provisioner pipeline

Mirrors the homelab Windows base structure
([`homelab/packer/windows-11-base/provision/`](../../../homelab/packer/windows-11-base/provision/)).

| Script | Source | State |
| --- | --- | --- |
| `00-wait-for-winrm.ps1` | Ported as-is from homelab | Ready |
| `15-windows-cleanup.ps1` | Ported as-is (registry / DISM — arch-agnostic) | Ready |
| `20-harden.ps1` | Homelab equivalent enables RDP + OpenSSH Server | **Stub** — port the homelab file once we can verify on ARM |
| `30-install-cloudbase-init.ps1` | Homelab uses x64 MSI | **Stub** — needs an ARM64 cloudbase-init installer URL |
| `99-sysprep.ps1` | Ported from homelab with `processorArchitecture="arm64"` and cloudbase-init pre-check relaxed | Ready (cleanup task + sysprep) |

## Validation gates

```bash
just validate          # packer fmt -check + packer validate
xmllint --noout Autounattend.xml
bash -n ../../scripts/build-windows.sh
```

## What works, what doesn't, why we paused

End-to-end status of the pipeline we built before pausing:

| Step | State |
| --- | --- |
| `swtpm` provides TPM 2.0 over Unix socket | Works |
| EDK2 UEFI firmware + writable NVRAM per build | Works |
| HVF acceleration on Apple Silicon | Works |
| qemu launches successfully with all our overrides | Works |
| EFI splash + "Press any key to boot from CD" + Setup boot | Works (boot_command spam-enter) |
| Cocoa display via `ramfb` | Works |
| `Autounattend.xml` discovered + applied through the language picker | Works (silent skip past it) |
| **Setup finds the boot disk** | **Fails — no in-box driver** |

We tried three storage interfaces and got "no disks found" on all of them:

- `virtio-blk` (Packer's default `disk_interface=virtio`)
- `NVMe` (via wrapper-script argv rewrite)
- `AHCI/SATA` (also via wrapper rewrite)

The homelab x86 build uses AHCI/SATA successfully because Win11 24H2 *x86*
WinPE ships `storahci.sys` in-box. The ARM64 driver set is different and
none of the QEMU controllers we tried matched. The homelab also documents
that 24H2 ignores the `Microsoft-Windows-PnpCustomizationsWinPE` driver
injection mechanism, so the unattend block we wrote (referencing
`virtio-win.iso` paths) probably wouldn't help even if a binary-compatible
ARM64 driver existed there.

The viable remaining path is the **"custom-rolled install ISO"** mentioned
as out-of-scope in the homelab comments: use DISM to inject virtio
drivers directly into `boot.wim` and `install.wim` on a copy of the
Windows install ISO, then point Packer at that. Significant work and
brittle to upstream Win11 ISO changes; not attempted here.

## Scaffolding kept for future revival

The Autounattend.xml, build wrapper, qemu+TPM wrapper, and provisioner
pipeline are all complete and validated. If the WinPE driver story
changes (Microsoft fixes the unattend bug, or virtio-win publishes
boot-wim-injection tooling, or you take on the custom-ISO project), the
build should run from `just build-windows` without further plumbing.

Inputs the build expects from `.env.local`:

- `WINDOWS_ISO_PATH` (required) — Win11 24H2 ARM64 ISO
- `WINDOWS_ISO_SHA256` (optional) — published hash for integrity check
- `VIRTIO_WIN_ISO_PATH` (optional) — virtio-win.iso, attached as third
  CD-ROM by the qemu wrapper if set. Referenced by the unattend's
  `Microsoft-Windows-PnpCustomizationsWinPE` block — note that 24H2 may
  ignore this block per homelab findings.

## Gotchas / open questions

- **`qemu_binary` points at a wrapper script, not `qemu-system-aarch64`.**
  Packer's qemu plugin treats `qemuargs` as a complete replacement for
  its auto-generated args, not an append — using `qemuargs` to inject
  TPM kills the disk/CD/network/EFI setup. The workaround is
  [`scripts/qemu-with-tpm.sh`](../../scripts/qemu-with-tpm.sh): the
  wrapper forwards all of Packer's args to the real binary and appends
  the three TPM args at the end. Anyone debugging "qemu failed to
  start" should check the wrapper first.
- **swtpm state is wiped per build.** The wrapper deletes the swtpm state
  directory before starting a new run. If you ever need to preserve TPM
  state between builds (sealed-data testing), remove the `rm -rf` line
  in `scripts/build-windows.sh`. Default behavior is the right one for
  reproducible base-image builds.
- **EFI firmware path is hardcoded** to `/opt/homebrew/share/qemu/`. If
  Homebrew installs QEMU elsewhere (unusual), update both
  `efi_firmware_code` and `efi_firmware_vars` in `windows.pkr.hcl`.
- **Windows 11 Pro SKU name in Autounattend.xml.** If 24H2 ARM64 uses a
  different SKU label internally (e.g. "Windows 11 Pro for ARM"), the
  install halts at "the image you have selected is not for this type of
  computer." Check with `7z l <iso> | grep install.wim` or boot the
  installer once interactively to see the SKU list, then update the
  `<MetaData>` value in `Autounattend.xml`.
- **OOBE bypass.** Win11 24H2 introduced new "must sign in with Microsoft
  account" friction. The Autounattend.xml uses `HideOnlineAccountScreens`
  which still works as of 2026-05; if it stops working, the next escape
  hatch is RunSynchronous registry writes for the BYPASSNRO key.
- **cloudbase-init for ARM64.** No official installer at
  [cloudbase.it/downloads/](https://cloudbase.it/downloads/) yet. Until
  one lands, clones won't auto-consume cloud-init seeds for per-VM
  identity — see `provision/30-install-cloudbase-init.ps1` for the
  open question.

## Where context lives

- Project-level: [`../../CLAUDE.md`](../../CLAUDE.md)
- UTM runbook for consuming the output:
  [`../../docs/windows-utm.md`](../../docs/windows-utm.md)
- Sibling x86_64 build (homelab reference):
  `homelab/packer/windows-11-base/`
