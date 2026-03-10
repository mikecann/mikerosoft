@echo off
setlocal

call "%~dp0build.bat"
if errorlevel 1 exit /b 1

where dotnet >nul 2>nul
if %errorlevel% neq 0 (
    echo ERROR: dotnet SDK not found.
    exit /b 1
)

echo Building unit tests...
dotnet build "%~dp0tests\unit\TaskStats.UnitTests.csproj" -c Release -nologo -v minimal
if errorlevel 1 exit /b 1

echo.
echo Running unit tests...
"%LOCALAPPDATA%\task-stats-tests\unit\TaskStats.UnitTests.exe"
exit /b %errorlevel%
