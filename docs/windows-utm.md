# Running Windows 11 ARM64 under UTM

The Windows base image is built by the Packer pipeline at
[`../packer/windows-11-arm64/`](../packer/windows-11-arm64/) — a sysprep'd
qcow2 under `./output-windows-11-arm64/`. This doc covers the two ways to
consume it: importing into UTM (graphical, what most users want) and
running directly with `qemu-system-aarch64` (terminal-friendly, for
automation).

If you'd rather install Windows interactively in UTM instead of building
via Packer, that path is at the bottom — but the Packer build is the
recommended primary path, since clones share the same provisioner state.

## Why UTM at all (vs Tart)

Tart can't host Win11 — three layered blockers (no Windows VM
configuration in Tart's source, no TPM in Apple Virtualization.framework,
and AVF only exposing virtio buses that ARM WinPE has no in-box driver
for; see [`windows-build-attempts.md`](windows-build-attempts.md) §1
for the full analysis). UTM is the Apple Silicon front-end for QEMU; it
ships TPM 2.0 + Secure Boot + USB controllers natively. The Packer build
also uses QEMU + swtpm under the hood, so an imported qcow2 keeps the
same platform shape it was built on.

## Prerequisites

```bash
brew install --cask utm
```

UTM 4.5+. Older versions don't expose Secure Boot toggles for ARM64
guests.

## Importing the Packer-built qcow2

After `just build-windows` produces
`packer/windows-11-arm64/output-windows-11-arm64/windows-11-arm64-base.qcow2`:

1. **Create a new VM** in UTM: **File → New → Virtualize → Other**.
2. **Skip the wizard's ISO step** — we already have a disk; pick **Skip
   ISO Boot** and finish.
3. **Right-click the new VM → Edit**.
4. Under **System**:
   - Architecture: **ARM64 (aarch64)**.
   - System: **QEMU virt** (latest).
   - CPU: leave at Default (Apple).
   - Memory: 8192 MB or higher.
   - CPU Cores: 4 or higher.
5. Under **Devices**:
   - **TPM**: enabled (this is why we're not on Tart).
   - Display: VirtIO.
   - Network: VirtIO.
6. Under **Drives**:
   - Delete the empty placeholder drive UTM created.
   - Click **New Drive** → **Import…** → point at the qcow2 produced by
     the Packer build.
   - Set the interface to **VirtIO**.
7. Under **System → Show Advanced Settings → UEFI Boot** → ensure UEFI is
   on. Secure Boot is recommended.

Save and **Play**. First boot lands at OOBE-mini — the `PackerBuildCleanup`
scheduled task fires AtStartup as SYSTEM, rotates the Administrator
password to 32 random bytes, disables the account, and self-removes
before networking comes up. Create your real local account from there.

## Running the qcow2 directly via QEMU

Skips UTM entirely; faster iteration if you live in the terminal.

```bash
# One-time: make a copy-on-write clone from the golden image so the base
# stays clean. Also copy the matching EFI vars file — Packer's qemu
# source seeds NVRAM during the install, and the qcow2 won't boot
# cleanly against a fresh edk2-arm-vars.fd template.
cd packer/windows-11-arm64/output-windows-11-arm64
qemu-img create -f qcow2 -b windows-11-arm64-base -F qcow2 mywork.qcow2
cp efivars.fd mywork-vars.fd

# Start swtpm. Path stays short so we don't blow macOS's 104-byte
# Unix-socket-path limit.
SWTPM_DIR="$(mktemp -d -t mywork.XXXXXX)"
swtpm socket \
  --tpmstate "dir=${SWTPM_DIR}" \
  --ctrl "type=unixio,path=${SWTPM_DIR}/s" \
  --tpm2 --daemon

# Boot. The args mirror what scripts/qemu-with-tpm.sh produces during
# the build:
#   - No virtualization=on — HVF refuses nested-virt passthrough.
#   - pflash for both EFI code (RO) and vars (RW) — -bios doesn't work
#     for Secure-Boot-aware boots from disk on edk2-aarch64.
#   - ramfb so EFI has a framebuffer to draw on (ARM virt has no
#     graphics device by default).
#   - qemu-xhci + usb-kbd + usb-tablet so the VM accepts input.
#   - tpm-tis-device wires swtpm into the guest.
#   - cocoa,zoom-to-fit=on lets you drag-resize the host window.
qemu-system-aarch64 \
  -machine virt,gic-version=max \
  -accel hvf \
  -cpu host \
  -smp 4 -m 8192 \
  -drive "if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-aarch64-code.fd" \
  -drive "if=pflash,format=raw,file=mywork-vars.fd" \
  -chardev "socket,id=chrtpm,path=${SWTPM_DIR}/s" \
  -tpmdev "emulator,id=tpm0,chardev=chrtpm" \
  -device "tpm-tis-device,tpmdev=tpm0" \
  -device "ramfb" \
  -device "qemu-xhci,id=usb" \
  -device "usb-kbd,bus=usb.0" \
  -device "usb-tablet,bus=usb.0" \
  -drive "file=mywork.qcow2,if=virtio,format=qcow2" \
  -device "virtio-net-pci,netdev=net0" \
  -netdev "user,id=net0" \
  -display "cocoa,zoom-to-fit=on"
```

## Snapshotting + clone-equivalent workflow

UTM has GUI snapshots: VM toolbar → **More → Save Snapshot**. The clone
equivalent of `tart clone base mywork` is **UTM → right-click VM → Clone**.

For the qemu-direct path: snapshots live in the qcow2 (`qemu-img snapshot`),
or you make additional backing-file children.

## Daily ergonomics

| Task | UTM | qemu direct |
| --- | --- | --- |
| Fresh experiment from base | Right-click → Clone | `qemu-img create -b base.qcow2 -F qcow2 new.qcow2` |
| Reset to clean state | Restore Snapshot → clean | Delete the cow file; remake |
| Snapshot before a risky change | More → Save Snapshot | `qemu-img snapshot -c name foo.qcow2` |
| Hand off to another Mac | Export → .utm bundle | `scp` the qcow2 |

## Interactive install in UTM (if you skip the Packer build)

If you'd rather install Windows interactively without using the Packer
pipeline:

1. Same setup as the import flow above, but:
   - In **Drives**, keep the empty 100 GB drive UTM creates.
   - In **CD/DVD**, attach the Windows 11 ARM64 ISO (`WINDOWS_ISO_PATH`).
2. **Play**. Windows Setup boots. Run through the language picker, OOBE,
   etc. manually.
3. At the Microsoft account screen: **Shift+F10** → `OOBE\BYPASSNRO` → VM
   reboots and lets you create a local account.
4. Install **UTM Guest Tools** (Menu → Drive Image Options → Install
   Windows Guest Tools, run `SPICEUtils.exe` inside the VM) for clipboard
   sharing and host-folder mounts.
5. Save a snapshot named `clean-install` to use as your "base."

This path doesn't get the provisioner pipeline's hardening or the
`PackerBuildCleanup` first-boot credential rotation — you're on your own
for those. Recommended only if the Packer build is broken or unavailable.

## Where context lives

- [`../packer/windows-11-arm64/README.md`](../packer/windows-11-arm64/README.md)
  — the Packer build that produces the qcow2.
- [`../CLAUDE.md`](../CLAUDE.md) — project context and tool-choice rationale.
- [`cloning-and-cloud-init.md`](cloning-and-cloud-init.md) — sibling doc for
  the Ubuntu Tart cloning path.
