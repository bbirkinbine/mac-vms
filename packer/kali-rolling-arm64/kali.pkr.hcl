# kali.pkr.hcl — Kali rolling ARM64 base image, built via Tart.
#
// The tart-cli builder boots an aarch64 VM under Apple Virtualization.framework,
// attaches a *repacked* Kali installer ISO, and runs Debian Installer in
// preseed mode. The repack happens in scripts/build-kali.sh — xorriso
// replaces the upstream boot/grub/grub.cfg with one that autoboots the
// installer with preseed/file=/cdrom/preseed/preseed.cfg, and bakes the
// templated preseed at /preseed/preseed.cfg on the ISO. That removes any
// boot_command keystroke tuning and any Packer HTTP server. After install
// completes and the VM reboots into the installed OS, shell provisioners
// finalize the baseline and seal the image.

packer {
  required_version = ">= 1.10.0"
  required_plugins {
    tart = {
      version = ">= 1.12.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

source "tart-cli" "kali" {
  vm_name      = var.vm_name
  cpu_count    = var.cpu_count
  memory_gb    = var.memory_gb
  disk_size_gb = var.disk_size_gb

  // Boot the repacked installer ISO. Tart attaches it as a CD-ROM and
  // boots. The tart-cli plugin's `from_iso` requires an *absolute local
  // path* — no HTTPS — so the build wrapper handles the download, SHA256
  // check, and xorriso repack, then hands us the cached path via
  // PKR_VAR_iso_path.
  from_iso = [var.iso_path]

  // The build user defined in http/preseed.cfg; SSH provisioners use this.
  ssh_username = var.build_username
  ssh_password = var.build_password

  // Longer than Ubuntu's 45m. The default kali-linux-headless meta-package
  // pulls down a much larger task than Ubuntu Server's stock set; a slow
  // mirror should not fail the build.
  ssh_timeout = "60m"

  // No boot_command — the repacked ISO's grub.cfg autoboots straight into
  // preseed mode (preseed/file=/cdrom/preseed/preseed.cfg), so there's
  // nothing to type. boot_wait gives the firmware a moment to hand off to
  // GRUB before Packer starts probing for SSH.
  boot_wait    = "5s"
  boot_command = []
}

build {
  sources = ["source.tart-cli.kali"]

  // Shell provisioners run after the install completes and the VM reboots
  // into the freshly-installed OS. Keep them minimal — heavier role-
  // specific setup belongs in downstream cloud-init or Ansible, not in
  // the base image.
  provisioner "shell" {
    execute_command = "echo '${var.build_password}' | {{ .Vars }} sudo -S -E bash '{{ .Path }}'"
    scripts = [
      "provision/00-baseline.sh",
      "provision/99-cleanup.sh",
    ]
  }
}
