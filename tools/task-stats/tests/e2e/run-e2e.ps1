param(
    [switch]$SkipAI
)

$ErrorActionPreference = 'Stop'

function Load-DotEnv($RepoRoot) {
    $dotEnvPath = Join-Path $RepoRoot ".env"
    if (-not (Test-Path $dotEnvPath)) { return }

    Get-Content $dotEnvPath | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]*?)\s*=\s*(.*)\s*$') {
            $val = $Matches[2].Trim().Trim('"').Trim("'")
            [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $val, 'Process')
        }
    }
}

$RepoRoot   = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..")).Path
$ToolRoot   = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$Artifacts  = Join-Path $PSScriptRoot "artifacts"
$VisualProj = Join-Path $ToolRoot 'tests\visual\TaskStats.VisualHarness.csproj'
$VisualExe  = Join-Path $env:LOCALAPPDATA 'task-stats-tests\visual\TaskStats.VisualHarness.exe'

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw "dotnet SDK not found. Install .NET 10 SDK and try again."
}

Load-DotEnv $RepoRoot

if (Test-Path $Artifacts) {
    Remove-Item $Artifacts -Recurse -Force
}
New-Item -ItemType Directory -Path $Artifacts | Out-Null

Write-Host "Building task-stats..." -ForegroundColor Cyan
dotnet build (Join-Path $ToolRoot 'task-stats.csproj') -c Release -nologo -v minimal
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Building visual harness..." -ForegroundColor Cyan
dotnet build $VisualProj -c Release -nologo -v minimal
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Capturing deterministic screenshots..." -ForegroundColor Cyan
& $VisualExe $Artifacts
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$required = @('aggregate.png', 'aggregate.json', 'percore.png', 'percore.json')
foreach ($name in $required) {
    $path = Join-Path $Artifacts $name
    if (-not (Test-Path $path)) {
        throw "Expected artifact missing: $path"
    }
    if ((Get-Item $path).Length -le 0) {
        throw "Expected artifact is empty: $path"
    }
}

Write-Host "Local visual checks passed." -ForegroundColor Green

if ($SkipAI) {
    Write-Host "Skipping AI screenshot evaluation." -ForegroundColor Yellow
    exit 0
}

if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
    throw "bun is required for AI screenshot evaluation. Install it with: winget install oven-sh.bun"
}

if (-not $env:OPENROUTER_API_KEY) {
    throw "OPENROUTER_API_KEY is not set. Add it to the repo root .env file."
}

Push-Location $PSScriptRoot
try {
    bun run evaluate-screenshots.ts $Artifacts
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
