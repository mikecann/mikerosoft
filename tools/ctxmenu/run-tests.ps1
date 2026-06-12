param()

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path $MyInvocation.MyCommand.Path
$mainScript = Join-Path $scriptDir 'ctxmenu.ps1'
$src = Get-Content $mainScript -Raw
$cutAt = $src.IndexOf('function pngToIcon')
if ($cutAt -lt 0) { throw 'Could not find ctxmenu.ps1 function/UI boundary.' }
Invoke-Expression $src.Substring(0, $cutAt)

function Assert-True([bool]$condition, [string]$message) {
    if (-not $condition) { throw $message }
}

$testAppSubKey = 'Software\Classes\Applications\CodexCtxMenuTest.exe'
$testShellExSubKey = 'Software\Classes\*\shellex\ContextMenuHandlers\CodexCtxMenuShellExTest'
$testShellExClsId = '{11111111-2222-3333-4444-555555555555}'
$blockedSubKey = 'Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
$hkcu = [Microsoft.Win32.Registry]::CurrentUser

try {
    try { $hkcu.DeleteSubKeyTree($testAppSubKey) } catch { }
    try { $hkcu.DeleteSubKeyTree($testShellExSubKey) } catch { }
    $blockedKey = $hkcu.OpenSubKey($blockedSubKey, $true)
    if ($blockedKey) {
        try { $blockedKey.DeleteValue($testShellExClsId) } catch { }
        $blockedKey.Close()
    }

    $openKey = $hkcu.CreateSubKey("$testAppSubKey\shell\open")
    $openKey.SetValue('Icon', "$env:SystemRoot\System32\notepad.exe", [Microsoft.Win32.RegistryValueKind]::String)
    $openKey.Close()

    $cmdKey = $hkcu.CreateSubKey("$testAppSubKey\shell\open\command")
    $cmdKey.SetValue('', "`"$env:SystemRoot\System32\notepad.exe`" `"%1`"", [Microsoft.Win32.RegistryValueKind]::String)
    $cmdKey.Close()

    $entries = @(scanOpenWithApplications)
    $entry = $entries | Where-Object { $_.VerbName -eq 'OpenWith:CodexCtxMenuTest.exe' } | Select-Object -First 1

    Assert-True ($null -ne $entry) 'Expected test Open With app to be scanned.'
    Assert-True ($entry.Kind -eq 'OpenWith') 'Expected OpenWith kind.'
    Assert-True ($entry.AppliesTo -eq 'All Files') 'Expected Open With app to apply to All Files.'
    Assert-True ($entry.Label -eq 'Open with CodexCtxMenuTest') "Unexpected label: $($entry.Label)"
    Assert-True ($entry.Enabled) 'Expected test Open With app to start enabled.'

    applyEntry $entry $false
    $appKey = $hkcu.OpenSubKey($testAppSubKey, $false)
    Assert-True ($appKey.GetValueNames() -icontains 'NoOpenWith') 'Expected disabling to set NoOpenWith.'
    $appKey.Close()

    $disabledEntry = @(scanOpenWithApplications) |
        Where-Object { $_.VerbName -eq 'OpenWith:CodexCtxMenuTest.exe' } |
        Select-Object -First 1
    Assert-True (-not $disabledEntry.Enabled) 'Expected scanner to see NoOpenWith as disabled.'

    applyEntry $entry $true
    $appKey = $hkcu.OpenSubKey($testAppSubKey, $false)
    Assert-True (-not ($appKey.GetValueNames() -icontains 'NoOpenWith')) 'Expected enabling to remove NoOpenWith.'
    $appKey.Close()

    $shellExKey = $hkcu.CreateSubKey($testShellExSubKey)
    $shellExKey.SetValue('', $testShellExClsId, [Microsoft.Win32.RegistryValueKind]::String)
    $shellExKey.Close()

    $shellExEntry = @(scanShellEx 'HKCU' 'Software\Classes\*\shellex\ContextMenuHandlers' 'All Files') |
        Where-Object { $_.VerbName -eq 'CodexCtxMenuShellExTest' } |
        Select-Object -First 1
    Assert-True ($null -ne $shellExEntry) 'Expected test ShellEx handler to be scanned.'
    Assert-True ($shellExEntry.Enabled) 'Expected test ShellEx handler to start enabled.'

    applyEntry $shellExEntry $false
    $blockedKey = $hkcu.OpenSubKey($blockedSubKey, $false)
    Assert-True ($null -ne $blockedKey) 'Expected disabling ShellEx to create Shell Extensions\Blocked.'
    Assert-True ($blockedKey.GetValueNames() -icontains $testShellExClsId) 'Expected disabling ShellEx to block the CLSID.'
    $blockedKey.Close()

    $disabledShellExEntry = @(scanShellEx 'HKCU' 'Software\Classes\*\shellex\ContextMenuHandlers' 'All Files') |
        Where-Object { $_.VerbName -eq 'CodexCtxMenuShellExTest' } |
        Select-Object -First 1
    Assert-True (-not $disabledShellExEntry.Enabled) 'Expected scanner to see blocked ShellEx CLSID as disabled.'

    applyEntry $shellExEntry $true
    $blockedKey = $hkcu.OpenSubKey($blockedSubKey, $false)
    Assert-True (-not ($blockedKey -and ($blockedKey.GetValueNames() -icontains $testShellExClsId))) 'Expected enabling ShellEx to unblock the CLSID.'
    if ($blockedKey) { $blockedKey.Close() }

    $shellExKey = $hkcu.OpenSubKey($testShellExSubKey, $true)
    $shellExKey.SetValue('', "-$testShellExClsId", [Microsoft.Win32.RegistryValueKind]::String)
    $shellExKey.Close()

    $migratedShellExEntry = @(scanShellEx 'HKCU' 'Software\Classes\*\shellex\ContextMenuHandlers' 'All Files') |
        Where-Object { $_.VerbName -eq 'CodexCtxMenuShellExTest' } |
        Select-Object -First 1
    Assert-True (-not $migratedShellExEntry.Enabled) 'Expected legacy negative ShellEx marker to remain disabled.'

    $blockedKey = $hkcu.OpenSubKey($blockedSubKey, $false)
    Assert-True ($blockedKey.GetValueNames() -icontains $testShellExClsId) 'Expected legacy negative ShellEx marker to be migrated to Blocked.'
    $blockedKey.Close()

    Write-Host '[PASS] ctxmenu Open With application tests' -ForegroundColor Green
    Write-Host '[PASS] ctxmenu ShellEx blocked CLSID tests' -ForegroundColor Green
} finally {
    try { $hkcu.DeleteSubKeyTree($testAppSubKey) } catch { }
    try { $hkcu.DeleteSubKeyTree($testShellExSubKey) } catch { }
    $blockedKey = $hkcu.OpenSubKey($blockedSubKey, $true)
    if ($blockedKey) {
        try { $blockedKey.DeleteValue($testShellExClsId) } catch { }
        $blockedKey.Close()
    }
}
