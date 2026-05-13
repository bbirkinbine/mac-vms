# ubuntu.pkr.hcl — Ubuntu 24.04 ARM64 base image, built via Tart.
#
// The tart-cli builder boots an aarch64 VM under Apple Virtualization.framework,
// attaches the Ubuntu live ISO, and runs subiquity in autoinstall mode. The
// installer fetches cloud-init data from a Packer-served HTTP endpoint
// (http/user-data + http/meta-data). After install completes and the VM
// reboots, shell provisioners harden the image and clear cloud-init state.
//
// TODO(next-session): verify exact boot_command keystrokes against the
// packer-plugin-tart README + the current Ubuntu 24.04 live ISO grub menu.
// The Linux ARM ISO uses GRUB rather than the BIOS-era boot prompt, so the
// `<tab>` autoinstall append happens at the grub edit step ('e'), not at a
// boot: prompt.

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

  // Boot the live installer ISO. Tart creates a fresh empty VM and attaches
  // the ISO as a CD-ROM, then boots it.
  from_iso = [var.iso_url]
  # iso_checksum = var.iso_checksum   // TODO(next-session): confirm whether the
  //                                      tart-cli builder validates ISO checksums
  //                                      directly or expects them on the download.

  // Packer serves files from this dir on a random port; the boot_command
  // points the kernel at {{ .HTTPIP }}:{{ .HTTPPort }}/ to fetch user-data.
  http_directory = "http"

  // The build user from http/user-data; SSH provisioners use this.
  ssh_username = var.build_username
  ssh_password = var.build_password
  ssh_timeout  = "45m"

  // After cleanup script runs, shut the VM down so Tart can finalize the image.
  shutdown_command = "sudo /sbin/shutdown -P now"

  // TODO(next-session): the boot_command below is a starting point — the
  // exact GRUB edit sequence for ARM64 Ubuntu 24.04 live needs verification.
  // Pattern is: <esc> to interrupt grub, 'e' to edit the highlighted entry,
  // arrow keys to the linux line, append autoinstall + ds=nocloud-net args,
  // <F10> to boot. Headless makes this brittle — consider running with
  // `display = "..."` and headed for the first successful pass, then
  // switching back to headless once the boot_command stabilizes.
  boot_wait = "10s"
  boot_command = [
    "<esc><wait>",
    "e<wait>",
    "<down><down><down><end>",
    " autoinstall ds=nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/",
    "<f10>",
  ]
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
    ]
  }
}
