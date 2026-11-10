#Requires -Version 5.1
<#
  Generates src\assets\claude-session-widget.ico: the round ✻ app icon used by
  the Start menu / Startup shortcuts, the Installed apps entry and the setup window.

  The .ico holds PNG frames at 16, 20, 24, 32, 40, 48, 64, 96, 128 and 256 px, each
  drawn at its own size (not scaled down) so small sizes stay crisp. Run it again
  after changing the design and commit the result:

    powershell -NoProfile -ExecutionPolicy Bypass -File tools\New-Icon.ps1
#>
[CmdletBinding()]
param([string]$OutFile)

$ErrorActionPreference = 'Stop'
if (-not $OutFile) { $OutFile = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\assets\claude-session-widget.ico' }
Add-Type -AssemblyName System.Drawing

$Background = [System.Drawing.ColorTranslator]::FromHtml('#262624')
$Ring = [System.Drawing.ColorTranslator]::FromHtml('#3D3D3A')
$Accent = [System.Drawing.ColorTranslator]::FromHtml('#D97757')

# Draws the ✻ as eight rounded spokes (no font needed, so every size renders the same).
function New-IconFrame([int]$Size) {
  $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.PixelOffsetMode = 'HighQuality'
  $g.Clear([System.Drawing.Color]::Transparent)

  # Dark disc with a thin ring
  $pad = [Math]::Max(0.5, $Size * 0.02)
  $g.FillEllipse((New-Object System.Drawing.SolidBrush $Background), $pad, $pad, $Size - 2 * $pad, $Size - 2 * $pad)
  if ($Size -ge 24) {
    $pen = New-Object System.Drawing.Pen $Ring, ([Math]::Max(1, $Size * 0.025))
    $g.DrawEllipse($pen, $pad, $pad, $Size - 2 * $pad, $Size - 2 * $pad)
  }

  # Eight spokes; small sizes use thicker, longer spokes so the shape still reads
  $c = $Size / 2.0
  $outer = $Size * 0.33
  $inner = $Size * 0.07
  $width = [Math]::Max(1.6, $Size * 0.085)
  if ($Size -le 24) { $outer = $Size * 0.36; $inner = $Size * 0.04; $width = [Math]::Max(1.8, $Size * 0.12) }
  $spoke = New-Object System.Drawing.Pen $Accent, $width
  $spoke.StartCap = 'Round'; $spoke.EndCap = 'Round'
  for ($i = 0; $i -lt 8; $i++) {
    $a = [Math]::PI * $i / 4
    $len = $outer; if ($i % 2 -eq 1) { $len = $outer * 0.82 }   # diagonals a little shorter, like ✻
    $g.DrawLine($spoke, [float]($c + [Math]::Cos($a) * $inner), [float]($c + [Math]::Sin($a) * $inner),
      [float]($c + [Math]::Cos($a) * $len), [float]($c + [Math]::Sin($a) * $len))
  }
  $g.Dispose()

  $ms = New-Object System.IO.MemoryStream
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  return , $ms.ToArray()
}

$sizes = 16, 20, 24, 32, 40, 48, 64, 96, 128, 256
$frames = foreach ($s in $sizes) { , (New-IconFrame $s) }

# ICO container: ICONDIR, one ICONDIRENTRY per frame, then the PNG data
$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter $out
$w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
  $s = $sizes[$i]; $data = $frames[$i]
  $dim = [byte]($s % 256)            # 256 is written as 0
  $w.Write($dim); $w.Write($dim)
  $w.Write([byte]0); $w.Write([byte]0)          # colors, reserved
  $w.Write([UInt16]1); $w.Write([UInt16]32)     # planes, bits per pixel
  $w.Write([UInt32]$data.Length); $w.Write([UInt32]$offset)
  $offset += $data.Length
}
foreach ($data in $frames) { $w.Write($data) }
$w.Flush()

$dir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[System.IO.File]::WriteAllBytes($OutFile, $out.ToArray())
Write-Output $OutFile
