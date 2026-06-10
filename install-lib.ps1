function Write-BatStub {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$ToolName,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Content,

        [Parameter(Mandatory = $false)]
        [string]$ToolsDir
    )

    if (-not $PSBoundParameters.ContainsKey("ToolsDir")) {
        $ToolsDir = Get-Variable -Name ToolsDir -Scope 1 -ValueOnly
    }

    $batDest = Join-Path $ToolsDir "$ToolName.bat"
    Set-Content -Path $batDest -Value $Content -Encoding ASCII
    Write-Host "  [bat]  $batDest" -ForegroundColor Green

    $bashDest = Join-Path $ToolsDir $ToolName
    $bashContent = @'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/__TOOL_NAME__.bat" "$@"
'@.Replace("__TOOL_NAME__", $ToolName)
    Set-Content -Path $bashDest -Value $bashContent -Encoding ASCII
    Write-Host "  [bash] $bashDest" -ForegroundColor Green
}
