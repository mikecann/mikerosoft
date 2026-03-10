@echo off
setlocal

echo Stopping any running task-stats instance...
call "%~dp0kill.bat"

where dotnet >nul 2>nul
if %errorlevel% neq 0 (
    echo ERROR: dotnet SDK not found.
    echo Install .NET 10 SDK and try again.
    pause
    exit /b 1
)

echo Building task-stats.csproj ...
dotnet build "%~dp0task-stats.csproj" -c Release -nologo -v minimal

if %errorlevel% neq 0 (
    echo.
    echo Build FAILED. See errors above.
    pause
    exit /b 1
)

echo.
echo Build succeeded: %LOCALAPPDATA%\task-stats\task-stats.exe
echo You can now launch task-stats via task-stats.vbs
