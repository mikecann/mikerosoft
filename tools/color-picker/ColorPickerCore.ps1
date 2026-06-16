Set-StrictMode -Version Latest

function Assert-ColorByte {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [int]$Value
    )

    if ($Value -lt 0 -or $Value -gt 255) {
        throw "$Name must be between 0 and 255. Got $Value."
    }
}

function Convert-RgbToHsl {
    param(
        [Parameter(Mandatory = $true)][int]$R,
        [Parameter(Mandatory = $true)][int]$G,
        [Parameter(Mandatory = $true)][int]$B
    )

    Assert-ColorByte "R" $R
    Assert-ColorByte "G" $G
    Assert-ColorByte "B" $B

    $rn = $R / 255.0
    $gn = $G / 255.0
    $bn = $B / 255.0

    $max = [Math]::Max($rn, [Math]::Max($gn, $bn))
    $min = [Math]::Min($rn, [Math]::Min($gn, $bn))
    $delta = $max - $min

    $h = 0.0
    $s = 0.0
    $l = ($max + $min) / 2.0

    if ($delta -ne 0) {
        $s = if ($l -gt 0.5) {
            $delta / (2.0 - $max - $min)
        } else {
            $delta / ($max + $min)
        }

        if ($max -eq $rn) {
            $h = (($gn - $bn) / $delta)
            if ($gn -lt $bn) { $h += 6.0 }
        } elseif ($max -eq $gn) {
            $h = (($bn - $rn) / $delta) + 2.0
        } else {
            $h = (($rn - $gn) / $delta) + 4.0
        }

        $h /= 6.0
    }

    [pscustomobject]@{
        H = [int][Math]::Round($h * 360.0)
        S = [int][Math]::Round($s * 100.0)
        L = [int][Math]::Round($l * 100.0)
    }
}

function Convert-RgbToHsv {
    param(
        [Parameter(Mandatory = $true)][int]$R,
        [Parameter(Mandatory = $true)][int]$G,
        [Parameter(Mandatory = $true)][int]$B
    )

    Assert-ColorByte "R" $R
    Assert-ColorByte "G" $G
    Assert-ColorByte "B" $B

    $rn = $R / 255.0
    $gn = $G / 255.0
    $bn = $B / 255.0

    $max = [Math]::Max($rn, [Math]::Max($gn, $bn))
    $min = [Math]::Min($rn, [Math]::Min($gn, $bn))
    $delta = $max - $min

    $h = 0.0
    if ($delta -ne 0) {
        if ($max -eq $rn) {
            $h = 60.0 * ((($gn - $bn) / $delta) % 6.0)
        } elseif ($max -eq $gn) {
            $h = 60.0 * ((($bn - $rn) / $delta) + 2.0)
        } else {
            $h = 60.0 * ((($rn - $gn) / $delta) + 4.0)
        }
    }
    if ($h -lt 0) { $h += 360.0 }

    $s = if ($max -eq 0) { 0.0 } else { $delta / $max }

    [pscustomobject]@{
        H = [int][Math]::Round($h)
        S = [int][Math]::Round($s * 100.0)
        V = [int][Math]::Round($max * 100.0)
    }
}

function Convert-RgbToCmyk {
    param(
        [Parameter(Mandatory = $true)][int]$R,
        [Parameter(Mandatory = $true)][int]$G,
        [Parameter(Mandatory = $true)][int]$B
    )

    Assert-ColorByte "R" $R
    Assert-ColorByte "G" $G
    Assert-ColorByte "B" $B

    $rn = $R / 255.0
    $gn = $G / 255.0
    $bn = $B / 255.0

    $k = 1.0 - [Math]::Max($rn, [Math]::Max($gn, $bn))
    if ($k -ge 1.0) {
        return [pscustomobject]@{ C = 0; M = 0; Y = 0; K = 100 }
    }

    [pscustomobject]@{
        C = [int][Math]::Round(((1.0 - $rn - $k) / (1.0 - $k)) * 100.0)
        M = [int][Math]::Round(((1.0 - $gn - $k) / (1.0 - $k)) * 100.0)
        Y = [int][Math]::Round(((1.0 - $bn - $k) / (1.0 - $k)) * 100.0)
        K = [int][Math]::Round($k * 100.0)
    }
}

function Get-ColorPickerFormats {
    param(
        [Parameter(Mandatory = $true)][int]$R,
        [Parameter(Mandatory = $true)][int]$G,
        [Parameter(Mandatory = $true)][int]$B
    )

    Assert-ColorByte "R" $R
    Assert-ColorByte "G" $G
    Assert-ColorByte "B" $B

    $hsl = Convert-RgbToHsl -R $R -G $G -B $B
    $hsv = Convert-RgbToHsv -R $R -G $G -B $B
    $cmyk = Convert-RgbToCmyk -R $R -G $G -B $B

    [ordered]@{
        HEX  = "#{0:X2}{1:X2}{2:X2}" -f $R, $G, $B
        RGB  = "rgb($R, $G, $B)"
        HSL  = "hsl($($hsl.H), $($hsl.S)%, $($hsl.L)%)"
        HLS  = "hls($($hsl.H), $($hsl.L)%, $($hsl.S)%)"
        HSV  = "hsv($($hsv.H), $($hsv.S)%, $($hsv.V)%)"
        CMYK = "cmyk($($cmyk.C)%, $($cmyk.M)%, $($cmyk.Y)%, $($cmyk.K)%)"
        BGR  = "0x{0:X2}{1:X2}{2:X2}" -f $B, $G, $R
    }
}

function Get-ColorPickerContrastName {
    param(
        [Parameter(Mandatory = $true)][int]$R,
        [Parameter(Mandatory = $true)][int]$G,
        [Parameter(Mandatory = $true)][int]$B
    )

    Assert-ColorByte "R" $R
    Assert-ColorByte "G" $G
    Assert-ColorByte "B" $B

    $luminance = (0.299 * $R) + (0.587 * $G) + (0.114 * $B)
    if ($luminance -ge 150) { "Black" } else { "White" }
}
