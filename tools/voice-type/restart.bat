@echo off
echo Stopping any running voice-type instances...
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$needle = 'voice' + '-type' + '.py'; $self = $PID; Get-CimInstance Win32_Process | Where-Object { $_.ProcessId -ne $self -and $_.CommandLine -like ('*' + $needle + '*') } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
echo Launching voice-type...
wscript.exe "%~dp0voice-type.vbs"
echo Done.
