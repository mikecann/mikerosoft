# deps.ps1 -- dependency check + first-time build for task-stats

Write-Host "  [task-stats] Checking dependencies..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# nvml.dll -- ships with NVIDIA drivers, needed for GPU monitoring
# ---------------------------------------------------------------------------
$nvml = 'C:\Windows\System32\nvml.dll'
if (Test-Path $nvml) {
    Write-Host "  [task-stats] nvml.dll found -- NVIDIA GPU monitoring available." -ForegroundColor Green
} else {
    Write-Host "  [task-stats] WARN: nvml.dll not found at $nvml" -ForegroundColor Yellow
    Write-Host "               GPU monitoring will be unavailable (install NVIDIA drivers to enable)." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# dotnet SDK -- required to compile task-stats.csproj
# ---------------------------------------------------------------------------
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if (-not $dotnet) {
    Write-Host "  [task-stats] ERROR: dotnet SDK not found." -ForegroundColor Red
    Write-Host "               Install .NET 8 SDK: winget install Microsoft.DotNet.SDK.8" -ForegroundColor DarkGray
    exit 1
}
Write-Host "  [task-stats] dotnet SDK found." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Build task-stats.exe if it doesn't exist yet (first install on a fresh clone)
# ---------------------------------------------------------------------------
$exe = Join-Path $env:LOCALAPPDATA 'task-stats\task-stats.exe'
if (Test-Path $exe) {
    Write-Host "  [task-stats] task-stats.exe already built -- skipping build." -ForegroundColor Green
} else {
    Write-Host "  [task-stats] task-stats.exe not found -- building now..." -ForegroundColor Yellow
    $proj = Join-Path $PSScriptRoot 'task-stats.csproj'
    & dotnet build $proj -c Release -nologo -v minimal
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [task-stats] ERROR: Build failed. See errors above." -ForegroundColor Red
        exit 1
    }
    Write-Host "  [task-stats] Build succeeded: $exe" -ForegroundColor Green
}
