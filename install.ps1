#Requires -Version 5.1
<#
  Claude Session Widget — console installer.

  Most people double-click Install.cmd, which opens the setup window
  (installer\Setup.ps1). This script does the same install in a console; the
  one-line installer (get.ps1) and scripted installs use it.
  Installs to %LOCALAPPDATA%\ClaudeSessionWidget (no admin rights needed).

  Options:
    -NoStartup   Do not start with Windows
    -NoLaunch    Do not launch after install
#>
param(
  [switch]$NoStartup,
  [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$LangDir = Join-Path $Root 'src\lang'

function Say([string]$Text, [string]$Color = 'Gray') { Write-Host $Text -ForegroundColor $Color }

try {
  . (Join-Path $Root 'src\lib\I18n.ps1')
  Import-Strings -Language (Resolve-Language -Path $LangDir) -Path $LangDir
  . (Join-Path $Root 'installer\Installer.ps1')

  Say ''
  Say ('  * ' + (T 'SetupTitle')) Cyan
  Say ''
  $result = Install-ClaudeSessionWidget -SourceRoot $Root -NoStartup:$NoStartup -Progress {
    param($pct, $key)
    if ($key -ne 'SetupStepDone') { Say ('  ' + (T $key)) }
  }
  if (-not $NoLaunch) { Start-InstalledWidget }

  Say ''
  Say ('  ' + (T 'SetupConsoleDone')) Green
  Say ('  ' + ((T 'SetupConsoleHint') -f 'Claude Session Widget'))
  Say "  $($result.Dest)" DarkGray
  Say ''
}
catch {
  $msg = $_.Exception.Message
  if (Get-Command T -ErrorAction SilentlyContinue) { $msg = (T 'SetupConsoleFailed') -f $msg } else { $msg = "Install failed: $msg" }
  Say ''
  Say "  $msg" Red
  Say ''
  exit 1
}
