@echo off
powershell -NoProfile -Command ^
    "$exeTarget = Join-Path $env:LOCALAPPDATA 'task-stats\task-stats.exe';" ^
    "Get-CimInstance Win32_Process | Where-Object {" ^
    "  ($_.Name -eq 'task-stats.exe' -and ($_.ExecutablePath -eq $exeTarget -or $_.CommandLine -like '*task-stats.exe*')) -or" ^
    "  ($_.Name -eq 'powershell.exe' -and $_.CommandLine -like '*task-stats.ps1*')" ^
    "} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host ('Stopped PID ' + $_.ProcessId) }"
