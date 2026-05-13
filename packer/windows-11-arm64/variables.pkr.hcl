# variables.pkr.hcl — input surface for the Windows 11 ARM64 qemu build.
#
# Values come from PKR_VAR_* env vars set by ../../scripts/build-windows.sh
# (which sources ../../.env.local).

variable "iso_path" {
  type        = string
  description = "Absolute local path to the Microsoft-supplied Windows 11 ARM64 ISO (e.g. Win11_24H2_English_Arm64.iso). Bring-your-own — not redistributable, so the wrapper does not download it."
  # No default; the build wrapper fails fast if this isn't set.
}

variable "qemu_binary" {
  type        = string
  description = "Path to the qemu-system binary Packer invokes. The build wrapper points this at scripts/qemu-with-tpm.sh, which forwards Packer's args to qemu-system-aarch64 and appends the TPM 2.0 emulator wiring."
  # No default; the wrapper provides an absolute path.
}

variable "vm_name" {
  type        = string
  description = "Filename (without path) of the qcow2 disk image Packer writes into output_directory."
  default     = "windows-11-arm64-base.qcow2"
}

variable "output_directory" {
  type        = string
  description = "Directory Packer writes the build output into. Created if missing."
  default     = "output-windows-11-arm64"
}

variable "cpu_count" {
  type        = number
  description = "vCPUs assigned to the build VM."
  default     = 4
}

variable "memory_gb" {
  type        = number
  description = "RAM (in GiB) assigned to the build VM."
  default     = 8
}

variable "disk_size_gb" {
  type        = number
  description = "Disk size (in GiB) of the build VM."
  default     = 100
}

# Build-time credentials. Must match what Autounattend.xml writes for the
# Administrator account. Build-only, intentionally weak; rotated and
# disabled on first boot of any clone by the PackerBuildCleanup scheduled
# task installed in provision/99-sysprep.ps1.

variable "build_username" {
  type        = string
  description = "Username for WinRM provisioner connection during build."
  default     = "Administrator"
}

variable "build_password" {
  type        = string
  description = "Password for the build user. Build-time only; rotated + disabled by PackerBuildCleanup on first clone boot."
  default     = "packer-build-only-Win11!"
  sensitive   = true
}
