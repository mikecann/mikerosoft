# deps.ps1 - install task-stats visual test dependencies

if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
    Write-Host "  [task-stats:e2e] WARN: bun is not installed." -ForegroundColor Yellow
    Write-Host "                   Install it with: winget install oven-sh.bun" -ForegroundColor Yellow
    return
}

Write-Host "  [task-stats:e2e] Installing visual test dependencies..." -ForegroundColor DarkGray
Push-Location $PSScriptRoot
bun install --silent 2>&1 | Out-Null
Pop-Location
Write-Host "  [task-stats:e2e] Visual test dependencies ready." -ForegroundColor Green
