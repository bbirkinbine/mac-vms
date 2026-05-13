# 00-wait-for-winrm.ps1
#
# First provisioner step. WinRM is already up (Packer connected to run this),
# but settle a few things before later scripts run:
#   - Confirm we're running as Administrator
#   - Print version info to the build log for diagnostics
#   - Wait for any post-OOBE first-logon scripts to finish
#
# Keep this script idempotent and read-mostly. Real changes start in 10-*.
#
# Lifted as-is from homelab/packer/windows-11-base/provision/00-wait-for-winrm.ps1
# (arch-agnostic — no x86-specific calls).

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

Write-Host "=== 00-wait-for-winrm ==="

# Identity check
$me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$pri = New-Object System.Security.Principal.WindowsPrincipal($me)
if (-not $pri.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Not running as Administrator. WinRM session must connect with admin privileges."
}
Write-Host "Running as: $($me.Name)"

# Version info for the build log
$os = Get-CimInstance Win32_OperatingSystem
Write-Host "OS:        $($os.Caption) ($($os.Version), build $($os.BuildNumber))"
Write-Host "Arch:      $env:PROCESSOR_ARCHITECTURE"
Write-Host "Computer:  $env:COMPUTERNAME"
Write-Host "PSVersion: $($PSVersionTable.PSVersion)"

# Wait for any background OOBE finalizers to settle. Empirically 10-30 sec.
Write-Host "Waiting 30s for post-OOBE settle..."
Start-Sleep -Seconds 30

Write-Host "=== 00-wait-for-winrm done ==="
