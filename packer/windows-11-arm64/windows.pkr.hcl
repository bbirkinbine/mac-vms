# windows.pkr.hcl — Windows 11 ARM64 base image, built via Tart.
#
// SKELETON — needs verification against the current tart-cli plugin docs.
// The Windows-on-Tart story is less mature than Linux; expect the next
// session to revise this once the actual build runs end-to-end.
//
// Approach: rather than booting a Windows installer ISO with an
// Autounattend.xml (the homelab x86 path), this build attaches the
// Microsoft-supplied Windows 11 ARM64 VHDX directly. The VHDX boots into
// OOBE; a sysprep unattend file completes setup and lands at a known
// build-user login. WinRM provisioners then run any provisioners and
// sysprep --generalize before shutdown.

packer {
  required_version = ">= 1.10.0"
  required_plugins {
    tart = {
      version = ">= 1.12.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

source "tart-cli" "windows" {
  vm_name      = var.vm_name
  cpu_count    = var.cpu_count
  memory_gb    = var.memory_gb
  disk_size_gb = var.disk_size_gb

  // TODO(next-session): confirm exact tart-cli option for attaching an
  // existing VHDX as the boot disk. The plugin may want `from_iso` with a
  // VHDX path, or a separate `disk_image` option, or a `tart import`
  // workflow run outside Packer. Cirrus's CI examples mostly use prebuilt
  // base VMs (ghcr.io/cirruslabs/windows:...) rather than raw VHDX —
  // consider whether that's the better starting point.
  from_iso = [var.vhdx_path]

  // Windows boots into OOBE on first run. Unattend.xml under http/ would
  // be the cleanest answer if Tart can wire it; otherwise the
  // Autounattend.xml must be embedded in the VHDX before import via
  // dism or similar.
  http_directory = "http"

  communicator   = "winrm"
  winrm_username = var.build_username
  winrm_password = var.build_password
  winrm_timeout  = "60m"
  winrm_insecure = true
  winrm_use_ssl  = false

  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer Shutdown\""
}

build {
  sources = ["source.tart-cli.windows"]

  // No provisioners yet. Add .ps1 files under provision/ when first build
  // succeeds. Defender tuning / OneDrive removal / sysprep patterns from
  // the homelab Windows base may transfer conceptually but are
  // x86_64-specific in their current form.
}
