# ubuntu.pkr.hcl — Ubuntu 24.04 ARM64 base image, built via Tart.
#
// The tart-cli builder boots an aarch64 VM under Apple Virtualization.framework,
// attaches a *repacked* Ubuntu live ISO, and runs subiquity in autoinstall
// mode. The repack happens in scripts/build-ubuntu.sh — xorriso replaces the
// upstream grub.cfg with one that autoboots into autoinstall mode, and bakes
// the contents of ./http/ as a NoCloud seed at /nocloud/ on the ISO. That
// removes any boot_command keystroke tuning and any Packer HTTP server.
// After install completes and the VM reboots into the installed OS, shell
// provisioners harden the image and clear cloud-init state.

packer {
  required_version = ">= 1.10.0"
  required_plugins {
    tart = {
      version = ">= 1.12.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

source "tart-cli" "ubuntu" {
  vm_name      = var.vm_name
  cpu_count    = var.cpu_count
  memory_gb    = var.memory_gb
  disk_size_gb = var.disk_size_gb

  // Boot the repacked live installer ISO. Tart attaches it as a CD-ROM and
  // boots. The tart-cli plugin's `from_iso` requires an *absolute local path*
  // — no HTTPS — so the build wrapper handles the download, SHA256 check, and
  // xorriso repack, then hands us the cached path via PKR_VAR_iso_path.
  from_iso = [var.iso_path]

  // The build user defined in http/user-data; SSH provisioners use this.
  ssh_username = var.build_username
  ssh_password = var.build_password
  ssh_timeout  = "45m"

  // Shutdown is handled by the tart-cli plugin at the end of the build —
  // it issues PowerOff itself, then waits for the VM process to exit. The
  // source doesn't expose a `shutdown_command` attribute and doesn't need
  // one. (Earlier iterations of this file added an explicit
  // `nohup shutdown -P now` provisioner; that worked but raced the plugin's
  // own PowerOff and produced a noisy "shutdown already in progress" log.)

  // No boot_command — the repacked ISO's grub.cfg autoboots straight into
  // autoinstall mode (ds=nocloud;s=/cdrom/nocloud/), so there's nothing to
  // type and no GRUB-edit-over-VNC fragility. boot_wait gives the kernel a
  // moment to come up before Packer starts probing for SSH.
  boot_wait    = "5s"
  boot_command = []
}

build {
  sources = ["source.tart-cli.ubuntu"]

  // Shell provisioners run after the install completes and the VM reboots
  // into the freshly-installed OS. Keep them minimal — heavier role-specific
  // setup belongs in downstream cloud-init or Ansible, not in the base image.
  provisioner "shell" {
    execute_command = "echo '${var.build_password}' | {{ .Vars }} sudo -S -E bash '{{ .Path }}'"
    scripts = [
      "provision/00-baseline.sh",
      "provision/99-cleanup.sh",
    ]
  }
}
