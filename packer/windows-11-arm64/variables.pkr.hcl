# variables.pkr.hcl — input surface for the Windows 11 ARM64 build.
#
# Values are passed in via PKR_VAR_* env vars by ../../scripts/build-windows.sh
# (which sources ../../.env.local).

variable "vhdx_path" {
  type        = string
  description = "Absolute path to the Microsoft-supplied Windows 11 ARM64 VHDX. Bring-your-own — not redistributable."
  # No default; the build wrapper fails fast if this isn't set.
}

variable "vm_name" {
  type        = string
  description = "Name of the resulting Tart VM in ~/.tart/vms/."
  default     = "windows-11-arm64-base"
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
  default     = 64
}

# Build-time credentials. Must match the password set by Autounattend.xml.
# Build-only, intentionally weak; sysprep at end of build resets/clears.

variable "build_username" {
  type        = string
  description = "Username for WinRM/SSH provisioner connection during build."
  default     = "packer"
}

variable "build_password" {
  type        = string
  description = "Password for the build user. Build-time only; cleared at sysprep."
  default     = "packer-build-only-Win11!"
  sensitive   = true
}
