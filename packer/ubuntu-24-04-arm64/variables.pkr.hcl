# variables.pkr.hcl — input surface for the Ubuntu 24.04 ARM64 build.
#
# Values are passed in via PKR_VAR_* env vars by ../../scripts/build-ubuntu.sh
# (which sources ../../.env.local). Defaults are sensible for an M-series
# MacBook with 64+ GB of RAM.

variable "iso_url" {
  type        = string
  description = "URL of the Ubuntu Server 24.04 ARM64 live ISO."
  default     = "https://releases.ubuntu.com/24.04/ubuntu-24.04.1-live-server-arm64.iso"
}

variable "iso_checksum" {
  type        = string
  description = "Checksum of the Ubuntu ISO, e.g. 'sha256:abcd...'. Use 'file:URL' to fetch SHA256SUMS automatically."
  default     = "file:https://releases.ubuntu.com/24.04/SHA256SUMS"
}

variable "vm_name" {
  type        = string
  description = "Name of the resulting Tart VM in ~/.tart/vms/."
  default     = "ubuntu-24-04-arm64-base"
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
  default     = 40
}

# Build-time credentials. The cloud-init user-data must hash a matching
# password — keep these in sync. Default plaintext: 'packer-build-only'.
# Sysprep/cleanup at end of build removes the build user account.

variable "build_username" {
  type        = string
  description = "Username for SSH provisioner connection during build."
  default     = "packer"
}

variable "build_password" {
  type        = string
  description = "Password for the build user. Build-time only; removed at cleanup."
  default     = "packer-build-only"
  sensitive   = true
}
