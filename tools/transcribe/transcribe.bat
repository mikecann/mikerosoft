@echo off
setlocal enabledelayedexpansion

if "%~1"=="" (
    echo Usage: transcribe ^<video_file^> [--cpu] [--diarize]
    echo Example: transcribe c:/videos/video.mp4
    echo          transcribe c:/videos/video.mp4 --cpu
    echo          transcribe c:/videos/video.mp4 --diarize --min-speakers 2
    exit /b 1
)

set "VIDEO_FILE=%~1"
set "DEVICE=cuda"
for %%a in (%*) do (
    if /i "%%~a"=="--cpu" set "DEVICE=cpu"
    if /i "%%~a"=="--diarize" set "USE_PYTHON_DIARIZE=1"
)

rem EXEDIR is injected by the stub in c:\dev\tools and points to the directory
rem containing ffmpeg.exe, faster-whisper-xxl.exe and the _models folder.
rem When called directly (e.g. during development), fall back to this file's directory.
if not defined EXEDIR set "EXEDIR=%~dp0"

if not exist "!VIDEO_FILE!" (
    echo Error: File not found: !VIDEO_FILE!
    exit /b 1
)

if defined USE_PYTHON_DIARIZE (
    where python >nul 2>nul
    if errorlevel 1 (
        echo Error: --diarize uses the Python transcribe path, but python was not found on PATH.
        exit /b 1
    )
    python "%~dp0transcribe.py" %*
    exit /b !errorlevel!
)

echo Extracting audio from video...
set "TEMP_AUDIO=%TEMP%\transcribe_%RANDOM%_%RANDOM%.wav"
"%EXEDIR%ffmpeg.exe" -i "!VIDEO_FILE!" -vn -acodec pcm_s16le -ar 16000 -ac 1 -y "!TEMP_AUDIO!" 2>nul

if errorlevel 1 (
    echo Error: Failed to extract audio from video
    exit /b 1
)

echo Transcribing audio (device: !DEVICE!)...
set "TEMP_OUTPUT_DIR=%TEMP%\transcribe_output_%RANDOM%"
mkdir "!TEMP_OUTPUT_DIR!" 2>nul
if /i "!DEVICE!"=="cuda" (
    "%EXEDIR%faster-whisper-xxl.exe" --model_dir "%EXEDIR%_models" --device !DEVICE! --compute_type float16 --output_dir "!TEMP_OUTPUT_DIR!" --output_format srt "!TEMP_AUDIO!"
) else (
    "%EXEDIR%faster-whisper-xxl.exe" --model_dir "%EXEDIR%_models" --device !DEVICE! --output_dir "!TEMP_OUTPUT_DIR!" --output_format srt "!TEMP_AUDIO!"
)

if errorlevel 1 (
    if /i "!DEVICE!"=="cuda" (
        echo.
        echo CUDA failed, retrying with CPU...
        "%EXEDIR%faster-whisper-xxl.exe" --model_dir "%EXEDIR%_models" --device cpu --output_dir "!TEMP_OUTPUT_DIR!" --output_format srt "!TEMP_AUDIO!"
        if errorlevel 1 (
            echo Error: Transcription failed on both CUDA and CPU
            del "!TEMP_AUDIO!" 2>nul
            rmdir /s /q "!TEMP_OUTPUT_DIR!" 2>nul
            exit /b 1
        )
    ) else (
        echo Error: Transcription failed
        del "!TEMP_AUDIO!" 2>nul
        rmdir /s /q "!TEMP_OUTPUT_DIR!" 2>nul
        exit /b 1
    )
)

del "!TEMP_AUDIO!" 2>nul

set "FINAL_OUTPUT=%~dpn1.srt"
for %%f in ("!TEMP_OUTPUT_DIR!\*.srt") do (
    move /y "%%f" "!FINAL_OUTPUT!" >nul 2>&1
    set "OUTPUT_FILE=!FINAL_OUTPUT!"
)
rmdir /s /q "!TEMP_OUTPUT_DIR!" 2>nul
if exist "!OUTPUT_FILE!" (
    echo.
    echo ========================================
    echo Transcription:
    echo ========================================
    type "!OUTPUT_FILE!"
    echo.
    echo ========================================
    echo Transcription saved to: !OUTPUT_FILE!
) else (
    echo Warning: Could not find output file. Transcription may have failed.
)
