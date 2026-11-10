#Requires -Version 5.1
<#
  Claude Session Widget — installer

  Double-click Install.cmd, or use the one-line get.ps1 command from the README.
  Installs to %LOCALAPPDATA%\ClaudeSessionWidget (no admin rights needed),
  creates Start menu / Startup shortcuts, registers an "Installed apps" entry
  and removes the older "Claude Oturum Widget" version.

  Options:
    -NoStartup   Do not start with Windows
    -NoLaunch    Do not launch after install
#>
param(
  [switch]$NoStartup,
  [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$AppName = 'Claude Session Widget'
$Dest = Join-Path $env:LOCALAPPDATA 'ClaudeSessionWidget'
$Programs = [Environment]::GetFolderPath('Programs')
$Startup = [Environment]::GetFolderPath('Startup')
$StartMenu = Join-Path $Programs $AppName
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClaudeSessionWidget'

# Older version ("Claude Oturum Widget")
$LegacyName = 'Claude Oturum Widget'
$LegacyDest = Join-Path $env:LOCALAPPDATA 'ClaudeOturumWidget'
$LegacyUninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClaudeOturumWidget'

# Messages in Turkish when Windows is Turkish, English otherwise
$tr = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'tr'
function M([string]$en, [string]$trText) { if ($tr) { $trText } else { $en } }
function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }

function Save-WidgetIcon([string]$path) {
  Add-Type -AssemblyName System.Drawing
  $bmp = New-Object System.Drawing.Bitmap 64, 64
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.TextRenderingHint = 'AntiAliasGridFit'
  $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#262624'))), 0, 0, 63, 63)
  $font = New-Object System.Drawing.Font('Segoe UI Symbol', 36, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
  $sf = New-Object System.Drawing.StringFormat
  $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml('#D97757'))
  $g.DrawString([string][char]0x273B, $font, $brush, (New-Object System.Drawing.RectangleF(0, 2, 64, 64)), $sf)
  $g.Dispose()
  $ico = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
  $fs = [System.IO.File]::Create($path)
  $ico.Save($fs)
  $fs.Close()
}

# Stops running widgets, old (oturum-widget.ps1) and new (claude-session-widget.ps1).
function Stop-Widget {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $_.ProcessId -ne $PID -and
      ($_.CommandLine -like '*oturum-widget.ps1*' -or $_.CommandLine -like '*claude-session-widget.ps1*')
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 600
}

try {
  Say ''
  Say ("  * " + (M "Installing $AppName" "$AppName kuruluyor")) Cyan
  Say ''

  $root = $PSScriptRoot
  if (-not $root -or -not (Test-Path -LiteralPath (Join-Path $root 'src\claude-session-widget.ps1'))) {
    throw (M 'src\claude-session-widget.ps1 not found. Install with Install.cmd or get.ps1.' 'src\claude-session-widget.ps1 bulunamadı. Install.cmd ya da get.ps1 ile kurun.')
  }

  # ---- Close running copies
  Stop-Widget

  # ---- Remove the older version
  Remove-Item -LiteralPath $LegacyDest -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $LegacyUninstallKey -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $Programs $LegacyName) -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $Startup "$LegacyName.lnk") -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $env:TEMP 'oturum-widget.signal') -Force -ErrorAction SilentlyContinue

  # ---- Copy files (fresh copy, so files removed upstream do not linger)
  Say ('  ' + (M 'Copying files to' 'Dosyalar kopyalanıyor:') + " $Dest")
  Remove-Item -LiteralPath $Dest -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $Dest | Out-Null
  Copy-Item -Path (Join-Path $root 'src\*') -Destination $Dest -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $root 'uninstall.ps1') -Destination (Join-Path $Dest 'uninstall.ps1') -Force
  Get-ChildItem -LiteralPath $Dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

  $icon = Join-Path $Dest 'widget.ico'
  try { Save-WidgetIcon $icon } catch { $icon = $null }

  # Shortcut and launch-command helpers shared with the widget
  . (Join-Path $Dest 'lib\Settings.ps1')
  $ps = Get-PowerShellExe

  # ---- Start menu shortcuts (also replaces ones left by older versions)
  Say ('  ' + (M 'Creating Start menu shortcuts' 'Başlat menüsü kısayolları oluşturuluyor'))
  Remove-Item -LiteralPath $StartMenu -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $StartMenu | Out-Null
  New-WidgetShortcut -Path (Join-Path $StartMenu "$AppName.lnk") -AppDir $Dest `
    -Description (M 'Shows running Claude sessions' 'Çalışan Claude oturumlarını gösterir')
  New-WidgetShortcut -Path (Join-Path $StartMenu ("$AppName - " + (M 'Settings' 'Ayarlar') + '.lnk')) -AppDir $Dest `
    -Extra '-OpenSettings' -Description (M 'Widget settings' 'Widget ayarları')
  $sh = New-Object -ComObject WScript.Shell
  $l = $sh.CreateShortcut((Join-Path $StartMenu ("$AppName - " + (M 'Uninstall' 'Kaldır') + '.lnk')))
  $l.TargetPath = $ps
  $l.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $Dest 'uninstall.ps1')`""
  $l.WorkingDirectory = $Dest
  if ($icon) { $l.IconLocation = $icon }
  $l.Description = (M 'Uninstalls the widget' "Widget'ı kaldırır")
  $l.Save()

  # ---- Start with Windows
  $startupLnk = Get-StartupShortcutPath
  if ($NoStartup) {
    Remove-Item -LiteralPath $startupLnk -ErrorAction SilentlyContinue
  } else {
    Say ('  ' + (M 'Will start with Windows (can be turned off in Settings)' "Windows açılınca başlatılacak (Ayarlar'dan kapatılabilir)"))
    New-WidgetShortcut -Path $startupLnk -AppDir $Dest
  }

  # ---- Add to "Installed apps"
  $version = '1.0.0'
  $m = Select-String -LiteralPath (Join-Path $Dest 'claude-session-widget.ps1') -Pattern '^\$AppVersion\s*=\s*.([0-9.]+).' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($m) { $version = $m.Matches[0].Groups[1].Value }
  New-Item -Path $UninstallKey -Force | Out-Null
  $props = @{
    DisplayName = $AppName
    DisplayVersion = $version
    Publisher = 'claude-session-widget'
    InstallLocation = $Dest
    UninstallString = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $Dest 'uninstall.ps1')`""
    NoModify = 1
    NoRepair = 1
  }
  if ($icon) { $props.DisplayIcon = $icon }
  foreach ($k in $props.Keys) {
    $type = 'String'; if ($props[$k] -is [int]) { $type = 'DWord' }
    New-ItemProperty -Path $UninstallKey -Name $k -Value $props[$k] -PropertyType $type -Force | Out-Null
  }

  if (-not $NoLaunch) {
    Say ('  ' + (M 'Starting the widget' 'Widget başlatılıyor'))
    Start-Process -FilePath $ps -ArgumentList (Get-WidgetLaunchArgument -AppDir $Dest) -WorkingDirectory $Dest -WindowStyle Hidden
  }

  Say ''
  Say ('  ' + (M 'Done. The widget is in the bottom-right corner of your screen.' 'Kurulum tamam. Widget ekranın sağ alt köşesinde.')) Green
  Say ('  ' + (M "Start menu > $AppName to reopen it, change settings or uninstall." "Başlat menüsü > $AppName ile yeniden açabilir, ayarlarını değiştirebilir ya da kaldırabilirsiniz."))
  Say ''
}
catch {
  Say ''
  Say ('  ' + (M 'Install failed:' 'Kurulum başarısız:') + " $($_.Exception.Message)") Red
  Say ''
  exit 1
}
