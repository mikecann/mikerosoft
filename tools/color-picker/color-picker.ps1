param(
    [switch]$SelfTest,
    [switch]$SmokeTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "ColorPickerCore.ps1")

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not ("ColorPickerNative" -as [type])) {
    Add-Type -ReferencedAssemblies "System.Drawing" -TypeDefinition @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;

public static class ColorPickerNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    private static extern IntPtr GetDC(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);

    [DllImport("gdi32.dll")]
    private static extern uint GetPixel(IntPtr hdc, int nXPos, int nYPos);

    public static bool IsLeftButtonDown() {
        return (GetAsyncKeyState(0x01) & unchecked((short)0x8000)) != 0;
    }

    public static Color GetScreenPixel(int x, int y) {
        IntPtr hdc = GetDC(IntPtr.Zero);
        if (hdc == IntPtr.Zero) {
            throw new InvalidOperationException("Could not get the screen device context.");
        }

        try {
            uint pixel = GetPixel(hdc, x, y);
            if (pixel == 0xFFFFFFFF) {
                using (Bitmap bmp = new Bitmap(1, 1))
                using (Graphics graphics = Graphics.FromImage(bmp)) {
                    graphics.CopyFromScreen(x, y, 0, 0, new Size(1, 1));
                    return bmp.GetPixel(0, 0);
                }
            }

            int r = (int)(pixel & 0x000000FF);
            int g = (int)((pixel & 0x0000FF00) >> 8);
            int b = (int)((pixel & 0x00FF0000) >> 16);
            return Color.FromArgb(r, g, b);
        } finally {
            ReleaseDC(IntPtr.Zero, hdc);
        }
    }
}
'@
}

try { [ColorPickerNative]::SetProcessDPIAware() | Out-Null } catch { }

if ($SelfTest) {
    $pt = [ColorPickerNative+POINT]::new()
    [ColorPickerNative]::GetCursorPos([ref]$pt) | Out-Null
    $formats = Get-ColorPickerFormats -R 51 -G 102 -B 153
    if ($formats.HEX -ne "#336699") {
        throw "Color formatter self-test failed."
    }
    Write-Host "color-picker self-test passed" -ForegroundColor Green
    exit 0
}

function New-IconFromPng {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $stream = [System.IO.MemoryStream]::new()
    $writer = [System.IO.BinaryWriter]::new($stream)
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]1)
    $writer.Write([byte]16)
    $writer.Write([byte]16)
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]32)
    $writer.Write([uint32]$bytes.Length)
    $writer.Write([uint32]22)
    $writer.Write($bytes)
    $stream.Position = 0
    [System.Drawing.Icon]::new($stream)
}

function Set-ButtonStyle {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.Button]$Button,

        [System.Drawing.Color]$BackColor = [System.Drawing.Color]::FromArgb(55, 55, 58)
    )

    $Button.FlatStyle = "Flat"
    $Button.BackColor = $BackColor
    $Button.ForeColor = [System.Drawing.Color]::White
    $Button.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(88, 88, 92)
    $Button.FlatAppearance.BorderSize = 1
}

function Set-CopiedStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    [System.Windows.Forms.Clipboard]::SetText($Text)
    $script:statusLabel.Text = "Copied $Text"
}

function Update-Color {
    param(
        [Parameter(Mandatory = $true)]
        [System.Drawing.Color]$Color,

        [Parameter(Mandatory = $true)]
        [int]$X,

        [Parameter(Mandatory = $true)]
        [int]$Y,

        [Parameter(Mandatory = $true)]
        [string]$State
    )

    $formats = Get-ColorPickerFormats -R $Color.R -G $Color.G -B $Color.B
    $script:currentFormats = $formats

    foreach ($name in $script:formatOrder) {
        $script:formatTextBoxes[$name].Text = $formats[$name]
    }

    $script:swatchPanel.BackColor = $Color
    $script:swatchLabel.BackColor = $Color
    $script:swatchLabel.Text = $formats.HEX
    $script:swatchLabel.ForeColor = if ((Get-ColorPickerContrastName -R $Color.R -G $Color.G -B $Color.B) -eq "Black") {
        [System.Drawing.Color]::Black
    } else {
        [System.Drawing.Color]::White
    }

    $script:coordinateLabel.Text = "x $X, y $Y"
    $script:statusLabel.Text = $State
}

function Start-Picking {
    $script:isPicking = $true
    $script:pickerButton.Text = "Release mouse to pick"
    $script:pickerButton.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $script:pickerButton.Capture = $true
    $script:form.Cursor = [System.Windows.Forms.Cursors]::Cross
    $script:timer.Start()
}

function Stop-Picking {
    if (-not $script:isPicking) { return }

    $script:isPicking = $false
    $script:timer.Stop()
    $script:pickerButton.Text = "Hold and drag picker"
    $script:pickerButton.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 58)
    $script:pickerButton.Capture = $false
    $script:form.Cursor = [System.Windows.Forms.Cursors]::Default
    $script:statusLabel.Text = "Picked. Values are ready to copy."
}

$script:formatOrder = @("HEX", "RGB", "HSL", "HLS", "HSV", "CMYK", "BGR")
$script:formatTextBoxes = @{}
$script:currentFormats = [ordered]@{}
$script:isPicking = $false

$bg = [System.Drawing.Color]::FromArgb(29, 30, 33)
$panel = [System.Drawing.Color]::FromArgb(39, 41, 45)
$muted = [System.Drawing.Color]::FromArgb(164, 168, 176)
$line = [System.Drawing.Color]::FromArgb(65, 68, 74)
$accent = [System.Drawing.Color]::FromArgb(0, 120, 215)

$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = "Color Picker"
$script:form.ClientSize = New-Object System.Drawing.Size(430, 430)
$script:form.MinimumSize = New-Object System.Drawing.Size(420, 430)
$script:form.StartPosition = "Manual"
$script:form.FormBorderStyle = "FixedSingle"
$script:form.MaximizeBox = $false
$script:form.TopMost = $true
$script:form.BackColor = $bg
$script:form.ForeColor = [System.Drawing.Color]::White
$script:form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$script:form.KeyPreview = $true

$iconPath = Join-Path $PSScriptRoot "icons\color-picker.png"
if (Test-Path $iconPath) {
    try { $script:form.Icon = New-IconFromPng -Path $iconPath } catch { }
}

$workingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$script:form.Location = New-Object System.Drawing.Point(
    ($workingArea.Right - $script:form.Width - 18),
    ($workingArea.Bottom - $script:form.Height - 18)
)

$script:swatchPanel = New-Object System.Windows.Forms.Panel
$script:swatchPanel.Location = New-Object System.Drawing.Point(16, 16)
$script:swatchPanel.Size = New-Object System.Drawing.Size(132, 92)
$script:swatchPanel.BorderStyle = "FixedSingle"

$script:swatchLabel = New-Object System.Windows.Forms.Label
$script:swatchLabel.Dock = "Fill"
$script:swatchLabel.TextAlign = "MiddleCenter"
$script:swatchLabel.Font = New-Object System.Drawing.Font("Consolas", 13, [System.Drawing.FontStyle]::Bold)
$script:swatchPanel.Controls.Add($script:swatchLabel)

$script:pickerButton = New-Object System.Windows.Forms.Button
$script:pickerButton.Text = "Hold and drag picker"
$script:pickerButton.Location = New-Object System.Drawing.Point(164, 16)
$script:pickerButton.Size = New-Object System.Drawing.Size(248, 42)
$script:pickerButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
Set-ButtonStyle -Button $script:pickerButton

$copyHexButton = New-Object System.Windows.Forms.Button
$copyHexButton.Text = "Copy HEX"
$copyHexButton.Location = New-Object System.Drawing.Point(164, 66)
$copyHexButton.Size = New-Object System.Drawing.Size(116, 42)
Set-ButtonStyle -Button $copyHexButton -BackColor $accent

$copyAllButton = New-Object System.Windows.Forms.Button
$copyAllButton.Text = "Copy all"
$copyAllButton.Location = New-Object System.Drawing.Point(296, 66)
$copyAllButton.Size = New-Object System.Drawing.Size(116, 42)
Set-ButtonStyle -Button $copyAllButton

$separator = New-Object System.Windows.Forms.Panel
$separator.Location = New-Object System.Drawing.Point(16, 124)
$separator.Size = New-Object System.Drawing.Size(396, 1)
$separator.BackColor = $line

$rowTop = 140
foreach ($name in $script:formatOrder) {
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $name
    $label.Location = New-Object System.Drawing.Point(18, ($rowTop + 5))
    $label.Size = New-Object System.Drawing.Size(54, 22)
    $label.ForeColor = $muted
    $label.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point(76, $rowTop)
    $textBox.Size = New-Object System.Drawing.Size(244, 24)
    $textBox.ReadOnly = $true
    $textBox.BorderStyle = "FixedSingle"
    $textBox.BackColor = $panel
    $textBox.ForeColor = [System.Drawing.Color]::White
    $textBox.Font = New-Object System.Drawing.Font("Consolas", 10)

    $copyButton = New-Object System.Windows.Forms.Button
    $copyButton.Text = "Copy"
    $copyButton.Tag = $name
    $copyButton.Location = New-Object System.Drawing.Point(332, ($rowTop - 1))
    $copyButton.Size = New-Object System.Drawing.Size(80, 27)
    Set-ButtonStyle -Button $copyButton
    $copyButton.Add_Click({
        param($sender, $eventArgs)
        $formatName = [string]$sender.Tag
        Set-CopiedStatus -Text $script:formatTextBoxes[$formatName].Text
    })

    $script:formatTextBoxes[$name] = $textBox
    $script:form.Controls.AddRange(@($label, $textBox, $copyButton))
    $rowTop += 34
}

$script:coordinateLabel = New-Object System.Windows.Forms.Label
$script:coordinateLabel.Text = "x 0, y 0"
$script:coordinateLabel.Location = New-Object System.Drawing.Point(18, 386)
$script:coordinateLabel.Size = New-Object System.Drawing.Size(100, 22)
$script:coordinateLabel.ForeColor = $muted

$script:statusLabel = New-Object System.Windows.Forms.Label
$script:statusLabel.Text = "Ready."
$script:statusLabel.Location = New-Object System.Drawing.Point(120, 386)
$script:statusLabel.Size = New-Object System.Drawing.Size(292, 22)
$script:statusLabel.ForeColor = $muted
$script:statusLabel.TextAlign = "MiddleRight"

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 35
$script:timer.Add_Tick({
    if (-not $script:isPicking) { return }

    if (-not [ColorPickerNative]::IsLeftButtonDown()) {
        Stop-Picking
        return
    }

    $pt = [ColorPickerNative+POINT]::new()
    if (-not [ColorPickerNative]::GetCursorPos([ref]$pt)) {
        $script:statusLabel.Text = "Could not read cursor position."
        return
    }

    try {
        $color = [ColorPickerNative]::GetScreenPixel($pt.X, $pt.Y)
        Update-Color -Color $color -X $pt.X -Y $pt.Y -State "Picking..."
    } catch {
        $script:statusLabel.Text = $_.Exception.Message
    }
})

$script:pickerButton.Add_MouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Start-Picking
    }
})

$copyHexButton.Add_Click({
    Set-CopiedStatus -Text $script:formatTextBoxes["HEX"].Text
})

$copyAllButton.Add_Click({
    $lines = foreach ($name in $script:formatOrder) {
        "$name $($script:formatTextBoxes[$name].Text)"
    }
    Set-CopiedStatus -Text ($lines -join [Environment]::NewLine)
})

$script:form.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
        if ($script:isPicking) {
            Stop-Picking
        } else {
            $script:form.Close()
        }
    }
})

$script:form.Controls.AddRange(@(
    $script:swatchPanel,
    $script:pickerButton,
    $copyHexButton,
    $copyAllButton,
    $separator,
    $script:coordinateLabel,
    $script:statusLabel
))

Update-Color -Color ([System.Drawing.Color]::FromArgb(51, 102, 153)) -X 0 -Y 0 -State "Ready. Hold the picker button and drag over the screen."

if ($SmokeTest) {
    $script:smokeTimer = New-Object System.Windows.Forms.Timer
    $script:smokeTimer.Interval = 250
    $script:smokeTimer.Add_Tick({
        $script:smokeTimer.Stop()
        $script:form.Close()
    })
    $script:form.Add_Shown({
        $script:smokeTimer.Start()
    })
}

[System.Windows.Forms.Application]::Run($script:form)

if ($SmokeTest) {
    Write-Host "color-picker smoke-test passed" -ForegroundColor Green
}
