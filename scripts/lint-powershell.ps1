# lint-powershell.ps1 — parse-check the Windows provisioners without a build.
#
# The Windows image is built entirely from PowerShell provisioners, but
# nothing else in the validation gates looks at them. This catches syntax
# errors before sinking ~16 min into a build that would fail mid-provision.
#
# It checks two layers:
#   1. Each provision/*.ps1 at the top level.
#   2. The embedded here-string bodies (the @' ... '@ blocks that 30-* and
#      99-* write to disk and register as scheduled tasks) — those run on a
#      clone, never during the build, so a syntax error there would only
#      surface in production. Parse them too.
#
# Syntax-only: it uses the PowerShell parser, so the Windows-only cmdlets
# (New-LocalUser, Register-ScheduledTask, ...) don't need to exist. Runs on
# macOS/Linux pwsh.
#
# Usage: pwsh -NoProfile -File scripts/lint-powershell.ps1 [provisionDir]

param(
    [string]$ProvisionDir = "packer/windows-11-arm64/provision"
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $ProvisionDir)) {
    Write-Host "provision dir not found: $ProvisionDir" -ForegroundColor Red
    exit 2
}

$files = Get-ChildItem -Path $ProvisionDir -Filter *.ps1 | Sort-Object Name
$fail = 0

function Test-Errors($label, $errs) {
    if ($errs -and $errs.Count) {
        Write-Host "FAIL: $label" -ForegroundColor Red
        $errs | ForEach-Object { Write-Host "   line $($_.Extent.StartLineNumber): $($_.Message)" }
        return 1
    }
    Write-Host "ok:   $label"
    return 0
}

foreach ($f in $files) {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
    $fail += Test-Errors $f.Name $errs

    # Parse every single-quoted here-string body in the file (these are the
    # scripts written to C:\Windows\Setup\Scripts\ on a clone).
    $raw = Get-Content -Path $f.FullName -Raw
    foreach ($m in [regex]::Matches($raw, "(?s)@'\r?\n(.*?)\r?\n'@")) {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($m.Groups[1].Value, [ref]$null, [ref]$errs)
        $fail += Test-Errors "$($f.Name) (embedded body)" $errs
    }
}

Write-Host ""
if ($fail) {
    Write-Host "$fail PowerShell parse failure(s)" -ForegroundColor Red
    exit 1
}
Write-Host "All PowerShell parsed clean" -ForegroundColor Green
