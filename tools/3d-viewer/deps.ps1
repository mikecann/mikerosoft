$toolDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "  [3d-viewer] Checking dependencies..." -ForegroundColor Cyan

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-Host "  [3d-viewer] ERROR: Node.js not found. Install from https://nodejs.org" -ForegroundColor Red
} else {
    Write-Host "  [3d-viewer] Node.js $(node --version)" -ForegroundColor Green
}

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Host "  [3d-viewer] ERROR: npm not found." -ForegroundColor Red
    exit 1
}

$nodeModules = Join-Path $toolDir "node_modules"
if (-not (Test-Path $nodeModules)) {
    Write-Host "  [3d-viewer] Installing dependencies (three.js)..." -ForegroundColor Yellow
    Push-Location $toolDir
    bun install --silent
    Pop-Location
    Write-Host "  [3d-viewer] bun install done." -ForegroundColor Green
} else {
    Write-Host "  [3d-viewer] node_modules already present, skipping install." -ForegroundColor Green
}
