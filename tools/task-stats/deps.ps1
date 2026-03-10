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
# MSBuild -- required to compile task-stats.csproj
# ---------------------------------------------------------------------------
$msbuild = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe'
if (-not (Test-Path $msbuild)) {
    Write-Host "  [task-stats] ERROR: MSBuild.exe not found at $msbuild" -ForegroundColor Red
    Write-Host "               .NET Framework 4 is required. It ships with Windows 10/11." -ForegroundColor DarkGray
    exit 1
}
Write-Host "  [task-stats] MSBuild found." -ForegroundColor Green

# ---------------------------------------------------------------------------
# .NET 4.8.1 Developer Pack -- optional, silences the MSB3644 build warning.
# Without it, MSBuild falls back to GAC DLLs (works fine, just noisy).
# ---------------------------------------------------------------------------
$refPath = 'C:\Program Files (x86)\Reference Assemblies\Microsoft\Framework\.NETFramework'
$hasRefAsm = Test-Path "$refPath\v4.8.1"
if (-not $hasRefAsm) {
    Write-Host "  [task-stats] NOTE: .NET Framework targeting pack not installed." -ForegroundColor DarkGray
    Write-Host "               Build will show warning MSB3644 (harmless -- MSBuild uses GAC fallback)." -ForegroundColor DarkGray
    Write-Host "               To silence it: install the .NET 4.8.1 Developer Pack from https://dotnet.microsoft.com/en-us/download/dotnet-framework/net481" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Build task-stats.dll if it doesn't exist yet (first install on a fresh clone)
# ---------------------------------------------------------------------------
$dll = Join-Path $env:LOCALAPPDATA 'task-stats\task-stats.dll'
if (Test-Path $dll) {
    Write-Host "  [task-stats] task-stats.dll already built -- skipping build." -ForegroundColor Green
} else {
    Write-Host "  [task-stats] task-stats.dll not found -- building now..." -ForegroundColor Yellow
    $proj = Join-Path $PSScriptRoot 'task-stats.csproj'
    & $msbuild $proj /nologo /v:minimal /p:Configuration=Release
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [task-stats] ERROR: Build failed. See errors above." -ForegroundColor Red
        exit 1
    }
    Write-Host "  [task-stats] Build succeeded: $dll" -ForegroundColor Green
}
