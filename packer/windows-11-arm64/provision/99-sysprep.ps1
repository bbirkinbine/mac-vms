# 99-sysprep.ps1
#
# Final step: install first-boot credential cleanup, write post-sysprep
# unattend.xml, then sysprep generalize + shutdown. After this runs, the
# disk is the template artifact. Boot of any clone goes through OOBE-mini
# and (once cloudbase-init lands in 30-*) lands at cloudbase-init for
# per-clone identity.
#
# Sysprep terminates the WinRM session as part of generalize. Packer
# expects the disconnect — windows.pkr.hcl sets valid_exit_codes for the
# build block to allow it.
#
# Credential cleanup model. The build runs as Administrator with a known
# password (variables.pkr.hcl/var.build_password) so Packer can connect
# via WinRM. Sysprep /generalize clears the machine SID and drivers — it
# does NOT clear local-account passwords or the AutoAdminLogon registry
# values written by the answer file. Without explicit cleanup, every
# clone would inherit a known-password admin account discoverable from
# the public Autounattend.xml. Mirroring the Ubuntu base's
# packer-cleanup.service, we defer the credential teardown to a one-shot
# scheduled task that fires AtStartup on the first boot of every clone,
# then self-destructs. Sysprep preserves scheduled-task definitions
# across /generalize, so the task rides into every clone unchanged.
# Templates never power on, so the task never fires on the template
# itself.
#
# Ported from homelab/packer/windows-11-base/provision/99-sysprep.ps1
# with two changes:
#   - cloudbase-init pre-check downgraded from `throw` to a warning,
#     since 30-install-cloudbase-init.ps1 is currently a stub.
#   - unattend XML uses processorArchitecture="arm64".

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

Write-Host "=== 99-sysprep ==="

# Soft check: warn if cloudbase-init isn't installed. Once 30-* lands,
# tighten this back to `throw`.
$cbi = Get-Service -Name "cloudbase-init" -ErrorAction SilentlyContinue
if ($null -eq $cbi) {
    Write-Host "WARN: cloudbase-init service not found. Clones will not get per-VM identity from a cloud-init seed."
    Write-Host "      See provision/30-install-cloudbase-init.ps1 for the planned shape."
} elseif ($cbi.Status -eq "Running") {
    Write-Host "Stopping cloudbase-init service..."
    Stop-Service -Name "cloudbase-init" -Force
}

# Install first-boot cleanup script under C:\Windows\Setup\Scripts (a
# Microsoft-blessed location for OEM/setup scripts that survives sysprep).
# The script is wrapped in a verbatim here-string so $vars inside are
# LITERAL at install time — they evaluate when the cleanup script itself
# runs on the clone, not now.
$cleanupDir    = "$env:SystemRoot\Setup\Scripts"
$cleanupScript = "$cleanupDir\packer-cleanup.ps1"
if (-not (Test-Path $cleanupDir)) {
    New-Item -ItemType Directory -Path $cleanupDir -Force | Out-Null
}

$cleanupBody = @'
# packer-cleanup.ps1 — first-boot credential teardown for clones of the
# Windows 11 ARM64 base template. Installed by provision/99-sysprep.ps1
# and scheduled to fire AtStartup as SYSTEM. One-shot: self-destructs at
# the end so it cannot fire twice.
#
# Order is load-bearing:
#   1. Wait for cloudbase-init to finish so per-clone user creation has
#      already landed before we remove the build-Administrator path.
#   2. Rotate Administrator's password to a 32-byte random value before
#      disabling. Defense in depth — if anything later re-enables the
#      account, the embedded build password from the public
#      Autounattend.xml no longer works.
#   3. Disable the built-in Administrator account.
#   4. Clear AutoAdminLogon registry values written by the answer file
#      (DefaultPassword is an LSA secret; we delete the value to prevent
#      future use).
#   5. Self-destruct: unregister the scheduled task, remove this script.

$ErrorActionPreference = 'Stop'
$logPath = 'C:\Windows\Setup\Scripts\packer-cleanup.log'

function Write-CleanupLog($msg) {
    "$([DateTime]::UtcNow.ToString('o')) $msg" | Add-Content -Path $logPath -Encoding UTF8
}

try {
    Write-CleanupLog '=== packer-cleanup starting ==='

    # 1. Wait for cloudbase-init to reach Stopped (it auto-stops after
    #    its Plugins phase). Bound by ~120s — a stuck service must not
    #    block the credential lockdown forever.
    $cbi = Get-Service -Name 'cloudbase-init' -ErrorAction SilentlyContinue
    if ($cbi) {
        $deadline = (Get-Date).AddSeconds(120)
        while ($cbi.Status -ne 'Stopped' -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 5
            $cbi.Refresh()
        }
        Write-CleanupLog "cloudbase-init final status: $($cbi.Status)"
    } else {
        Write-CleanupLog 'cloudbase-init service not present (skipping wait)'
    }

    # 2. Rotate Administrator password to a strong random value.
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $randomPw = [Convert]::ToBase64String($bytes) + '!Aa1'
    & net.exe user Administrator $randomPw | Out-Null
    Write-CleanupLog 'Administrator password rotated'

    # 3. Disable the account. /active:no flips the UF_ACCOUNTDISABLE flag.
    & net.exe user Administrator /active:no | Out-Null
    Write-CleanupLog 'Administrator account disabled'

    # 4. Clear AutoAdminLogon registry values. AutoAdminLogon is a string
    #    "0"/"1"; the rest are simple values that we remove entirely.
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $winlogon -Name 'AutoAdminLogon' -Value '0' -Type String -ErrorAction SilentlyContinue
    foreach ($name in 'DefaultPassword','DefaultUserName','AutoLogonCount') {
        Remove-ItemProperty -Path $winlogon -Name $name -ErrorAction SilentlyContinue
    }
    Write-CleanupLog 'AutoAdminLogon registry values cleared'

    # 5. Self-destruct. Unregister first so a partial-failure leaves the
    #    task gone (next boot has no retry); then remove the script file.
    Unregister-ScheduledTask -TaskName 'PackerBuildCleanup' -Confirm:$false -ErrorAction SilentlyContinue
    Write-CleanupLog 'Scheduled task unregistered'
    Write-CleanupLog '=== packer-cleanup complete ==='
    Remove-Item -Path $PSCommandPath -Force -ErrorAction SilentlyContinue
} catch {
    Write-CleanupLog "ERROR: $_"
    throw
}
'@

Set-Content -Path $cleanupScript -Value $cleanupBody -Encoding UTF8
Write-Host "Wrote $cleanupScript"

# Register the scheduled task. AtStartup as SYSTEM, single-instance, with
# a 5-minute hard execution limit so a stuck wait loop can't park the
# task forever. -Force replaces any prior registration of the same name.
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$cleanupScript`""
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable
Register-ScheduledTask -TaskName "PackerBuildCleanup" `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description "One-shot first-boot cleanup of Packer build credentials. Self-destructs after running." `
    -Force | Out-Null
Write-Host "Registered PackerBuildCleanup scheduled task"

# Post-sysprep unattend: skip activation and OOBE prompts so clones come
# up cleanly. ARM64 in every <component>.
$unattendPath = "$env:SystemRoot\System32\Sysprep\unattend.xml"
@"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="arm64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
    </component>
    <component name="Microsoft-Windows-Security-SPP-UX" processorArchitecture="arm64"
               publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <SkipAutoActivation>true</SkipAutoActivation>
    </component>
  </settings>
</unattend>
"@ | Set-Content -Path $unattendPath -Encoding UTF8

Write-Host "Running sysprep /generalize /oobe /shutdown..."
$sysprep = "$env:SystemRoot\System32\Sysprep\sysprep.exe"
& $sysprep /generalize /oobe /shutdown /unattend:$unattendPath

# Sysprep starts shutdown async. The script should not return — Windows
# is in the process of going down. If we got here Packer will see the
# WinRM disconnect and conclude the build successfully.
Write-Host "Sysprep initiated. Shutdown in progress."
