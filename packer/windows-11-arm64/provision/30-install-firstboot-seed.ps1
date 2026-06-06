# 30-install-firstboot-seed.ps1
#
# ARM-native stand-in for cloudbase-init. cloudbase.it ships no official
# ARM64 build (checked 2026-06), so instead of installing a metadata
# service we install our own first-boot consumer: a one-shot scheduled
# task, FirstBootSeed, that fires AtStartup as SYSTEM on the first boot
# of every clone, reads a seed off an attached CD-ROM, and injects a
# working login. It then self-destructs.
#
# This mirrors the PackerBuildCleanup mechanism in 99-sysprep.ps1 — same
# install-script-as-here-string + Register-ScheduledTask shape — and the
# two coordinate via a marker file:
#
#   FirstBootSeed (this)        writes C:\Windows\Setup\Scripts\seed-applied.marker
#                               containing the created username, or "NO-SEED".
#   PackerBuildCleanup (99-*)   waits for that marker, and only rotates +
#                               disables the build Administrator when a real
#                               seed user was created. No seed => it leaves
#                               Administrator active rather than bricking
#                               the clone.
#
# Both tasks fire AtStartup; ordering is enforced by PackerBuildCleanup
# polling for the marker (it can start first and still block until this
# task lands the marker), the same way the homelab cleanup waits on the
# cloudbase-init service state.
#
# Seed format is JSON, not cloud-config YAML: Windows PowerShell 5.1 has
# no built-in YAML parser, and we own the consumer now, so JSON (native
# ConvertFrom-Json) is the robust choice. See seed/README.md.

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

Write-Host "=== 30-install-firstboot-seed ==="

$scriptsDir = "$env:SystemRoot\Setup\Scripts"
$seedScript = "$scriptsDir\firstboot-seed.ps1"
if (-not (Test-Path $scriptsDir)) {
    New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
}

# Verbatim here-string: $vars below are LITERAL at install time and only
# evaluate when firstboot-seed.ps1 runs on the clone.
$seedBody = @'
# firstboot-seed.ps1 — first-boot per-VM identity injection for clones of
# the Windows 11 ARM64 base template. Installed by
# provision/30-install-firstboot-seed.ps1 and scheduled to fire AtStartup
# as SYSTEM. One-shot: self-destructs at the end.
#
# Reads windows-seed.json off an attached CD-ROM (the cidata.iso built by
# seed/build-cidata.sh), creates/updates the local user it names, applies
# groups + SSH keys + hostname, then writes seed-applied.marker so
# PackerBuildCleanup knows whether a replacement login exists before it
# locks down the build Administrator.

$ErrorActionPreference = 'Stop'
$scriptsDir = "$env:SystemRoot\Setup\Scripts"
$logPath    = "$scriptsDir\firstboot-seed.log"
$markerPath = "$scriptsDir\seed-applied.marker"

function Write-SeedLog($msg) {
    "$([DateTime]::UtcNow.ToString('o')) $msg" | Add-Content -Path $logPath -Encoding UTF8
}

function Set-Marker($value) {
    # The marker is the handshake with PackerBuildCleanup; ASCII, no BOM,
    # trimmed on read. A value of NO-SEED tells cleanup to skip lockdown.
    [System.IO.File]::WriteAllText($markerPath, $value, (New-Object System.Text.ASCIIEncoding))
}

function Complete-Seed {
    # Self-destruct: unregister the task first (so a later failure can't
    # re-fire it), then remove this script.
    Unregister-ScheduledTask -TaskName 'FirstBootSeed' -Confirm:$false -ErrorAction SilentlyContinue
    Write-SeedLog 'FirstBootSeed task unregistered'
    Remove-Item -Path $PSCommandPath -Force -ErrorAction SilentlyContinue
}

try {
    Write-SeedLog '=== firstboot-seed starting ==='

    # 1. Locate windows-seed.json. Two wrinkles:
    #    - WinPE/Windows drive-letter assignment on ARM64 is
    #      non-deterministic, so scan letters rather than assume D:.
    #    - AtStartup fires early; the optical drive may not be enumerated
    #      yet. Retry the scan for ~60s before concluding no seed. (The
    #      PackerBuildCleanup marker wait is 180s, so this fits inside it.)
    $seedFile = $null
    $scanDeadline = (Get-Date).AddSeconds(60)
    while (-not $seedFile -and (Get-Date) -lt $scanDeadline) {
        foreach ($letter in [char[]](68..90)) {   # D..Z
            $candidate = "${letter}:\windows-seed.json"
            if (Test-Path $candidate) { $seedFile = $candidate; break }
        }
        if (-not $seedFile) { Start-Sleep -Seconds 5 }
    }

    if (-not $seedFile) {
        Write-SeedLog 'No windows-seed.json found on any CD-ROM/removable volume.'
        Set-Marker 'NO-SEED'
        Write-SeedLog 'Marker set to NO-SEED'
        Complete-Seed
        Write-SeedLog '=== firstboot-seed complete (no seed) ==='
        return
    }
    Write-SeedLog "Found seed at $seedFile"

    $seed = Get-Content -Path $seedFile -Raw | ConvertFrom-Json

    if (-not $seed.username -or -not $seed.password) {
        Write-SeedLog 'ERROR: seed missing username or password; treating as NO-SEED.'
        Set-Marker 'NO-SEED'
        Complete-Seed
        return
    }

    $username = [string]$seed.username
    $password = ConvertTo-SecureString ([string]$seed.password) -AsPlainText -Force

    # 2. Create or update the local user. PasswordNeverExpires so the
    #    injected login keeps working in a throwaway lab VM.
    if (Get-LocalUser -Name $username -ErrorAction SilentlyContinue) {
        Set-LocalUser -Name $username -Password $password -PasswordNeverExpires $true
        Write-SeedLog "Updated existing local user '$username'"
    } else {
        New-LocalUser -Name $username -Password $password -FullName $username `
            -Description 'Injected by FirstBootSeed' -PasswordNeverExpires -AccountNeverExpires | Out-Null
        Write-SeedLog "Created local user '$username'"
    }

    # 3. Group membership. Default to Administrators when unspecified.
    $groups = @($seed.groups)
    if (-not $groups -or $groups.Count -eq 0) { $groups = @('Administrators') }
    $isAdmin = $false
    foreach ($g in $groups) {
        $g = [string]$g
        try {
            Add-LocalGroupMember -Group $g -Member $username -ErrorAction Stop
            Write-SeedLog "Added '$username' to group '$g'"
        } catch {
            # Already a member, or group missing — log and move on.
            Write-SeedLog "Group '$g' add skipped: $_"
        }
        if ($g -ieq 'Administrators') { $isAdmin = $true }
    }

    # 4. SSH authorized keys (optional). Admins use the machine-wide
    #    administrators_authorized_keys with the strict ACL OpenSSH
    #    requires; standard users get keys under their profile if it
    #    exists yet (it usually won't pre-first-logon — log and skip).
    if ($seed.ssh_authorized_keys -and @($seed.ssh_authorized_keys).Count -gt 0) {
        $keys = (@($seed.ssh_authorized_keys) -join "`n") + "`n"
        if ($isAdmin) {
            $sshDir  = "$env:ProgramData\ssh"
            $keyFile = "$sshDir\administrators_authorized_keys"
            if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
            [System.IO.File]::WriteAllText($keyFile, $keys, (New-Object System.Text.UTF8Encoding($false)))
            # OpenSSH refuses administrators_authorized_keys unless only
            # Administrators + SYSTEM can write it.
            & icacls.exe $keyFile /inheritance:r /grant 'Administrators:F' /grant 'SYSTEM:F' | Out-Null
            Write-SeedLog "Wrote $([int]@($seed.ssh_authorized_keys).Count) SSH key(s) to administrators_authorized_keys"
        } else {
            $profileDir = "C:\Users\$username"
            if (Test-Path $profileDir) {
                $sshDir = "$profileDir\.ssh"
                if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
                [System.IO.File]::WriteAllText("$sshDir\authorized_keys", $keys, (New-Object System.Text.UTF8Encoding($false)))
                Write-SeedLog "Wrote SSH key(s) to $sshDir\authorized_keys"
            } else {
                Write-SeedLog "WARN: profile for '$username' not present yet; SSH keys not applied. Re-run after first interactive logon if needed."
            }
        }
    }

    # 5. Hostname (optional). NetBIOS caps at 15 chars — truncate + warn
    #    rather than fail. Rename-Computer applies on the next reboot.
    if ($seed.hostname) {
        $hostname = [string]$seed.hostname
        if ($hostname.Length -gt 15) {
            $hostname = $hostname.Substring(0, 15)
            Write-SeedLog "WARN: hostname truncated to 15 chars: '$hostname'"
        }
        if ($hostname -ine $env:COMPUTERNAME) {
            Rename-Computer -NewName $hostname -Force -ErrorAction SilentlyContinue
            Write-SeedLog "Hostname set to '$hostname' (effective next reboot)"
        }
    }

    # 6. Handshake: marker = the username we created. PackerBuildCleanup
    #    reads this and now safely locks down the build Administrator.
    Set-Marker $username
    Write-SeedLog "Marker set to '$username'"

    Complete-Seed
    Write-SeedLog '=== firstboot-seed complete ==='
} catch {
    Write-SeedLog "ERROR: $_"
    # On error, leave a NO-SEED marker so cleanup does NOT disable the only
    # admin account — a half-applied seed must not brick the clone.
    try { Set-Marker 'NO-SEED' } catch {}
    Complete-Seed
    throw
}
'@

Set-Content -Path $seedScript -Value $seedBody -Encoding UTF8
Write-Host "Wrote $seedScript"

# Register FirstBootSeed: AtStartup as SYSTEM, single-instance, 5-minute
# hard limit so a stuck scan can't park the task. -Force replaces any
# prior registration of the same name.
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$seedScript`""
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable
Register-ScheduledTask -TaskName "FirstBootSeed" `
    -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description "One-shot first-boot per-VM identity injection from an attached seed CD. Self-destructs after running." `
    -Force | Out-Null
Write-Host "Registered FirstBootSeed scheduled task"

Write-Host "=== 30-install-firstboot-seed done ==="
