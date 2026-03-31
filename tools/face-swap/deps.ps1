# face-swap/deps.ps1
# Checks bun, Python, and installs insightface + onnxruntime + opencv-python.
# Also checks for the inswapper_128.onnx model file.
# Idempotent - safe to run multiple times.

Write-Host "  [face-swap] Checking dependencies..." -ForegroundColor Cyan

# Check bun
if (-not (Get-Command bun -ErrorAction SilentlyContinue)) {
    Write-Host "    MISSING  bun - install from https://bun.sh" -ForegroundColor Red
} else {
    Write-Host "    OK  bun $(bun --version)" -ForegroundColor Green
}

# Check Python
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    Write-Host "    MISSING  python - install from https://python.org" -ForegroundColor Red
    return
}
Write-Host "    OK  $(python --version)" -ForegroundColor Green

# Check insightface
$insightfaceOk = python -c "import insightface; print('ok')" 2>$null
if ($insightfaceOk -eq "ok") {
    Write-Host "    OK  insightface already installed" -ForegroundColor Green
} else {
    Write-Host "    Installing insightface..." -ForegroundColor Yellow
    pip install insightface
}

# Check onnxruntime (try GPU first, fall back to CPU)
$onnxOk = python -c "import onnxruntime; print('ok')" 2>$null
if ($onnxOk -eq "ok") {
    Write-Host "    OK  onnxruntime already installed" -ForegroundColor Green
} else {
    Write-Host "    Installing onnxruntime-gpu (GPU-accelerated)..." -ForegroundColor Yellow
    pip install onnxruntime-gpu
    $onnxOk = python -c "import onnxruntime; print('ok')" 2>$null
    if ($onnxOk -ne "ok") {
        Write-Host "    onnxruntime-gpu failed; installing onnxruntime (CPU)..." -ForegroundColor Yellow
        pip install onnxruntime
    }
}

# Check opencv
$cvOk = python -c "import cv2; print('ok')" 2>$null
if ($cvOk -eq "ok") {
    Write-Host "    OK  opencv-python already installed" -ForegroundColor Green
} else {
    Write-Host "    Installing opencv-python..." -ForegroundColor Yellow
    pip install opencv-python
}

# Check model file
$modelsDir = "$env:LOCALAPPDATA\face-swap\models"
$modelPath  = "$modelsDir\inswapper_128.onnx"

New-Item -ItemType Directory -Force -Path $modelsDir | Out-Null

if (Test-Path $modelPath) {
    Write-Host "    OK  inswapper_128.onnx found at $modelPath" -ForegroundColor Green
} else {
    Write-Host "" -ForegroundColor Yellow
    Write-Host "    NOTICE: inswapper_128.onnx model not found." -ForegroundColor Yellow
    Write-Host "    Download it (~555 MB) from:" -ForegroundColor Yellow
    Write-Host "      https://github.com/facefusion/facefusion-assets/releases/download/models/inswapper_128.onnx" -ForegroundColor Cyan
    Write-Host "    Save it to:" -ForegroundColor Yellow
    Write-Host "      $modelPath" -ForegroundColor Cyan
    Write-Host "    (The models directory has been created for you.)" -ForegroundColor DarkGray
}
