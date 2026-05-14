# Windows 11 ARM64 build — attempt log

> **Purpose.** This doc is for whoever (or whichever LLM session) picks up
> the Windows pipeline next. It captures what we tried, what failed and
> why, the dead-ends ruled out, and the rationale behind the current
> shape. Read this before changing
> [`../packer/windows-11-arm64/`](../packer/windows-11-arm64/) — most of
> the obvious-looking moves have already been explored.
>
> **Status (2026-05-13, end of day): green.** Full pipeline produces a
> sysprep'd qcow2 artifact in ~16 min wall-clock on M2 Max + Apple HVF.
> The closing diagnostic session resolved five distinct walls in
> sequence, each gated on fixing the previous one. In order:
>
> 1. **CD-ROM attachment bus.** ARM `virt` has no IDE/SATA controller,
>    and Packer's `cdrom_interface=virtio` default needs a driver WinPE
>    can't load yet. Fix: [`qemu-with-tpm.sh`](../scripts/qemu-with-tpm.sh)
>    rewrites every `-drive ...,media=cdrom` Packer emits to
>    `usb-storage` form. See "The CD-ROM bus problem" below.
> 2. **USB enumeration order.** First fix put virtio-win.iso's
>    usb-storage device before the install ISO's in argv, so EDK2
>    tried to boot the non-bootable virtio-win.iso first and dropped
>    to EFI Shell. Fix: split the wrapper's extras so device_appends
>    (Packer cdroms) emit before our virtio-win.iso attach.
> 3. **Win11 hardware-requirements check.** Apple Silicon isn't on
>    Microsoft's supported-CPU list; `cpu host` advertises it, Setup
>    halts. Fix: [`Autounattend.xml`](../packer/windows-11-arm64/Autounattend.xml)'s
>    new RunSynchronous block writes the five `LabConfig` bypass keys
>    in windowsPE *before* the check fires (mirrors homelab x86).
> 4. **NetBIOS name length.** `<ComputerName>windows-11-arm64</ComputerName>`
>    is 16 chars; the schema cap is 15. Setup made it through windowsPE
>    and first reboot, then specialize bailed with hrResult=0x80220005
>    "Value is invalid" — passes xmllint and `packer validate` because
>    the rule lives inside Microsoft-Windows-Shell-Setup's own validator,
>    not the answer file's XSD. Fix: shortened to `win11-arm64` (11).
> 5. **Sysprep exit code.** Win11 24H2 PowerShell-over-WinRM returns
>    **16001** (not the legacy `2300218`) when sysprep tears down the
>    WinRM service. Provisioner's `valid_exit_codes` allowlist now
>    contains both.
>
> Two non-blocking warnings still show in setupact.log on a clean run:
> `CApplyDrivers::CopyToDriverStore` failures on oem*.inf (NetKVM may
> not survive into the installed system — FirstLogonCommands' pnputil
> step re-installs from `D:..I:\drivers\staging` and WinRM eventually
> binds anyway), and `hwreqchk: assuming metered network` telemetry
> noise. Neither blocks build success; flagged here in case they later
> become loadbearing.

---

## Chronological log of pivots

### 1. Tart with from-scratch ISO install — abandoned

Initial plan per [`../CLAUDE.md`](../CLAUDE.md): build Windows under Tart
the same way Ubuntu is built (tart-cli source, from_iso, Autounattend.xml
delivered via removable media).

**Why abandoned:** Tart can't host Windows at all, and the reasons stack
three deep. We initially understood only the first one; the third only
became obvious after solving the equivalent problem on QEMU.

1. **No Windows VM configuration in Tart's source.** Tart's
   [Run.swift](https://github.com/cirruslabs/tart/blob/main/Sources/tart/Commands/Run.swift)
   supports two guest types — macOS (`VZMacOSVirtualMachineConfiguration`)
   and Linux (`VZGenericMachineConfiguration` + kernel/initrd boot).
   There is no `--windows` flag, no Windows-aware EFI firmware path, no
   Windows boot wiring. This is a cirruslabs-side feature gap, not an
   Apple-side one — it could in principle be added.

2. **No TPM 2.0 device in Apple Virtualization.framework.** AVF has no
   `VZTPMDeviceConfiguration` class for non-macOS guests. We worked
   around this on QEMU with swtpm; AVF has no equivalent socket-attached
   TPM mechanism. Confirmed by
   [Motionbug's Apple-Silicon-Win11 article](https://motionbug.com/options-for-virtualizing-windows-11-arm-on-an-apple-silicon-mac/)
   which explicitly excludes Tart for the same reason. This one needs
   Apple to ship a new AVF API; cirruslabs can't route around it.

3. **AVF only exposes virtio buses to non-macOS guests, and ARM Win11
   WinPE has no in-box viostor.** This is the deepest blocker and is
   the same WinPE driver story we resolved on QEMU. On QEMU we attach
   CDs as `usb-storage` and WinPE's in-box xHCI stack lets it read
   them. On AVF there is no USB, no SATA, no NVMe — every disk is
   virtio-blk. So the boot sequence becomes:

   ```text
   EFI loads boot.wim from a virtio-blk-attached ISO  →  WinPE takes
   over  →  WinPE re-enumerates buses with its own drivers  →  no
   viostor in-box  →  WinPE sees no storage at all  →  can't read
   the boot device it just came from  →  Setup never reaches the
   disk picker.
   ```

   Our PnpCustomizationsWinPE driver-injection mechanism doesn't help
   because the unattend CD with the driver INFs is also on virtio-blk
   that WinPE can't see. No fallback bus available.

**What would it take for Tart to host Windows?** All three above plus a
pre-built install ISO with viostor injected into both `boot.wim` and
`install.wim` (DISM `/Add-Driver` on Windows, or wimlib on macOS, then
xorriso to repack preserving the El Torito EFI boot record). Even then
the build pipeline would lose its "stock Microsoft ISO + Autounattend"
ergonomics, and Tart's value-add (OCI registry distribution,
declarative VM specs) doesn't outweigh re-rolling the install media on
every Microsoft 24H2.x update. Not pursued.

**What carries over from this build to a hypothetical Tart-based one:**
Autounattend.xml's `<RunSynchronous>` LabConfig bypass and the
`FirstLogonCommands` chain are platform-independent and would apply.
Everything else (qemu wrapper rewrites, swtpm wiring, usb-storage CD
attach order, ramfb display) is QEMU-specific and would not.

### 2. Tart `vm_base_name` against a cirruslabs prebuilt — ruled out

Briefly considered using `vm_base_name = "ghcr.io/cirruslabs/windows:latest"`
to skip the ISO install entirely.

**Why ruled out:** No such image exists. Cirruslabs publishes
[`macos-image-templates`](https://github.com/cirruslabs/macos-image-templates)
and `linux-image-templates` but no Windows equivalent. Tart's README
makes no Windows guarantee. The image we'd need has never been built
publicly.

### 3. UTM as the practical Windows path — kept

UTM consumption path documented at [`windows-utm.md`](windows-utm.md).
UTM supports TPM 2.0 and Secure Boot natively and is the recommended
interactive front-end for the qcow2 the Packer build produces — useful
when you want a GUI for snapshot/clone management. The interactive
install path in that doc is also a viable manual escape hatch if the
Packer build ever regresses.

### 4. Packer qemu-iso + swtpm — current path

CLAUDE.md anticipates this as a fallback: *"UTM consumes qcow2 from
Packer's qemu builder if Tart doesn't fit a use case."* The qemu source
preserves the `just build-windows`-with-reproducible-artifact ergonomics
of the Ubuntu pipeline. Plumbing took several debugging cycles; each
QEMU/macOS gotcha is captured inline in the wrapper script's header and
the HCL comments.

**What works (verified end-to-end during earlier sessions):**

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

**What was blocking until 2026-05-13:** Setup's storage probe returned
"no installable hard drives found." Re-diagnosis below.

---

## QEMU/macOS gotchas — six captured during earlier sessions

Each costs a 5-30 minute debugging cycle and is non-obvious from public
docs. All are captured inline in
[`../scripts/qemu-with-tpm.sh`](../scripts/qemu-with-tpm.sh)'s header
and the HCL comments at
[`../packer/windows-11-arm64/windows.pkr.hcl`](../packer/windows-11-arm64/windows.pkr.hcl).

| # | Symptom | Cause | Fix |
| --- | --- | --- | --- |
| 1 | Disk/CD/network all missing; "Error launching VM" | Packer's `qemuargs` config option *replaces* its auto-generated args entirely, not appends | Don't use `qemuargs`. Point `qemu_binary` at a wrapper script that appends what we need after `"$@"`. |
| 2 | `mach-virt: HVF does not support providing Virtualization extensions to the guest CPU` | `machine_type = "virt,virtualization=on"` enables nested-virt which HVF can't pass through | Drop `virtualization=on`. Keep `gic-version=max`. |
| 3 | `-display gtk: Parameter 'type' does not accept value 'gtk'` | Packer's qemu plugin defaults `-display gtk` when not headless | Set `display = "cocoa"` in the source (macOS-native UI). |
| 4 | Cocoa window shows only `compat_monitor0` console; no VM frame | ARM `virt` machines don't ship a graphics device by default | Wrapper appends `-device ramfb` (not `virtio-gpu-pci` — EFI firmware doesn't have a driver for that during boot). |
| 5 | Mouse/keyboard don't interact with the VM | ARM `virt` machines don't ship input devices either | Wrapper appends `-device qemu-xhci,id=usb -device usb-kbd,bus=usb.0 -device usb-tablet,bus=usb.0`. |
| 6 | EFI Shell prompt instead of Windows boot loader | "Press any key to boot from CD" prompt times out before headless attention | `boot_command` spams `<enter><wait1>` for ~15 seconds via Packer's VNC keystroke channel. |

---

## The "WinPE driver wall" — diagnosed 2026-05-13

The previous version of this doc concluded the build was stuck on an
unsolvable problem with `Microsoft-Windows-PnpCustomizationsWinPE` driver
injection on Win11 ARM64 24H2, citing the sibling homelab x86 build's
finding that "24H2 Setup ignores `Microsoft-Windows-Setup\DriverPaths`."

**That conclusion conflated two different unattend elements.** Re-reading
the homelab Autounattend (`packer/windows-11-base/http/Autounattend.xml`
in the sibling repo):

> Driver paths live on Microsoft-Windows-PnpCustomizationsWinPE (above),
> not here. Win11 24H2's setup host silently ignores
> `Microsoft-Windows-Setup\DriverPaths`... PnpCustomizationsWinPE runs
> strictly earlier and is honoured.

i.e. the homelab build *uses* `PnpCustomizationsWinPE` and it works on
x86 24H2 — they switched away from `Microsoft-Windows-Setup\DriverPaths`
precisely because it didn't work, then verified the WinPE-pass mechanism
did. The mac-vms doc extrapolated to "ARM64 ignores PnpCustomizationsWinPE
too" without testing that element directly.

The *actual* failure mode was simpler: `VIRTIO_WIN_ISO_PATH` was not set
in `.env.local`. The wrapper's `WARN-and-continue` codepath meant
virtio-win.iso was never attached to the VM. The unattend's
`F:\viostor\w11\ARM64` reference resolved to nothing — Setup ran the
PnP block, found no INFs, loaded no drivers, and the disk probe failed.
The conclusion "PnpCustomizationsWinPE is broken on ARM64" rested on a
test where the driver source was never reachable in the first place.

---

## The CD-ROM bus problem

The post-rewrite build (drivers bundled into the unattend CD, multi-letter
candidate paths, hard-fail on missing `VIRTIO_WIN_ISO_PATH`) still hit the
interactive disk picker with no drives and no driver-load path working.
Pattern wouldn't fit the "Pnp resolution missed" theory: an interactive
disk picker means autounattend didn't apply at all, not that one block
silently no-op'd.

Cross-referencing three independent sources — the [virtio-win ARM64 KB](https://virtio-win.github.io/Knowledge-Base/Windows-arm64-vm-using-qemu.html),
the canonical [Vogtinator gist](https://gist.github.com/Vogtinator/293c4f90c5e92838f7e72610725905fd),
and the [Linaro WOA wiki](https://linaro.atlassian.net/wiki/spaces/WOAR/pages/28914909194)
— surfaces a load-bearing detail the earlier design missed:

**On QEMU's ARM `virt` machine there is no IDE / SATA controller.** A bare
`-drive file=...,media=cdrom` attaches to whatever bus the qemu defaults
pick, and on `virt` that's effectively unreadable to WinPE pre-injection.
Packer's qemu plugin defaults `cdrom_interface = "virtio"`, which is even
worse: virtio is precisely the driver WinPE doesn't have until *after*
PnpCustomizationsWinPE runs. So WinPE couldn't read the CD that carried
Autounattend.xml in the first place — never saw the answer file, fell back
to the interactive Setup UI, and "Load driver" → "Browse" couldn't see
the staging tree on that same CD either.

The x86 build never hit this because QEMU's `pc-q35` ships an in-box AHCI
controller and Win11 x86 WinPE has the `storahci` driver built in. A
bare `media=cdrom` "just works" on x86; on ARM it silently doesn't.

### The fix

All three CDs (Windows install ISO, Packer-built unattend CD, virtio-win.iso)
now attach via `usb-storage`. WinPE on ARM64 24H2 has the in-box xHCI/USB
stack — we already use it for the keyboard and tablet (`qemu-xhci` +
`usb-kbd` + `usb-tablet`), so a USB CD-ROM appears as a readable drive
the moment WinPE starts.

Because Packer auto-generates the `-drive` args for the install ISO and
the unattend CD, [`scripts/qemu-with-tpm.sh`](../scripts/qemu-with-tpm.sh)
rewrites them in-flight: walks `$@`, strips `if=...` / `index=...` from
each `media=cdrom` drive, appends `if=none,id=cd-pkr-<N>`, and emits a
matching `-device usb-storage,drive=cd-pkr-<N>`. The wrapper's own
virtio-win.iso attach was already under our control and switched to the
same usb-storage form. [`scripts/qemu-manual-boot.sh`](../scripts/qemu-manual-boot.sh)
got the same treatment for diagnostics-parity.

### How to verify

Before re-running the full Packer build, sanity-check the theory
manually:

```bash
./scripts/qemu-manual-boot.sh
# At the Setup screen: Shift+F10 → cmd → diskpart → list vol
# Expected: two CD volumes (Windows install + virtio-win) with assigned
# drive letters. dir D:\viostor\w11\ARM64 should list the INF/SYS/CAT.
# Manually load: drvload D:\viostor\w11\ARM64\viostor.inf
# After load, the qcow2 system disk should appear in diskpart list disk.
```

If that works, `just build-windows` should now make it past the disk
probe without manual intervention because the unattend CD is readable
and `PnpCustomizationsWinPE` resolves the bundled drivers from the same
disc that delivered Autounattend.xml.

---

## Current design (post-2026-05-13)

The fix tightens the wrapper and reshapes the driver delivery path:

1. **Hard-fail on missing inputs.** `scripts/build-windows.sh` now exits
   with a clear error if `VIRTIO_WIN_ISO_PATH` is unset or points at a
   missing file. No more silent fallthrough.

2. **Bundle drivers into the unattend CD.** The wrapper mounts
   `virtio-win.iso`, copies `viostor`, `vioscsi`, and `NetKVM` ARM64
   trees into `packer/windows-11-arm64/drivers/staging/`, and Packer's
   `cd_files` packs that subdir into the same auto-built CD as
   `Autounattend.xml`. The drivers WinPE needs at install time are now
   on the same disc WinPE just read the answer file from — no
   separately-attached ISO whose drive letter depends on enumeration
   order.

3. **Multi-letter unattend paths.** The
   `Microsoft-Windows-PnpCustomizationsWinPE` block lists the bundled
   drivers under D:, E:, F:, G: candidate paths. WinPE silently ignores
   paths that don't resolve and uses whichever letter the unattend CD
   actually got. This removes the drive-letter guessing game that
   previous attempts implicitly bet on.

4. **`virtio-win.iso` still attached as a runtime CD.** The qemu wrapper
   still attaches the full ISO as a third CD-ROM, but its role is now
   post-install: FirstLogonCommands' first step uses `pnputil` to install
   the bundled drivers into the running OS so NetKVM has a binding
   before the network-setup steps run. (Without that, the installed
   Windows boots from disk via viostor — which made it from WinPE into
   the boot path — but has no NIC driver, so the FirstLogon network
   wait would hang forever.)

5. **Manual-boot diagnostic script.**
   [`../scripts/qemu-manual-boot.sh`](../scripts/qemu-manual-boot.sh)
   boots the Win11 ARM64 ISO under the same QEMU/swtpm/UEFI/ramfb/USB
   stack as the build, but without Packer or the unattend CD. Use
   it for Shift+F10 → cmd diagnostics if something doesn't work: enumerate
   drive letters via `diskpart list vol`, test `drvload` on specific
   INFs, try alternative storage controllers.

---

## What's confirmed (2026-05-13 closing run)

The earlier list of open hypotheses all resolved during the verification
run that produced the first working artifact:

1. **Unattend CD drive letter on ARM64 WinPE.** With the usb-storage
   attach order enforced, the install ISO lands at D:, virtio-win at E:,
   and Packer's unattend CD at F: — inside the D:..G: candidate range the
   unattend block lists.
2. **Packer's `cd_files` directory recursion.** Works as expected — the
   `./drivers` directory tree gets packed into the unattend CD with
   structure preserved (`F:\drivers\staging\<driver>\<files>`).
3. **virtio-win 0.1.285 ARM64 driver signing.** Microsoft-signed and
   loaded by WinPE under Secure Boot without complaint. No
   `drvload`-rejects-signature failures observed.
4. **`pnputil` on first-boot ARM64 Win11.** The FirstLogonCommands step
   completes; NetKVM binds; WinRM comes up. `setupact.log` does show
   `CApplyDrivers::CopyToDriverStore` warnings during the offline-image
   phase, but pnputil's online install reconciles them in time for the
   network step.

---

## Fallback path if injection ever regresses

The **custom install ISO** route remains the documented escape hatch if
Microsoft changes WinPE's driver loader in a future 24H2.x or 25H1
update. Sketch: DISM (Windows-only) or wimlib on macOS to mount
`boot.wim` + `install.wim`, inject the virtio ARM64 drivers via
`Add-WindowsDriver`, repack with `xorriso` preserving the El Torito EFI
boot record, point `WINDOWS_ISO_PATH` at the new ISO. Significant work
and brittle to Microsoft ISO changes; not attempted because the
PnpCustomizationsWinPE + usb-storage CD attach combination worked
without it.

---

## What's preserved in the repo

The pipeline scaffolding is committed and validated:

- [`../packer/windows-11-arm64/windows.pkr.hcl`](../packer/windows-11-arm64/windows.pkr.hcl)
  — `qemu` source with all six QEMU gotchas worked around, `cd_files`
  including bundled drivers.
- [`../packer/windows-11-arm64/Autounattend.xml`](../packer/windows-11-arm64/Autounattend.xml)
  — ARM64 unattend, full four-pass setup, FirstLogonCommands pnputil
  bootstrap + WinRM enable, multi-letter PnpCustomizationsWinPE block.
- [`../packer/windows-11-arm64/drivers/`](../packer/windows-11-arm64/drivers/)
  — staging tree populated by the wrapper from `virtio-win.iso`.
- [`../packer/windows-11-arm64/provision/`](../packer/windows-11-arm64/provision/)
  — five PowerShell scripts mirroring the homelab structure.
- [`../scripts/build-windows.sh`](../scripts/build-windows.sh) — wrapper
  with hard-fail preconditions, swtpm management, driver extraction.
- [`../scripts/qemu-with-tpm.sh`](../scripts/qemu-with-tpm.sh) —
  forwards Packer's qemu args and appends TPM + ramfb + USB +
  virtio-win.iso CD-ROM.
- [`../scripts/qemu-manual-boot.sh`](../scripts/qemu-manual-boot.sh) —
  diagnostic boot path for when the Packer build needs investigation.

---

## How to read this with another Claude session

If you're picking this up later or sharing with a teammate's Claude:

- The status block at the top of this doc is the TL;DR of what works
  and what closed walls we hit getting there.
- The chronological narrative + the "WinPE driver wall" and "CD-ROM bus
  problem" sections explain the *why* of the current design — read once.
- The QEMU gotchas table is the "don't repeat these" cheat sheet.
- The "What's confirmed (2026-05-13 closing run)" section captures the
  hypotheses the verified build closed out. If a future build regresses,
  re-test those before assuming a new failure mode.
- The "Fallback path if injection ever regresses" section is the only
  open research direction documented here.
- [`../CLAUDE.md`](../CLAUDE.md) is the durable repo context; this doc
  is the decision-history that doesn't fit there.

Good luck.
