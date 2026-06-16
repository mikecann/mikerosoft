$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "..\ColorPickerCore.ps1")

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]
        $Actual,

        [Parameter(Mandatory = $true)]
        $Expected,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message. Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $threw = $false
    try {
        & $ScriptBlock
    } catch {
        $threw = $true
    }

    if (-not $threw) {
        throw "$Message. Expected command to throw."
    }
}

$red = Get-ColorPickerFormats -R 255 -G 0 -B 0
Assert-Equal $red.HEX "#FF0000" "Red hex"
Assert-Equal $red.RGB "rgb(255, 0, 0)" "Red RGB"
Assert-Equal $red.HSL "hsl(0, 100%, 50%)" "Red HSL"
Assert-Equal $red.HLS "hls(0, 50%, 100%)" "Red HLS"
Assert-Equal $red.HSV "hsv(0, 100%, 100%)" "Red HSV"
Assert-Equal $red.CMYK "cmyk(0%, 100%, 100%, 0%)" "Red CMYK"
Assert-Equal $red.BGR "0x0000FF" "Red Win32 BGR"

$blue = Get-ColorPickerFormats -R 0 -G 0 -B 255
Assert-Equal $blue.HSL "hsl(240, 100%, 50%)" "Blue HSL"
Assert-Equal $blue.HSV "hsv(240, 100%, 100%)" "Blue HSV"
Assert-Equal $blue.CMYK "cmyk(100%, 100%, 0%, 0%)" "Blue CMYK"
Assert-Equal $blue.BGR "0xFF0000" "Blue Win32 BGR"

$sample = Get-ColorPickerFormats -R 51 -G 102 -B 153
Assert-Equal $sample.HEX "#336699" "Sample hex"
Assert-Equal $sample.HSL "hsl(210, 50%, 40%)" "Sample HSL"
Assert-Equal $sample.HLS "hls(210, 40%, 50%)" "Sample HLS"
Assert-Equal $sample.HSV "hsv(210, 67%, 60%)" "Sample HSV"
Assert-Equal $sample.CMYK "cmyk(67%, 33%, 0%, 40%)" "Sample CMYK"
Assert-Equal $sample.BGR "0x996633" "Sample Win32 BGR"

$white = Get-ColorPickerFormats -R 255 -G 255 -B 255
Assert-Equal $white.HSL "hsl(0, 0%, 100%)" "White HSL"
Assert-Equal $white.CMYK "cmyk(0%, 0%, 0%, 0%)" "White CMYK"
Assert-Equal (Get-ColorPickerContrastName -R 255 -G 255 -B 255) "Black" "White contrast"

$black = Get-ColorPickerFormats -R 0 -G 0 -B 0
Assert-Equal $black.HSL "hsl(0, 0%, 0%)" "Black HSL"
Assert-Equal $black.CMYK "cmyk(0%, 0%, 0%, 100%)" "Black CMYK"
Assert-Equal (Get-ColorPickerContrastName -R 0 -G 0 -B 0) "White" "Black contrast"

Assert-Throws { Get-ColorPickerFormats -R 256 -G 0 -B 0 | Out-Null } "Rejects color bytes over 255"
Assert-Throws { Get-ColorPickerFormats -R 0 -G -1 -B 0 | Out-Null } "Rejects negative color bytes"

Write-Host "color-picker core tests passed" -ForegroundColor Green
