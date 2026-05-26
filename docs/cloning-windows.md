# Cloning the Windows base image and creating a per-VM identity

This is the runbook for what happens **after** `just build-windows`
finishes — how to consume the sysprep'd qcow2 and get a usable VM.

Windows is structurally different from the Linux pipelines. There's no
cloud-init equivalent landed yet for the cidata-style "drop a seed
ISO, get a configured VM" flow — the qcow2 boots into OOBE-mini and
the local account is created **interactively** on first boot. See the
sibling Linux docs for the working cloud-init flows:
[Ubuntu](cloning-ubuntu.md), [Kali](cloning-kali.md).

## Mental model — three layers

The Linux pipelines have all three layers wired. Windows has the first
two; the third is the open work.

| Layer | What | Where | Status |
| --- | --- | --- | --- |
| 1. **Packer** | Sysprep'd Win11 ARM64 qcow2 | [`packer/windows-11-arm64/output-windows-11-arm64/`](../packer/windows-11-arm64/) | Working |
| 2. **Clone** | UTM clone or `qemu-img create -b <base>.qcow2 -F qcow2 new.qcow2` | UTM or shell | Working |
| 3. **Per-VM identity injection** | hostname / admin user / SSH key / RDP creds applied on first boot | NoCloud-shaped seed + a consumer | **Not implemented** — see end |

Why the Tart-based Linux path can't host Windows here: three layered
blockers (no Windows VM config in Tart's source, no TPM in Apple
Virtualization.framework, AVF only exposes virtio buses to non-macOS
guests and ARM WinPE has no in-box viostor). See
[`windows-build-attempts.md`](windows-build-attempts.md) §1 for the
full diagnostic story. Consumption is via UTM or
`qemu-system-aarch64` directly ([`windows-utm.md`](windows-utm.md)).

## Quick start (test VM with interactive account creation)

UTM path — easiest:

```bash
just build-windows   # if you haven't already
open -a UTM
# File → New → Virtualize → Other → Skip ISO Boot
# Edit VM → System: ARM64 / QEMU virt / 8 GiB / 4 cores; TPM + Secure Boot on
# Drives → Import → point at output-windows-11-arm64/windows-11-arm64-base
# Play.
```

Or terminal path — see
[`windows-utm.md`](windows-utm.md#running-the-qcow2-directly-via-qemu)
for the full `qemu-system-aarch64` invocation.

Either way, first boot lands at OOBE-mini. Walk through:

1. **Region / keyboard layout** → Next, Next.
2. **Network** — pick "I don't have internet" if it shows up (the
   bypass is already in the unattend but 24H2 sometimes re-prompts).
   If that option is missing, press `Shift+F10` → `OOBE\BYPASSNRO` →
   VM reboots and you'll get the local-account form.
3. **Local account** — enter a test account name + password. That's
   your login. The build-time Administrator is already disabled by
   `PackerBuildCleanup`; only this new account works.
4. Decline the data / Recall / Copilot opt-ins.

Once the desktop loads, you've got a usable test VM. Snapshot from UTM
(**VM toolbar → More → Save Snapshot**) so you can roll back to a
clean state without rerunning OOBE.

## What's already automated

- **Sysprep** runs at the end of the Packer build. The output qcow2
  is generalized — a fresh boot triggers OOBE-mini.
- **`PackerBuildCleanup` scheduled task** fires at first boot,
  rotating + disabling the build-time Administrator account. Clones
  are not reachable via the build-time credentials.
- **No automatic per-VM hostname / SSH-key / user-account injection.**
  This is the gap — see the next section.

## The cloudbase-init gap

A CIDATA ISO would be valid input, but the qcow2 has no NoCloud
consumer installed (see
[`packer/windows-11-arm64/provision/30-install-cloudbase-init.ps1`](../packer/windows-11-arm64/provision/30-install-cloudbase-init.ps1)
— still a stub).

[`cloudbase-init`](https://cloudbase.it/cloudbase-init/) has no
official ARM64 installer at
[`cloudbase.it/downloads/`](https://cloudbase.it/downloads/) as of
2026-05. Two viable paths if you need the cidata-style automation
before the official ARM64 build ships:

1. **Build cloudbase-init from source.** Python wheel + pythonized
   service wrapper. Non-trivial but tractable; the
   [cloudbase-init repo](https://github.com/cloudbase/cloudbase-init)
   is pure Python.
2. **NoCloud-style PowerShell bootstrap.** A scheduled task at first
   boot reads `user-data` from an attached unattend ISO and applies
   it. Bespoke, but matches the existing `PackerBuildCleanup`
   mechanism.

Open in [`../TODO.md`](../TODO.md).

## What NOT to do

1. **Don't rely on the build-time Administrator account.** It's
   disabled by `PackerBuildCleanup` at first boot. The clone is not
   reachable with the build credentials.
2. **Don't bake a permanent admin password into the base.** Every
   clone inherits it; rotating means rebuilding the base AND every
   existing VM.
3. **Don't put a hash where plaintext belongs.** Where cloud-init
   expects a `$6$<salt>$<hash>` on Linux, cloudbase-init takes
   plaintext on Windows and hashes it itself.
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

## Where context lives

- Project context: [`../CLAUDE.md`](../CLAUDE.md)
- Windows Packer pipeline: [`../packer/windows-11-arm64/README.md`](../packer/windows-11-arm64/README.md)
- Build-history runbook: [`windows-build-attempts.md`](windows-build-attempts.md)
- UTM consumption: [`windows-utm.md`](windows-utm.md)
- Open Windows work: [`../TODO.md`](../TODO.md)
- Sibling cloning docs: [Ubuntu](cloning-ubuntu.md), [Kali](cloning-kali.md)
