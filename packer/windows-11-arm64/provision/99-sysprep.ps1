# 99-sysprep.ps1
#
# Final step: install first-boot credential cleanup, write post-sysprep
# unattend.xml, then sysprep generalize + shutdown. After this runs, the
# disk is the template artifact. Boot of any clone runs FirstBootSeed
# (installed by 30-install-firstboot-seed.ps1) to inject a per-VM login
# from an attached seed CD, then PackerBuildCleanup to lock down the
# build Administrator.
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
# Ported from homelab/packer/windows-11-base/provision/99-sysprep.ps1.
# The homelab cleanup waits on the cloudbase-init service; this one waits
# on the FirstBootSeed marker file instead (no cloudbase-init on ARM64 —
# see 30-install-firstboot-seed.ps1) and refuses to disable the only admin
# account when no seed was applied. unattend XML uses
# processorArchitecture="arm64".

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

Write-Host "=== 99-sysprep ==="

# Precondition: 30-install-firstboot-seed.ps1 must have registered the
# FirstBootSeed task earlier in the pipeline. Without it, clones get no
# per-VM login and PackerBuildCleanup would have nothing to wait for.
if (-not (Get-ScheduledTask -TaskName "FirstBootSeed" -ErrorAction SilentlyContinue)) {
    throw "FirstBootSeed task not found. 30-install-firstboot-seed.ps1 must run before 99-sysprep.ps1."
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
#   1. Wait for FirstBootSeed to land its marker so the per-VM login has
#      already been created before we remove the build-Administrator path.
#   2. GATE: only lock down Administrator if a real seed user exists. If
#      the marker is NO-SEED (or never appears), leave Administrator
#      ACTIVE — disabling the only admin account on an unseeded clone
#      would brick it. The seeded path is the supported one.
#   3. Rotate Administrator's password to a 32-byte random value before
#      disabling. Defense in depth — if anything later re-enables the
#      account, the embedded build password from the public
#      Autounattend.xml no longer works.
#   4. Disable the built-in Administrator account.
#   5. Clear AutoAdminLogon registry values written by the answer file
#      (DefaultPassword is an LSA secret; we delete the value to prevent
#      future use). Done in every case — it can never cause a lockout.
#   6. Self-destruct: unregister the scheduled task, remove this script.

$ErrorActionPreference = 'Stop'
$logPath    = 'C:\Windows\Setup\Scripts\packer-cleanup.log'
$markerPath = 'C:\Windows\Setup\Scripts\seed-applied.marker'

function Write-CleanupLog($msg) {
    "$([DateTime]::UtcNow.ToString('o')) $msg" | Add-Content -Path $logPath -Encoding UTF8
}

try {
    Write-CleanupLog '=== packer-cleanup starting ==='

    # 1. Wait for FirstBootSeed to write its marker. Both tasks fire
    #    AtStartup; this poll is what orders them — we block here until the
    #    seed task lands the marker (or ~180s elapses). A stuck seed must
    #    not park the lockdown forever.
    $deadline = (Get-Date).AddSeconds(180)
    while (-not (Test-Path $markerPath) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
    }
    $seedUser = if (Test-Path $markerPath) { (Get-Content -Path $markerPath -Raw).Trim() } else { '' }
    Write-CleanupLog "seed marker: '$seedUser'"

    # 2. Gate. Lock down Administrator only when a replacement login exists.
    if ($seedUser -and $seedUser -ne 'NO-SEED') {
        # 3. Rotate Administrator password to a strong random value.
        $bytes = New-Object byte[] 24
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $randomPw = [Convert]::ToBase64String($bytes) + '!Aa1'
        & net.exe user Administrator $randomPw | Out-Null
        Write-CleanupLog 'Administrator password rotated'

        # 4. Disable the account. /active:no flips the UF_ACCOUNTDISABLE flag.
        & net.exe user Administrator /active:no | Out-Null
        Write-CleanupLog "Administrator account disabled (seed user '$seedUser' present)"
    } else {
        Write-CleanupLog 'WARNING: no seed user created (no CIDATA seed attached or seed failed).'
        Write-CleanupLog 'WARNING: leaving Administrator ACTIVE to avoid locking out the clone.'
        Write-CleanupLog 'WARNING: this clone still carries the public build password from Autounattend.xml.'
        Write-CleanupLog 'WARNING: attach a seed CD (see seed/README.md) or change the password manually.'
    }

    # 5. Clear AutoAdminLogon registry values in every case — this can
    #    never cause a lockout, only stop a stray auto-login. AutoAdminLogon
    #    is a string "0"/"1"; the rest are values we remove entirely.
    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $winlogon -Name 'AutoAdminLogon' -Value '0' -Type String -ErrorAction SilentlyContinue
    foreach ($name in 'DefaultPassword','DefaultUserName','AutoLogonCount') {
        Remove-ItemProperty -Path $winlogon -Name $name -ErrorAction SilentlyContinue
    }
    Write-CleanupLog 'AutoAdminLogon registry values cleared'

    # 6. Self-destruct. Unregister first so a partial-failure leaves the
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
