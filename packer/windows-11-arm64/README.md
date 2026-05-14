# Windows 11 ARM64 base image — qemu + swtpm + bundled virtio injection

> **Status (2026-05-13): green, verified end-to-end.** Full build produces
> a sysprep'd qcow2 in ~16 minutes wall-clock on M2 Max + Apple HVF. The
> closing diagnostic session resolved five distinct walls (CD-ROM bus,
> USB enumeration order, Win11 hardware-check, NetBIOS name length,
> sysprep exit code) — captured in
> [`../../docs/windows-build-attempts.md`](../../docs/windows-build-attempts.md).
> Read that doc before changing anything in this directory; most of the
> obvious-looking moves have already been ruled out.
>
> UTM remains an option for interactive use of the qcow2 — see
> [`../../docs/windows-utm.md`](../../docs/windows-utm.md) for the import
> recipe.

Packer config that produces `windows-11-arm64-base` (a qcow2) in
`./output-windows-11-arm64/`. Built via Packer's `qemu` source under
`qemu-system-aarch64` + `swtpm` on Apple Silicon's HVF accelerator — Tart
can't host Windows 11 (no TPM 2.0, no Secure Boot), so we use QEMU for
the build and UTM (or QEMU itself) for runtime consumption.

The output qcow2 is the equivalent of the Ubuntu base's Tart image
artifact: a sysprep'd, generalized image suitable for cloning into
per-VM identities downstream.

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
- **`virtio-win.iso`** with ARM64 drivers (release 0.1.240 or later).
  Download from
  [virtio-win stable](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso)
  and set `VIRTIO_WIN_ISO_PATH` in `.env.local`. The build wrapper
  extracts the ARM64 viostor / vioscsi / NetKVM subset into the unattend
  CD so WinPE can load them at install time; the full ISO is also
  attached as a runtime CD-ROM for FirstLogonCommands to pick up the
  guest-tools installer.

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

1. Verifies dependencies (`packer`, `qemu-system-aarch64`, `swtpm`, `xmllint`, `hdiutil`).
2. Verifies the Windows and virtio-win ISOs exist and (optionally) the Windows SHA256.
3. Mounts `virtio-win.iso`, extracts the ARM64 viostor / vioscsi / NetKVM
   driver trees into `drivers/staging/`, then detaches the ISO mount.
4. Starts `swtpm` in the background, exposes its socket. Cleans up on any exit.
5. Runs `packer init`, `fmt -check`, `validate`, `build`. Packer's `cd_files`
   packs `Autounattend.xml` + `drivers/` into the unattend CD that Setup
   reads at first probe.

Build duration: ~16 minutes wall-clock on M2 Max (verified 2026-05-13).
Apple HVF runs Windows 11 ARM64 at near-native speed; the duration is
mostly Windows Setup itself.

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

## Inputs expected from `.env.local`

- `WINDOWS_ISO_PATH` (**required**) — Win11 24H2 ARM64 ISO. The build
  wrapper hard-fails if missing.
- `VIRTIO_WIN_ISO_PATH` (**required**) — `virtio-win.iso` release 0.1.240
  or later (for ARM64 binaries). The build wrapper hard-fails if missing.
  Drivers extracted from this ISO are bundled into the unattend CD so
  WinPE can load them before the disk probe; the full ISO is also
  attached as a runtime CD for FirstLogonCommands to pick up the
  guest-tools installer.
- `WINDOWS_ISO_SHA256` (optional) — published hash for integrity check
  before sinking ~16 min into a build against a corrupt download.

## Gotchas / open questions

- **`qemu_binary` points at a wrapper script, not `qemu-system-aarch64`.**
  Packer's qemu plugin treats `qemuargs` as a complete replacement for
  its auto-generated args, not an append. The workaround is
  [`scripts/qemu-with-tpm.sh`](../../scripts/qemu-with-tpm.sh): forwards
  Packer's args verbatim and appends/rewrites surgically. It does four
  things — adds TPM 2.0 (swtpm), adds `ramfb` + USB controller + input
  devices, rewrites every Packer-generated `media=cdrom` drive to
  `usb-storage` form (ARM `virt` has no IDE/SATA controller), and
  attaches `virtio-win.iso` as a third usb-storage CD. The wrapper also
  logs its final qemu argv to
  `packer_cache/qemu-with-tpm.cmd.log` — first place to look if qemu
  refuses to start.
- **USB enumeration order matters for EFI auto-boot.** EDK2 on ARM virt
  walks USB devices in argv order looking for `\EFI\Boot\bootaa64.efi`;
  if a non-bootable usb-storage device (like virtio-win.iso) precedes
  the install ISO, EDK2 drops to the EFI Shell instead of booting
  Setup. The wrapper enforces the right order — keep the install ISO's
  usb-storage device first if you ever restructure.
- **NetBIOS computer-name limit (15 chars).** Enforced inside
  Microsoft-Windows-Shell-Setup's own validator, not the answer file's
  XSD — `xmllint` and `packer validate` will both pass a 16-char name,
  then specialize bails on first reboot with hrResult=0x80220005. Cap
  any change to `<ComputerName>` at 15.
- **Sysprep exit codes from PowerShell over WinRM.** Win11 24H2 returns
  `16001` when the WinRM service is torn down mid-`sysprep /generalize`
  (the legacy code is `2300218`); `valid_exit_codes` in
  `windows.pkr.hcl` accepts both.
- **swtpm state is wiped per build.** The wrapper deletes the swtpm state
  directory before starting a new run. If you ever need to preserve TPM
  state between builds (sealed-data testing), remove the `rm -rf` line
  in `scripts/build-windows.sh`.
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
- **NetKVM may not survive WinPE → installed-system handoff.**
  `setupact.log` from a clean build still shows `CApplyDrivers::
  CopyToDriverStore: Failed to copy driver package` warnings for the
  NetKVM INF. The FirstLogonCommands pnputil step re-installs NetKVM
  from the unattend CD before WinRM bring-up, so the build still
  succeeds — but if NetKVM ever stops re-installing cleanly the
  symptom will be a hang at "waiting for WinRM."
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
