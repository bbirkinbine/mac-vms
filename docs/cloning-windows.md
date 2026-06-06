# Cloning the Windows base image and creating a per-VM identity

> ## Status: built, not yet verified on a clean clone
>
> As of 2026-06-06 the per-VM identity flow is **implemented** but has
> not been walked end-to-end on a fresh build + clone. The pieces:
> `provision/30-install-firstboot-seed.ps1` installs a `FirstBootSeed`
> scheduled task into the image; `seed/build-cidata.sh` builds the seed
> CD; `provision/99-sysprep.ps1` coordinates so the build Administrator
> is only locked down after a seed login lands. Treat the steps below as
> the design of record, but expect to debug the first real run — the
> Linux pipelines ([Ubuntu](cloning-ubuntu.md), [Kali](cloning-kali.md))
> remain the battle-tested reference.

This is the runbook for what happens **after** `just build-windows`
finishes — how to consume the sysprep'd qcow2 and get a usable VM.

Windows is structurally different from the Linux pipelines: there's no
cloudbase-init build for ARM64, so instead of a metadata service the
image carries a small first-boot consumer (`FirstBootSeed`) that reads
a JSON seed off an attached CD and injects the login. The seed CD is
the Windows analogue of the Linux `cidata.iso`.

## Mental model — three layers

The Linux pipelines have all three layers wired. Windows has the first
two; the third is the open work.

| Layer | What | Where | Status |
| --- | --- | --- | --- |
| 1. **Packer** | Sysprep'd Win11 ARM64 qcow2 | [`packer/windows-11-arm64/output-windows-11-arm64/`](../packer/windows-11-arm64/) | Working |
| 2. **Clone** | UTM clone or `qemu-img create -b <base>.qcow2 -F qcow2 new.qcow2` | UTM or shell | Working |
| 3. **Per-VM identity injection** | hostname / user / SSH key applied on first boot | JSON seed CD + the in-image `FirstBootSeed` task | Built, not yet verified — see [Seeded flow](#seeded-flow-recommended) |

Why the Tart-based Linux path can't host Windows here: three layered
blockers (no Windows VM config in Tart's source, no TPM in Apple
Virtualization.framework, AVF only exposes virtio buses to non-macOS
guests and ARM WinPE has no in-box viostor). See
[`windows-build-attempts.md`](windows-build-attempts.md) §1 for the
full diagnostic story. Consumption is via UTM or
`qemu-system-aarch64` directly ([`windows-utm.md`](windows-utm.md)).

## Seeded flow (recommended)

This is the automated path: build a seed CD, attach it to a clone, get
a configured login with no OOBE clicking.

```bash
just build-windows   # if you haven't already

cd packer/windows-11-arm64
cp seed/lab-seed.example.json seed/lab-seed.json
$EDITOR seed/lab-seed.json        # set username, password, hostname, SSH key
./seed/build-cidata.sh            # -> output-cidata/cidata.iso
```

Then boot a **clone** of the base qcow2 with `cidata.iso` attached as a
CD-ROM:

UTM path:

```text
open -a UTM
# File → New → Virtualize → Other → Skip ISO Boot
# Edit VM → System: ARM64 / QEMU virt / 8 GiB / 4 cores; TPM + Secure Boot on
# Drives → Import → output-windows-11-arm64/windows-11-arm64-base   (the disk)
# Drives → New → CD/DVD → import output-cidata/cidata.iso           (the seed)
# Play.
```

qemu path — the seed CD must be a `usb-storage` device, same as the
build (ARM `virt` has no IDE/SATA). Add to your
`qemu-system-aarch64` invocation (see
[`windows-utm.md`](windows-utm.md#running-the-qcow2-directly-via-qemu)
for the base command):

```text
-drive file=output-cidata/cidata.iso,media=cdrom,if=none,id=seedcd \
-device usb-storage,drive=seedcd,bus=usb.0
```

On first boot, in order:

1. **`FirstBootSeed`** (SYSTEM, AtStartup) scans CD-ROM volumes for
   `windows-seed.json`, creates the user with the password and groups
   from the seed, installs the SSH key, sets the hostname, and writes
   `C:\Windows\Setup\Scripts\seed-applied.marker`.
2. **`PackerBuildCleanup`** waits for that marker, sees a real seed
   user, then rotates + disables the build Administrator.

Log in (console / RDP / SSH — both are enabled by `20-harden.ps1`) as
the seeded user. The hostname takes effect after the first reboot.
After first boot the seed CD can be detached; both tasks self-destruct.

## Fallback: interactive account creation (no seed)

If you boot a clone with **no** seed CD attached, `FirstBootSeed`
records `NO-SEED` and `PackerBuildCleanup` deliberately **leaves the
build Administrator active** (disabling the only admin account would
brick the clone). The clone then carries the public build password
from `Autounattend.xml` — log in as `Administrator` /
`packer-build-only-Win11!`, then immediately change it or create your
own account. The seeded flow above is preferred precisely because it
avoids shipping that public credential.

## What's automated

- **Sysprep** runs at the end of the Packer build. The output qcow2
  is generalized — a fresh boot triggers OOBE-mini.
- **`FirstBootSeed`** injects a per-VM user / SSH key / hostname from
  the attached seed CD on first boot.
- **`PackerBuildCleanup`** rotates + disables the build Administrator —
  but only once a seed login exists (see the fallback above).

## Why not cloudbase-init

[`cloudbase-init`](https://cloudbase.it/cloudbase-init/) is the obvious
NoCloud consumer, but it has no official ARM64 installer at
[`cloudbase.it/downloads/`](https://cloudbase.it/downloads/) (checked
2026-06). Rather than build it from source (Python wheel + pythonized
service wrapper) or run the x64 MSI under emulation, this pipeline ships
a small bespoke consumer — `FirstBootSeed` — that reuses the exact
scheduled-task scaffolding already proven by `PackerBuildCleanup`. The
trade-off: the seed is JSON, not cloud-config YAML (Windows PowerShell
5.1 has no built-in YAML parser). If an official ARM64 cloudbase-init
ships later, swapping it in is a contained change to
`provision/30-install-firstboot-seed.ps1`.

## What NOT to do

1. **Don't rely on the build-time Administrator account for a seeded
   clone.** Once a seed login lands, `PackerBuildCleanup` disables it.
   It survives *only* on an unseeded clone, as the recovery path
   described under [Fallback](#fallback-interactive-account-creation-no-seed)
   — don't design around it.
2. **Don't bake a permanent admin password into the base.** Every
   clone would inherit it; rotating means rebuilding the base AND every
   existing VM. Per-VM credentials belong in the seed.
3. **Don't put a hash where plaintext belongs.** The seed's `password`
   is plaintext — `New-LocalUser` hashes it. A `$6$...`/`$2y$...` hash
   becomes the literal password and locks you out. (Same gotcha as the
   homelab cloudbase-init seed.)
4. **Don't expect a 16+ character NetBIOS computer name to stick.**
   NetBIOS caps at 15 characters; the unattend validator enforces
   this. See [`windows-build-attempts.md`](windows-build-attempts.md)
   for the diagnostic story (the cap is not in the XSD — it's a
   runtime validator).

## Debugging first boot

If OOBE-mini doesn't appear, the qcow2 didn't sysprep cleanly.
Check the Packer build log for sysprep exit codes — the post-install
sysprep step has a known quirk where the build can succeed while
sysprep silently leaves residue. Boot the qcow2 manually with
`qemu-system-aarch64` (see [`windows-utm.md`](windows-utm.md)) and
look at:

```powershell
# Inside the booted VM:
Get-Content C:\Windows\System32\Sysprep\Panther\setupact.log -Tail 200
Get-Content C:\Windows\System32\Sysprep\Panther\setuperr.log
Get-ScheduledTask -TaskName PackerBuildCleanup | Get-ScheduledTaskInfo
```

If `PackerBuildCleanup` shows `LastRunTime` of 1999-11-30, it didn't
fire and the build-time Administrator is still active. If `setuperr.log`
has anything substantive, sysprep itself failed.

If the seeded login didn't appear, the two first-boot tasks leave logs
and a marker under `C:\Windows\Setup\Scripts\`:

```powershell
Get-Content C:\Windows\Setup\Scripts\firstboot-seed.log     # seed consumer
Get-Content C:\Windows\Setup\Scripts\seed-applied.marker     # username, or NO-SEED
Get-Content C:\Windows\Setup\Scripts\packer-cleanup.log      # the lockdown gate
```

- Marker says `NO-SEED` → `FirstBootSeed` never found `windows-seed.json`.
  Check the CD is attached as `usb-storage` (qemu) / a CD/DVD drive (UTM)
  and that `cidata.iso` actually contains `windows-seed.json` at its root
  (`hdiutil attach output-cidata/cidata.iso` on the Mac to inspect).
- Marker says a username but you can't log in → check
  `firstboot-seed.log` for the `New-LocalUser`/`Add-LocalGroupMember`
  lines; a bad password (e.g. a hash) is the usual cause.
- `packer-cleanup.log` shows the `WARNING: no seed user` lines → the
  cleanup ran before the seed task landed its marker, or the seed failed.
  The build Administrator is still active as the recovery path.

## Where context lives

- Project context: [`../CLAUDE.md`](../CLAUDE.md)
- Windows Packer pipeline: [`../packer/windows-11-arm64/README.md`](../packer/windows-11-arm64/README.md)
- Seed format + `build-cidata.sh`: [`../packer/windows-11-arm64/seed/README.md`](../packer/windows-11-arm64/seed/README.md)
- Build-history runbook: [`windows-build-attempts.md`](windows-build-attempts.md)
- UTM consumption: [`windows-utm.md`](windows-utm.md)
- Open Windows work: [`../TODO.md`](../TODO.md)
- Sibling cloning docs: [Ubuntu](cloning-ubuntu.md), [Kali](cloning-kali.md)
