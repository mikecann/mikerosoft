@echo off
setlocal

call "%~dp0run-unit-tests.bat"
if errorlevel 1 exit /b 1

echo.
call "%~dp0run-integration-tests.bat"
exit /b %errorlevel%
