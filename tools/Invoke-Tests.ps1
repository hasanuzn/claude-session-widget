#Requires -Version 5.1
<#
  Runs the Pester tests in tests\ and exits non-zero when any test fails.

  Needs Pester 5 (Windows PowerShell 5.1 ships only Pester 3.4):
    Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck

  Usage: powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-Tests.ps1 [-ResultFile testResults.xml]
#>
param([string]$ResultFile)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

$pester = Get-Module Pester -ListAvailable | Where-Object { $_.Version.Major -ge 5 } |
  Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
  Write-Host 'Pester 5 or newer is required. Install it with:' -ForegroundColor Red
  Write-Host '  Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck' -ForegroundColor Red
  exit 1
}
Remove-Module Pester -ErrorAction SilentlyContinue
Import-Module $pester.Path -Force
Write-Host "Using Pester $($pester.Version)"

$cfg = New-PesterConfiguration
$cfg.Run.Path = Join-Path $Root 'tests'
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Detailed'
if ($ResultFile) {
  $cfg.TestResult.Enabled = $true
  $cfg.TestResult.OutputFormat = 'NUnitXml'
  $cfg.TestResult.OutputPath = $ResultFile
}
$result = Invoke-Pester -Configuration $cfg

if ($result.Result -ne 'Passed' -or $result.FailedCount -gt 0 -or $result.FailedBlocksCount -gt 0 -or $result.FailedContainersCount -gt 0) {
  Write-Host ("Tests failed: {0} failed, {1} passed, {2} failed blocks, {3} failed containers" -f
    $result.FailedCount, $result.PassedCount, $result.FailedBlocksCount, $result.FailedContainersCount) -ForegroundColor Red
  exit 1
}
Write-Host ("All tests passed ({0})" -f $result.PassedCount) -ForegroundColor Green
exit 0
