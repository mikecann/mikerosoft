[CmdletBinding()]
param(
    [ValidateRange(0, 60)]
    [int]$DelaySeconds = 3,

    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$logDir = Join-Path $env:LOCALAPPDATA "sleep-monitors"
$logPath = Join-Path $logDir "sleep-monitors.log"
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Write-Log {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    Add-Content -Path $logPath -Value "$timestamp $Message" -Encoding UTF8
}

trap {
    Write-Log "ERROR $($_.Exception.Message)"
    throw
}

Write-Log "Starting DelaySeconds=$DelaySeconds DryRun=$DryRun"

$nativeSource = @'
using System;
using System.Runtime.InteropServices;

namespace SleepMonitors
{
    public static class NativeMethods
    {
        [DllImport("user32.dll", SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd,
            uint Msg,
            IntPtr wParam,
            IntPtr lParam,
            uint fuFlags,
            uint uTimeout,
            out IntPtr lpdwResult);
    }
}
'@

Add-Type -TypeDefinition $nativeSource -ErrorAction Stop

if ($DelaySeconds -gt 0) {
    Write-Host "Putting monitors to sleep in $DelaySeconds second(s)..." -ForegroundColor Cyan
    Write-Log "Waiting $DelaySeconds second(s) before sending monitor sleep command"
    Start-Sleep -Seconds $DelaySeconds
}

$hwndBroadcast = [IntPtr]0xffff
$wmSysCommand = 0x0112
$scMonitorPower = [IntPtr]0xF170
$monitorPowerOff = [IntPtr]2
$smtoAbortIfHung = 0x0002
$timeoutMs = 5000
$result = [IntPtr]::Zero

if ($DryRun) {
    Write-Log "Dry run complete"
    Write-Host "Dry run: user32 interop and monitor sleep constants are ready; monitor sleep message was not sent." -ForegroundColor Yellow
    exit 0
}

Write-Host "Putting monitors to sleep. Move the mouse or press a key to wake them." -ForegroundColor Cyan

$sendResult = [SleepMonitors.NativeMethods]::SendMessageTimeout(
    $hwndBroadcast,
    $wmSysCommand,
    $scMonitorPower,
    $monitorPowerOff,
    $smtoAbortIfHung,
    $timeoutMs,
    [ref]$result)

if ($sendResult -eq [IntPtr]::Zero) {
    $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Log "SendMessageTimeout failed result=$result error=$errorCode"
    if ($errorCode -ne 0) {
        throw "Windows did not accept the monitor sleep command. Win32 error: $errorCode"
    }
} else {
    Write-Log "SendMessageTimeout succeeded result=$result"
}

Write-Log "Monitor sleep command sent"
