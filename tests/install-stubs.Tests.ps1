$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$libPath = Join-Path $repoRoot "install-lib.ps1"
. $libPath

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("mikerosoft-install-stubs-" + [guid]::NewGuid().ToString("N"))
$toolsDir = Join-Path $testRoot "tools"
New-Item -ItemType Directory -Path $toolsDir | Out-Null

try {
    Write-BatStub `
        -ToolsDir $toolsDir `
        -ToolName "ghopen" `
        -Content "@echo off`r`necho ghopen %*"

    $batPath = Join-Path $toolsDir "ghopen.bat"
    $bashPath = Join-Path $toolsDir "ghopen"

    if (-not (Test-Path $batPath -PathType Leaf)) {
        throw "Expected .bat stub at $batPath"
    }

    if (-not (Test-Path $bashPath -PathType Leaf)) {
        throw "Expected extensionless Git Bash shim at $bashPath"
    }

    $batText = Get-Content $batPath -Raw
    if ($batText -notmatch "@echo off") {
        throw "Expected .bat stub content to be written"
    }

    $bashText = (Get-Content $bashPath -Raw).Replace("`r`n", "`n")
    $expected = @'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/ghopen.bat" "$@"
'@
    if ($bashText.TrimEnd() -ne $expected.TrimEnd()) {
        throw "Unexpected Git Bash shim content:`n$bashText"
    }

    $bytes = [System.IO.File]::ReadAllBytes($batPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "Expected .bat stub to be ASCII without UTF-8 BOM"
    }

    Write-Host "install stub tests passed" -ForegroundColor Green
}
finally {
    if (Test-Path $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
