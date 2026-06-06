# 20-harden.ps1
#
# Enable the two remote-login paths the seeded user needs: RDP (with NLA)
# and OpenSSH Server. Ported from
# homelab/packer/windows-11-base/provision/20-harden.ps1, but trimmed to
# just the remote-access posture.
#
# Deliberately NOT ported: the homelab script's default-deny inbound
# firewall, LLMNR/NetBIOS/SMBv1 disables, and audit-policy block. Two
# reasons: (1) this base stays close to stock — broader hardening is a
# downstream role/Ansible concern, same philosophy as the Linux bases;
# (2) flipping DefaultInboundAction to Block mid-build runs over the live
# WinRM session that the remaining provisioners (30, 99) depend on, an
# avoidable risk for a throwaway-lab image. Add stricter controls per
# role, not in the universal base.
#
# All cmdlets here are arch-agnostic (registry + firewall + capability),
# so the script ports to ARM64 unchanged.

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

Write-Host "=== 20-harden ==="

# ----------------------------------------------------------------------
# RDP — enabled with Network-Level Authentication. Roles narrow the source.
# ----------------------------------------------------------------------
Write-Host "Enabling RDP with Network-Level Authentication..."
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
    -Name "fDenyTSConnections" -Value 0 -Type DWord
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
    -Name "UserAuthentication" -Value 1 -Type DWord
Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue

# ----------------------------------------------------------------------
# OpenSSH Server — installed, running, allowed in firewall. Mirrors the
# SSH posture of the Ubuntu base so the seeded user can SSH in directly.
# ----------------------------------------------------------------------
Write-Host "Installing OpenSSH Server..."
$ssh = Get-WindowsCapability -Online -Name "OpenSSH.Server*"
if ($ssh.State -ne "Installed") {
    Add-WindowsCapability -Online -Name $ssh.Name | Out-Null
}
Set-Service -Name sshd -StartupType Automatic
Start-Service -Name sshd

# Default shell for SSH sessions is PowerShell, not cmd.
New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
    -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force | Out-Null

# Firewall rule for SSH on 22 (the OpenSSH capability usually adds one, but
# make it idempotent and explicit).
if (-not (Get-NetFirewallRule -Name "sshd-tcp-in" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -Name "sshd-tcp-in" -DisplayName "OpenSSH Server (sshd) Inbound" `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}

Write-Host "=== 20-harden done ==="
