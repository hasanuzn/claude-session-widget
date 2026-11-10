#Requires -Version 5.1
<#
  Static checks for the PowerShell sources (no Pester needed).

  - every *.ps1 / *.psd1 parses with the PowerShell AST parser
  - every *.ps1 / *.psd1 starts with a UTF-8 BOM and uses CRLF line endings
    (Windows PowerShell 5.1 reads BOM-less files as ANSI, which breaks
    non-ASCII text such as the Turkish UI strings)
  - get.ps1, Install.cmd and Uninstall.cmd are pure ASCII with CRLF
    (get.ps1 runs through "irm | iex"; the .cmd files run through cmd.exe)

  Exits 1 and lists every problem when a check fails.

  Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\Test-Scripts.ps1 [-Root <repo>]
#>
param([string]$Root = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
$problems = New-Object System.Collections.ArrayList
$excludeDirs = @('.git', 'dist', 'node_modules')

function Get-RelPath([string]$path) { return $path.Substring($Root.Length + 1) }
function Add-Problem([string]$file, [string]$message) { [void]$problems.Add([pscustomobject]@{ File = $file; Problem = $message }) }

# Returns a description of the first line-ending problem, or $null when the
# file uses CRLF everywhere.
function Test-Crlf([byte[]]$bytes) {
  $line = 1
  for ($i = 0; $i -lt $bytes.Length; $i++) {
    if ($bytes[$i] -eq 10) {
      if ($i -eq 0 -or $bytes[$i - 1] -ne 13) { return "LF without CR (line $line); expected CRLF" }
      $line++
    }
    elseif ($bytes[$i] -eq 13 -and ($i + 1 -ge $bytes.Length -or $bytes[$i + 1] -ne 10)) {
      return "CR without LF (line $line); expected CRLF"
    }
  }
  return $null
}

function Test-HasBom([byte[]]$bytes) {
  return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

$asciiOnly = @('get.ps1', 'Install.cmd', 'Uninstall.cmd')

# (-Include is silently ignored together with -LiteralPath on 5.1, so filter by extension.)
$files = @(Get-ChildItem -LiteralPath $Root -Recurse -File |
  Where-Object {
    if (@('.ps1', '.psd1') -notcontains $_.Extension.ToLowerInvariant()) { return $false }
    $rel = Get-RelPath $_.FullName
    -not ($excludeDirs | Where-Object { $rel -eq $_ -or $rel.StartsWith("$_\") })
  } | Sort-Object FullName)

foreach ($f in $files) {
  $rel = Get-RelPath $f.FullName
  $bytes = [System.IO.File]::ReadAllBytes($f.FullName)

  # 1. Syntax
  $tokens = $null; $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
  foreach ($e in @($errors)) {
    $msg = (($e.Message -split "`r?`n")[0]).Trim()
    if ($msg.Length -gt 160) { $msg = $msg.Substring(0, 157) + '...' }
    Add-Problem $rel ("parse error at line {0}, col {1}: {2}" -f $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $msg)
  }

  # 2. Encoding (ASCII-only files are checked separately below)
  if ($asciiOnly -notcontains $rel) {
    if (-not (Test-HasBom $bytes)) { Add-Problem $rel 'missing UTF-8 BOM' }
    if ($bytes.Length -ge 6 -and (Test-HasBom $bytes) -and $bytes[3] -eq 0xEF -and $bytes[4] -eq 0xBB -and $bytes[5] -eq 0xBF) {
      Add-Problem $rel 'duplicated UTF-8 BOM'
    }
    $crlf = Test-Crlf $bytes
    if ($crlf) { Add-Problem $rel $crlf }
  }
}

# 3. Pure-ASCII files at the repository root
foreach ($name in $asciiOnly) {
  $path = Join-Path $Root $name
  if (-not (Test-Path -LiteralPath $path)) { Add-Problem $name 'file is missing'; continue }
  $bytes = [System.IO.File]::ReadAllBytes($path)
  if (Test-HasBom $bytes) { Add-Problem $name 'has a UTF-8 BOM; must be pure ASCII' }
  $line = 1; $bad = New-Object System.Collections.ArrayList
  foreach ($b in $bytes) {
    if ($b -eq 10) { $line++ }
    elseif ($b -gt 127 -and $bad -notcontains $line) { [void]$bad.Add($line) }
  }
  if ($bad.Count) { Add-Problem $name ('non-ASCII bytes on line(s) ' + (($bad | Select-Object -First 10) -join ', ')) }
  $crlf = Test-Crlf $bytes
  if ($crlf) { Add-Problem $name $crlf }
}

$checked = $files.Count + @($asciiOnly | Where-Object { $files.Name -notcontains $_ }).Count
if ($problems.Count) {
  Write-Host ("Test-Scripts: {0} problem(s) found in {1} file(s):" -f $problems.Count, @($problems | Select-Object -ExpandProperty File -Unique).Count) -ForegroundColor Red
  foreach ($p in $problems) { Write-Host ("  {0}: {1}" -f $p.File, $p.Problem) -ForegroundColor Red }
  exit 1
}
Write-Host ("Test-Scripts: OK ({0} files checked)" -f $checked) -ForegroundColor Green
exit 0
