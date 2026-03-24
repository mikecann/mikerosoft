# backup-phone.ps1
# Copies all photos/videos from an iPhone (MTP device) into year/month subfolders (YYYY/mmm).
# Processes one folder at a time, newest first (so recent photos come first).
# Filenames are prefixed with their source folder to avoid collisions.
# HEIC files are automatically converted to WebP (in background while next file copies).
# Skips files that already exist in the destination.

param(
    [string]$Destination = "D:\bak\photos",
    [string]$DeviceName = "Apple iPhone",
    [switch]$Yes
)

$ErrorActionPreference = "Stop"

# --- Helpers ---

function Get-ShellFolder {
    param([object]$Parent, [string]$Name)
    foreach ($item in $Parent.Items()) {
        if ($item.Name -eq $Name) {
            return $item.GetFolder
        }
    }
    return $null
}

$script:MediaYmPy = Join-Path $PSScriptRoot "get_media_ym.py"
$script:MonthFolderNames = @(
    "jan", "feb", "mar", "apr", "may", "jun",
    "jul", "aug", "sep", "oct", "nov", "dec"
)

function Get-BackupSubfolderRelativePath {
    param([string]$FilePath)
    $ext = [IO.Path]::GetExtension($FilePath).ToLowerInvariant()
    # Keep in sync with IMAGE_EXTS_FOR_EXIF in get_media_ym.py
    $imageExts = @(
        ".heic", ".heif", ".jpg", ".jpeg", ".jpe", ".png", ".webp", ".tif", ".tiff"
    )
    if ($imageExts -contains $ext) {
        $rel = & python $script:MediaYmPy $FilePath 2>$null
        if ($LASTEXITCODE -eq 0 -and $rel) {
            return ($rel.Trim() -replace "/", [IO.Path]::DirectorySeparatorChar)
        }
    }
    $item = Get-Item -LiteralPath $FilePath
    $d = $item.LastWriteTime
    return "{0}{1}{2}" -f $d.Year, [IO.Path]::DirectorySeparatorChar, $script:MonthFolderNames[$d.Month - 1]
}

# --- Main ---

Write-Host ""
Write-Host "=== iPhone Photo Backup ===" -ForegroundColor Cyan
Write-Host ""

# Ensure destination exists
if (-not (Test-Path $Destination)) {
    Write-Host "Creating destination folder: $Destination"
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
}

# Connect to the MTP device via Shell COM
Write-Host "Looking for device: $DeviceName ..."
$shell = New-Object -ComObject Shell.Application
$myComputer = $shell.Namespace(0x11)

$device = $null
foreach ($item in $myComputer.Items()) {
    if ($item.Name -match $DeviceName) {
        $device = $item.GetFolder
        Write-Host "Found device: $($item.Name)" -ForegroundColor Green
        break
    }
}

if (-not $device) {
    Write-Host "Error: Could not find '$DeviceName'. Make sure it is:" -ForegroundColor Red
    Write-Host "  - Connected via USB" -ForegroundColor Red
    Write-Host "  - Unlocked and trusting this PC" -ForegroundColor Red
    Write-Host ""
    Write-Host "Available devices:" -ForegroundColor Yellow
    foreach ($item in $myComputer.Items()) {
        Write-Host "  - $($item.Name)"
    }
    exit 1
}

# Navigate to Internal Storage
$storage = Get-ShellFolder -Parent $device -Name "Internal Storage"
if (-not $storage) {
    Write-Host "Error: Could not find 'Internal Storage' on device." -ForegroundColor Red
    exit 1
}

# Prompt user to ensure phone is ready
Write-Host ""
Write-Host "Before starting, please make sure your phone is:" -ForegroundColor Yellow
Write-Host '  1. Unlocked' -ForegroundColor Yellow
Write-Host '  2. Tap "Trust" if you see a "Trust This Computer?" prompt' -ForegroundColor Yellow
Write-Host ""
if (-not $Yes) {
    Read-Host "Press Enter when ready"
}

# Build lookup of existing backup files (any depth under destination)
Write-Host "Checking existing backups in $Destination ..."
$existingFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
Get-ChildItem -Path $Destination -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
    $existingFiles.Add($_.Name) | Out-Null
}
Write-Host "  Existing files in backup: $($existingFiles.Count)" -ForegroundColor DarkGray

# Count backed-up files per folder prefix
$backedUpPrefixes = @{}
foreach ($name in $existingFiles) {
    $parts = $name -split '_', 3
    if ($parts.Count -ge 3) {
        $prefix = "$($parts[0])_$($parts[1])"
        if (-not $backedUpPrefixes.ContainsKey($prefix)) {
            $backedUpPrefixes[$prefix] = 0
        }
        $backedUpPrefixes[$prefix]++
    }
}

# Get folder list and sort newest first
Write-Host ""
Write-Host "Reading folder list..."
$folders = [System.Collections.ArrayList]::new()
foreach ($item in $storage.Items()) {
    $itemName = $item.Name
    if (-not $itemName) { continue }
    if ($item.IsFolder) {
        $folders.Add($item) | Out-Null
    }
}
$folders = $folders | Sort-Object -Property Name -Descending

Write-Host "Found $($folders.Count) folders. Processing newest first..." -ForegroundColor Cyan
Write-Host ""

# Use a temp staging folder so CopyHere never conflicts with existing files
$stagingDir = Join-Path $env:TEMP "backup-phone-staging"
if (Test-Path $stagingDir) { Remove-Item $stagingDir -Recurse -Force }
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null
$copyNamespace = $shell.Namespace($stagingDir)

# Python conversion script (written to temp file so background jobs can use it)
$convertScript = Join-Path $env:TEMP "backup-phone-heic2webp.py"
@"
import sys
import pillow_heif
pillow_heif.register_heif_opener()
from PIL import Image
img = Image.open(sys.argv[1])
exif = img.info.get('exif', None)
if exif:
    img.save(sys.argv[2], 'WEBP', quality=90, exif=exif)
else:
    img.save(sys.argv[2], 'WEBP', quality=90)
"@ | Set-Content -Path $convertScript -Encoding UTF8

$totalCopied = 0
$totalConverted = 0
$totalSkipped = 0
$totalErrors = 0
$foldersProcessed = 0
$foldersSkipped = 0
$overallStart = Get-Date

# Track background conversion jobs
$pendingJobs = [System.Collections.ArrayList]::new()

function Wait-ConversionJobs {
    param([bool]$WaitAll = $false)
    $limit = if ($WaitAll) { 0 } else { 3 }  # keep up to 3 running in parallel
    while ($pendingJobs.Count -gt $limit) {
        $done = @()
        foreach ($j in $pendingJobs) {
            if ($j.Process.HasExited) { $done += $j }
        }
        foreach ($j in $done) {
            if ($j.Process.ExitCode -eq 0 -and (Test-Path $j.FinalPath)) {
                Remove-Item $j.StagedPath -Force -ErrorAction SilentlyContinue
                $script:totalConverted++
                Write-Host "    $($j.DestNameFinal) (converted)" -ForegroundColor Green
            } else {
                # Conversion failed - move HEIC with prefix
                Move-Item -Path $j.StagedPath -Destination $j.FallbackPath -Force -ErrorAction SilentlyContinue
                $script:totalCopied++
                Write-Host "    $($j.DestName) (convert failed, kept HEIC)" -ForegroundColor Yellow
            }
            $j.Process.Dispose()
            $pendingJobs.Remove($j) | Out-Null
        }
        if ($pendingJobs.Count -gt $limit) {
            Start-Sleep -Milliseconds 200
        }
    }
}

foreach ($folder in $folders) {
    $folderName = $folder.Name
    $backedCount = if ($backedUpPrefixes.ContainsKey($folderName)) { $backedUpPrefixes[$folderName] } else { 0 }

    # Open folder (this can be slow over MTP)
    Write-Host "  Loading $folderName ..." -ForegroundColor DarkGray -NoNewline
    $sub = $folder.GetFolder
    $subItems = $sub.Items()
    $phoneCount = $subItems.Count

    if ($phoneCount -eq 0) {
        Write-Host " empty, skipping" -ForegroundColor DarkGray
        continue
    }

    # Skip if all files already backed up
    if ($backedCount -ge $phoneCount) {
        Write-Host " $phoneCount files (all backed up)" -ForegroundColor DarkGray
        $totalSkipped += $phoneCount
        $foldersSkipped++
        continue
    }

    Write-Host " $phoneCount files ($backedCount backed up)" -ForegroundColor White
    $foldersProcessed++
    $folderCopied = 0
    $folderConverted = 0
    $folderSkipped = 0
    $folderErrors = 0

    foreach ($fileItem in $subItems) {
        $fileName = $fileItem.Name
        if (-not $fileName) { continue }
        if ($fileItem.IsFolder) { continue }

        # Skip AAE sidecar files (iOS edit metadata, not actual images)
        if ($fileName -match '\.aae$') { continue }

        $destName = "${folderName}_${fileName}"
        $isHeic = $fileName -match '\.heic$'
        if ($isHeic) {
            $destNameFinal = [System.IO.Path]::ChangeExtension($destName, ".webp")
        } else {
            $destNameFinal = $destName
        }

        # Skip if already exists
        if ($existingFiles.Contains($destNameFinal)) {
            $folderSkipped++
            Write-Host "    $destNameFinal (skipped)" -ForegroundColor DarkGray
            continue
        }

        $stagedPath = Join-Path $stagingDir $fileName

        try {
            # Clean staging area for this file
            if (Test-Path $stagedPath) { Remove-Item $stagedPath -Force }

            # Copy from phone to staging folder
            $copyNamespace.CopyHere($fileItem, 0x14)

            # Wait for file to arrive in staging (MTP copy is async)
            $timeout = 120
            $elapsed = 0
            while (-not (Test-Path $stagedPath) -and $elapsed -lt $timeout) {
                Start-Sleep -Milliseconds 500
                $elapsed += 0.5
            }

            if (Test-Path $stagedPath) {
                if ($isHeic) {
                    # Move staged file to a unique temp name so next copy doesn't conflict
                    $heicTempPath = Join-Path $stagingDir "${folderName}_${fileName}"
                    Move-Item -Path $stagedPath -Destination $heicTempPath -Force

                    $sub = Get-BackupSubfolderRelativePath -FilePath $heicTempPath
                    $destSubDir = Join-Path $Destination $sub
                    if (-not (Test-Path -LiteralPath $destSubDir)) {
                        New-Item -ItemType Directory -Path $destSubDir -Force | Out-Null
                    }
                    $finalPath = Join-Path $destSubDir $destNameFinal
                    $fallbackHeicPath = Join-Path $destSubDir $destName

                    # Start conversion in background
                    $proc = Start-Process -FilePath "python" `
                        -ArgumentList "`"$convertScript`" `"$heicTempPath`" `"$finalPath`"" `
                        -NoNewWindow -PassThru
                    $pendingJobs.Add([PSCustomObject]@{
                        Process       = $proc
                        StagedPath    = $heicTempPath
                        FinalPath     = $finalPath
                        FallbackPath  = $fallbackHeicPath
                        DestName      = $destName
                        DestNameFinal = $destNameFinal
                    }) | Out-Null

                    # Drain completed jobs (keep up to 3 in flight)
                    Wait-ConversionJobs -WaitAll $false
                    $folderConverted++
                } else {
                    $sub = Get-BackupSubfolderRelativePath -FilePath $stagedPath
                    $destSubDir = Join-Path $Destination $sub
                    if (-not (Test-Path -LiteralPath $destSubDir)) {
                        New-Item -ItemType Directory -Path $destSubDir -Force | Out-Null
                    }
                    $finalPath = Join-Path $destSubDir $destNameFinal
                    Move-Item -Path $stagedPath -Destination $finalPath -Force
                    $folderCopied++
                    Write-Host "    $sub\$destNameFinal" -ForegroundColor Green
                }
                $existingFiles.Add($destNameFinal) | Out-Null
            } else {
                $folderErrors++
                Write-Host "    $destNameFinal TIMEOUT" -ForegroundColor Yellow
            }
        } catch {
            $folderErrors++
            Write-Host "    $destNameFinal ERROR: $_" -ForegroundColor Red
        }
    }

    # Wait for remaining conversions from this folder
    Wait-ConversionJobs -WaitAll $true

    $folderNew = $folderCopied + $folderConverted
    if ($folderNew -gt 0 -or $folderErrors -gt 0) {
        $parts = @()
        if ($folderCopied -gt 0) { $parts += "$folderCopied copied" }
        if ($folderConverted -gt 0) { $parts += "$folderConverted converted" }
        if ($folderSkipped -gt 0) { $parts += "$folderSkipped skipped" }
        if ($folderErrors -gt 0) { $parts += "$folderErrors errors" }
        Write-Host "    Done: $($parts -join ', ')" -ForegroundColor DarkCyan
    }

    $totalCopied += $folderCopied
    $totalSkipped += $folderSkipped
    $totalErrors += $folderErrors
}

# Final drain of any remaining jobs
Wait-ConversionJobs -WaitAll $true

# Clean up
Remove-Item $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $convertScript -Force -ErrorAction SilentlyContinue

$totalDuration = (Get-Date) - $overallStart
Write-Host ""
Write-Host "=== Backup Complete ===" -ForegroundColor Cyan
Write-Host "  Copied:    $totalCopied" -ForegroundColor Green
Write-Host "  Converted: $totalConverted (HEIC -> WebP)" -ForegroundColor Green
Write-Host "  Skipped:   $totalSkipped (already backed up)" -ForegroundColor DarkGray
Write-Host "  Folders:   $foldersProcessed processed, $foldersSkipped already done" -ForegroundColor DarkGray
if ($totalErrors -gt 0) {
    Write-Host "  Errors:    $totalErrors" -ForegroundColor Red
}
Write-Host "  Time:      $([math]::Round($totalDuration.TotalMinutes, 1)) minutes"
Write-Host "  Destination: $Destination"
Write-Host ""
