# task-stats.ps1 -- compatibility launcher for the built EXE host

Add-Type -AssemblyName System.Windows.Forms

$exe = Join-Path $env:LOCALAPPDATA 'task-stats\task-stats.exe'
if (-not (Test-Path $exe)) {
    $buildBat = Join-Path $PSScriptRoot 'build.bat'
    [System.Windows.Forms.MessageBox]::Show(
        "task-stats has not been built yet.`n`nPlease run build.bat first:`n`n  $buildBat`n`nThis only needs to be done once (and again after any code changes).",
        'task-stats -- not built',
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    exit 1
}

& $exe $PSScriptRoot
exit $LASTEXITCODE
