# ctxmenu.ps1  –  Context Menu Manager
#
# Renders a visual preview of your context menu (dark theme, icons, submenu arrows)
# and lets you click items to hide/show them in Windows Explorer.
#
# All writes go to HKCU, so no admin rights needed.
#   Static verbs:  LegacyDisable value in HKCU shadow key
#   COM handlers:  prefix CLSID with '-' in HKCU shadow key

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Add-Type -ReferencedAssemblies 'System.Windows.Forms','System.Drawing' @'
using System;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public class CmEntry {
    public string VerbName;
    public string Label;
    public string AppliesTo;
    public string Source;
    public string Kind;
    public string ReadPath;
    public string ShadowPath;
    public bool   Enabled;
    public bool   IsSubmenu;
    public string ClsId;
}

public class IconUtil {
    [DllImport("shell32.dll", CharSet=CharSet.Auto)]
    private static extern int ExtractIconEx(string f,int i,IntPtr[] l,IntPtr[] s,int n);
    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr h);
    public static Icon GetSmall(string file, int idx) {
        try {
            var l=new IntPtr[1]; var s=new IntPtr[1];
            if(ExtractIconEx(file,idx,l,s,1)==0) return null;
            if(l[0]!=IntPtr.Zero) DestroyIcon(l[0]);
            if(s[0]==IntPtr.Zero) return null;
            var icon=(Icon)Icon.FromHandle(s[0]).Clone();
            DestroyIcon(s[0]);
            return icon;
        } catch { return null; }
    }
}

public class MuiUtil {
    [DllImport("shlwapi.dll", CharSet=CharSet.Unicode)]
    private static extern int SHLoadIndirectString(string src, System.Text.StringBuilder buf, int len, IntPtr reserved);

    public static string Resolve(string s) {
        if (string.IsNullOrEmpty(s) || !s.StartsWith("@")) return s;
        var buf = new System.Text.StringBuilder(512);
        int hr = SHLoadIndirectString(s, buf, buf.Capacity, IntPtr.Zero);
        return (hr == 0 && buf.Length > 0) ? buf.ToString() : s;
    }
}

// Double-buffered panel - eliminates ALL flickering and rendering artifacts
public class MenuPanel : Panel {
    public MenuPanel() {
        this.DoubleBuffered = true;
        this.SetStyle(
            ControlStyles.AllPaintingInWmPaint |
            ControlStyles.UserPaint |
            ControlStyles.OptimizedDoubleBuffer, true);
        this.ResizeRedraw = true;
    }
}
'@

# ── Colours (matching Windows 11 dark context menu) ──────────────────────────
$C_BG       = [System.Drawing.Color]::FromArgb(30, 30, 30)
$C_TOOLBAR  = [System.Drawing.Color]::FromArgb(44, 44, 44)
$C_ROW      = [System.Drawing.Color]::FromArgb(32, 32, 32)
$C_ROW_HOV  = [System.Drawing.Color]::FromArgb(58, 58, 58)
$C_ROW_DIS  = [System.Drawing.Color]::FromArgb(22, 22, 22)
$C_TXT      = [System.Drawing.Color]::FromArgb(242, 242, 242)
$C_TXT_DIS  = [System.Drawing.Color]::FromArgb(85,  85,  85)
$C_SEP      = [System.Drawing.Color]::FromArgb(50,  50,  50)
$C_BTN_HIDE = [System.Drawing.Color]::FromArgb(180, 40, 40)
$C_BTN_SHOW = [System.Drawing.Color]::FromArgb(30, 130, 50)

$ROW_H  = 34
$ICON_X = 12
$TEXT_X = 36
$BTN_W  = 52

# Pre-create shared GDI resources
$GDI = @{
    fontNorm   = New-Object System.Drawing.Font('Segoe UI', 9)
    fontStrike = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Strikeout)
    fontBtn    = New-Object System.Drawing.Font('Segoe UI', 8)
    fontArrow  = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    sfMid      = (& { $sf = New-Object System.Drawing.StringFormat; $sf.LineAlignment = 'Center'; $sf })
    sfCenter   = (& { $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'; $sf })
}

# ── Registry helpers ──────────────────────────────────────────────────────────
function rOpen([string]$p) {
    $parts = $p -split '\\', 2
    if ($parts.Count -lt 2) { return $null }
    $root = switch ($parts[0]) {
        'HKEY_LOCAL_MACHINE' { [Microsoft.Win32.Registry]::LocalMachine }
        'HKEY_CURRENT_USER'  { [Microsoft.Win32.Registry]::CurrentUser  }
        'HKEY_CLASSES_ROOT'  { [Microsoft.Win32.Registry]::ClassesRoot  }
        default              { return $null }
    }
    return $root.OpenSubKey($parts[1], $false)
}
function rLabel([Microsoft.Win32.RegistryKey]$k) {
    foreach ($n in @('MUIVerb', '')) {
        $raw = $k.GetValue($n)
        if (-not $raw) { continue }
        $s = "$raw"
        if (-not $s) { continue }
        # Resolve @dll,-id MUI resource references
        if ($s.StartsWith('@')) { $s = [MuiUtil]::Resolve($s) }
        # Strip accelerator key markers (&) used in menu labels
        $s = $s -replace '&', ''
        if ($s) { return $s }
    }
    return $k.Name.Split('\')[-1]
}
function hkuShadow([string]$hive, [string]$sub) {
    if ($hive -eq 'HKCU') { return $sub }
    return $sub -replace '^SOFTWARE\\Classes\\', 'Software\Classes\'
}
function isVerbDisabled([string]$rp, [string]$sh) {
    foreach ($p in @($rp, "HKEY_CURRENT_USER\$sh")) {
        $k = rOpen $p
        if ($k) { $d = $k.GetValueNames() -icontains 'LegacyDisable'; $k.Close(); if ($d) { return $true } }
    }
    return $false
}
$script:SHELL_EXT_BLOCKED_SUBKEY = 'Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'

function isShellExtensionBlocked([string]$clsId) {
    if (-not $clsId) { return $false }
    foreach ($p in @(
        "HKEY_CURRENT_USER\$script:SHELL_EXT_BLOCKED_SUBKEY",
        'HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'
    )) {
        $k = rOpen $p
        if ($k) {
            $blocked = $k.GetValueNames() -icontains $clsId
            $k.Close()
            if ($blocked) { return $true }
        }
    }
    return $false
}
function setShellExtensionBlocked([string]$clsId, [string]$label, [bool]$blocked) {
    if (-not $clsId) { return }
    $hkcu = [Microsoft.Win32.Registry]::CurrentUser
    $k = $hkcu.OpenSubKey($script:SHELL_EXT_BLOCKED_SUBKEY, $true)
    if (-not $k -and $blocked) { $k = $hkcu.CreateSubKey($script:SHELL_EXT_BLOCKED_SUBKEY) }
    if (-not $k) { return }
    try {
        if ($blocked) { $k.SetValue($clsId, $label, [Microsoft.Win32.RegistryValueKind]::String) }
        else { try { $k.DeleteValue($clsId) } catch { } }
    } finally {
        $k.Close()
    }
}
function isShellExLegacyDisabled([string]$rp, [string]$sh) {
    foreach ($p in @("HKEY_CURRENT_USER\$sh", $rp)) {
        $k = rOpen $p
        if ($k) { $v = "$($k.GetValue(''))"; $k.Close(); if ($v) { return $v.StartsWith('-') } }
    }
    return $false
}
function isShellExDisabled([string]$rp, [string]$sh, [string]$clsId) {
    if (isShellExtensionBlocked $clsId) { return $true }
    return (isShellExLegacyDisabled $rp $sh)
}
function isOpenWithDisabled([string]$rp, [string]$sh) {
    foreach ($p in @("HKEY_CURRENT_USER\$sh", $rp)) {
        $k = rOpen $p
        if ($k) {
            $d = $k.GetValueNames() -icontains 'NoOpenWith'
            $k.Close()
            if ($d) { return $true }
        }
    }
    return $false
}
function trimExeDisplayName([string]$name) {
    if (-not $name) { return $name }
    return [System.IO.Path]::GetFileNameWithoutExtension($name.Trim())
}
function getAppDisplayName([Microsoft.Win32.RegistryKey]$appKey, [string]$appName) {
    foreach ($n in @('FriendlyAppName', 'ApplicationName', '')) {
        $raw = $appKey.GetValue($n)
        if (-not $raw) { continue }
        $s = "$raw"
        if ($s.StartsWith('@')) { $s = [MuiUtil]::Resolve($s) }
        $s = $s -replace '&', ''
        if ($s -and -not $s.StartsWith('@')) { return $s }
    }

    $info = $appKey.OpenSubKey('Application')
    if ($info) {
        foreach ($n in @('ApplicationName', 'ApplicationDescription')) {
            $raw = $info.GetValue($n)
            if (-not $raw) { continue }
            $s = "$raw"
            if ($s.StartsWith('@')) { $s = [MuiUtil]::Resolve($s) }
            $s = $s -replace '&', ''
            if ($s -and -not $s.StartsWith('@')) {
                $info.Close()
                return $s
            }
        }
        $info.Close()
    }

    return (trimExeDisplayName $appName)
}

# Verb names Windows explicitly hides from right-click menus.
# printto  = "Print to" handler, only invoked via drag-to-printer, never shown in menu.
# runas    = "Run as administrator" - Windows only shows this on .exe/.bat/.cmd etc.
# opennewwindow, explore, find = folder/shell-internal actions.
$script:HIDDEN_VERBS = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@('printto','runas','opennewwindow','explore','find','printto32'),
    [System.StringComparer]::OrdinalIgnoreCase)

# ── Registry scanners ─────────────────────────────────────────────────────────
function scanVerbs([string]$hive, [string]$sub, [string]$applies) {
    $out = [System.Collections.Generic.List[CmEntry]]::new()
    $hw  = if ($hive -eq 'HKLM') { 'HKEY_LOCAL_MACHINE' } else { 'HKEY_CURRENT_USER' }
    $shell = rOpen "$hw\$sub"; if (-not $shell) { return $out }
    $base  = hkuShadow $hive $sub
    foreach ($v in $shell.GetSubKeyNames()) {
        try {
            if ($script:HIDDEN_VERBS.Contains($v)) { continue }  # skip Windows-internal hidden verbs
            $vk = $shell.OpenSubKey($v); if (-not $vk) { continue }
            # Skip verbs with "Extended" value - Windows only shows these on Shift+right-click
            $isExtended = $null -ne $vk.GetValue('Extended')
            $label = rLabel $vk; $isSub = $null -ne $vk.GetValue('SubCommands'); $vk.Close()
            if ($isExtended) { continue }
            $e = [CmEntry]::new()
            $e.VerbName=$v; $e.Label=$label; $e.AppliesTo=$applies; $e.Source=$hive
            $e.Kind = if ($isSub) { 'Submenu' } else { 'Verb' }
            $e.ReadPath="$hw\$sub\$v"; $e.ShadowPath="$base\$v"
            $e.Enabled=-not(isVerbDisabled $e.ReadPath $e.ShadowPath); $e.IsSubmenu=$isSub
            $out.Add($e)
        } catch { }
    }
    $shell.Close(); return $out
}
function scanShellEx([string]$hive, [string]$sub, [string]$applies) {
    $out = [System.Collections.Generic.List[CmEntry]]::new()
    $hw  = if ($hive -eq 'HKLM') { 'HKEY_LOCAL_MACHINE' } else { 'HKEY_CURRENT_USER' }
    $h   = rOpen "$hw\$sub"; if (-not $h) { return $out }
    $base = hkuShadow $hive $sub
    foreach ($n in $h.GetSubKeyNames()) {
        try {
            $hk = $h.OpenSubKey($n); if (-not $hk) { continue }
            $clsRaw = "$($hk.GetValue(''))"; $hk.Close(); if (-not $clsRaw) { continue }
            $cls = $clsRaw.TrimStart('-')
            $label = $n
            # Key name may itself be a CLSID (e.g. {90AA3A4E...}) - look that up too
            $clsidToLookup = if ($n -match '^\{[0-9A-F-]+\}$') { $n } else { $cls }
            $ck = rOpen "HKEY_CLASSES_ROOT\CLSID\$clsidToLookup"
            if ($ck) {
                $fn = "$($ck.GetValue(''))"; $ck.Close()
                if ($fn) { $label = if ($n -eq $clsidToLookup) { $fn } else { "$n  [$fn]" } }
            } elseif ($cls -and -not $cls.StartsWith('{')) {
                # Value is a plain string name (e.g. "Taskband Pin") - use it
                $label = $cls
            }
            $e = [CmEntry]::new(); $e.VerbName=$n; $e.Label=$label; $e.AppliesTo=$applies; $e.Source=$hive
            $e.Kind='ShellEx'; $e.ReadPath="$hw\$sub\$n"; $e.ShadowPath="$base\$n"
            $e.ClsId=$cls
            $legacyDisabled = isShellExLegacyDisabled $e.ReadPath $e.ShadowPath
            if ($legacyDisabled -and -not (isShellExtensionBlocked $cls)) {
                setShellExtensionBlocked $cls $label $true
            }
            $e.Enabled=-not(isShellExDisabled $e.ReadPath $e.ShadowPath $e.ClsId)
            $out.Add($e)
        } catch { }
    }
    $h.Close(); return $out
}
function scanExtGroup([string[]]$exts, [string]$type) {
    $seen  = [System.Collections.Generic.Dictionary[string,CmEntry]]::new()
    $paths = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]]::new()
    foreach ($ext in $exts) {
        foreach ($hive in @('HKCU','HKLM')) {
            $hw  = if ($hive -eq 'HKLM') { 'HKEY_LOCAL_MACHINE' } else { 'HKEY_CURRENT_USER' }
            $sub = if ($hive -eq 'HKLM') { "SOFTWARE\Classes\SystemFileAssociations\$ext\shell" } `
                   else { "Software\Classes\SystemFileAssociations\$ext\shell" }
            $shell = rOpen "$hw\$sub"; if (-not $shell) { continue }
            foreach ($v in $shell.GetSubKeyNames()) {
                try {
                    if ($script:HIDDEN_VERBS.Contains($v)) { continue }
                    $vk = $shell.OpenSubKey($v); if (-not $vk) { continue }
                    $isExtended = $null -ne $vk.GetValue('Extended')
                    $label = rLabel $vk; $isSub = $null -ne $vk.GetValue('SubCommands'); $vk.Close()
                    if ($isExtended) { continue }
                    $sp = "Software\Classes\SystemFileAssociations\$ext\shell\$v"
                    if (-not $seen.ContainsKey($v)) {
                        $e = [CmEntry]::new(); $e.VerbName=$v; $e.Label=$label; $e.AppliesTo=$type; $e.Source=$hive
                        $e.Kind = if ($isSub) { 'Submenu' } else { 'Verb' }
                        $e.ReadPath="$hw\$sub\$v"; $e.ShadowPath=$sp
                        $e.Enabled=-not(isVerbDisabled $e.ReadPath $e.ShadowPath); $e.IsSubmenu=$isSub
                        $seen[$v]=$e; $paths[$v]=[System.Collections.Generic.List[string]]::new()
                    }
                    $paths[$v].Add($sp)
                } catch { }
            }
            $shell.Close()
        }
    }
    foreach ($v in $seen.Keys) { $seen[$v].ShadowPath = ($paths[$v] | Sort-Object -Unique) -join ';' }
    return $seen.Values
}
# Scan shell verbs registered under ProgIDs for a set of extensions.
# E.g. VLC registers Play/AddToPlaylist under HKCR\VLC.mp4\shell, not SystemFileAssociations.
function scanProgIdShell([string[]]$exts, [string]$applies) {
    $out   = [System.Collections.Generic.List[CmEntry]]::new()
    $pids  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $hkcr  = [Microsoft.Win32.Registry]::ClassesRoot

    foreach ($ext in $exts) {
        $ek = $hkcr.OpenSubKey($ext); if (-not $ek) { continue }
        $def = "$($ek.GetValue(''))"
        if ($def) { [void]$pids.Add($def) }
        $owi = $ek.OpenSubKey('OpenWithProgids')
        if ($owi) { foreach ($n in $owi.GetValueNames()) { if ($n) { [void]$pids.Add($n) } }; $owi.Close() }
        $ek.Close()
    }

    foreach ($progId in $pids) {
        $shellKey = $hkcr.OpenSubKey("$progId\shell"); if (-not $shellKey) { continue }
        foreach ($v in $shellKey.GetSubKeyNames()) {
            try {
                if ($script:HIDDEN_VERBS.Contains($v)) { continue }
                $vk = $shellKey.OpenSubKey($v); if (-not $vk) { continue }
                $isExtended = $null -ne $vk.GetValue('Extended')
                $label = rLabel $vk; $isSub = $null -ne $vk.GetValue('SubCommands'); $vk.Close()
                if ($isExtended) { continue }
                $e = [CmEntry]::new()
                $e.VerbName    = $v; $e.Label = $label; $e.AppliesTo = $applies; $e.Source = 'HKCR'
                $e.Kind        = if ($isSub) { 'Submenu' } else { 'Verb' }
                $e.ReadPath    = "HKEY_CLASSES_ROOT\$progId\shell\$v"
                $e.ShadowPath  = "Software\Classes\$progId\shell\$v"
                $e.Enabled     = -not (isVerbDisabled $e.ReadPath $e.ShadowPath)
                $e.IsSubmenu   = $isSub
                $out.Add($e)
            } catch { }
        }
        $shellKey.Close()
    }
    return $out
}

# Scan apps registered for Windows "Open with ..." suggestions.
# These live under Applications\<exe>, not under *\shell, so LegacyDisable
# will not affect them. The reversible user-level switch is NoOpenWith.
function scanOpenWithApplications {
    $out = [System.Collections.Generic.List[CmEntry]]::new()

    foreach ($hive in @('HKCU','HKLM')) {
        $hw  = if ($hive -eq 'HKLM') { 'HKEY_LOCAL_MACHINE' } else { 'HKEY_CURRENT_USER' }
        $sub = if ($hive -eq 'HKLM') { 'SOFTWARE\Classes\Applications' } else { 'Software\Classes\Applications' }
        $apps = rOpen "$hw\$sub"; if (-not $apps) { continue }
        $base = hkuShadow $hive $sub

        foreach ($appName in $apps.GetSubKeyNames()) {
            try {
                $appKey = $apps.OpenSubKey($appName); if (-not $appKey) { continue }
                $openKey = $appKey.OpenSubKey('shell\open')
                $cmdKey = $appKey.OpenSubKey('shell\open\command')
                if (-not $openKey -or -not $cmdKey) {
                    if ($openKey) { $openKey.Close() }
                    if ($cmdKey) { $cmdKey.Close() }
                    $appKey.Close()
                    continue
                }

                $name = getAppDisplayName $appKey $appName
                $openKey.Close()
                $cmdKey.Close()
                $appKey.Close()

                if (-not $name) { $name = trimExeDisplayName $appName }
                $e = [CmEntry]::new()
                $e.VerbName   = "OpenWith:$appName"
                $e.Label      = "Open with $name"
                $e.AppliesTo  = 'All Files'
                $e.Source     = $hive
                $e.Kind       = 'OpenWith'
                $e.ReadPath   = "$hw\$sub\$appName"
                $e.ShadowPath = "$base\$appName"
                $e.Enabled    = -not (isOpenWithDisabled $e.ReadPath $e.ShadowPath)
                $e.IsSubmenu  = $false
                $out.Add($e)
            } catch { }
        }

        $apps.Close()
    }

    return $out
}

function getAllEntries {
    $all = [System.Collections.Generic.List[CmEntry]]::new()
    $add = { param($c) foreach ($e in $c) { if ($e) { $all.Add($e) } } }
    @(
        @('HKLM','SOFTWARE\Classes\*\shell','All Files'),
        @('HKCU','Software\Classes\*\shell','All Files'),
        @('HKLM','SOFTWARE\Classes\Directory\shell','Folders'),
        @('HKCU','Software\Classes\Directory\shell','Folders'),
        @('HKLM','SOFTWARE\Classes\Directory\Background\shell','Folder Background'),
        @('HKCU','Software\Classes\Directory\Background\shell','Folder Background'),
        @('HKLM','SOFTWARE\Classes\Drive\shell','Drives'),
        @('HKCU','Software\Classes\Drive\shell','Drives')
    ) | ForEach-Object { & $add (scanVerbs $_[0] $_[1] $_[2]) }
    @(
        @('HKLM','SOFTWARE\Classes\*\shellex\ContextMenuHandlers','All Files'),
        @('HKCU','Software\Classes\*\shellex\ContextMenuHandlers','All Files'),
        @('HKLM','SOFTWARE\Classes\Directory\shellex\ContextMenuHandlers','Folders'),
        @('HKCU','Software\Classes\Directory\shellex\ContextMenuHandlers','Folders'),
        @('HKLM','SOFTWARE\Classes\Directory\Background\shellex\ContextMenuHandlers','Folder Background'),
        @('HKCU','Software\Classes\Directory\Background\shellex\ContextMenuHandlers','Folder Background')
    ) | ForEach-Object { & $add (scanShellEx $_[0] $_[1] $_[2]) }
    & $add (scanOpenWithApplications)
    $videoExts = @('.mp4','.mkv','.avi','.mov','.wmv','.webm','.m4v','.mpg','.mpeg','.ts','.mts','.m2ts','.flv')
    $imageExts = @('.jpg','.jpeg','.png','.webp','.bmp','.tiff','.tif')
    & $add (scanExtGroup $videoExts 'Video Files')
    & $add (scanExtGroup $imageExts 'Image Files')
    # ProgID verbs (e.g. VLC.mp4\shell - where VLC registers Play/AddToPlaylist)
    & $add (scanProgIdShell $videoExts 'Video Files')
    & $add (scanProgIdShell $imageExts 'Image Files')
    # Perceived-type keys - where VLC, Clipchamp, Filmora etc. register
    @(
        @('HKLM','SOFTWARE\Classes\SystemFileAssociations\video\shell','Video Files'),
        @('HKCU','Software\Classes\SystemFileAssociations\video\shell','Video Files'),
        @('HKLM','SOFTWARE\Classes\SystemFileAssociations\image\shell','Image Files'),
        @('HKCU','Software\Classes\SystemFileAssociations\image\shell','Image Files'),
        @('HKLM','SOFTWARE\Classes\video\shell','Video Files'),
        @('HKCU','Software\Classes\video\shell','Video Files'),
        @('HKLM','SOFTWARE\Classes\image\shell','Image Files'),
        @('HKCU','Software\Classes\image\shell','Image Files')
    ) | ForEach-Object { & $add (scanVerbs $_[0] $_[1] $_[2]) }
    return $all
}

# ── Apply enable/disable (HKCU writes only) ───────────────────────────────────
function applyEntry([CmEntry]$entry, [bool]$enable) {
    $hkcu = [Microsoft.Win32.Registry]::CurrentUser
    if ($entry.Kind -eq 'OpenWith') {
        foreach ($sh in ($entry.ShadowPath -split ';')) {
            try {
                $k = $hkcu.OpenSubKey($sh, $true)
                if (-not $k -and -not $enable) { $k = $hkcu.CreateSubKey($sh) }
                if ($k) {
                    if ($enable) { try { $k.DeleteValue('NoOpenWith') } catch { } }
                    else { $k.SetValue('NoOpenWith','', [Microsoft.Win32.RegistryValueKind]::String) }
                    $k.Close()
                }
            } catch { }
        }
    } elseif ($entry.Kind -ne 'ShellEx') {
        foreach ($sh in ($entry.ShadowPath -split ';')) {
            try {
                $k = $hkcu.OpenSubKey($sh, $true)
                if (-not $k -and -not $enable) { $k = $hkcu.CreateSubKey($sh) }
                if ($k) {
                    if ($enable) { try { $k.DeleteValue('LegacyDisable') } catch { } }
                    else { $k.SetValue('LegacyDisable','', [Microsoft.Win32.RegistryValueKind]::String) }
                    $k.Close()
                }
            } catch { }
        }
    } else {
        try {
            setShellExtensionBlocked $entry.ClsId $entry.Label (-not $enable)
            $k = $hkcu.OpenSubKey($entry.ShadowPath, $true)
            if ($k) {
                $v = "$($k.GetValue(''))"
                if ($enable -and $v.StartsWith('-')) {
                    $k.SetValue('', $entry.ClsId, [Microsoft.Win32.RegistryValueKind]::String)
                }
                $k.Close()
            }
        } catch { }
    }
}
function notifyShell {
    Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public class CtxSh3 {
    [DllImport("shell32.dll")] public static extern void SHChangeNotify(int e,uint f,IntPtr a,IntPtr b);
}
'@ -ErrorAction SilentlyContinue
    try { [CtxSh3]::SHChangeNotify(0x08000000,0,[IntPtr]::Zero,[IntPtr]::Zero) } catch { }
}

# ── Icon loading ──────────────────────────────────────────────────────────────
$script:imgCache = [System.Collections.Generic.Dictionary[string,System.Drawing.Bitmap]]::new()

function getFallback([CmEntry]$e) {
    $rel = switch ($e.Kind) {
        'ShellEx'  { '..\task-stats\icons\cog.png' }
        'Submenu'  { '..\task-stats\icons\bullet_go.png' }
        'OpenWith' { 'icons\application_form.png' }
        default    { '..\transcribe\icons\wrench.png' }
    }
    $p = Join-Path $PSScriptRoot $rel
    try { if (Test-Path $p) { return [System.Drawing.Bitmap]::new($p) } } catch { }
    $bmp = New-Object System.Drawing.Bitmap(16,16); return $bmp
}
function getEntryBitmap([CmEntry]$entry) {
    $spec = $null
    if ($entry.Kind -eq 'OpenWith') {
        $vk = rOpen "$($entry.ReadPath)\shell\open"
        if ($vk) { $spec = $vk.GetValue('Icon'); $vk.Close() }
        if (-not $spec) {
            $dk = rOpen "$($entry.ReadPath)\DefaultIcon"
            if ($dk) { $spec = $dk.GetValue(''); $dk.Close() }
        }
    } else {
        $vk = rOpen $entry.ReadPath
        if ($vk) { $spec = $vk.GetValue('Icon'); $vk.Close() }
    }
    if (-not $spec -and $entry.Kind -eq 'ShellEx' -and $entry.ClsId) {
        $ck = rOpen "HKEY_CLASSES_ROOT\CLSID\$($entry.ClsId)\InprocServer32"
        if ($ck) { $dll = "$($ck.GetValue(''))"; $ck.Close(); if ($dll) { $spec = "$dll,0" } }
    }
    if (-not $spec) { return getFallback $entry }
    $key = "$spec"
    if ($script:imgCache.ContainsKey($key)) { return $script:imgCache[$key] }
    try {
        $raw = [System.Environment]::ExpandEnvironmentVariables($key).Trim()
        if ($raw.StartsWith('@')) { throw 'MUI' }
        $idx = 0; $comma = $raw.LastIndexOf(',')
        $path = if ($comma -gt 2) {
            [int]::TryParse($raw.Substring($comma+1),[ref]$idx)|Out-Null
            $raw.Substring(0,$comma)
        } else { $raw }
        $path = $path.Trim().Trim('"').Trim("'")
        if (-not [System.IO.File]::Exists($path)) { throw 'missing' }
        $icon = [IconUtil]::GetSmall($path, $idx)
        if (-not $icon) { $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($path) }
        if ($icon) {
            $bmp = New-Object System.Drawing.Bitmap(16,16)
            $g   = [System.Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode = 'HighQualityBicubic'
            $g.DrawImage($icon.ToBitmap(), 0, 0, 16, 16)
            $g.Dispose(); $icon.Dispose()
            $script:imgCache[$key] = $bmp; return $bmp
        }
    } catch { }
    $fb = getFallback $entry; $script:imgCache[$key] = $fb; return $fb
}

# ── Owner-draw paint routine ──────────────────────────────────────────────────
function paintList([System.Windows.Forms.PaintEventArgs]$pe, [int]$panelW) {
    $g = $pe.Graphics
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $g.SmoothingMode     = 'AntiAlias'

    $y = 0
    for ($i = 0; $i -lt $script:displayItems.Count; $i++) {
        $item = $script:displayItems[$i]
        $hov  = ($i -eq $script:hoveredIdx)

        # ---- background
        $bgC = if ($hov) { $C_ROW_HOV } elseif ($item.Enabled) { $C_ROW } else { $C_ROW_DIS }
        $bgB = [System.Drawing.SolidBrush]::new($bgC)
        $g.FillRectangle($bgB, 0, $y, $panelW, $ROW_H); $bgB.Dispose()

        # ---- icon
        $bmp = getEntryBitmap $item
        if ($bmp) {
            if (-not $item.Enabled) {
                $ia = New-Object System.Drawing.Imaging.ImageAttributes
                $cm = New-Object System.Drawing.Imaging.ColorMatrix; $cm.Matrix33 = 0.3
                $ia.SetColorMatrix($cm)
                $dest = New-Object System.Drawing.Rectangle($ICON_X, ($y+9), 16, 16)
                $g.DrawImage($bmp, $dest, 0, 0, $bmp.Width, $bmp.Height, 'Pixel', $ia)
            } else {
                $g.DrawImage($bmp, $ICON_X, ($y+9), 16, 16)
            }
        }

        # ---- text
        $txtC  = if ($item.Enabled) { $C_TXT } else { $C_TXT_DIS }
        $txtB  = [System.Drawing.SolidBrush]::new($txtC)
        $font  = if ($item.Enabled) { $GDI.fontNorm } else { $GDI.fontStrike }
        $tR    = New-Object System.Drawing.RectangleF($TEXT_X, $y, ($panelW - $TEXT_X - 75), $ROW_H)
        $g.DrawString($item.Label, $font, $txtB, $tR, $GDI.sfMid); $txtB.Dispose()

        # ---- submenu arrow
        if ($item.IsSubmenu) {
            $aB = [System.Drawing.SolidBrush]::new($txtC)
            $aR = New-Object System.Drawing.RectangleF(($panelW - 20), $y, 16, $ROW_H)
            $g.DrawString('>', $GDI.fontArrow, $aB, $aR, $GDI.sfCenter); $aB.Dispose()
        }

        # ---- action button (shown on hover)
        if ($hov) {
            $btnLabel = if ($item.Enabled) { 'Hide' } else { 'Show' }
            $btnClr   = if ($item.Enabled) { $C_BTN_HIDE } else { $C_BTN_SHOW }
            $btnRect  = New-Object System.Drawing.Rectangle(($panelW - $BTN_W - 6), ($y+5), $BTN_W, ($ROW_H-10))
            $btnPen   = New-Object System.Drawing.Pen($btnClr, 1)
            $g.DrawRectangle($btnPen, $btnRect); $btnPen.Dispose()
            $btnBrush = New-Object System.Drawing.SolidBrush($btnClr)
            $g.FillRectangle($btnBrush, $btnRect); $btnBrush.Dispose()
            $wB = [System.Drawing.Brushes]::White
            $g.DrawString($btnLabel, $GDI.fontBtn, $wB, [System.Drawing.RectangleF]::op_Implicit($btnRect), $GDI.sfCenter)
        }

        # ---- separator
        $sepP = New-Object System.Drawing.Pen($C_SEP, 1)
        $g.DrawLine($sepP, 0, ($y+$ROW_H-1), $panelW, ($y+$ROW_H-1)); $sepP.Dispose()

        $y += $ROW_H
    }
}

# ── Form icon ─────────────────────────────────────────────────────────────────
function pngToIcon([string]$p) {
    $b=$([System.IO.File]::ReadAllBytes($p))
    $ms=New-Object System.IO.MemoryStream
    $w=New-Object System.IO.BinaryWriter($ms)
    $w.Write([uint16]0);$w.Write([uint16]1);$w.Write([uint16]1)
    $w.Write([byte]16);$w.Write([byte]16);$w.Write([byte]0)
    $w.Write([byte]0);$w.Write([uint16]1);$w.Write([uint16]32)
    $w.Write([uint32]$b.Length);$w.Write([uint32]22);$w.Write($b)
    $ms.Position=0; return [System.Drawing.Icon]::new($ms)
}

# ── Build display list ────────────────────────────────────────────────────────
function buildDisplayItems {
    $context     = $script:cbContext.SelectedItem
    $showHidden  = $script:chkHidden.Checked

    # File-type contexts include All Files items (7-Zip, Open with Code, etc.)
    # because *\shell entries appear on every file including videos/images
    $categories = if ($context -in @('Video Files','Image Files','All Files')) {
        @($context, 'All Files')
    } else {
        @($context)
    }
    $contextItems = @($script:allEntries | Where-Object { $_.AppliesTo -in $categories })

    # Deduplicate by VerbName (case-insensitive). Priority: HKCU > HKLM > HKCR
    $deduped = [System.Collections.Generic.Dictionary[string,CmEntry]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in ($contextItems | Where-Object { $_.Source -eq 'HKCU' })) { $deduped[$e.VerbName] = $e }
    foreach ($e in ($contextItems | Where-Object { $_.Source -ne 'HKCU' })) {
        if (-not $deduped.ContainsKey($e.VerbName)) { $deduped[$e.VerbName] = $e }
    }

    $enabled  = @($deduped.Values | Where-Object {  $_.Enabled } | Sort-Object Label)
    $disabled = @($deduped.Values | Where-Object { -not $_.Enabled } | Sort-Object Label)
    $list = [System.Collections.Generic.List[CmEntry]]::new()
    foreach ($e in $enabled)  { $list.Add($e) }
    if ($showHidden) { foreach ($e in $disabled) { $list.Add($e) } }

    $script:displayItems = $list
    $h = [Math]::Max($list.Count * $ROW_H, 1)
    $script:listPanel.Height = $h
    $script:listPanel.Invalidate()

    $total = $deduped.Count
    $dis   = $disabled.Count
    $script:lblStatus.Text = "$($total-$dis) visible  |  $dis hidden  |  $total total"
}

function reloadAll {
    $script:lblStatus.Text = 'Scanning registry...'
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $form.Refresh()
    try   { $script:allEntries = getAllEntries }
    finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
    $script:imgCache.Clear()
    buildDisplayItems
}

# ── UI setup ──────────────────────────────────────────────────────────────────
$script:allEntries   = [CmEntry[]]@()
$script:displayItems = [System.Collections.Generic.List[CmEntry]]::new()
$script:hoveredIdx   = -1

$form = New-Object System.Windows.Forms.Form
$form.Text          = 'Context Menu Manager'
$form.Size          = New-Object System.Drawing.Size(520, 680)
$form.MinimumSize   = New-Object System.Drawing.Size(380, 360)
$form.StartPosition = 'CenterScreen'
$form.Font          = New-Object System.Drawing.Font('Segoe UI', 9)
$form.BackColor     = $C_BG

$iconPath = Join-Path $PSScriptRoot '..\task-stats\icons\application_view_list.png'
if (Test-Path $iconPath) { try { $form.Icon = pngToIcon $iconPath } catch { } }

# Toolbar
$toolbar = New-Object System.Windows.Forms.Panel
$toolbar.Dock = 'Top'; $toolbar.Height = 44; $toolbar.BackColor = $C_TOOLBAR

$lblCtx = New-Object System.Windows.Forms.Label
$lblCtx.Text = 'Show menu for:'; $lblCtx.AutoSize = $true
$lblCtx.ForeColor = [System.Drawing.Color]::FromArgb(175,175,175)
$lblCtx.Top = 12; $lblCtx.Left = 10

$script:cbContext = New-Object System.Windows.Forms.ComboBox
$script:cbContext.DropDownStyle = 'DropDownList'
$script:cbContext.Width = 160; $script:cbContext.Top = 8; $script:cbContext.Left = 110
$script:cbContext.Items.AddRange(@('Folder Background','Folders','All Files','Video Files','Image Files','Drives'))
$script:cbContext.SelectedIndex = 0

$script:chkHidden = New-Object System.Windows.Forms.CheckBox
$script:chkHidden.Text = 'Show hidden'; $script:chkHidden.Checked = $true
$script:chkHidden.ForeColor = [System.Drawing.Color]::FromArgb(175,175,175)
$script:chkHidden.AutoSize = $true; $script:chkHidden.Top = 11; $script:chkHidden.Left = 284

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = 'Refresh'; $btnRefresh.Width = 68; $btnRefresh.Height = 26
$btnRefresh.Top = 8; $btnRefresh.Left = 420
$btnRefresh.FlatStyle = 'Flat'
$btnRefresh.ForeColor = [System.Drawing.Color]::FromArgb(200,200,200)
$btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(65,65,65)
$btnRefresh.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(85,85,85)

$toolbar.Controls.AddRange(@($lblCtx, $script:cbContext, $script:chkHidden, $btnRefresh))

# Scroll container
$scroll = New-Object System.Windows.Forms.Panel
$scroll.Dock = 'Fill'; $scroll.BackColor = $C_BG; $scroll.AutoScroll = $true
try {
    $dp = [System.Windows.Forms.Panel].GetProperty('DoubleBuffered',[System.Reflection.BindingFlags]'NonPublic,Instance')
    $dp.SetValue($scroll, $true)
} catch { }

# The owner-draw list panel inside the scroll container
$script:listPanel = New-Object MenuPanel
$script:listPanel.SetBounds(0, 0, 480, 1)
$script:listPanel.BackColor = $C_BG

# Paint handler - renders all items via GDI+
$script:listPanel.add_Paint({
    param($s, $e)
    paintList $e $s.Width
})

# Resize: keep full width of scroll container
$scroll.add_Resize({
    $script:listPanel.Width = $scroll.ClientSize.Width
    $script:listPanel.Invalidate()
})

# Mouse hover
$script:listPanel.add_MouseMove({
    param($s, $e)
    $idx = [int]($e.Y / $ROW_H)
    if ($idx -ge $script:displayItems.Count) { $idx = -1 }
    if ($idx -ne $script:hoveredIdx) {
        $script:hoveredIdx = $idx
        $s.Invalidate()
    }
    # Update tooltip
    if ($idx -ge 0) {
        $item = $script:displayItems[$idx]
        $script:tip.SetToolTip($s, $item.ReadPath)
    } else {
        $script:tip.SetToolTip($s, '')
    }
})
$script:listPanel.add_MouseLeave({
    $script:hoveredIdx = -1
    $script:listPanel.Invalidate()
})

# Click handler
$script:listPanel.add_MouseClick({
    param($s, $e)
    $idx = [int]($e.Y / $ROW_H)
    if ($idx -lt 0 -or $idx -ge $script:displayItems.Count) { return }
    $item = $script:displayItems[$idx]
    $newState = -not $item.Enabled
    applyEntry $item $newState
    notifyShell
    $item.Enabled = $newState
    buildDisplayItems
})

$script:tip = New-Object System.Windows.Forms.ToolTip

$scroll.Controls.Add($script:listPanel)

# Status bar
$statusBar = New-Object System.Windows.Forms.Panel
$statusBar.Dock = 'Bottom'; $statusBar.Height = 28; $statusBar.BackColor = $C_TOOLBAR

$script:lblStatus = New-Object System.Windows.Forms.Label
$script:lblStatus.Text = 'Loading...'
$script:lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(140,140,140)
$script:lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 8)
$script:lblStatus.AutoSize = $true; $script:lblStatus.Top = 6; $script:lblStatus.Left = 10

$lblNote = New-Object System.Windows.Forms.Label
$lblNote.Text = 'Shows registry-managed items only. Windows built-ins (Rotate, Cast to Device, Defender, etc.) are not shown.'
$lblNote.ForeColor = [System.Drawing.Color]::FromArgb(90,90,90)
$lblNote.Font = New-Object System.Drawing.Font('Segoe UI', 7.5)
$lblNote.AutoSize = $true; $lblNote.Top = 10; $lblNote.Left = 370

$statusBar.Controls.Add($script:lblStatus)
$statusBar.Controls.Add($lblNote)

# Control add order matters for docking (Fill must be added before Top/Bottom)
$form.Controls.Add($scroll)
$form.Controls.Add($statusBar)
$form.Controls.Add($toolbar)

# Events
$script:cbContext.add_SelectedIndexChanged({ buildDisplayItems })
$script:chkHidden.add_CheckedChanged({ buildDisplayItems })
$btnRefresh.add_Click({ reloadAll })
$form.add_Shown({ reloadAll })
$scroll.add_Resize({ $script:listPanel.Width = $scroll.ClientSize.Width; $script:listPanel.Invalidate() })

[void]$form.ShowDialog()
