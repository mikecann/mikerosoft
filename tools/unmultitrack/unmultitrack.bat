@echo off
setlocal

if "%~1"=="" (
    echo Usage: unmultitrack ^<video_file^> [options]
    echo Example: unmultitrack C:\videos\recording.mp4
    echo.
    echo Options:
    echo   --video-only    Do not copy audio into each extracted file
    echo   --overwrite     Overwrite existing extracted files
    exit /b 1
)

if not defined EXEDIR set "EXEDIR=%~dp0"

python "%~dp0unmultitrack.py" %*
