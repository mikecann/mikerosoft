@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\e2e\run-e2e.ps1"
exit /b %errorlevel%
