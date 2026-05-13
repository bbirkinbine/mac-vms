# 20-harden.ps1
#
# STUB — port from
# homelab/packer/windows-11-base/provision/20-harden.ps1.
#
# Intent: enable RDP with NLA, install OpenSSH Server, configure firewall
# rules for SSH/RDP, set default SSH shell to PowerShell. The homelab
# script is mostly arch-agnostic (Add-WindowsCapability, registry, firewall
# cmdlets) and should port with minimal changes, but it needs a real build
# to verify nothing depends on x86-only behavior.
#
# Next session: port the homelab file in full, then run the Windows build
# end-to-end to confirm sshd installs cleanly on Windows 11 ARM64.

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

Write-Host "=== 20-harden (STUB) ==="
Write-Host "TODO: port homelab/packer/windows-11-base/provision/20-harden.ps1"
Write-Host "=== 20-harden done (no-op) ==="
