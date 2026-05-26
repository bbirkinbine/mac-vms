# variables.pkr.hcl — input surface for the Kali rolling ARM64 build.
#
# Values are passed in via PKR_VAR_* env vars by ../../scripts/build-kali.sh
# (which sources ../../.env.local). Defaults are sensible for an M-series
# MacBook with 64+ GB of RAM.

// The tart-cli builder's from_iso only accepts an *absolute local path*, not
// an HTTPS URL. The build wrapper (scripts/build-kali.sh) handles the
// download + SHA256 verification, caches into ./packer_cache/iso/, runs
// xorriso to bake an autoboot grub.cfg + the staged preseed onto the ISO,
// then exports PKR_VAR_iso_path. You don't usually override this directly.
variable "iso_path" {
  type        = string
  description = "Absolute local path to the repacked Kali ARM64 installer ISO. Provided by the build wrapper."
}

variable "vm_name" {
  type        = string
  description = "Name of the resulting Tart VM in ~/.tart/vms/."
  default     = "kali-rolling-arm64-base"
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

# Build-time credentials. The preseed.cfg must hash a matching password —
# keep these in sync. Default plaintext: 'packer-build-only'. The deferred
# packer-cleanup one-shot removes this user on first boot of any clone (and
# on the base image itself the first time you `tart run` it), so don't
# treat the password as a real credential.

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

# Note: the Kali meta-package (kali-linux-headless / -core / -default /
# -everything) is *not* a Packer variable. The preseed.cfg containing the
# pkgsel/include line is xorriso-baked into the ISO before Packer ever
# sees it, so Packer can't template the value. The wrapper script reads
# KALI_META_PKG from .env.local and sed-substitutes the __KALI_META_PKG__
# placeholder in the staged preseed.cfg before the repack. See
# scripts/build-kali.sh and docs/kali-vs-ubuntu.md.
