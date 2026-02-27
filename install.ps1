# install.ps1 — wires up all tools so they are available on the PATH.
#
# Run once after cloning, and re-run whenever a new tool is added.
# Updating an existing tool only requires a `git pull` — no reinstall needed.
#
# What it does:
#   - Writes thin stub .bat files into $ToolsDir (which should be on your PATH)
#   - Stubs simply forward to the real scripts inside this repo
#   - Recreates the "Scale Monitor" taskbar shortcut
#   - Runs each tool's deps.ps1 (if present) to install/check dependencies
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File install.ps1
#   powershell -ExecutionPolicy Bypass -File install.ps1 -SkipDeps

param(
    [switch]$SkipDeps
)

$RepoDir  = Split-Path -Parent $MyInvocation.MyCommand.Path   # auto-resolved; move the repo freely
$ToolsDir = "C:\dev\tools"                                    # directory on your PATH

if (-not (Test-Path $ToolsDir)) {
    New-Item -ItemType Directory -Path $ToolsDir | Out-Null
    Write-Host "Created $ToolsDir" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# .env — load repo-root .env file into the current process environment
# ---------------------------------------------------------------------------
$dotEnvPath = Join-Path $RepoDir ".env"
if (Test-Path $dotEnvPath) {
    Get-Content $dotEnvPath | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]*?)\s*=\s*(.*)\s*$') {
            $val = $Matches[2].Trim().Trim('"').Trim("'")
            [System.Environment]::SetEnvironmentVariable($Matches[1].Trim(), $val, 'Process')
        }
    }
    Write-Host "  [env]  Loaded $dotEnvPath" -ForegroundColor Green
} else {
    Write-Host "  [env]  No .env found - copy .env.example to .env and fill in your keys." -ForegroundColor Yellow
}

# Hard-fail if OPENROUTER_API_KEY is missing (required by video-titles and future AI tools).
if (-not $env:OPENROUTER_API_KEY) {
    Write-Host ""
    Write-Host "ERROR: OPENROUTER_API_KEY is not set." -ForegroundColor Red
    Write-Host "  1. Copy .env.example to .env at the repo root" -ForegroundColor Yellow
    Write-Host "  2. Set OPENROUTER_API_KEY=sk-or-..." -ForegroundColor Yellow
    Write-Host "  Get a key at: https://openrouter.ai/keys" -ForegroundColor Yellow
    exit 1
}

# ---------------------------------------------------------------------------
# PATH check — warn and offer to fix if $ToolsDir is not on PATH
# ---------------------------------------------------------------------------
$machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine"); if (-not $machinePath) { $machinePath = "" }
$userPath    = [System.Environment]::GetEnvironmentVariable("Path", "User");    if (-not $userPath)    { $userPath    = "" }
$onPath      = ($machinePath -split ";") + ($userPath -split ";") |
               Where-Object { $_.TrimEnd("\") -ieq $ToolsDir.TrimEnd("\") }

if (-not $onPath) {
    Write-Host ""
    Write-Host "WARNING: '$ToolsDir' is not on your PATH." -ForegroundColor Yellow
    $ans = Read-Host "  Add it to your User PATH now? [Y/n]"
    if ($ans -eq "" -or $ans -imatch "^y") {
        $newUserPath = ($userPath.TrimEnd(";") + ";$ToolsDir").TrimStart(";")
        [System.Environment]::SetEnvironmentVariable("Path", $newUserPath, "User")
        $env:PATH += ";$ToolsDir"
        Write-Host "  Added '$ToolsDir' to User PATH. Open a new terminal to use the tools." -ForegroundColor Green
    } else {
        Write-Host "  Skipped. Add '$ToolsDir' to PATH manually to use the tools." -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "Installing mikerosoft.app -> $ToolsDir" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------------------
# Helper: write a stub .bat that calls a target, preserving all arguments
# ---------------------------------------------------------------------------
function Write-BatStub($toolName, $content) {
    $dest = Join-Path $ToolsDir "$toolName.bat"
    Set-Content -Path $dest -Value $content -Encoding ASCII
    Write-Host "  [bat]  $dest" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# transcribe  — needs EXEDIR so the exe files in c:\dev\tools are found
# ---------------------------------------------------------------------------
Write-BatStub "transcribe" @"
@echo off
set "EXEDIR=%~dp0"
call "$RepoDir\tools\transcribe\transcribe.bat" %*
"@

# ---------------------------------------------------------------------------
# removebg
# ---------------------------------------------------------------------------
Write-BatStub "removebg" @"
@echo off
call "$RepoDir\tools\removebg\removebg.bat" %*
"@

# ---------------------------------------------------------------------------
# ghopen — open current repo/PR in browser
# ---------------------------------------------------------------------------
Write-BatStub "ghopen" @"
@echo off
call "$RepoDir\tools\ghopen\ghopen.bat" %*
"@

# ---------------------------------------------------------------------------
# ctxmenu — context menu manager GUI
# ---------------------------------------------------------------------------
Write-BatStub "ctxmenu" @"
@echo off
wscript.exe "$RepoDir\tools\ctxmenu\ctxmenu.vbs"
"@

# ---------------------------------------------------------------------------
# backup-phone
# ---------------------------------------------------------------------------
Write-BatStub "backup-phone" @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "$RepoDir\tools\backup-phone\backup-phone.ps1" %*
"@

# ---------------------------------------------------------------------------
# copypath — copies current or specified path to clipboard
# ---------------------------------------------------------------------------
Write-BatStub "copypath" @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "$RepoDir\tools\copypath\copypath.ps1" %*
"@

# ---------------------------------------------------------------------------
# video-to-markdown — YouTube URL to markdown clipboard
# ---------------------------------------------------------------------------
Write-BatStub "video-to-markdown" @"
@echo off
bun run "$RepoDir\tools\video-to-markdown\index.ts" %*
"@

# ---------------------------------------------------------------------------
# video-titles — CLI title brainstorming chat tool
# ---------------------------------------------------------------------------
Write-BatStub "video-titles" @"
@echo off
bun run "$RepoDir\tools\video-titles\index.ts" %*
"@

# ---------------------------------------------------------------------------
# generate-from-image — AI image generation from a right-clicked image
# ---------------------------------------------------------------------------
Write-BatStub "generate-from-image" @"
@echo off
bun run "$RepoDir\tools\generate-from-image\index.ts" %*
"@

# ---------------------------------------------------------------------------
# video-description — generate YouTube description from transcript via chat
# ---------------------------------------------------------------------------
Write-BatStub "video-description" @"
@echo off
bun run "$RepoDir\tools\video-description\index.ts" %*
"@

# ---------------------------------------------------------------------------
# svg-to-png — render SVG to PNG, smallest dimension >= 2048px
# ---------------------------------------------------------------------------
Write-BatStub "svg-to-png" @"
@echo off
bun run "$RepoDir\tools\svg-to-png\svg-to-png.ts" %*
"@

# ---------------------------------------------------------------------------
# img-to-svg — convert raster image to SVG vector using vtracer
# ---------------------------------------------------------------------------
Write-BatStub "img-to-svg" @"
@echo off
call "$RepoDir\tools\img-to-svg\img-to-svg.bat" %*
"@

# ---------------------------------------------------------------------------
# scale-monitor — taskbar shortcut (no bat stub needed; launched via shortcut)
# ---------------------------------------------------------------------------
$vbsPath      = "$RepoDir\tools\scale-monitor\scale-monitor.vbs"
$shortcutPath = Join-Path $ToolsDir "Scale Monitor.lnk"
$wsh          = New-Object -ComObject WScript.Shell
$sc           = $wsh.CreateShortcut($shortcutPath)
$sc.TargetPath       = "wscript.exe"
$sc.Arguments        = "`"$vbsPath`""
$sc.WorkingDirectory = "$RepoDir\tools\scale-monitor"
$sc.Description      = "Toggle Monitor 4 scale between 200% (normal) and 300% (filming)"
$sc.IconLocation     = "%SystemRoot%\System32\imageres.dll,109"
$sc.Save()
Write-Host "  [lnk]  $shortcutPath" -ForegroundColor Green

# Also place in Start Menu so Windows Search finds it (Win key + type)
$startMenuPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Scale Monitor.lnk"
$scSm = $wsh.CreateShortcut($startMenuPath)
$scSm.TargetPath       = "wscript.exe"
$scSm.Arguments        = "`"$vbsPath`""
$scSm.WorkingDirectory = "$RepoDir\tools\scale-monitor"
$scSm.Description      = "Toggle Monitor 4 scale between 200% (normal) and 300% (filming)"
$scSm.IconLocation     = "%SystemRoot%\System32\imageres.dll,109"
$scSm.Save()
Write-Host "  [lnk]  $startMenuPath" -ForegroundColor Green

# ---------------------------------------------------------------------------
# task-stats — bat stub (terminal launch) + taskbar shortcut
# ---------------------------------------------------------------------------
Write-BatStub "task-stats" @"
@echo off
wscript.exe "$RepoDir\tools\task-stats\task-stats.vbs"
"@

# task-stats shortcut (C:\dev\tools + Start Menu so Windows Search finds it)
$tmVbsPath      = "$RepoDir\tools\task-stats\task-stats.vbs"
$tmShortcutPath = Join-Path $ToolsDir "Task Stats.lnk"
$tmSc           = $wsh.CreateShortcut($tmShortcutPath)
$tmSc.TargetPath       = "wscript.exe"
$tmSc.Arguments        = "`"$tmVbsPath`""
$tmSc.WorkingDirectory = "$RepoDir\tools\task-stats"
$tmSc.Description      = "Taskbar system stats: NET / CPU / GPU / MEM sparklines"
$tmSc.IconLocation     = "%SystemRoot%\System32\imageres.dll,174"
$tmSc.Save()
Write-Host "  [lnk]  $tmShortcutPath" -ForegroundColor Green

$tmStartMenuPath = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Task Stats.lnk"
$tmSmSc = $wsh.CreateShortcut($tmStartMenuPath)
$tmSmSc.TargetPath       = "wscript.exe"
$tmSmSc.Arguments        = "`"$tmVbsPath`""
$tmSmSc.WorkingDirectory = "$RepoDir\tools\task-stats"
$tmSmSc.Description      = "Taskbar system stats: NET / CPU / GPU / MEM sparklines"
$tmSmSc.IconLocation     = "%SystemRoot%\System32\imageres.dll,174"
$tmSmSc.Save()
Write-Host "  [lnk]  $tmStartMenuPath" -ForegroundColor Green

# ---------------------------------------------------------------------------
# voice-type — taskbar shortcut (launched via VBS for no console window)
# ---------------------------------------------------------------------------
$vtVbsPath      = "$RepoDir\tools\voice-type\voice-type.vbs"
$vtShortcutPath = Join-Path $ToolsDir "Voice Type.lnk"
$vtSc           = $wsh.CreateShortcut($vtShortcutPath)
$vtSc.TargetPath       = "wscript.exe"
$vtSc.Arguments        = "`"$vtVbsPath`""
$vtSc.WorkingDirectory = "$RepoDir\tools\voice-type"
$vtSc.Description      = "Push-to-talk voice typing: hold Right Ctrl to record, release to transcribe and paste"
$vtSc.IconLocation     = "%SystemRoot%\System32\imageres.dll,109"
$vtSc.Save()
Write-Host "  [lnk]  $vtShortcutPath" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Context menu - "Mike's Tools" submenu in File Explorer
# Covers: video files (transcribe), image files (removebg), folders (ghopen)
# ---------------------------------------------------------------------------
Write-Host "  [reg]  Registering 'Mike''s Tools' context menus..." -ForegroundColor Green

# Convert a PNG to an .ico using PNG-in-ICO format (Vista+).
# Embeds raw PNG bytes into the ICO container to preserve full alpha
# transparency. GetHicon()/Icon.FromHandle() fills alpha with black.
function ConvertTo-Ico($pngPath, $icoPath) {
    $pngBytes = [System.IO.File]::ReadAllBytes($pngPath)
    $stream   = [System.IO.FileStream]::new($icoPath, [System.IO.FileMode]::Create)
    $w        = [System.IO.BinaryWriter]::new($stream)
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]1)   # ICONDIR
    $w.Write([byte]16);  $w.Write([byte]16);  $w.Write([byte]0)     # ICONDIRENTRY width/height/colorcount
    $w.Write([byte]0);   $w.Write([uint16]1); $w.Write([uint16]32)  # reserved/planes/bitcount
    $w.Write([uint32]$pngBytes.Length); $w.Write([uint32]22)        # data size / offset
    $w.Write($pngBytes)
    $w.Close(); $stream.Close()
}

# Helper: ensure a "Mike's Tools" submenu root exists at $rootKey with $icon.
function Set-MikesToolsRoot($rootKey, $icon) {
    New-Item -Path $rootKey -Force | Out-Null
    Set-ItemProperty -Path $rootKey -Name "MUIVerb"     -Value "Mike's Tools"
    Set-ItemProperty -Path $rootKey -Name "SubCommands" -Value ""
    Set-ItemProperty -Path $rootKey -Name "Icon"        -Value $icon
}

# Helper: add a verb entry + command under an existing Mike's Tools root.
function Add-MikesVerb($rootKey, $verbName, $label, $icon, $command) {
    $verbKey = "$rootKey\shell\$verbName"
    $cmdKey  = "$verbKey\command"
    New-Item -Path $verbKey -Force | Out-Null
    New-Item -Path $cmdKey  -Force | Out-Null
    Set-ItemProperty -Path $verbKey -Name "MUIVerb" -Value $label
    Set-ItemProperty -Path $verbKey -Name "Icon"    -Value $icon
    Set-ItemProperty -Path $cmdKey  -Name "(Default)" -Value $command
}

$iconsOut = "$env:LOCALAPPDATA\mikerosoft.app\icons"
New-Item -ItemType Directory -Force $iconsOut | Out-Null

$wrenchIco      = "$iconsOut\mikes-tools.ico"
$filmIco        = "$iconsOut\transcribe.ico"
$pictureIco     = "$iconsOut\removebg.ico"
$worldIco       = "$iconsOut\ghopen.ico"
$linkPageIco    = "$iconsOut\vid2md.ico"
$titlesIco      = "$iconsOut\video-titles.ico"
$wandIco        = "$iconsOut\wand.ico"
$svgIco         = "$iconsOut\svg-to-png.ico"
$descriptionIco = "$iconsOut\video-description.ico"
$imgToSvgIco    = "$iconsOut\img-to-svg.ico"
$viewer3dIco    = "$iconsOut\3d-viewer.ico"
ConvertTo-Ico "$RepoDir\tools\transcribe\icons\wrench.png"                        $wrenchIco
ConvertTo-Ico "$RepoDir\tools\transcribe\icons\film.png"                          $filmIco
ConvertTo-Ico "$RepoDir\tools\removebg\icons\picture.png"                         $pictureIco
ConvertTo-Ico "$RepoDir\tools\ghopen\icons\world_go.png"                          $worldIco
ConvertTo-Ico "$RepoDir\tools\video-to-markdown\icons\page_white_link.png"         $linkPageIco
ConvertTo-Ico "$RepoDir\tools\video-titles\icons\video-titles.png"                $titlesIco
ConvertTo-Ico "$RepoDir\tools\generate-from-image\icons\wand.png"                $wandIco
ConvertTo-Ico "$RepoDir\tools\svg-to-png\icons\svg-to-png.png"                   $svgIco
ConvertTo-Ico "$RepoDir\tools\video-description\icons\video-description.png"     $descriptionIco
ConvertTo-Ico "$RepoDir\tools\img-to-svg\icons\img-to-svg.png"                   $imgToSvgIco
ConvertTo-Ico "$RepoDir\tools\3d-viewer\icons\3d-viewer.png"                     $viewer3dIco
Write-Host "  [ico]  Icons written to $iconsOut" -ForegroundColor Green

# --- transcribe + vid2md: video file extensions ---
$videoExts = @('.mp4', '.mkv', '.avi', '.mov', '.wmv', '.webm', '.m4v', '.mpg', '.mpeg', '.ts', '.mts', '.m2ts', '.flv', '.f4v')
foreach ($ext in $videoExts) {
    $root = "HKCU:\Software\Classes\SystemFileAssociations\$ext\shell\MikesTools"
    Set-MikesToolsRoot $root $wrenchIco
    Add-MikesVerb $root "Transcribe"        "Transcribe Video"    $filmIco        'cmd.exe /k ""C:\dev\tools\transcribe.bat" "%1""'
    Add-MikesVerb $root "VideoTitles"      "Video Titles"        $titlesIco      'cmd.exe /k ""C:\dev\tools\video-titles.bat" "%1""'
    Add-MikesVerb $root "VideoDescription" "Video Description"   $descriptionIco 'cmd.exe /k ""C:\dev\tools\video-description.bat" "%1""'
    Add-MikesVerb $root "Vid2md"           "Video to Markdown"   $linkPageIco    'cmd.exe /k ""C:\dev\tools\video-to-markdown.bat" "%1""'
}

# --- removebg: image file extensions ---
$imageExts = @('.jpg', '.jpeg', '.png', '.webp', '.bmp', '.tiff', '.tif')
foreach ($ext in $imageExts) {
    $root = "HKCU:\Software\Classes\SystemFileAssociations\$ext\shell\MikesTools"
    Set-MikesToolsRoot $root $wrenchIco
    Add-MikesVerb $root "RemoveBg"           "Remove Background"    $pictureIco 'cmd.exe /k ""C:\dev\tools\removebg.bat" "%1""'
    Add-MikesVerb $root "GenerateFromImage" "Generate from Image"  $wandIco    'cmd.exe /k ""C:\dev\tools\generate-from-image.bat" "%1""'
    Add-MikesVerb $root "ImgToSvg"          "Convert to SVG"       $imgToSvgIco 'cmd.exe /k ""C:\dev\tools\img-to-svg.bat" "%1""'
}

# --- svg-to-png: SVG files ---
$svgRoot = "HKCU:\Software\Classes\SystemFileAssociations\.svg\shell\MikesTools"
Set-MikesToolsRoot $svgRoot $wrenchIco
Add-MikesVerb $svgRoot "SvgToPng" "Render to PNG (2048px min)" $svgIco 'cmd.exe /k ""C:\dev\tools\svg-to-png.bat" "%1""'

# --- 3d-viewer: GLB files (context menu) ---
$glbRoot = "HKCU:\Software\Classes\SystemFileAssociations\.glb\shell\MikesTools"
Set-MikesToolsRoot $glbRoot $wrenchIco
Add-MikesVerb $glbRoot "View3D" "View in 3D Viewer" $viewer3dIco "wscript.exe `"$RepoDir\tools\3d-viewer\3d-viewer.vbs`" `"%1`""

# --- 3d-viewer: GLB default file association (double-click to open) ---
# Register a ProgID with the open verb, then point .glb at it.
# UserChoice takes priority on Win10+ if a default was previously set via the OS dialog;
# in that case a reminder is printed below to check Default Apps.
$progId     = 'Mikerosoft.3DViewer'
$openCmd    = "wscript.exe `"$RepoDir\tools\3d-viewer\3d-viewer.vbs`" `"%1`""

# ProgID registration
New-Item -Path "HKCU:\Software\Classes\$progId"                        -Force | Out-Null
Set-ItemProperty "HKCU:\Software\Classes\$progId"                      -Name '(Default)'  -Value 'GLB 3D Model'
New-Item -Path "HKCU:\Software\Classes\$progId\DefaultIcon"            -Force | Out-Null
Set-ItemProperty "HKCU:\Software\Classes\$progId\DefaultIcon"          -Name '(Default)'  -Value $viewer3dIco
New-Item -Path "HKCU:\Software\Classes\$progId\shell\open"             -Force | Out-Null
Set-ItemProperty "HKCU:\Software\Classes\$progId\shell\open"           -Name '(Default)'  -Value 'View in 3D Viewer'
New-Item -Path "HKCU:\Software\Classes\$progId\shell\open\command"     -Force | Out-Null
Set-ItemProperty "HKCU:\Software\Classes\$progId\shell\open\command"   -Name '(Default)'  -Value $openCmd

# Point .glb at the ProgID and add to OpenWithProgids
New-Item -Path "HKCU:\Software\Classes\.glb"                           -Force | Out-Null
Set-ItemProperty "HKCU:\Software\Classes\.glb"                         -Name '(Default)'  -Value $progId
New-Item -Path "HKCU:\Software\Classes\.glb\OpenWithProgids"           -Force | Out-Null
New-ItemProperty "HKCU:\Software\Classes\.glb\OpenWithProgids"         -Name $progId -Value '' -PropertyType String -Force | Out-Null

Write-Host "  [reg]  .glb default open: $progId" -ForegroundColor Green

# --- vid2md: Internet Shortcut files (.url) - YouTube links ---
$urlRoot = "HKCU:\Software\Classes\SystemFileAssociations\.url\shell\MikesTools"
Set-MikesToolsRoot $urlRoot $wrenchIco
Add-MikesVerb $urlRoot "Vid2md" "Video to Markdown" $linkPageIco 'cmd.exe /k ""C:\dev\tools\video-to-markdown.bat" "%1""'

# --- ghopen + vid2md: folders (right-click on folder icon) and folder background ---
$vid2mdCmd = 'cmd.exe /k ""C:\dev\tools\video-to-markdown.bat" "%1""'

# Directory - right-clicking a folder item; %1 = folder path
$dirRoot = "HKCU:\Software\Classes\Directory\shell\MikesTools"
Set-MikesToolsRoot $dirRoot $wrenchIco
Add-MikesVerb $dirRoot "GhOpen"           "Open on GitHub"     $worldIco       'cmd.exe /k "cd /d "%1" && "C:\dev\tools\ghopen.bat""'
Add-MikesVerb $dirRoot "VideoDescription" "Video Description"  $descriptionIco 'cmd.exe /k ""C:\dev\tools\video-description.bat" "%1""'
Add-MikesVerb $dirRoot "Vid2md"           "Video to Markdown"  $linkPageIco    $vid2mdCmd

# Directory\Background - right-clicking inside an open folder; %V = current folder
$bgRoot = "HKCU:\Software\Classes\Directory\Background\shell\MikesTools"
Set-MikesToolsRoot $bgRoot $wrenchIco
Add-MikesVerb $bgRoot "GhOpen"           "Open on GitHub"     $worldIco       'cmd.exe /k "cd /d "%V" && "C:\dev\tools\ghopen.bat""'
Add-MikesVerb $bgRoot "VideoDescription" "Video Description"  $descriptionIco 'cmd.exe /k ""C:\dev\tools\video-description.bat" "%V""'
Add-MikesVerb $bgRoot "Vid2md"           "Video to Markdown"  $linkPageIco    'cmd.exe /k "C:\dev\tools\video-to-markdown.bat"'

# --- vid2md: all files and folders via AllFilesystemObjects ---
# AllFilesystemObjects is a Windows shell class that matches every file and folder.
# It has no literal '*' in the registry path so PowerShell's -Path handles it safely.
# Windows merges these verbs with any more-specific SystemFileAssociations entries
# (e.g. video files also get Transcribe from their own registration).
$afoRoot = "HKCU:\Software\Classes\AllFilesystemObjects\shell\MikesTools"
Set-MikesToolsRoot $afoRoot $wrenchIco
Add-MikesVerb $afoRoot "Vid2md" "Video to Markdown" $linkPageIco $vid2mdCmd

# Notify the shell so Explorer picks up all changes without a manual restart.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class ShellNotify {
    [DllImport("shell32.dll")]
    public static extern void SHChangeNotify(int wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);
}
'@
[ShellNotify]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero)

Write-Host "  [reg]  Done. Mike's Tools in context menus for videos, images, and folders." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Dependencies — run each tool's deps.ps1 if present
# ---------------------------------------------------------------------------
if ($SkipDeps) {
    Write-Host "Skipping dependency checks (-SkipDeps was set)." -ForegroundColor DarkGray
} else {
    Write-Host ""
    Write-Host "Checking / installing tool dependencies..." -ForegroundColor Cyan

    $depsScripts = Get-ChildItem -Path $RepoDir -Recurse -Filter "deps.ps1" |
        Where-Object { $_.FullName -ne (Join-Path $RepoDir "deps.ps1") }

    if ($depsScripts.Count -eq 0) {
        Write-Host "  (no deps.ps1 files found)" -ForegroundColor DarkGray
    } else {
        foreach ($script in $depsScripts | Sort-Object FullName) {
            & $script.FullName
        }
    }
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Done. To update tools in future: git pull (no reinstall needed)." -ForegroundColor Yellow
Write-Host "To add a new tool: create its subfolder, then re-run install.ps1." -ForegroundColor Yellow
Write-Host "To skip dependency checks: install.ps1 -SkipDeps" -ForegroundColor Yellow
Write-Host ""
Write-Host "Reminder: right-click 'Scale Monitor.lnk' in $ToolsDir and pin to taskbar." -ForegroundColor Cyan
Write-Host "Reminder: right-click 'Task Stats.lnk' in $ToolsDir and pin to taskbar." -ForegroundColor Cyan
Write-Host "Reminder: right-click 'Voice Type.lnk' in $ToolsDir and pin to taskbar (or run on login)." -ForegroundColor Cyan
Write-Host "Reminder: if double-clicking .glb files doesn't open 3D Viewer, go to Settings > Default Apps > choose by file type > .glb." -ForegroundColor Cyan
