#Requires -Version 5.1
<#
  Claude Session Widget
  Shows the Claude sessions that are working right now, their task list and
  progress, in a small always-on-top window on the desktop.

  Run (no console; this is what the shortcuts use):
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File claude-session-widget.ps1

  Options:
    -Test           Scan once and print the sessions to the console, then exit.
    -OpenSettings   Open the settings window (also in an already running widget).
    -Restart        Wait for the running instance to exit, then start (used after a language change).
    -Demo           Fake sessions for screenshots; reads no sessions and saves nothing.
    -DemoView       With -Demo: icon | card | settings (default card).
    -Language       Use this UI language code for this run (e.g. en, tr).
    -Screenshot     With -Demo: save the shown view as a PNG with a transparent
                    background, then exit. Works without a visible desktop.
                    e.g. -Demo -DemoView settings -Language en -Screenshot docs\screenshots\settings.png

  Code layout: lib\Scanner.ps1 (finding sessions), lib\Demo.ps1, lib\I18n.ps1 +
  lang\*.psd1 (translations), lib\Settings.ps1, lib\Theme.ps1,
  lib\MainWindow.ps1, lib\SettingsWindow.ps1.
#>
[CmdletBinding()]
param(
  [switch]$Test,
  [switch]$OpenSettings,
  [switch]$Restart,
  [switch]$Demo,
  [ValidateSet('icon', 'card', 'settings')][string]$DemoView = 'card',
  [string]$Language,
  [string]$Screenshot
)

$ErrorActionPreference = 'Stop'
$AppVersion = '1.0.0'
$RepoUrl = 'https://github.com/hasanuzn/claude-session-widget'
$AppDir = $PSScriptRoot
$LibDir = Join-Path $AppDir 'lib'
$ScannerPath = Join-Path $LibDir 'Scanner.ps1'
$LogFile = Join-Path $env:TEMP 'claude-session-widget.log'
$IsDemo = [bool]$Demo

. $ScannerPath
. (Join-Path $LibDir 'Demo.ps1')

# ---- Test mode: scan once and print
if ($Test) {
  if ($IsDemo) { $found = @(Get-DemoSession) } else { $found = @(Get-ClaudeSession -IncludeTerminal) }
  if (-not $found.Count) { 'No sessions running right now.' }
  $found | ForEach-Object {
    "{0}  [{1}]  {2}/{3}  ▸ {4}  ⎿ {5}" -f $_.Name, $_.Where, $_.Done, $_.Total, $_.Current, $_.Activity
  }
  return
}

# ======================================================================
#  User interface
# ======================================================================
try {
  foreach ($lib in 'I18n', 'Settings', 'Theme', 'MainWindow', 'SettingsWindow') { . (Join-Path $LibDir "$lib.ps1") }
  Hide-ConsoleWindow
  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

  # ---- Single instance (the demo uses its own lock and signal file)
  $MutexName = 'Local\ClaudeSessionWidget'
  $SignalFile = Join-Path $env:TEMP 'claude-session-widget.signal'
  if ($IsDemo) {
    $MutexName = 'Local\ClaudeSessionWidgetDemo'
    $SignalFile = Join-Path $env:TEMP 'claude-session-widget-demo.signal'
  }
  $createdNew = $false
  $mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$createdNew)
  if (-not $createdNew -and $Restart) {
    try { $createdNew = $mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $createdNew = $true }
  }
  if (-not $createdNew) {
    # Already running: ask it to show the card or the settings window.
    $flag = 'show'; if ($OpenSettings) { $flag = 'settings' }
    try { Set-Content -LiteralPath $SignalFile -Value $flag -Encoding ASCII } catch {}
    return
  }

  # ---- Settings and language
  if ($IsDemo) {
    $SettingsReadOnly = $true
    $settings = Import-WidgetSettings -NoMigrate
  } else {
    $settings = Import-WidgetSettings
    Update-LegacyStartupShortcut -AppDir $AppDir
  }
  if ($Language) { $settings.Language = $Language }
  Import-Strings -Language (Resolve-Language ([string]$settings.Language))
  Initialize-Theme

  # ---- Data source: background scanner, or fixed demo data
  if ($IsDemo) { Start-DemoFeed } else { Start-SessionScanner -ScannerPath $ScannerPath }

  # ---- Window
  if ($IsDemo) {
    Initialize-MainWindow -Expanded ($DemoView -ne 'icon')
    $state.Open['demo-1'] = $true
    foreach ($done in @(Get-DemoFinished)) { [void]$state.Finished.Add($done) }
    if ($Screenshot) {
      # Render the view off-screen (RenderTargetBitmap at 2x) once the demo data has been drawn.
      $script:ShotPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Screenshot)
      $script:ShotTimer = New-Object System.Windows.Threading.DispatcherTimer
      $script:ShotTimer.Interval = [TimeSpan]::FromSeconds(3)
      $script:ShotTimer.Add_Tick({
          $script:ShotTimer.Stop()
          try {
            $target = $win
            if ($DemoView -eq 'settings' -and $state.SettingsWin) { $target = $state.SettingsWin }
            $root = $target.Content
            $root.UpdateLayout()
            # Include the root's own margin (the drop-shadow area) so nothing is clipped.
            $m = $root.Margin
            $w = [int][Math]::Ceiling($root.ActualWidth + $m.Left + $m.Right)
            $h = [int][Math]::Ceiling($root.ActualHeight + $m.Top + $m.Bottom)
            $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(($w * 2), ($h * 2), 192, 192, [System.Windows.Media.PixelFormats]::Pbgra32)
            $rtb.Render($root)
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
            $dir = Split-Path -Parent $script:ShotPath
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $fs = [System.IO.File]::Create($script:ShotPath)
            try { $enc.Save($fs) } finally { $fs.Close() }
          } catch {
            Add-Content -LiteralPath $LogFile -Value "$(Get-Date -Format s) screenshot: $($_.Exception.Message)"
          }
          $app.Shutdown()
        })
      $script:ShotTimer.Start()
    }
    Start-WidgetApp -OpenSettingsWindow:($DemoView -eq 'settings' -or $OpenSettings)
  } else {
    Initialize-MainWindow
    Start-WidgetApp -OpenSettingsWindow:$OpenSettings
  }

  Stop-SessionScanner
  $mutex.ReleaseMutex()
}
catch {
  try { Add-Content -LiteralPath $LogFile -Value "$(Get-Date -Format s) $($_.Exception.Message)`n$($_.ScriptStackTrace)" } catch {}
  try { [System.Windows.MessageBox]::Show("Claude Session Widget could not start:`n$($_.Exception.Message)") | Out-Null } catch {}
}
