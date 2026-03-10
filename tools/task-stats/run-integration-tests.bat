@echo off
setlocal

call "%~dp0build.bat"
if errorlevel 1 exit /b 1

set "MSBUILD=C:\Windows\Microsoft.NET\Framework64\v4.0.30319\MSBuild.exe"
if not exist "%MSBUILD%" (
    echo ERROR: MSBuild not found.
    exit /b 1
)

echo Building integration tests...
"%MSBUILD%" "%~dp0tests\integration\TaskStats.IntegrationTests.csproj" /nologo /v:minimal /p:Configuration=Release
if errorlevel 1 exit /b 1

echo.
echo Running integration tests...
"%LOCALAPPDATA%\task-stats-tests\integration\TaskStats.IntegrationTests.exe"
exit /b %errorlevel%
