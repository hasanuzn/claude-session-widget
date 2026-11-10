#Requires -Version 5.1
<#
  Claude Session Widget — installer / kurulum

  Double-click Install.cmd, or use the one-line get.ps1 command from the README.
  Install.cmd dosyasına çift tıklayın ya da README'deki tek satırlık get.ps1 komutunu kullanın.

  Options / Seçenekler:
    -NoStartup   Do not start with Windows / Windows açılınca başlatma
    -NoLaunch    Do not launch after install / Kurulumdan sonra başlatma
#>
param(
  [switch]$NoStartup,
  [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$AppName = 'Claude Session Widget'
$LegacyName = 'Claude Oturum Widget'
$Dest = Join-Path $env:LOCALAPPDATA 'ClaudeOturumWidget'
$Programs = [Environment]::GetFolderPath('Programs')
$Startup = [Environment]::GetFolderPath('Startup')
$StartMenu = Join-Path $Programs $AppName
$StartupLnk = Join-Path $Startup "$AppName.lnk"
$UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClaudeOturumWidget'

# Language: Turkish when Windows is Turkish, English otherwise
$tr = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'tr'
function M([string]$en, [string]$trText) { if ($tr) { $trText } else { $en } }
function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }

function New-Shortcut([string]$path, [string]$target, [string]$arguments, [string]$icon, [string]$desc) {
  $sh = New-Object -ComObject WScript.Shell
  $l = $sh.CreateShortcut($path)
  $l.TargetPath = $target
  $l.Arguments = $arguments
  $l.WorkingDirectory = $Dest
  if ($icon) { $l.IconLocation = $icon }
  $l.Description = $desc
  $l.Save()
}

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

try {
  Say ''
  Say ("  * " + (M "Installing $AppName" "$AppName kuruluyor")) Cyan
  Say ''

  $root = $PSScriptRoot
  if (-not $root -or -not (Test-Path -LiteralPath (Join-Path $root 'src\oturum-widget.ps1'))) {
    throw (M 'src\oturum-widget.ps1 not found. Install with Install.cmd or get.ps1.' 'src\oturum-widget.ps1 bulunamadı. Install.cmd ya da get.ps1 ile kurun.')
  }

  # ---- Close a running copy
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*oturum-widget.ps1*' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Start-Sleep -Milliseconds 600

  # ---- Copy files
  Say ('  ' + (M 'Copying files to' 'Dosyalar kopyalanıyor:') + " $Dest")
  New-Item -ItemType Directory -Force -Path $Dest | Out-Null
  Copy-Item -Path (Join-Path $root 'src\*') -Destination $Dest -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $root 'uninstall.ps1') -Destination (Join-Path $Dest 'uninstall.ps1') -Force
  Get-ChildItem -LiteralPath $Dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

  $icon = Join-Path $Dest 'widget.ico'
  try { Save-WidgetIcon $icon } catch { $icon = $null }

  # ---- Remove shortcuts left by older versions
  Remove-Item -LiteralPath (Join-Path $Programs $LegacyName) -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $Startup "$LegacyName.lnk") -Force -ErrorAction SilentlyContinue

  # ---- Start menu shortcuts
  Say ('  ' + (M 'Creating Start menu shortcuts' 'Başlat menüsü kısayolları oluşturuluyor'))
  Remove-Item -LiteralPath $StartMenu -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $StartMenu | Out-Null
  $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
  $vbs = Join-Path $Dest 'baslat.vbs'
  $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
  New-Shortcut (Join-Path $StartMenu "$AppName.lnk") $wscript "`"$vbs`"" $icon (M 'Shows running Claude sessions' 'Çalışan Claude oturumlarını gösterir')
  New-Shortcut (Join-Path $StartMenu ("$AppName - " + (M 'Settings' 'Ayarlar') + '.lnk')) $wscript "`"$vbs`" -OpenSettings" $icon (M 'Widget settings' 'Widget ayarları')
  New-Shortcut (Join-Path $StartMenu ("$AppName - " + (M 'Uninstall' 'Kaldır') + '.lnk')) $ps "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $Dest 'uninstall.ps1')`"" $icon (M 'Uninstalls the widget' "Widget'ı kaldırır")

  # ---- Start with Windows
  if ($NoStartup) {
    Remove-Item -LiteralPath $StartupLnk -ErrorAction SilentlyContinue
  } else {
    Say ('  ' + (M 'Will start with Windows (can be turned off in Settings)' "Windows açılınca başlatılacak (Ayarlar'dan kapatılabilir)"))
    New-Shortcut $StartupLnk $wscript "`"$vbs`"" $icon $AppName
  }

  # ---- Add to "Installed apps"
  $version = '1.0.0'
  $m = Select-String -LiteralPath (Join-Path $Dest 'oturum-widget.ps1') -Pattern '^\$AppVersion\s*=\s*.([0-9.]+).' -ErrorAction SilentlyContinue | Select-Object -First 1
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
    Start-Process -FilePath $wscript -ArgumentList "`"$vbs`""
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
