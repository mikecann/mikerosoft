@echo off
setlocal

if not defined EXEDIR set "EXEDIR=%~dp0"

python "%~dp0img-upscale.py" %*
