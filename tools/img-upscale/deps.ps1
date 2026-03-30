# img-upscale/deps.ps1
# Sets up the quality backend (Swin2SR via transformers) and checks the optional
# fast backend (Real-ESRGAN ncnn Vulkan).

Write-Host "  [img-upscale] Checking dependencies..." -ForegroundColor Cyan

$requiredPythonPkgs = @(
    @{ module = "numpy"; package = "numpy" }
    @{ module = "PIL"; package = "Pillow" }
    @{ module = "transformers"; package = "transformers" }
    @{ module = "huggingface_hub"; package = "huggingface-hub" }
    @{ module = "safetensors"; package = "safetensors" }
)

$missingPackages = @()
foreach ($pkg in $requiredPythonPkgs) {
    $installed = python -c "import $($pkg.module); print('ok')" 2>$null
    if ($installed -eq "ok") {
        Write-Host "    OK  $($pkg.package)" -ForegroundColor Green
        continue
    }

    $missingPackages += $pkg.package
}

$torchInstalled = python -c "import torch; print(torch.__version__)" 2>$null
if (-not $torchInstalled) {
    Write-Host "    WARNING  torch is not installed" -ForegroundColor Yellow
    Write-Host "    The quality backend needs a working PyTorch install." -ForegroundColor Yellow
    Write-Host "    Install a CUDA-enabled PyTorch build, then rerun deps.ps1." -ForegroundColor Yellow
} else {
    Write-Host "    OK  torch $torchInstalled" -ForegroundColor Green
}

if ($missingPackages.Count -gt 0) {
    Write-Host "    Installing Python packages for the quality backend..." -ForegroundColor Yellow
    pip install $missingPackages
    if ($LASTEXITCODE -ne 0) {
        Write-Host "    ERROR  failed to install one or more Python packages" -ForegroundColor Red
    } else {
        Write-Host "    OK  quality backend packages installed" -ForegroundColor Green
    }
}

$exePath = "C:\dev\tools\realesrgan-ncnn-vulkan.exe"
$modelsDir = "C:\dev\tools\models"
$modelParam = Join-Path $modelsDir "realesrgan-x4plus.param"
$modelBin = Join-Path $modelsDir "realesrgan-x4plus.bin"

if (-not (Test-Path $exePath)) {
    Write-Host "    NOTE  fast backend not installed: $exePath" -ForegroundColor Yellow
    Write-Host "    That is fine if you only want the default quality backend." -ForegroundColor Yellow
    return
}

Write-Host "    OK  optional fast backend exe found" -ForegroundColor Green

if ((Test-Path $modelParam) -and (Test-Path $modelBin)) {
    Write-Host "    OK  optional fast backend model files found" -ForegroundColor Green
    return
}

Write-Host "    WARNING  fast backend model files missing under C:\dev\tools\models" -ForegroundColor Yellow
Write-Host "    Expected for the optional fast backend:" -ForegroundColor Yellow
Write-Host "      - C:\dev\tools\models\realesrgan-x4plus.param" -ForegroundColor Yellow
Write-Host "      - C:\dev\tools\models\realesrgan-x4plus.bin" -ForegroundColor Yellow
