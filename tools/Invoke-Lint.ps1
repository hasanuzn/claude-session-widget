#Requires -Version 5.1
<#
  Runs PSScriptAnalyzer on src\, install.ps1, uninstall.ps1 and get.ps1.
  Prints errors and warnings; exits 1 only when there is an Error (or a
  ParseError) finding. Warnings are reported but do not fail the run.

  Needs PSScriptAnalyzer:
    Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -SkipPublisherCheck

  Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Lint.ps1
#>
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

if (-not (Get-Module PSScriptAnalyzer -ListAvailable)) {
  Write-Host 'PSScriptAnalyzer is required: Install-Module PSScriptAnalyzer -Scope CurrentUser -Force' -ForegroundColor Red
  exit 1
}
Import-Module PSScriptAnalyzer

$targets = @('src', 'install.ps1', 'uninstall.ps1', 'get.ps1') |
  ForEach-Object { Join-Path $Root $_ } |
  Where-Object { Test-Path -LiteralPath $_ }

$findings = @(foreach ($t in $targets) {
  Invoke-ScriptAnalyzer -Path $t -Recurse -Severity @('Error', 'Warning', 'ParseError') -ErrorAction Continue
})

$errorFindings = @($findings | Where-Object { [string]$_.Severity -in @('Error', 'ParseError') })
$warnFindings = @($findings | Where-Object { [string]$_.Severity -eq 'Warning' })

foreach ($f in $findings) {
  $rel = $f.ScriptPath
  if ($rel -and $rel.StartsWith($Root)) { $rel = $rel.Substring($Root.Length + 1) }
  $msg = (([string]$f.Message -split "`r?`n")[0]).Trim()
  if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 197) + '...' }
  $line = "{0}:{1} [{2}] {3}: {4}" -f $rel, $f.Line, $f.Severity, $f.RuleName, $msg
  if ([string]$f.Severity -eq 'Warning') {
    Write-Host $line -ForegroundColor Yellow
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::warning file=$($rel -replace '\\','/'),line=$($f.Line)::$($f.RuleName): $msg" }
  }
  else {
    Write-Host $line -ForegroundColor Red
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::error file=$($rel -replace '\\','/'),line=$($f.Line)::$($f.RuleName): $msg" }
  }
}

Write-Host ("PSScriptAnalyzer: {0} error(s), {1} warning(s)" -f $errorFindings.Count, $warnFindings.Count)
if ($errorFindings.Count) { exit 1 }
exit 0
