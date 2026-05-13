# windows.pkr.hcl — Windows 11 ARM64 base image, built via Packer's qemu
# source on Apple Silicon.
#
// Tart can't host Win11 (no TPM 2.0, no Secure Boot — both are Win11 system
// requirements). The qemu-iso path solves both: swtpm provides a virtual
// TPM 2.0, and edk2 (the UEFI firmware QEMU ships) supports Secure Boot
// capability. The Apple HVF accelerator gives us near-native performance
// on ARM64.
//
// Output is a qcow2 disk image. UTM consumes it directly (Import existing
// disk image), or you can boot via `qemu-system-aarch64` directly if you
// want to stay in terminal-land.
//
// scripts/build-windows.sh starts swtpm in the background before invoking
// Packer and exports PKR_VAR_swtpm_socket_path; it also stops swtpm on
// wrapper exit.

packer {
  required_version = ">= 1.10.0"
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

source "qemu" "windows" {
  vm_name          = var.vm_name
  output_directory = var.output_directory

  // Windows install ISO. The wrapper validates the file exists and verifies
  // SHA256 against WINDOWS_ISO_SHA256 (if set) before invoking Packer; we
  // tell Packer "none" so it doesn't recompute the same hash.
  iso_url      = var.iso_path
  iso_checksum = "none"

  cpus           = var.cpu_count
  memory         = var.memory_gb * 1024
  disk_size      = "${var.disk_size_gb}G"
  format         = "qcow2"
  disk_interface = "virtio"
  net_device     = "virtio-net-pci"

  // ARM64 + Apple Silicon HVF. gic-version=max selects GICv3, the modern
  // ARM interrupt controller. cpu_model="host" is required for HVF on
  // Apple Silicon.
  //
  // Notably: do NOT set `virtualization=on` on the machine type — HVF
  // can't pass nested-virt extensions through to the guest, and qemu
  // refuses to start with a "mach-virt: HVF does not support providing
  // Virtualization extensions to the guest CPU" error.
  //
  // qemu_binary points at a wrapper script that injects TPM 2.0 args
  // (swtpm socket + tpm-tis-device) on top of whatever Packer generates.
  // We can't do this via the `qemuargs` config option — that REPLACES
  // Packer's auto-generated args entirely, killing the disk/CD/net/EFI
  // setup. The wrapper appends instead. See scripts/qemu-with-tpm.sh.
  qemu_binary  = var.qemu_binary
  machine_type = "virt,gic-version=max"
  accelerator  = "hvf"
  cpu_model    = "host"

  // UEFI firmware. The vars file (NVRAM) is the writable EFI variable
  // store; Packer copies the template per-build into the output directory.
  efi_boot          = true
  efi_firmware_code = "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
  efi_firmware_vars = "/opt/homebrew/share/qemu/edk2-arm-vars.fd"

  // Packer builds a small ISO from these files and attaches it as a second
  // CD-ROM. Windows Setup probes attached media for Autounattend.xml at the
  // root and applies it before the language picker — no boot_command
  // keystrokes needed.
  cd_files = ["./Autounattend.xml"]
  cd_label = "UNATTEND"

  // Communicator. WinRM listens on 5985; Packer's qemu source arranges the
  // host port forwarding automatically (user-mode networking + hostfwd).
  communicator   = "winrm"
  winrm_username = var.build_username
  winrm_password = var.build_password
  winrm_timeout  = "60m"
  winrm_port     = 5985

  // Headed for now — QEMU's display is more reliable than Tart's for
  // Windows-on-ARM. Flip to true once builds are routine.
  headless = false

  // QEMU on macOS uses Cocoa (Apple's native UI), not GTK. Packer's qemu
  // plugin defaults `-display gtk` when not headless, which fails to
  // launch on macOS with "Parameter 'type' does not accept value 'gtk'".
  display = "cocoa"

  // Windows installer's EFI bootloader shows a "Press any key to boot
  // from CD or DVD" prompt for ~5 seconds. If no key is pressed, the
  // firmware skips the CD and falls through to EFI Shell (or nothing).
  // Spam <enter> via VNC for ~15 seconds starting 1 second after VM
  // start — at least one keystroke is guaranteed to land in the prompt
  // window regardless of exactly when EFI POST finishes.
  boot_wait = "1s"
  boot_command = [
    "<enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter><wait1><enter>"
  ]
}

build {
  sources = ["source.qemu.windows"]

  // Provisioner pipeline parallels the homelab Windows base:
  //   00 — preamble (identity check, version dump, OOBE settle)
  //   15 — disable telemetry, OneDrive, news, hibernate
  //   20 — STUB. Port homelab harden script (RDP + OpenSSH Server)
  //   30 — STUB. cloudbase-init install needs an ARM64 installer URL
  //   99 — install PackerBuildCleanup scheduled task + sysprep generalize
  provisioner "powershell" {
    scripts = [
      "provision/00-wait-for-winrm.ps1",
      "provision/15-windows-cleanup.ps1",
      "provision/20-harden.ps1",
      "provision/30-install-cloudbase-init.ps1",
    ]
  }

  // Sysprep terminates the WinRM session as part of /generalize. Packer
  // treats that disconnect as an error by default; valid_exit_codes lets
  // it complete cleanly.
  provisioner "powershell" {
    scripts          = ["provision/99-sysprep.ps1"]
    valid_exit_codes = [0, 2300218]
  }
}
