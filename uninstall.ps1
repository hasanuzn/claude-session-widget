#Requires -Version 5.1
<#
  Claude Session Widget — uninstaller / kaldırma
    -KeepSettings   Keep settings (%APPDATA%\ClaudeOturumWidget) / Ayarları silme
    -Quiet          No prompts or messages / Soru ve mesaj gösterme
#>
param([switch]$KeepSettings, [switch]$Quiet)

$ErrorActionPreference = 'Stop'
$AppName = 'Claude Session Widget'
$LegacyName = 'Claude Oturum Widget'
$Dest = Join-Path $env:LOCALAPPDATA 'ClaudeOturumWidget'
$SettingsDir = Join-Path $env:APPDATA 'ClaudeOturumWidget'
$Programs = [Environment]::GetFolderPath('Programs')
$Startup = [Environment]::GetFolderPath('Startup')
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClaudeOturumWidget'

$tr = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'tr'
function M([string]$en, [string]$trText) { if ($tr) { $trText } else { $en } }

Add-Type -AssemblyName PresentationFramework

if (-not $Quiet) {
  $answer = [System.Windows.MessageBox]::Show((M "Uninstall $AppName?" "$AppName kaldırılsın mı?"), $AppName, 'YesNo', 'Question')
  if ($answer -ne 'Yes') { exit 0 }
}

try {
  # Close the running widget
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*oturum-widget.ps1*' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 600

  Set-Location $env:TEMP
  foreach ($name in $AppName, $LegacyName) {
    Remove-Item -LiteralPath (Join-Path $Startup "$name.lnk") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $Programs $name) -Recurse -Force -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $UninstallKey -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $Dest -Recurse -Force -ErrorAction SilentlyContinue
  if (-not $KeepSettings) { Remove-Item -LiteralPath $SettingsDir -Recurse -Force -ErrorAction SilentlyContinue }
  Remove-Item -LiteralPath (Join-Path $env:TEMP 'oturum-widget.signal') -ErrorAction SilentlyContinue

  if (-not $Quiet) { [void][System.Windows.MessageBox]::Show((M "$AppName was uninstalled." "$AppName kaldırıldı."), $AppName, 'OK', 'Information') }
}
catch {
  if (-not $Quiet) { [void][System.Windows.MessageBox]::Show((M 'Uninstall error: ' 'Kaldırma sırasında hata: ') + $_.Exception.Message, $AppName, 'OK', 'Error') }
  exit 1
}
