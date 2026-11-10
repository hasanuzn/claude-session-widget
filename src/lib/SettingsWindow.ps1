#Requires -Version 5.1
<#
  Settings window. Every change is applied and saved immediately.
  Only function definitions; uses the $script: state set up by the entry
  script and Initialize-MainWindow ($settings, $state, $shared, $win ...).
#>

# XAML name of a pill (radio button): prefix + value with unsafe characters replaced.
function Get-PillName([string]$Prefix, [string]$Value) { $Prefix + ($Value -replace '[^A-Za-z0-9]', '_') }

function New-ToggleRowXaml([string]$Name, [string]$Title, [string]$Desc) {
  $C = $script:C
  @"
      <Grid Margin="0,8,0,8">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel Margin="0,0,12,0">
          <TextBlock Text="$(ConvertTo-XmlText $Title)" Foreground="$($C.Text)" FontSize="12.5"/>
          <TextBlock Text="$(ConvertTo-XmlText $Desc)" Foreground="$($C.Muted)" FontSize="11" TextWrapping="Wrap" Margin="0,2,0,0"/>
        </StackPanel>
        <CheckBox x:Name="$Name" Grid.Column="1" Style="{StaticResource Switch}"/>
      </Grid>
"@
}

<#
  A row of pills. $Options is a list of @(value, label); the value is kept in
  the pill's Tag. With more than four options the pills wrap below the title.
#>
function New-PillRowXaml([string]$Prefix, [string]$Title, [string]$Desc, $Options) {
  $C = $script:C
  $wrap = @($Options).Count -gt 4
  $pillMargin = ''; if ($wrap) { $pillMargin = ' Margin="0,0,4,4"' }
  $pills = (@($Options) | ForEach-Object {
      "<RadioButton x:Name=`"$(Get-PillName $Prefix $_[0])`" Tag=`"$(ConvertTo-XmlText $_[0])`" GroupName=`"$Prefix`"$pillMargin Style=`"{StaticResource Pill}`" Content=`"$(ConvertTo-XmlText $_[1])`"/>"
    }) -join ''
  $text = @"
          <TextBlock Text="$(ConvertTo-XmlText $Title)" Foreground="$($C.Text)" FontSize="12.5"/>
          <TextBlock Text="$(ConvertTo-XmlText $Desc)" Foreground="$($C.Muted)" FontSize="11" TextWrapping="Wrap" Margin="0,2,0,0"/>
"@
  if ($wrap) {
    return @"
      <StackPanel Margin="0,8,0,8">
$text
        <WrapPanel Margin="0,8,0,0">$pills</WrapPanel>
      </StackPanel>
"@
  }
  @"
      <Grid Margin="0,8,0,8">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel Margin="0,0,12,0" VerticalAlignment="Center">
$text
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">$pills</StackPanel>
      </Grid>
"@
}

function New-SectionXaml([string]$Text) {
  "<TextBlock Text=`"$(ConvertTo-XmlText $Text)`" Foreground=`"$($script:C.Muted)`" FontSize=`"10`" FontWeight=`"SemiBold`" Margin=`"0,14,0,2`"/>"
}

# Option lists: @(value, label). Languages come from the src\lang\*.psd1 files.
function Get-SettingsOption {
  $langs = @(, @('auto', (T 'LAuto')))
  foreach ($lg in @(Get-AvailableLanguage)) { $langs += , @($lg.Code, $lg.Name) }
  @{
    Open = @(@('icon', (T 'OIcon')), @('card', (T 'OCard')), @('last', (T 'OLast')))
    Lang = $langs
    Refresh = @(@('2', "2 $(T 'Sec')"), @('3', "3 $(T 'Sec')"), @('5', "5 $(T 'Sec')"), @('10', "10 $(T 'Sec')"))
    Opacity = @(@('100', '100%'), @('90', '90%'), @('80', '80%'), @('70', '70%'), @('60', '60%'))
    Keep = @(@('15', "15 $(T 'Min')"), @('30', "30 $(T 'Min')"), @('60', "1 $(T 'Hr')"))
  }
}

function Show-Settings {
  if ($state.SettingsWin) { $state.SettingsWin.Activate() | Out-Null; return }
  $C = $script:C
  $opts = Get-SettingsOption

  $body = (New-SectionXaml (T 'General')) +
    (New-ToggleRowXaml 'OptStartup' (T 'Startup') (T 'StartupD')) +
    (New-ToggleRowXaml 'OptTopmost' (T 'Topmost') (T 'TopmostD')) +
    (New-PillRowXaml 'OptOpen_' (T 'OpenMode') (T 'OpenModeD') $opts.Open) +
    (New-PillRowXaml 'OptLang_' (T 'Language') (T 'LanguageD') $opts.Lang) +
    (New-PillRowXaml 'OptOpacity_' (T 'Opacity') (T 'OpacityD') $opts.Opacity) +
    (New-SectionXaml (T 'Notifications')) +
    (New-ToggleRowXaml 'OptNotify' (T 'Notify') (T 'NotifyD')) +
    (New-ToggleRowXaml 'OptBlink' (T 'Blink') (T 'BlinkD')) +
    (New-SectionXaml (T 'Data')) +
    (New-ToggleRowXaml 'OptCli' (T 'Cli') (T 'CliD')) +
    (New-PillRowXaml 'OptRefresh_' (T 'Refresh') (T 'RefreshD') $opts.Refresh) +
    (New-PillRowXaml 'OptKeep_' (T 'Keep') (T 'KeepD') $opts.Keep)

  [xml]$sx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Session Widget · $(ConvertTo-XmlText (T 'SettingsTitle'))" Width="460" SizeToContent="Height" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent" Topmost="True" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
$script:SharedStyles
  </Window.Resources>
  <Border CornerRadius="12" Margin="14" Background="$($C.Bg)" BorderBrush="$($C.Line)" BorderThickness="1">
    <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="4" Opacity="0.55"/></Border.Effect>
    <StackPanel>
      <Grid x:Name="SHeader" Margin="18,12,10,10" Background="Transparent">
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock Text="&#x273B;" FontFamily="Segoe UI Symbol" FontSize="18" Foreground="$($C.Accent)" VerticalAlignment="Center"/>
        <TextBlock Grid.Column="1" Text="$(ConvertTo-XmlText (T 'SettingsTitle'))" Foreground="$($C.Text)" FontSize="14" FontWeight="SemiBold" Margin="10,0,0,0" VerticalAlignment="Center"/>
        <Button x:Name="SClose" Grid.Column="2" Style="{StaticResource IconBtn}" Content="&#xE8BB;" ToolTip="$(ConvertTo-XmlText (T 'Close'))"/>
      </Grid>
      <Border Height="1" Background="$($C.Line)"/>
      <StackPanel Margin="18,2,18,10">
$body
      </StackPanel>
      <Border Height="1" Background="$($C.Line)"/>
      <Grid Margin="18,10,12,12">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock VerticalAlignment="Center" FontSize="11" Foreground="$($C.Muted)">
          <Run Text="$(ConvertTo-XmlText ((T 'Version') -f $AppVersion))"/><Hyperlink x:Name="SLink" Foreground="$($C.Accent)" TextDecorations="{x:Null}">GitHub</Hyperlink>
        </TextBlock>
        <Button x:Name="SQuit" Grid.Column="1" Style="{StaticResource TextBtn}" Content="$(ConvertTo-XmlText (T 'Quit'))"/>
      </Grid>
    </StackPanel>
  </Border>
</Window>
"@
  $sw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $sx))
  $state.SettingsWin = $sw
  $find = { param($n) $sw.FindName($n) }
  $pill = { param($prefix, $value) $sw.FindName((Get-PillName $prefix ([string]$value))) }

  # Current values
  (& $find 'OptStartup').IsChecked = (Test-StartupShortcut)
  (& $find 'OptTopmost').IsChecked = [bool]$settings.Topmost
  (& $find 'OptNotify').IsChecked = [bool]$settings.Notify
  (& $find 'OptBlink').IsChecked = [bool]$settings.Blink
  (& $find 'OptCli').IsChecked = [bool]$settings.ShowCli
  $langPref = [string]$settings.Language
  if (-not (@($opts.Lang | ForEach-Object { $_[0] }) -contains $langPref)) { $langPref = 'auto' }
  foreach ($pair in @(@('OptOpen_', $settings.OpenMode), @('OptLang_', $langPref), @('OptRefresh_', $settings.RefreshSec),
      @('OptKeep_', $settings.KeepMin), @('OptOpacity_', $settings.Opacity))) {
    $o = & $pill $pair[0] $pair[1]; if ($o) { $o.IsChecked = $true }
  }

  # Changes are applied and saved immediately
  (& $find 'OptStartup').Add_Click({
      if ($IsDemo) { return }
      try { Set-StartupShortcut -Enabled ([bool]$this.IsChecked) -AppDir $AppDir } catch { $this.IsChecked = (Test-StartupShortcut) }
    })
  (& $find 'OptTopmost').Add_Click({ Set-Topmost ([bool]$this.IsChecked) })
  (& $find 'OptNotify').Add_Click({ $settings.Notify = [bool]$this.IsChecked; Save-WidgetSettings $settings })
  (& $find 'OptBlink').Add_Click({ $settings.Blink = [bool]$this.IsChecked; Save-WidgetSettings $settings; Update-Chrome })
  (& $find 'OptCli').Add_Click({
      $settings.ShowCli = [bool]$this.IsChecked; $shared.ShowCli = $settings.ShowCli; $shared.Wake = $true; Save-WidgetSettings $settings
    })
  foreach ($opt in $opts.Open) {
    (& $pill 'OptOpen_' $opt[0]).Add_Checked({ $settings.OpenMode = [string]$this.Tag; Save-WidgetSettings $settings })
  }
  foreach ($opt in $opts.Lang) {
    (& $pill 'OptLang_' $opt[0]).Add_Checked({
        $pick = [string]$this.Tag
        if ($pick -eq [string]$settings.Language) { return }
        $settings.Language = $pick; Save-WidgetSettings $settings
        if ((Resolve-Language $pick) -ne $Lang) { Restart-Widget }
      })
  }
  foreach ($opt in $opts.Refresh) {
    (& $pill 'OptRefresh_' $opt[0]).Add_Checked({
        $settings.RefreshSec = [int]$this.Tag; $shared.RefreshMs = $settings.RefreshSec * 1000; Save-WidgetSettings $settings
      })
  }
  foreach ($opt in $opts.Opacity) {
    (& $pill 'OptOpacity_' $opt[0]).Add_Checked({
        $settings.Opacity = [int]$this.Tag; Save-WidgetSettings $settings
        # Applied right away so the effect is visible while choosing
        $win.Opacity = Get-RestOpacity
      })
  }
  foreach ($opt in $opts.Keep) {
    (& $pill 'OptKeep_' $opt[0]).Add_Checked({ $settings.KeepMin = [int]$this.Tag; Save-WidgetSettings $settings })
  }

  (& $find 'SHeader').Add_MouseLeftButtonDown({ try { $state.SettingsWin.DragMove() } catch {} })
  (& $find 'SClose').Add_Click({ $state.SettingsWin.Close() })
  (& $find 'SQuit').Add_Click({ $state.SettingsWin.Close(); Exit-Widget })
  (& $find 'SLink').Add_Click({ try { Start-Process $RepoUrl } catch {} })
  $sw.Add_Closed({ $state.SettingsWin = $null })
  $sw.Show()
  [void]$sw.Activate()
}
