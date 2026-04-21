# deps.ps1 for worktrees — ensures Bun deps are installed for this tool.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
    Write-Host "  [worktrees] bun not found. Install from https://bun.sh then re-run install.ps1." -ForegroundColor Yellow
    return
}

Write-Host "  [worktrees] bun $($(& bun --version | Select-Object -First 1))" -ForegroundColor Green
Push-Location $here
try {
    bun install
} finally {
    Pop-Location
}
