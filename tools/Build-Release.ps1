#Requires -Version 5.1
<#
  Builds the release archive dist\claude-session-widget-<version>.zip.

  The archive holds one top-level folder, claude-session-widget-<version>\,
  with: src\ (whole folder), install.ps1, uninstall.ps1, Install.cmd,
  Uninstall.cmd, README.md, LICENSE. Files are stored byte-for-byte (no
  line-ending or encoding conversion), so the BOM/CRLF scripts stay intact.

  The version comes from  $AppVersion = '...'  in src\claude-session-widget.ps1
  (falls back to src\oturum-widget.ps1) unless -Version is given.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Release.ps1 [-Version 1.2.3] [-OutDir dist]
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\Build-Release.ps1 -ShowVersion
#>
param(
  [string]$Version,
  [string]$OutDir,
  [switch]$ShowVersion
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $Root 'dist' }

function Get-AppVersion {
  foreach ($name in 'claude-session-widget.ps1', 'oturum-widget.ps1') {
    $path = Join-Path $Root "src\$name"
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    $m = [regex]::Match($text, '(?m)^\s*\$AppVersion\s*=\s*[''"]([^''"]+)[''"]')
    if ($m.Success) { return $m.Groups[1].Value }
  }
  throw 'Could not find $AppVersion = ''...'' in src\claude-session-widget.ps1 or src\oturum-widget.ps1.'
}

if ($ShowVersion) { Get-AppVersion; return }
if (-not $Version) { $Version = Get-AppVersion }
if ($Version -notmatch '^[0-9A-Za-z][0-9A-Za-z.\-+]*$') { throw "Invalid version '$Version'." }

# Generated or OS files that may sit in a working copy (see .gitignore).
$skipNames = @('widget.ico', 'Thumbs.db', 'desktop.ini')
$skipExt = @('.log')

$items = New-Object System.Collections.ArrayList
foreach ($name in 'install.ps1', 'uninstall.ps1', 'Install.cmd', 'Uninstall.cmd', 'README.md', 'LICENSE') {
  $path = Join-Path $Root $name
  if (-not (Test-Path -LiteralPath $path)) { throw "Required file is missing: $name" }
  [void]$items.Add([pscustomobject]@{ Path = $path; Entry = $name })
}
$srcDir = Join-Path $Root 'src'
if (-not (Test-Path -LiteralPath $srcDir)) { throw 'Required folder is missing: src' }
Get-ChildItem -LiteralPath $srcDir -Recurse -File | Sort-Object FullName | ForEach-Object {
  if ($skipNames -contains $_.Name -or $skipExt -contains $_.Extension) { return }
  $rel = $_.FullName.Substring($Root.Length + 1) -replace '\\', '/'
  [void]$items.Add([pscustomobject]@{ Path = $_.FullName; Entry = $rel })
}

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
$baseName = "claude-session-widget-$Version"
$zipPath = Join-Path $OutDir "$baseName.zip"
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

$stream = [System.IO.File]::Open($zipPath, [System.IO.FileMode]::CreateNew)
try {
  $zip = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
  try {
    foreach ($it in $items) {
      # Forward slashes: Compress-Archive on 5.1 writes backslashes, which
      # some unzip tools turn into literal file names.
      $entry = $zip.CreateEntry("$baseName/$($it.Entry)", [System.IO.Compression.CompressionLevel]::Optimal)
      $entry.LastWriteTime = [DateTimeOffset](Get-Item -LiteralPath $it.Path).LastWriteTime
      $bytes = [System.IO.File]::ReadAllBytes($it.Path)
      $es = $entry.Open()
      try { $es.Write($bytes, 0, $bytes.Length) } finally { $es.Dispose() }
    }
  }
  finally { $zip.Dispose() }
}
finally { $stream.Dispose() }

Write-Host ("Built {0} ({1} files, version {2})" -f $zipPath, $items.Count, $Version)
$zipPath
