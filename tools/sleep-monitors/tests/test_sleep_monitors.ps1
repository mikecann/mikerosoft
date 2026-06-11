$ErrorActionPreference = "Stop"

$toolRoot = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $toolRoot)
$scriptPath = Join-Path $toolRoot "sleep-monitors.ps1"
$vbsPath = Join-Path $toolRoot "sleep-monitors.vbs"
$installPath = Join-Path $repoRoot "install.ps1"

if (-not (Test-Path $scriptPath)) {
    throw "Missing sleep-monitors.ps1"
}

if (-not (Test-Path $vbsPath)) {
    throw "Missing sleep-monitors.vbs"
}

$logPath = Join-Path $env:LOCALAPPDATA "sleep-monitors\sleep-monitors.log"
if (Test-Path $logPath) {
    Remove-Item -LiteralPath $logPath -Force
}

$output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -DelaySeconds 0 -DryRun 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Dry run failed with exit code $LASTEXITCODE`n$output"
}

$outputText = $output | Out-String
if ($outputText -notmatch "Dry run") {
    throw "Dry run output did not make it clear that no monitor sleep message was sent.`n$outputText"
}

$logText = Get-Content $logPath -Raw
if ($logText -notmatch "Starting DelaySeconds=0 DryRun=True" -or $logText -notmatch "Dry run complete") {
    throw "Dry run should write a useful log entry.`n$logText"
}

$vbsText = Get-Content $vbsPath -Raw
if ($vbsText -notmatch "WindowStyle Hidden" -or $vbsText -notmatch "sleep-monitors\.ps1" -or $vbsText -notmatch "DelaySeconds 5") {
    throw "VBS launcher should run sleep-monitors.ps1 hidden."
}

$installText = Get-Content $installPath -Raw
if ($installText -notmatch 'Write-BatStub "sleep-monitors"' -or $installText -notmatch "Sleep Monitors\.lnk") {
    throw "install.ps1 should install the sleep-monitors PATH stub and shortcut."
}

Write-Host "sleep-monitors tests passed" -ForegroundColor Green
