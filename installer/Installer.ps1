#Requires -Version 5.1
<#
  Install / update logic shared by the setup window (installer\Setup.ps1) and the
  console installer (install.ps1). Function definitions only: safe to dot-source,
  also inside a background runspace.

  Needs T (src\lib\I18n.ps1, strings imported) for shortcut names and descriptions.
#>

function Get-InstallLayout {
  $programs = [Environment]::GetFolderPath('Programs')
  $startup = [Environment]::GetFolderPath('Startup')
  [pscustomobject]@{
    AppName = 'Claude Session Widget'
    Dest = Join-Path $env:LOCALAPPDATA 'ClaudeSessionWidget'
    Programs = $programs
    Startup = $startup
    StartMenu = Join-Path $programs 'Claude Session Widget'            # folder used by older versions
    StartMenuLink = Join-Path $programs 'Claude Session Widget.lnk'
    UninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClaudeSessionWidget'
    LegacyName = 'Claude Oturum Widget'
    LegacyDest = Join-Path $env:LOCALAPPDATA 'ClaudeOturumWidget'
    LegacyUninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ClaudeOturumWidget'
  }
}

# Version written as $AppVersion = 'x.y.z' in an entry script; $null when missing.
function Get-WidgetVersion([string]$EntryScript) {
  if (-not (Test-Path -LiteralPath $EntryScript)) { return $null }
  $m = Select-String -LiteralPath $EntryScript -Pattern '^\$AppVersion\s*=\s*.([0-9A-Za-z.\-]+).' -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($m) { return $m.Matches[0].Groups[1].Value }
  return $null
}

# Version currently installed, or $null.
function Get-InstalledWidgetVersion {
  $layout = Get-InstallLayout
  Get-WidgetVersion (Join-Path $layout.Dest 'claude-session-widget.ps1')
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

<#
  Installs or updates the widget from <SourceRoot>\src.
  -Progress is called as & $Progress <percent 0-100> <string key> before each step.
  Returns { Dest, Icon, Version, PowerShell }.
#>
function Install-ClaudeSessionWidget {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [switch]$NoStartup,
    [scriptblock]$Progress = {}
  )
  $layout = Get-InstallLayout
  $src = Join-Path $SourceRoot 'src'
  if (-not (Test-Path -LiteralPath (Join-Path $src 'claude-session-widget.ps1'))) {
    throw (T 'SetupNotFound')
  }

  & $Progress 5 'SetupStepStop'
  Stop-Widget

  # Remove the older version ("Claude Oturum Widget")
  Remove-Item -LiteralPath $layout.LegacyDest -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $layout.LegacyUninstallKey -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $layout.Programs $layout.LegacyName) -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $layout.Startup "$($layout.LegacyName).lnk") -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $env:TEMP 'oturum-widget.signal') -Force -ErrorAction SilentlyContinue

  # Fresh copy, so files removed upstream do not linger
  & $Progress 25 'SetupStepCopy'
  $dest = $layout.Dest
  Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  Copy-Item -Path (Join-Path $src '*') -Destination $dest -Recurse -Force
  Copy-Item -LiteralPath (Join-Path $SourceRoot 'uninstall.ps1') -Destination (Join-Path $dest 'uninstall.ps1') -Force
  Get-ChildItem -LiteralPath $dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

  # Shortcut, icon and launch-command helpers shared with the widget
  . (Join-Path $dest 'lib\Settings.ps1')
  $ps = Get-PowerShellExe
  $icon = Get-WidgetIconPath -AppDir $dest
  if (-not (Test-Path -LiteralPath $icon)) { $icon = $null }

  # One Start menu entry. Settings open from the widget; uninstall lives in Installed apps.
  & $Progress 50 'SetupStepShortcuts'
  Remove-Item -LiteralPath $layout.StartMenu -Recurse -Force -ErrorAction SilentlyContinue   # folder of older versions
  New-WidgetShortcut -Path $layout.StartMenuLink -AppDir $dest -Description (T 'SetupLnkDesc')

  & $Progress 70 'SetupStepStartup'
  $startupLnk = Get-StartupShortcutPath
  if ($NoStartup) { Remove-Item -LiteralPath $startupLnk -ErrorAction SilentlyContinue }
  else { New-WidgetShortcut -Path $startupLnk -AppDir $dest }

  & $Progress 85 'SetupStepRegister'
  $version = Get-WidgetVersion (Join-Path $dest 'claude-session-widget.ps1')
  if (-not $version) { $version = '0.0.0' }
  New-Item -Path $layout.UninstallKey -Force | Out-Null
  $props = @{
    DisplayName = $name
    DisplayVersion = $version
    Publisher = 'claude-session-widget'
    InstallLocation = $dest
    UninstallString = "`"$ps`" -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $dest 'uninstall.ps1')`""
    NoModify = 1
    NoRepair = 1
  }
  if ($icon) { $props.DisplayIcon = "$icon,0" }
  foreach ($k in $props.Keys) {
    $type = 'String'; if ($props[$k] -is [int]) { $type = 'DWord' }
    New-ItemProperty -Path $layout.UninstallKey -Name $k -Value $props[$k] -PropertyType $type -Force | Out-Null
  }

  & $Progress 100 'SetupStepDone'
  [pscustomobject]@{ Dest = $dest; Icon = $icon; Version = $version; PowerShell = $ps }
}

# Starts the installed widget without a console window.
function Start-InstalledWidget {
  $layout = Get-InstallLayout
  . (Join-Path $layout.Dest 'lib\Settings.ps1')
  Start-Process -FilePath (Get-PowerShellExe) -ArgumentList (Get-WidgetLaunchArgument -AppDir $layout.Dest) `
    -WorkingDirectory $layout.Dest -WindowStyle Hidden
}
