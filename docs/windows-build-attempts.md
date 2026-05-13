# Windows 11 ARM64 build — attempt log and current wall

> **Purpose.** This doc is for whoever (or whichever LLM session) picks up
> the Windows pipeline next. It captures what we tried, what failed and
> why, the dead-ends ruled out, and the one remaining viable path
> identified but not pursued. Read this before changing
> [`../packer/windows-11-arm64/`](../packer/windows-11-arm64/) — most of
> the obvious-looking moves have already been ruled out.
>
> Written on commit `a4e0b6e`, the first non-scaffold commit. The Ubuntu
> pipeline is fully working; Windows is blocked at the WinPE driver
> wall described at the bottom.

---

## Current state in one sentence

The Packer pipeline parses, validates, launches QEMU with full UEFI +
TPM 2.0 + Secure Boot, boots Win11 24H2 ARM64 Setup successfully, and
gets stopped at Setup's *"no installable hard drives found"* screen
because **no in-box WinPE driver matches any of QEMU's emulated storage
controllers**, and **24H2 Setup ignores `Microsoft-Windows-PnpCustomizationsWinPE`
driver injection** (per the homelab x86 build's documented experience).

---

## Chronological log of pivots

### 1. Tart with from-scratch ISO install — abandoned

Initial plan per [`../CLAUDE.md`](../CLAUDE.md): build Windows under Tart
the same way Ubuntu is built (tart-cli source, from_iso, Autounattend.xml
delivered via removable media).

**Why abandoned:** Tart can't host Windows 11 at all. Tart's source code
([Run.swift in cirruslabs/tart](https://github.com/cirruslabs/tart/blob/main/Sources/tart/Commands/Run.swift))
has no TPM or Secure Boot wiring — both Win11 system requirements.
Confirmed by [Motionbug's Apple-Silicon-Win11 article](https://motionbug.com/options-for-virtualizing-windows-11-arm-on-an-apple-silicon-mac/)
which explicitly excludes Tart for the same reason. The black-screen +
input-stutter symptom we hit early on wasn't really about Tart's display
layer — it was that Setup refused to proceed without TPM.

**What still applies if Tart adds TPM later:** the
[`Autounattend.xml`](../packer/windows-11-arm64/Autounattend.xml) and the
provisioner pipeline (00 / 15 / 20 / 30 / 99) work conceptually under any
QEMU-shaped Windows builder.

### 2. Tart `vm_base_name` against a cirruslabs prebuilt — ruled out

Briefly considered using `vm_base_name = "ghcr.io/cirruslabs/windows:latest"`
to skip the ISO install entirely.

**Why ruled out:** No such image exists. Cirruslabs publishes
[`macos-image-templates`](https://github.com/cirruslabs/macos-image-templates)
and `linux-image-templates` but no Windows equivalent. Tart's README
makes no Windows guarantee. The image we'd need has never been built
publicly.

### 3. UTM as the practical Windows path — kept

Active fallback documented at [`windows-utm.md`](windows-utm.md). UTM
supports TPM 2.0 and Secure Boot natively and walks the user through
storage-driver selection at install time. Interactive only, no
programmatic build, but it works.

This is the answer for **"I need a Windows ARM64 VM right now."**

### 4. Packer qemu-iso + swtpm — pursued, scaffolding complete

CLAUDE.md anticipates this as a fallback: *"UTM consumes qcow2 from
Packer's qemu builder if Tart doesn't fit a use case."* Pursued it
because it preserves the `just build-windows`-with-reproducible-artifact
ergonomics of the Ubuntu pipeline. Plumbing took several debugging
cycles; each gotcha is documented inline.

**What works (verified end-to-end during this session):**

- `swtpm socket --tpm2 --daemon` provides TPM 2.0 over a Unix socket.
- `edk2-aarch64-code.fd` + per-build copy of `edk2-arm-vars.fd` give UEFI
  with Secure Boot capability.
- Apple HVF acceleration runs Win11 ARM64 at near-native speed.
- `ramfb` provides an EFI-writable framebuffer for visibility through
  Cocoa display.
- USB controller + keyboard + tablet via the wrapper script for input.
- Packer's `boot_command` types spam-enter into the "press any key to
  boot from CD" prompt window.
- Windows Setup boots, processes the Autounattend.xml, and proceeds past
  the language picker.

**What does not work (the wall):** Setup's storage probe. See "the wall"
section below.

---

## QEMU/macOS gotchas — six captured during this session

Each of these costs a 5-30 minute debugging cycle and is non-obvious
from public docs. All are captured inline in
[`../scripts/qemu-with-tpm.sh`](../scripts/qemu-with-tpm.sh)'s header
and the HCL comments at [`../packer/windows-11-arm64/windows.pkr.hcl`](../packer/windows-11-arm64/windows.pkr.hcl).

| # | Symptom | Cause | Fix |
| --- | --- | --- | --- |
| 1 | Disk/CD/network all missing; "Error launching VM" | Packer's `qemuargs` config option *replaces* its auto-generated args entirely, not appends | Don't use `qemuargs`. Point `qemu_binary` at a wrapper script that appends what we need after `"$@"`. |
| 2 | `mach-virt: HVF does not support providing Virtualization extensions to the guest CPU` | `machine_type = "virt,virtualization=on"` enables nested-virt which HVF can't pass through | Drop `virtualization=on`. Keep `gic-version=max`. |
| 3 | `-display gtk: Parameter 'type' does not accept value 'gtk'` | Packer's qemu plugin defaults `-display gtk` when not headless | Set `display = "cocoa"` in the source (macOS-native UI). |
| 4 | Cocoa window shows only `compat_monitor0` console; no VM frame | ARM `virt` machines don't ship a graphics device by default | Wrapper appends `-device ramfb` (not `virtio-gpu-pci` — EFI firmware doesn't have a driver for that during boot). |
| 5 | Mouse/keyboard don't interact with the VM | ARM `virt` machines don't ship input devices either | Wrapper appends `-device qemu-xhci,id=usb -device usb-kbd,bus=usb.0 -device usb-tablet,bus=usb.0`. |
| 6 | EFI Shell prompt instead of Windows boot loader | "Press any key to boot from CD" prompt times out before headless attention | `boot_command` spams `<enter><wait1>` for ~15 seconds via Packer's VNC keystroke channel. |

After these six, the build runs Setup successfully through to the
storage-probe screen.

---

## The wall — WinPE storage drivers on Win11 24H2 ARM64

Tried three QEMU storage interfaces, all reported "no installable hard
drives found":

- `virtio-blk` (Packer's `disk_interface = "virtio"` default)
- NVMe (via wrapper-script argv rewrite to `-device nvme,drive=osdisk,serial=osdisk`)
- AHCI/SATA (via wrapper rewrite to `-device ahci,id=ahci0 -device ide-hd,bus=ahci0.0,drive=osdisk`)

Compare to the homelab x86 build at
[`~/Downloads/src/homelab/packer/windows-11-base/windows-11-base.pkr.hcl`](file:///Users/brian.birkinbine/Downloads/src/homelab/packer/windows-11-base/windows-11-base.pkr.hcl),
which documents the x86 WinPE driver inventory:

> Win11 24H2's WinPE has:
> - msiscsi.sys, pvscsii.sys, scsiport.sys, **storahci.sys** present
> - sym_*, megasas, viostor, vioscsi NOT present
>
> So out-of-the-box Win11 24H2 only sees the install disk if it's on
> **SATA AHCI** (storahci.sys), **VMware PV SCSI** (pvscsii.sys), or **NVMe**.

That's why AHCI works for the x86 build. On ARM64 the corresponding
WinPE driver set evidently differs — none of QEMU's standard emulated
storage matched. Confirmed by trial, not by inspecting the ARM64 WinPE
driver inventory directly (that'd be an interesting first-step research
task for the next attempt).

The homelab comment also flags a separate 24H2 issue:

> virtio-scsi-single would be ideal — but Win11 24H2's setup host also
> **ignores Autounattend DriverPaths** and we don't want to ship a
> custom-rolled install ISO. SATA is the universally-supported fallback.

So injecting drivers via `Microsoft-Windows-PnpCustomizationsWinPE`
(which our [`Autounattend.xml`](../packer/windows-11-arm64/Autounattend.xml)
*does* have, referencing `F:\viostor\w11\ARM64` etc.) probably wouldn't
help even if [`virtio-win.iso`](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso)
contained signed ARM64 binaries — because Setup will ignore the block.

The homelab found this for x86 24H2 and fell back to AHCI. We don't have
an AHCI fallback (or any other in-box) for ARM64 24H2.

---

## Remaining viable path — custom install ISO with pre-injected drivers

The homelab comment explicitly identifies the option they didn't pursue
on x86 because they had AHCI as a fallback:

> ...we don't want to ship a custom-rolled install ISO.

For ARM64 there is no in-box fallback, so the custom ISO is the only
path that bypasses the unattend-injection bug.

**Sketch of what this would entail:**

1. Mount the upstream Win11 24H2 ARM64 ISO and extract `boot.wim` and
   `install.wim` (the WinPE and installed-system filesystems).
2. Mount `boot.wim` with DISM (`dism /Mount-Wim ...`) — note: DISM
   is Windows-only; would need a Windows host to do this. Alternatively
   `wimlib` on macOS via `brew install wimlib`.
3. Inject ARM64 virtio drivers via `dism /Add-Driver /Recurse` (or
   `wimlib-imagex update`) for `viostor`, `vioscsi`, `NetKVM`.
4. Unmount, commit changes.
5. Repeat for `install.wim` (so the running OS, not just WinPE, has the
   drivers).
6. Repackage the modified files into a new bootable ISO via `xorriso`
   preserving the original EFI boot record.
7. Point the build wrapper at the custom ISO instead of the upstream.

Pitfalls to expect:

- ARM64 virtio drivers from `virtio-win.iso` need to be Microsoft-signed
  for Secure Boot to accept them — verify before investing in injection.
- The upstream ISO's exact structure may change with each 24H2 servicing
  release; the script needs to be idempotent against new ISOs.
- The xorriso repack must preserve the El Torito boot record + UEFI boot
  partition exactly, or QEMU's EFI firmware won't boot the new ISO.
- This whole flow probably wants to live in
  [`../scripts/build-windows.sh`](../scripts/build-windows.sh) as an
  optional pre-build step gated by an env var (
  `WINDOWS_CUSTOM_ISO_PATH` similar to how `VIRTIO_WIN_ISO_PATH` is
  wired today).

Total estimated effort: 1-2 days of focused work + multiple build
cycles. Not attempted in this session.

---

## What's preserved in the repo, ready to resume

The pipeline scaffolding is committed and validated:

- [`../packer/windows-11-arm64/windows.pkr.hcl`](../packer/windows-11-arm64/windows.pkr.hcl)
  — `qemu` source with all six QEMU gotchas worked around.
- [`../packer/windows-11-arm64/Autounattend.xml`](../packer/windows-11-arm64/Autounattend.xml)
  — ARM64 unattend, full four-pass setup, FirstLogonCommands WinRM
  bootstrap ported from homelab, `Microsoft-Windows-PnpCustomizationsWinPE`
  block referencing virtio-win arm64 paths (currently inert per the
  24H2 ignore-injection bug, but harmless to leave in place).
- [`../packer/windows-11-arm64/provision/`](../packer/windows-11-arm64/provision/)
  — five PowerShell scripts mirroring homelab structure
  (00-wait-for-winrm / 15-windows-cleanup / 20-harden stub /
  30-install-cloudbase-init stub / 99-sysprep). `99-sysprep.ps1` is
  the most load-bearing — it installs the `PackerBuildCleanup`
  scheduled task that rotates the build Administrator password on
  first clone boot.
- [`../scripts/qemu-with-tpm.sh`](../scripts/qemu-with-tpm.sh)
  — wrapper around `qemu-system-aarch64` that appends TPM + ramfb +
  USB + (optionally) virtio-win CD. Header documents each gotcha
  with the symptom-cause-fix triplet from the table above.
- [`../scripts/build-windows.sh`](../scripts/build-windows.sh) —
  starts `swtpm` in the background, exports `SWTPM_SOCK` +
  `PKR_VAR_qemu_binary`, manages cleanup via `trap`.

A resumer who solves the WinPE driver problem (most likely via the
custom-ISO route) should be able to run `just build-windows` without
further plumbing changes. The rest of the pipeline is intact.

---

## Open questions worth answering early on any resume

1. **What's actually in Win11 24H2 ARM64 WinPE's driver store?** Mount
   `boot.wim` from the ISO, list drivers with
   `dism /Get-Drivers /Image:<mount>`. Figure out if there's any
   storage interface QEMU can emulate that matches an in-box driver
   without injection — would obviate the custom-ISO project.
2. **Does the homelab's "24H2 ignores DriverPaths" finding also hold
   on ARM64?** It's possible the ARM Setup behaviour differs. Could be
   tested with a deliberately-misconfigured `Autounattend.xml`
   referencing a driver path that should be discoverable; if the
   driver loads, injection works. (Microsoft documents the feature as
   working; the homelab finding is empirical.)
3. **Are ARM64 virtio-win drivers Microsoft-signed for Secure Boot?**
   Check the `.cat` files in the relevant `arm64` directories on
   `virtio-win.iso`. Unsigned drivers won't load under Secure Boot.
4. **Is wimlib's `Add-Driver` equivalent (or DISM run via a Windows
   stepping-stone VM) reliable enough for a build pipeline?** This
   is a build-time tooling question, not a runtime one.

---

## How to read this with another Claude session

If you're picking this up later or sharing with a teammate's Claude:

- The chronological narrative is the "why" — read it once.
- The QEMU gotchas table is the "don't repeat these" cheat sheet —
  cross-reference against the file links.
- The wall + remaining-viable-path sections are the actual research
  agenda if anyone takes Windows further.
- The CLAUDE.md is the durable repo context; this doc is the
  decision-history that doesn't fit there.

Good luck.
