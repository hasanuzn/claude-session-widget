#Requires -Version 5.1
<#
  Claude Session Widget — uninstaller
  Removes the current install and anything left by the older
  "Claude Oturum Widget" version.
    -KeepSettings   Keep settings (%APPDATA%\ClaudeSessionWidget)
    -Quiet          No prompts or messages
#>
param([switch]$KeepSettings, [switch]$Quiet)

$ErrorActionPreference = 'Stop'
$AppName = 'Claude Session Widget'
$LegacyName = 'Claude Oturum Widget'
$Programs = [Environment]::GetFolderPath('Programs')
$Startup = [Environment]::GetFolderPath('Startup')
$UninstallRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'

# Current and legacy locations
$InstallDirs = @((Join-Path $env:LOCALAPPDATA 'ClaudeSessionWidget'), (Join-Path $env:LOCALAPPDATA 'ClaudeOturumWidget'))
$SettingsDirs = @((Join-Path $env:APPDATA 'ClaudeSessionWidget'), (Join-Path $env:APPDATA 'ClaudeOturumWidget'))
$UninstallKeys = @("$UninstallRoot\ClaudeSessionWidget", "$UninstallRoot\ClaudeOturumWidget")
$TempFiles = @('claude-session-widget.signal', 'claude-session-widget-demo.signal', 'oturum-widget.signal')

$tr = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'tr'
function M([string]$en, [string]$trText) { if ($tr) { $trText } else { $en } }

Add-Type -AssemblyName PresentationFramework

if (-not $Quiet) {
  $answer = [System.Windows.MessageBox]::Show((M "Uninstall $AppName?" "$AppName kaldırılsın mı?"), $AppName, 'YesNo', 'Question')
  if ($answer -ne 'Yes') { exit 0 }
}

try {
  # Close running widgets (old and new script names)
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $_.ProcessId -ne $PID -and
      ($_.CommandLine -like '*oturum-widget.ps1*' -or $_.CommandLine -like '*claude-session-widget.ps1*')
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 600

  Set-Location $env:TEMP
  foreach ($name in $AppName, $LegacyName) {
    Remove-Item -LiteralPath (Join-Path $Startup "$name.lnk") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Programs "$name.lnk") -Force -ErrorAction SilentlyContinue   # Start menu entry
    Remove-Item -LiteralPath (Join-Path $Programs $name) -Recurse -Force -ErrorAction SilentlyContinue  # older Start menu folder
  }
  foreach ($key in $UninstallKeys) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
  foreach ($dir in $InstallDirs) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
  if (-not $KeepSettings) {
    foreach ($dir in $SettingsDirs) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
  }
  foreach ($f in $TempFiles) { Remove-Item -LiteralPath (Join-Path $env:TEMP $f) -ErrorAction SilentlyContinue }

  if (-not $Quiet) { [void][System.Windows.MessageBox]::Show((M "$AppName was uninstalled." "$AppName kaldırıldı."), $AppName, 'OK', 'Information') }
}
catch {
  if (-not $Quiet) { [void][System.Windows.MessageBox]::Show((M 'Uninstall error: ' 'Kaldırma sırasında hata: ') + $_.Exception.Message, $AppName, 'OK', 'Error') }
  exit 1
}
