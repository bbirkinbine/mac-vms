# Cloning the Windows base image and creating a per-VM identity

> ## Status: verified end-to-end (2026-06-06)
>
> The per-VM identity flow has been walked end-to-end on a fresh
> `just build-windows` artifact: a COW clone booted with a seed CD,
> `FirstBootSeed` created the seeded user (in Administrators) and
> installed its SSH key, `PackerBuildCleanup` then disabled the build
> Administrator, both tasks self-destructed, and the seeded user logged
> in over SSH using the injected key. The pieces:
> `provision/30-install-firstboot-seed.ps1` installs the `FirstBootSeed`
> task; `seed/build-cidata.sh` builds the seed CD; `provision/99-sysprep.ps1`
> coordinates so the build Administrator is only locked down after a seed
> login lands. `just run-windows --seed <file>` drives the whole clone +
> seed + boot the repo way.

This is the runbook for what happens **after** `just build-windows`
finishes — how to consume the sysprep'd qcow2 and get a usable VM.

Windows is structurally different from the Linux pipelines: there's no
cloudbase-init build for ARM64, so instead of a metadata service the
image carries a small first-boot consumer (`FirstBootSeed`) that reads
a JSON seed off an attached CD and injects the login. The seed CD is
the Windows analogue of the Linux `cidata.iso`.

## Mental model — three layers

All three layers are wired, the same as the Linux pipelines (just under
qemu instead of Tart).

| Layer | What | Where | Status |
| --- | --- | --- | --- |
| 1. **Packer** | Sysprep'd Win11 ARM64 qcow2 | [`packer/windows-11-arm64/output-windows-11-arm64/`](../packer/windows-11-arm64/) | Working |
| 2. **Clone** | `just spawn windows` / `just run-windows`, or a manual `qemu-img create -b <base>.qcow2 -F qcow2` / UTM clone | Justfile, shell, or UTM | Working |
| 3. **Per-VM identity injection** | hostname / user / SSH key applied on first boot | JSON seed CD + the in-image `FirstBootSeed` task | Working (verified 2026-06-06) — see [Seeded flow](#seeded-flow-recommended) |

Why the Tart-based Linux path can't host Windows here: three layered
blockers (no Windows VM config in Tart's source, no TPM in Apple
Virtualization.framework, AVF only exposes virtio buses to non-macOS
guests and ARM WinPE has no in-box viostor). See
[`windows-build-attempts.md`](windows-build-attempts.md) §1 for the
full diagnostic story. Consumption is via UTM or
`qemu-system-aarch64` directly ([`windows-utm.md`](windows-utm.md)).

## Seeded flow (recommended)

This is the automated path: boot a clone with a seed attached, get a
configured login with no OOBE clicking. It has sensible defaults, so the
zero-config version needs no seed file at all:

```bash
just build-windows         # if you haven't already
just run-windows --seed    # defaults: user 'admin', your ~/.ssh keys, random password
```

That clones the base, builds a seed CD from defaults (user `admin`,
hostname `windows`, every `~/.ssh/id_*.pub` auto-injected, a strong random
password **printed in the output**), attaches it as a `usb-storage` CD,
and forwards host ports. Once first boot finishes:

```bash
ssh -p 2222 admin@127.0.0.1              # key login; or RDP 127.0.0.1:13389 with the printed password
```

To customize, write a seed and pass it — every field is optional (see
[`seed/README.md`](../packer/windows-11-arm64/seed/README.md)):

```bash
cd packer/windows-11-arm64
cp seed/lab-seed.example.json seed/lab-seed.json
$EDITOR seed/lab-seed.json        # set any of: username, password, hostname, ssh keys
just run-windows --fresh --seed packer/windows-11-arm64/seed/lab-seed.json
```

`just run-windows --seed` is the seeded analogue of the Linux `just spawn`
flow: it runs `seed/build-cidata.sh` for you, attaches the resulting
`cidata.iso` as a `usb-storage` CD (ARM `virt` has no IDE/SATA), and
forwards host ports so the clone is reachable without console access.

### Doing it by hand (UTM, or manual qemu)

If you'd rather drive it yourself — build the CD with
`./seed/build-cidata.sh` (→ `output-cidata/cidata.iso`) and attach it:

UTM path:

```text
open -a UTM
# File → New → Virtualize → Other → Skip ISO Boot
# Edit VM → System: ARM64 / QEMU virt / 8 GiB / 4 cores; TPM + Secure Boot on
# Drives → Import → output-windows-11-arm64/windows-11-arm64-base   (the disk)
# Drives → New → CD/DVD → import output-cidata/cidata.iso           (the seed)
# Play.
```

Manual qemu — the seed CD must be a `usb-storage` device:

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

## Multiple instances (`just spawn windows`)

`just run-windows --seed` is single-VM (fixed COW disk + fixed host
ports). To run a **fleet**, use the spawn command — `just spawn windows`
delegates to the Windows fleet manager (`spawn-windows.sh`), so the same
verb works for all three OSes even though Windows runs under qemu and
ubuntu/kali run under Tart:

```bash
just spawn windows               # win-<next-free-N>   (= just spawn-windows)
just spawn windows -c 3          # three at once
just spawn windows -n devbox     # explicit name
just spawn windows --seed packer/windows-11-arm64/seed/lab-seed.json   # base seed, hostname per-instance
```

Each instance gets its own COW disk + NVRAM (the base qcow2 stays
sysprep-fresh), a seed CD with `hostname = instance name` and user
`admin`, and its generated admin password appended to `.env.windows-vms`
(gitignored) — spawn passes `build-cidata.sh --env`, so passwords never
hit stdout:

```bash
# .env.windows-vms
WINVM_WINDOWS_1_PASSWORD='...'
WINVM_WINDOWS_2_PASSWORD='...'
```

### Networking: why per-VM SSH ports (and not DHCP like Linux)

This differs from the Linux pipelines, and the reason is the hypervisor.
Tart (Ubuntu/Kali) sets up Apple `vmnet` shared networking for you, so
each Linux VM gets its own DHCP IP and `tart ip <name>` finds it — for
free, no sudo, because Tart holds the vmnet entitlement. Windows runs
under raw qemu, whose two macOS options are user-mode NAT (no privileges)
or vmnet (own IP, but qemu can only open it as **root**). The fleet
defaults to NAT so `just spawn windows` stays sudo-free like its Linux
sibling — the cost is the localhost port-offsets below.

By default, then, the fleet uses qemu **user-mode NAT**: every VM shares
the host's loopback IP, so each one's guest `:22`/`:3389` is forwarded to
a distinct host port, scanned from SSH `2222+`, RDP `13389+`, VNC `5950+`.
A host port binds once, so the VMs can't share `:22` — hence the offsets.
(The Packer *build* uses the same user-mode networking, forwarding WinRM
to an auto-picked host port.) After first boot (a few minutes):

```bash
ssh admin@127.0.0.1 -p 2222      # windows-1   (key login; password in .env.windows-vms for RDP)
ssh admin@127.0.0.1 -p 2223      # windows-2
```

For the Tart-like "each VM has its own IP, reachable on the normal `:22`",
pass **`--bridged`**, which uses macOS **vmnet** instead of NAT. vmnet
needs root, so it must run under sudo:

```bash
sudo just spawn windows --bridged -c 2
```

Each VM then gets its own IP on a shared, host-reachable subnet (and a
deterministic MAC). Discovery isn't as turnkey as NAT — find a VM's IP
from its VNC console (`ipconfig`) or your `arp` table, then
`ssh admin@<ip>`. Note a bridged instance's qemu runs as root, so its
teardown needs `sudo just cleanup-windows-vms`.

### List and tear down

Windows VMs are plain qemu processes, not Tart-managed, so `tart list`
can't see them — use `just list-windows` (and `just list` shows both
Tart VMs and Windows instances):

```bash
just list-windows                        # name, running state, ssh/RDP access, VNC
just list                                # Tart VMs + Windows instances together

just cleanup-windows-vms                 # stop qemu/swtpm, remove disks, prune .env
just cleanup-windows-vms -n windows-2    # just one
just cleanup-vms windows                 # same teardown via the unified verb
```

Per-instance state (disk, NVRAM, cidata, pidfiles, logs, `meta`) lives
under `packer/windows-11-arm64/output-windows-11-arm64/instances/<name>/`
(gitignored). VMs run headless; attach a VNC viewer to
`127.0.0.1:<5900+display>` to watch one boot.

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
