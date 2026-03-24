# Organize a flat backup folder into YYYY/mmm subfolders using photo EXIF when available,
# otherwise the file's LastWriteTime (typical for videos and MTP copies).
# Uses a single Python process (fast for thousands of files).
#
#   .\organize-existing-backup.ps1 [-Destination D:\bak\photos] [-WhatIf] [-Quiet]

param(
    [string]$Destination = "D:\bak\photos",
    [switch]$WhatIf,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$py = Join-Path $PSScriptRoot "organize_flat_to_ym.py"
if (-not (Test-Path -LiteralPath $py)) {
    Write-Error "Missing $py"
}

$args = @($py, $Destination)
if ($WhatIf) {
    $args += "--dry-run"
}
if ($Quiet) {
    $args += "--quiet"
}

Write-Host "Running: python $($args -join ' ')" -ForegroundColor Cyan
& python @args
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
