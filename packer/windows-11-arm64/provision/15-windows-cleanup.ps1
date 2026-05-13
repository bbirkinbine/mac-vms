# 15-windows-cleanup.ps1
#
# Disable telemetry, news feeds, OneDrive auto-mount, hibernate, and other
# stock-Windows behaviors that are noise in a lab base image.
#
# Mirrors the spirit of Ubuntu's 99-cleanup.sh — remove the parts of the OS
# that phone home or burn disk on the wrong things.
#
# Lifted as-is from homelab/packer/windows-11-base/provision/15-windows-cleanup.ps1
# (all settings are registry / powercfg / DISM — arch-agnostic).

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

Write-Host "=== 15-windows-cleanup ==="

# ----------------------------------------------------------------------
# Telemetry / diagnostic data
# ----------------------------------------------------------------------
Write-Host "Setting diagnostic data to minimum (Required only)..."
$dataCollection = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
New-Item -Path $dataCollection -Force | Out-Null
Set-ItemProperty -Path $dataCollection -Name "AllowTelemetry" -Value 0 -Type DWord
Set-ItemProperty -Path $dataCollection -Name "AllowDeviceNameInTelemetry" -Value 0 -Type DWord

# Disable Customer Experience Improvement Program scheduled tasks
Get-ScheduledTask -TaskPath "\Microsoft\Windows\Customer Experience Improvement Program\" -ErrorAction SilentlyContinue |
    Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null

# ----------------------------------------------------------------------
# Hibernation off (saves ~RAM-size disk)
# ----------------------------------------------------------------------
Write-Host "Disabling hibernation..."
& powercfg /hibernate off

# ----------------------------------------------------------------------
# News / Widgets / Cortana / Bing search
# ----------------------------------------------------------------------
Write-Host "Disabling news feed and widgets..."
$dsh = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"
New-Item -Path $dsh -Force | Out-Null
Set-ItemProperty -Path $dsh -Name "AllowNewsAndInterests" -Value 0 -Type DWord

Write-Host "Disabling Cortana..."
$ws = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
New-Item -Path $ws -Force | Out-Null
Set-ItemProperty -Path $ws -Name "AllowCortana" -Value 0 -Type DWord
Set-ItemProperty -Path $ws -Name "DisableWebSearch" -Value 1 -Type DWord
Set-ItemProperty -Path $ws -Name "ConnectedSearchUseWeb" -Value 0 -Type DWord

# ----------------------------------------------------------------------
# OneDrive auto-mount
# ----------------------------------------------------------------------
Write-Host "Removing OneDrive..."
$onedriveSetup = "$env:SystemRoot\System32\OneDriveSetup.exe"
if (Test-Path $onedriveSetup) {
    & $onedriveSetup /uninstall
}
$onedriveSetup64 = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
if (Test-Path $onedriveSetup64) {
    & $onedriveSetup64 /uninstall
}

# ----------------------------------------------------------------------
# Microsoft Store auto-update
# ----------------------------------------------------------------------
Write-Host "Disabling Microsoft Store auto-update..."
$store = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore"
New-Item -Path $store -Force | Out-Null
Set-ItemProperty -Path $store -Name "AutoDownload" -Value 2 -Type DWord

# ----------------------------------------------------------------------
# Windows Update — leave service installed but disable auto-install/reboot.
# Downstream consumers (cloud-init runcmd, Ansible) re-enable per role.
# ----------------------------------------------------------------------
Write-Host "Disabling Windows Update auto-install..."
$au = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
New-Item -Path $au -Force | Out-Null
Set-ItemProperty -Path $au -Name "NoAutoUpdate" -Value 1 -Type DWord
Set-ItemProperty -Path $au -Name "AUOptions" -Value 1 -Type DWord  # 1 = never check

# ----------------------------------------------------------------------
# Disk cleanup — release space from update install + temp
# ----------------------------------------------------------------------
Write-Host "Running DISM image cleanup..."
& dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase

Write-Host "Clearing %TEMP%..."
Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "=== 15-windows-cleanup done ==="
