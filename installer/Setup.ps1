#Requires -Version 5.1
<#
  Claude Session Widget — setup window.
  Started by Install.cmd. A small three-step window: welcome (two options and an
  Install button), progress, done. The actual work is in installer\Installer.ps1,
  run in a background runspace so the window stays responsive.

  Options:
    -Language <code>   UI language for this run (default: Windows display language)
    -Page / -Screenshot  Render one page (welcome | progress | done | error) to a
                         transparent PNG without installing anything, then exit.
                         e.g. -Page welcome -Language en -Screenshot docs\screenshots\setup.png
#>
[CmdletBinding()]
param(
  [string]$Language,
  [ValidateSet('welcome', 'progress', 'done', 'error')][string]$Page = 'welcome',
  [string]$Screenshot
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$LibDir = Join-Path $Root 'src\lib'
$LangDir = Join-Path $Root 'src\lang'
$LogFile = Join-Path $env:TEMP 'claude-session-widget-setup.log'

function Write-SetupLog([string]$Text) {
  try { Add-Content -LiteralPath $LogFile -Value "$(Get-Date -Format s) $Text" } catch {}
}

try {
  . (Join-Path $LibDir 'I18n.ps1')
  . (Join-Path $LibDir 'Theme.ps1')
  . (Join-Path $LibDir 'Settings.ps1')
  . (Join-Path $PSScriptRoot 'Installer.ps1')

  $pref = 'auto'; if ($Language) { $pref = $Language }
  $Lang = Resolve-Language -Preference $pref -Path $LangDir
  Import-Strings -Language $Lang -Path $LangDir

  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing

  $C = Get-ThemeColor
  $Styles = Get-SharedStyleXaml $C
  function X([string]$Text) { [System.Security.SecurityElement]::Escape($Text) }

  $NewVersion = Get-WidgetVersion (Join-Path $Root 'src\claude-session-widget.ps1')
  $OldVersion = Get-InstalledWidgetVersion
  $IsShot = [bool]$Screenshot
  if ($IsShot) { $OldVersion = $null }
  $Layout = Get-InstallLayout
  $StartupOn = $true
  if ($OldVersion) { $StartupOn = [bool](Test-StartupShortcut) }

  # ------------------------------------------------------------------ XAML
  [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$(X (T 'SetupTitle'))" Width="472" SizeToContent="Height" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
$Styles
    <Style x:Key="PrimaryBtn" TargetType="Button">
      <Setter Property="Foreground" Value="$($C.Ink)"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="MinWidth" Value="104"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="$($C.Accent)" CornerRadius="8" Padding="18,9">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#E38B6D"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Background" Value="#C5664A"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SecondaryBtn" TargetType="Button">
      <Setter Property="Foreground" Value="$($C.Text2)"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="MinWidth" Value="92"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="$($C.Bg2)" BorderBrush="$($C.Line)" BorderThickness="1" CornerRadius="8" Padding="16,8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="$($C.Muted)"/>
                <Setter Property="Foreground" Value="$($C.Text)"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="Frame" CornerRadius="14" Margin="18" Background="$($C.Bg)" BorderBrush="$($C.Line)" BorderThickness="1">
    <Border.Effect><DropShadowEffect BlurRadius="26" ShadowDepth="4" Opacity="0.5"/></Border.Effect>
    <Grid>
      <Button x:Name="BtnX" Style="{StaticResource IconBtn}" Content="&#xE8BB;" ToolTip="$(X (T 'Close'))"
              HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,10,10,0"/>
      <StackPanel Margin="30,30,30,24">

        <!-- Header -->
        <StackPanel Orientation="Horizontal">
          <Border Width="54" Height="54" CornerRadius="27" Background="$($C.Bg2)" BorderBrush="$($C.Line)" BorderThickness="1">
            <TextBlock Text="&#x273B;" FontFamily="Segoe UI Symbol" FontSize="29" Foreground="$($C.Accent)"
                       HorizontalAlignment="Center" VerticalAlignment="Center" Margin="0,-2,0,0" RenderTransformOrigin="0.5,0.5">
              <TextBlock.RenderTransform><RotateTransform x:Name="LogoSpin" Angle="0"/></TextBlock.RenderTransform>
            </TextBlock>
          </Border>
          <StackPanel Margin="14,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="Claude Session Widget" FontSize="18" FontWeight="SemiBold" Foreground="$($C.Text)"/>
            <TextBlock x:Name="VersionText" FontSize="11.5" Foreground="$($C.Muted)" Margin="0,2,0,0"/>
          </StackPanel>
        </StackPanel>

        <!-- Welcome -->
        <StackPanel x:Name="PageWelcome" Margin="0,20,0,0">
          <TextBlock Text="$(X (T 'SetupIntro'))" TextWrapping="Wrap" Foreground="$($C.Text2)" FontSize="13" LineHeight="19"/>
          <TextBlock x:Name="UpdateNote" Visibility="Collapsed" Margin="0,10,0,0" Foreground="$($C.Accent)" FontSize="12" TextWrapping="Wrap"/>
          <Border Margin="0,18,0,0" Background="$($C.Bg2)" CornerRadius="10" Padding="16,4">
            <StackPanel>
              <Grid Margin="0,10,0,10">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel Margin="0,0,12,0">
                  <TextBlock Text="$(X (T 'Startup'))" Foreground="$($C.Text)" FontSize="12.5"/>
                  <TextBlock Text="$(X (T 'StartupD'))" Foreground="$($C.Muted)" FontSize="11" Margin="0,2,0,0" TextWrapping="Wrap"/>
                </StackPanel>
                <CheckBox x:Name="OptStartup" Grid.Column="1" Style="{StaticResource Switch}"/>
              </Grid>
              <Border Height="1" Background="$($C.Line)"/>
              <Grid Margin="0,10,0,10">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel Margin="0,0,12,0">
                  <TextBlock Text="$(X (T 'SetupOptLaunch'))" Foreground="$($C.Text)" FontSize="12.5"/>
                  <TextBlock Text="$(X (T 'SetupOptLaunchD'))" Foreground="$($C.Muted)" FontSize="11" Margin="0,2,0,0" TextWrapping="Wrap"/>
                </StackPanel>
                <CheckBox x:Name="OptLaunch" Grid.Column="1" Style="{StaticResource Switch}" IsChecked="True"/>
              </Grid>
            </StackPanel>
          </Border>
          <TextBlock x:Name="LocationText" Margin="0,14,0,0" FontSize="11" Foreground="$($C.Muted)" TextTrimming="CharacterEllipsis"/>
          <TextBlock Text="$(X (T 'SetupNoAdmin'))" FontSize="11" Foreground="$($C.Muted)" Margin="0,2,0,0" TextWrapping="Wrap"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,24,0,0">
            <Button x:Name="BtnCancel" Style="{StaticResource SecondaryBtn}" Content="$(X (T 'SetupCancel'))"/>
            <Button x:Name="BtnInstall" Style="{StaticResource PrimaryBtn}" Margin="10,0,0,0"/>
          </StackPanel>
        </StackPanel>

        <!-- Progress -->
        <StackPanel x:Name="PageProgress" Visibility="Collapsed" Margin="0,28,0,10">
          <TextBlock Text="$(X (T 'SetupInstalling'))" FontSize="15" FontWeight="SemiBold" Foreground="$($C.Text)"/>
          <Grid x:Name="Track" Margin="0,14,0,0" Height="6">
            <Border CornerRadius="3" Background="$($C.Line)"/>
            <Border x:Name="Fill" CornerRadius="3" Background="$($C.Accent)" HorizontalAlignment="Left" Width="0"/>
          </Grid>
          <TextBlock x:Name="StepText" Margin="0,10,0,0" FontSize="12" Foreground="$($C.Muted)"/>
        </StackPanel>

        <!-- Done -->
        <StackPanel x:Name="PageDone" Visibility="Collapsed" Margin="0,24,0,0">
          <StackPanel Orientation="Horizontal">
            <Border Width="22" Height="22" CornerRadius="11" Background="$($C.Green)">
              <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="11" Foreground="$($C.Ink)"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock Text="$(X (T 'SetupDone'))" FontSize="15" FontWeight="SemiBold" Foreground="$($C.Text)" Margin="10,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock Text="$(X (T 'SetupDoneText'))" TextWrapping="Wrap" Foreground="$($C.Text2)" FontSize="13" LineHeight="19" Margin="0,12,0,0"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,24,0,0">
            <Button x:Name="BtnOpen" Style="{StaticResource SecondaryBtn}" Content="$(X (T 'SetupOpen'))"/>
            <Button x:Name="BtnClose" Style="{StaticResource PrimaryBtn}" Margin="10,0,0,0" Content="$(X (T 'Close'))"/>
          </StackPanel>
        </StackPanel>

        <!-- Error -->
        <StackPanel x:Name="PageError" Visibility="Collapsed" Margin="0,24,0,0">
          <StackPanel Orientation="Horizontal">
            <Border Width="22" Height="22" CornerRadius="11" Background="#E5786D">
              <TextBlock Text="&#xE711;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="$($C.Ink)"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <TextBlock Text="$(X (T 'SetupFailed'))" FontSize="15" FontWeight="SemiBold" Foreground="$($C.Text)" Margin="10,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBox x:Name="ErrorText" IsReadOnly="True" Margin="0,12,0,0" Padding="8,6" MaxHeight="120"
                   Background="$($C.Bg2)" Foreground="$($C.Text2)" BorderBrush="$($C.Line)" BorderThickness="1"
                   TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontFamily="Cascadia Mono, Consolas" FontSize="11"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,22,0,0">
            <Button x:Name="BtnErrClose" Style="{StaticResource SecondaryBtn}" Content="$(X (T 'Close'))"/>
            <Button x:Name="BtnRetry" Style="{StaticResource PrimaryBtn}" Margin="10,0,0,0" Content="$(X (T 'SetupRetry'))"/>
          </StackPanel>
        </StackPanel>

      </StackPanel>
    </Grid>
  </Border>
</Window>
"@

  $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
  $ui = @{}
  foreach ($n in 'Frame', 'BtnX', 'LogoSpin', 'VersionText', 'PageWelcome', 'UpdateNote', 'OptStartup', 'OptLaunch',
    'LocationText', 'BtnCancel', 'BtnInstall', 'PageProgress', 'Track', 'Fill', 'StepText', 'PageDone', 'BtnOpen',
    'BtnClose', 'PageError', 'ErrorText', 'BtnErrClose', 'BtnRetry') { $ui[$n] = $win.FindName($n) }

  # Taskbar / Alt+Tab icon
  try {
    $iconFile = Get-WidgetIconPath -AppDir (Join-Path $Root 'src')
    $win.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$iconFile)
  } catch {}

  # Texts that depend on the current install
  $ui.VersionText.Text = "v$NewVersion"
  $shownDest = $Layout.Dest
  if ($IsShot) { $shownDest = '%LOCALAPPDATA%\ClaudeSessionWidget' }   # no user name in screenshots
  $ui.LocationText.Text = (T 'SetupLocation') -f $shownDest
  $ui.LocationText.ToolTip = $Layout.Dest
  $ui.OptStartup.IsChecked = $StartupOn
  if ($OldVersion) {
    $ui.BtnInstall.Content = T 'SetupUpdate'
    $ui.UpdateNote.Text = (T 'SetupUpdateFrom') -f $OldVersion, $NewVersion
    $ui.UpdateNote.Visibility = 'Visible'
  } else {
    $ui.BtnInstall.Content = T 'SetupInstall'
  }

  # ------------------------------------------------------------------ Pages
  $state = @{ Busy = $false; Shown = 0.0; Started = [DateTime]::MinValue; Launched = $false }

  function Show-Page([string]$Name) {
    foreach ($p in 'PageWelcome', 'PageProgress', 'PageDone', 'PageError') { $ui[$p].Visibility = 'Collapsed' }
    $ui["Page$Name"].Visibility = 'Visible'
  }

  function Set-Spin([bool]$On) {
    if ($On) {
      $anim = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 360, (New-Object System.Windows.Duration ([TimeSpan]::FromSeconds(2.4))))
      $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
      $ui.LogoSpin.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $anim)
    } else {
      $ui.LogoSpin.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
      $ui.LogoSpin.Angle = 0
    }
  }

  function Close-Setup {
    if ($state.Busy) { return }
    $win.Close()
  }

  # ------------------------------------------------- Install in the background
  $sync = [hashtable]::Synchronized(@{ Pct = 0; Key = 'SetupStepStop'; Done = $false; Error = $null })

  function Start-Install {
    $state.Busy = $true
    $state.Shown = 0.0
    $state.Started = Get-Date
    $sync.Pct = 0; $sync.Key = 'SetupStepStop'; $sync.Done = $false; $sync.Error = $null
    $ui.Fill.Width = 0
    $ui.StepText.Text = T 'SetupStepStop'
    $ui.BtnX.IsEnabled = $false
    Show-Page 'Progress'
    Set-Spin $true

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    $job = [powershell]::Create()
    $job.Runspace = $rs
    [void]$job.AddScript({
        param($sync, $root, $installer, $i18n, $langDir, $lang, $noStartup)
        $ErrorActionPreference = 'Stop'
        try {
          . $i18n
          Import-Strings -Language $lang -Path $langDir
          . $installer
          [void](Install-ClaudeSessionWidget -SourceRoot $root -NoStartup:$noStartup -Progress {
              param($pct, $key) $sync.Pct = $pct; $sync.Key = $key
            })
        } catch {
          $sync.Error = $_.Exception.Message
        }
        $sync.Done = $true
      }).AddArgument($sync).AddArgument($Root).AddArgument((Join-Path $PSScriptRoot 'Installer.ps1')).AddArgument(
      (Join-Path $LibDir 'I18n.ps1')).AddArgument($LangDir).AddArgument($Lang).AddArgument(-not [bool]$ui.OptStartup.IsChecked)
    [void]$job.BeginInvoke()
    $tick.Start()
  }

  # Animates the bar toward the reported percentage; switches page when finished
  # (shown for at least a moment, so the steps can be read).
  $tick = New-Object System.Windows.Threading.DispatcherTimer
  $tick.Interval = [TimeSpan]::FromMilliseconds(40)
  $tick.Add_Tick({
      $target = [double]$sync.Pct
      $state.Shown += ($target - $state.Shown) * 0.18
      $trackWidth = $ui.Track.ActualWidth
      if ($trackWidth -gt 0) { $ui.Fill.Width = [Math]::Max(0, [Math]::Min($trackWidth, $trackWidth * $state.Shown / 100)) }
      $ui.StepText.Text = T ([string]$sync.Key)

      $elapsed = ((Get-Date) - $state.Started).TotalMilliseconds
      if ($sync.Done -and ($sync.Error -or ($state.Shown -gt 98.5 -and $elapsed -gt 1400))) {
        $tick.Stop()
        Set-Spin $false
        $state.Busy = $false
        $ui.BtnX.IsEnabled = $true
        if ($sync.Error) {
          Write-SetupLog "install: $($sync.Error)"
          $ui.ErrorText.Text = [string]$sync.Error
          Show-Page 'Error'
        } else {
          if ($ui.OptLaunch.IsChecked) {
            try { Start-InstalledWidget; $state.Launched = $true } catch { Write-SetupLog "launch: $($_.Exception.Message)" }
          }
          # Widget already running: only "Close" is needed.
          if ($state.Launched) { $ui.BtnOpen.Visibility = 'Collapsed' }
          Show-Page 'Done'
        }
      }
    })

  # ------------------------------------------------------------------ Events
  $win.Add_MouseLeftButtonDown({ try { $win.DragMove() } catch {} })
  $ui.BtnX.Add_Click({ Close-Setup })
  $ui.BtnCancel.Add_Click({ Close-Setup })
  $ui.BtnInstall.Add_Click({ Start-Install })
  $ui.BtnRetry.Add_Click({ Start-Install })
  $ui.BtnErrClose.Add_Click({ Close-Setup })
  $ui.BtnClose.Add_Click({ Close-Setup })
  $ui.BtnOpen.Add_Click({
      try { Start-InstalledWidget } catch { Write-SetupLog "launch: $($_.Exception.Message)" }
      Close-Setup
    })
  $win.Add_Closing({ param($s, $e) if ($state.Busy) { $e.Cancel = $true } })

  # ------------------------------------------------- Screenshot mode (no install)
  if ($IsShot) {
    switch ($Page) {
      'progress' { Show-Page 'Progress'; $ui.StepText.Text = T 'SetupStepCopy' }
      'done' { Show-Page 'Done'; $ui.BtnOpen.Visibility = 'Collapsed' }
      'error' { Show-Page 'Error'; $ui.ErrorText.Text = 'Access to the path is denied.' }
      default { Show-Page 'Welcome' }
    }
    $shotPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Screenshot)
    $shot = New-Object System.Windows.Threading.DispatcherTimer
    $shot.Interval = [TimeSpan]::FromMilliseconds(1200)
    $shot.Add_Tick({
        $shot.Stop()
        try {
          if ($Page -eq 'progress') { $ui.Fill.Width = $ui.Track.ActualWidth * 0.45 }
          $rootEl = $win.Content
          $rootEl.UpdateLayout()
          $m = $rootEl.Margin
          $w = [int][Math]::Ceiling($rootEl.ActualWidth + $m.Left + $m.Right)
          $h = [int][Math]::Ceiling($rootEl.ActualHeight + $m.Top + $m.Bottom)
          $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(($w * 2), ($h * 2), 192, 192, [System.Windows.Media.PixelFormats]::Pbgra32)
          $rtb.Render($rootEl)
          $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
          $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
          $dir = Split-Path -Parent $shotPath
          if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
          $fs = [System.IO.File]::Create($shotPath)
          try { $enc.Save($fs) } finally { $fs.Close() }
        } catch { Write-SetupLog "screenshot: $($_.Exception.Message)" }
        $win.Close()
      })
    $shot.Start()
  } else {
    Show-Page 'Welcome'
  }

  [void]$win.ShowDialog()
}
catch {
  Write-SetupLog "$($_.Exception.Message)`n$($_.ScriptStackTrace)"
  try {
    Add-Type -AssemblyName PresentationFramework
    [void][System.Windows.MessageBox]::Show("Claude Session Widget setup could not start:`n$($_.Exception.Message)", 'Claude Session Widget', 'OK', 'Error')
  } catch {}
  exit 1
}
