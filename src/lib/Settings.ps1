#Requires -Version 5.1
<#
  Settings (stored in %APPDATA%\ClaudeSessionWidget\settings.json), the
  "Start with Windows" shortcut, the launch command and migration from the
  older "ClaudeOturumWidget" version.

  Only function definitions. install.ps1 dot-sources this file too.
  Set $script:SettingsReadOnly = $true (demo mode) to make saving a no-op.
#>

function Get-SettingsPath { Join-Path (Join-Path $env:APPDATA 'ClaudeSessionWidget') 'settings.json' }
function Get-LegacySettingsPath { Join-Path (Join-Path $env:APPDATA 'ClaudeOturumWidget') 'ayarlar.json' }

function Get-DefaultSettings {
  [pscustomobject]@{
    Language = 'auto'     # auto | <code of a src\lang\*.psd1 file>
    OpenMode = 'last'     # icon | card | last
    Expanded = $false
    Topmost = $true
    Notify = $true
    Blink = $true
    ShowCli = $true
    RefreshSec = 3
    Opacity = 100
    KeepMin = 30
    Right = -1            # window anchor (bottom-right corner), -1 = default
    Bottom = -1
  }
}

# Copies the old version's settings file once, if the new one does not exist yet.
function Copy-LegacySettings {
  $new = Get-SettingsPath
  $old = Get-LegacySettingsPath
  if ((Test-Path -LiteralPath $new) -or -not (Test-Path -LiteralPath $old)) { return }
  try {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $new) | Out-Null
    Copy-Item -LiteralPath $old -Destination $new
  } catch {}
}

# Defaults overlaid with the saved values. -NoMigrate skips the legacy copy.
function Import-WidgetSettings {
  [CmdletBinding()]
  param([switch]$NoMigrate)
  if (-not $NoMigrate) { Copy-LegacySettings }
  $result = Get-DefaultSettings
  $file = Get-SettingsPath
  if (-not (Test-Path -LiteralPath $file) -and $NoMigrate) { $file = Get-LegacySettingsPath }
  if (Test-Path -LiteralPath $file) {
    try {
      $saved = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
      foreach ($p in $result.PSObject.Properties.Name) { if ($null -ne $saved.$p) { $result.$p = $saved.$p } }
    } catch {}
  }
  return $result
}

function Save-WidgetSettings {
  [CmdletBinding()]
  param([Parameter(Mandatory)]$Data)
  if ($script:SettingsReadOnly) { return }
  try {
    $file = Get-SettingsPath
    $dir = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $Data | ConvertTo-Json | Set-Content -LiteralPath $file -Encoding UTF8
  } catch {}
}

# ---------------------------------------------------------------- Launching

function Get-PowerShellExe { Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe' }

<#
  Arguments that start the widget without a visible console:
    -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "<dir>\claude-session-widget.ps1" [extra]
  Used by every shortcut and by Restart-Widget.
#>
function Get-WidgetLaunchArgument {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$AppDir, [string[]]$Extra = @())
  $entry = Join-Path $AppDir 'claude-session-widget.ps1'
  $line = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$entry`""
  if ($Extra.Count) { $line += ' ' + ($Extra -join ' ') }
  return $line
}

# Creates a .lnk that launches the widget (icon = widget.ico when present).
function New-WidgetShortcut {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$AppDir,
    [string[]]$Extra = @(),
    [string]$Description = 'Claude Session Widget'
  )
  $sh = New-Object -ComObject WScript.Shell
  $lnk = $sh.CreateShortcut($Path)
  $lnk.TargetPath = Get-PowerShellExe
  $lnk.Arguments = Get-WidgetLaunchArgument -AppDir $AppDir -Extra $Extra
  $lnk.WorkingDirectory = $AppDir
  $lnk.WindowStyle = 7   # minimized, so no console flashes before -WindowStyle Hidden applies
  $lnk.Description = $Description
  $ico = Join-Path $AppDir 'widget.ico'
  if (Test-Path -LiteralPath $ico) { $lnk.IconLocation = $ico }
  $lnk.Save()
}

# ------------------------------------------------------- Start with Windows

function Get-StartupShortcutPath { Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Session Widget.lnk' }

function Test-StartupShortcut { Test-Path -LiteralPath (Get-StartupShortcutPath) }

function Set-StartupShortcut {
  [CmdletBinding(SupportsShouldProcess)]
  param([Parameter(Mandatory)][bool]$Enabled, [Parameter(Mandatory)][string]$AppDir)
  $path = Get-StartupShortcutPath
  if (-not $PSCmdlet.ShouldProcess($path)) { return }
  if ($Enabled) { New-WidgetShortcut -Path $path -AppDir $AppDir }
  else { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
}

# Older versions started through wscript.exe + baslat.vbs; point such a
# Startup shortcut at the direct PowerShell launch command instead.
function Update-LegacyStartupShortcut {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$AppDir)
  $path = Get-StartupShortcutPath
  if (-not (Test-Path -LiteralPath $path)) { return }
  try {
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($path)
    if ($lnk.TargetPath -like '*wscript.exe' -or $lnk.Arguments -like '*baslat.vbs*') {
      New-WidgetShortcut -Path $path -AppDir $AppDir
    }
  } catch {}
}
