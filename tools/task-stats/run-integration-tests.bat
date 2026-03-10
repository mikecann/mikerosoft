@echo off
setlocal

call "%~dp0build.bat"
if errorlevel 1 exit /b 1

where dotnet >nul 2>nul
if %errorlevel% neq 0 (
    echo ERROR: dotnet SDK not found.
    exit /b 1
)

echo Building integration tests...
dotnet build "%~dp0tests\integration\TaskStats.IntegrationTests.csproj" -c Release -nologo -v minimal
if errorlevel 1 exit /b 1

echo.
echo Running integration tests...
"%LOCALAPPDATA%\task-stats-tests\integration\TaskStats.IntegrationTests.exe"
exit /b %errorlevel%
