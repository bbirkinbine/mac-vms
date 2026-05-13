# Windows 11 ARM64 base image

Packer config that produces `windows-11-arm64-base` in `~/.tart/vms/`. **Stub
status** — the skeleton is in place but the build does not run end-to-end yet.
Several decisions are open and tagged with `TODO(next-session)` in the HCL.

## Prerequisites

- Apple Silicon Mac (M-series).
- Tart installed: `brew install --cask tart`
- Packer + the Tart plugin: `brew install packer && packer plugins install github.com/cirruslabs/tart`
- **The Windows 11 ARM64 VHDX from Microsoft.** Bring your own — Microsoft
  does not permit redistribution, so this file cannot be committed or
  fetched by the build. Download steps:
  1. Sign in at [Windows Insider Preview Downloads](https://www.microsoft.com/en-us/software-download/windowsinsiderpreviewARM64).
  2. Download the ARM64 VHDX (typically ~11 GB).
  3. Set `WINDOWS_VHDX_PATH` in `.env.local` to its absolute path.

## Build

From the repo root:

```bash
just build-windows
```

Or directly:

```bash
WINDOWS_VHDX_PATH=/path/to/Windows11_InsiderPreview_Client_ARM64.vhdx \
  ./scripts/build-windows.sh
```

## Open questions before this works end-to-end

These are the things the next Claude session (or a manual pass) needs to resolve.

1. **How `tart-cli` consumes the VHDX.** The plugin's `from_iso` may or may
   not accept a VHDX path. The alternative is `tart import` of the VHDX into
   a Tart VM up front, then using `vm_base_name` instead of `from_iso` to
   clone-and-customize. Cirrus Labs' own Windows examples push prebuilt
   images to ghcr.io/cirruslabs/windows:* — consider whether that's the more
   pragmatic starting point.
2. **Where Autounattend.xml lives.** Two options:
   - Mount the VHDX before first boot, copy the unattend into
     `Panther/unattend.xml`, unmount, then let Tart boot it.
   - Serve it from Packer's `http_directory` and let Windows discover it
     during OOBE (requires either an autounattend ISO mounted as a CD, or a
     specific path the Windows installer probes — neither is guaranteed
     with an already-installed VHDX).
3. **ARM64 unattend schema.** The schema is the same as x86, but every
   `<component>` needs `processorArchitecture="arm64"`. Don't copy from the
   sibling `homelab/packer/windows-11-base/Autounattend.xml` without a
   careful pass.
4. **Communicator.** WinRM over Tart's NAT network should work; SSH-on-Windows
   is an alternative if WinRM proves rocky.

## Validate XML and HCL

```bash
xmllint --noout Autounattend.xml
packer init .
packer fmt -check .
packer validate .
```

## Where context lives

- Project-level: [`../../CLAUDE.md`](../../CLAUDE.md)
- Sibling x86_64 build (for reference, NOT direct copy source):
  `homelab/packer/windows-11-base/`
