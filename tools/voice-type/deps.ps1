# voice-type/deps.ps1 — installs Python dependencies for voice-type.
# Idempotent: checks before installing.

Write-Host "  [voice-type] Checking dependencies..." -ForegroundColor Cyan

$packages = @(
    @{ import = "faster_whisper";  pip = "faster-whisper" },
    @{ import = "sounddevice";     pip = "sounddevice" },
    @{ import = "numpy";           pip = "numpy" },
    @{ import = "PIL";             pip = "Pillow" },
    @{ import = "pystray";         pip = "pystray" },
    @{ import = "sherpa_onnx";     pip = "sherpa-onnx" },
    @{ import = "huggingface_hub"; pip = "huggingface_hub" },
    @{ import = "llama_cpp";       pip = "llama-cpp-python" }
)

foreach ($pkg in $packages) {
    $check = python -c "import $($pkg.import)" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    OK  $($pkg.pip)" -ForegroundColor Green
    } else {
        Write-Host "    Installing $($pkg.pip)..." -ForegroundColor Yellow
        pip install $pkg.pip --quiet
        if ($LASTEXITCODE -eq 0) {
            Write-Host "    OK  $($pkg.pip) (installed)" -ForegroundColor Green
        } else {
            Write-Host "    FAILED  $($pkg.pip)" -ForegroundColor Red
        }
    }
}

Write-Host ""
Write-Host "    NOTE: Whisper and formatter models download automatically on first use." -ForegroundColor DarkGray
Write-Host "    They are cached under %USERPROFILE%\.cache\huggingface and %LOCALAPPDATA%\voice-type\llm-models." -ForegroundColor DarkGray
