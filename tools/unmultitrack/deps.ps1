# unmultitrack/deps.ps1
# Checks the ffmpeg tools used by the multi-track demuxer.

$ToolsDir = "C:\dev\tools"

Write-Host "  [unmultitrack] Checking dependencies..." -ForegroundColor Cyan

$ffmpegPath = Join-Path $ToolsDir "ffmpeg.exe"
$ffprobePath = Join-Path $ToolsDir "ffprobe.exe"

if (Test-Path $ffmpegPath) {
    Write-Host "    OK    ffmpeg.exe found in $ToolsDir" -ForegroundColor Green
} elseif (Get-Command ffmpeg -ErrorAction SilentlyContinue) {
    Write-Host "    OK    ffmpeg found on PATH" -ForegroundColor Green
} else {
    Write-Host "    WARN  ffmpeg.exe not found. Put ffmpeg.exe in C:\dev\tools or on PATH." -ForegroundColor Yellow
}

if (Test-Path $ffprobePath) {
    Write-Host "    OK    ffprobe.exe found in $ToolsDir" -ForegroundColor Green
} elseif (Get-Command ffprobe -ErrorAction SilentlyContinue) {
    Write-Host "    OK    ffprobe found on PATH" -ForegroundColor Green
} else {
    Write-Host "    WARN  ffprobe.exe not found. The tool will fall back to parsing ffmpeg stream output." -ForegroundColor Yellow
}
