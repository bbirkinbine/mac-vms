# 30-install-cloudbase-init.ps1
#
# STUB — needs an ARM64 cloudbase-init installer URL.
#
# The homelab script uses
# https://www.cloudbase.it/downloads/CloudbaseInitSetup_Stable_x64.msi
# which is x86_64 only. Check whether cloudbase.it publishes an ARM64
# MSI; if not, either:
#   - Build cloudbase-init from source for ARM64 (Python wheel + a
#     pythonized service wrapper — non-trivial),
#   - Use a third-party arm64 build (verify provenance), or
#   - Skip cloudbase-init entirely and run a NoCloud-style PowerShell
#     bootstrap at first boot via a scheduled task that reads
#     user-data from an attached unattend ISO.
#
# Once installed, the conf-file BOM bug applies regardless of arch:
# write the .conf file with [System.IO.File]::WriteAllText and
# UTF8Encoding($false), not Set-Content -Encoding UTF8 (which writes a
# BOM and breaks oslo_config's INI parser). See homelab notes.
#
# Until this lands, clones won't have an automatic per-VM identity
# mechanism. See docs/cloning-and-cloud-init.md "Windows — the planned
# path" for the design and the two viable approaches.

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

Write-Host "=== 30-install-cloudbase-init (STUB) ==="
Write-Host "TODO: source an ARM64 cloudbase-init installer, then port"
Write-Host "      homelab/packer/windows-11-base/provision/30-install-cloudbase-init.ps1"
Write-Host "=== 30-install-cloudbase-init done (no-op) ==="
