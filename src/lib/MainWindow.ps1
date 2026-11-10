#Requires -Version 5.1
<#
  Main window: the round bubble icon <-> the card with the session list,
  accordion rows, tray icon, notifications and timers.

  Only function definitions. Initialize-MainWindow creates the window and
  stores the shared state in $script: variables of the entry script:
    $script:win, $script:ui, $script:state, $script:tray, $script:shared ...
  Event handlers run in that same scope, so they can use those variables.

  Expects (set by the entry script): $script:settings, $script:AppDir,
  $script:LogFile, $script:SignalFile, $script:IsDemo, $script:C,
  $script:SharedStyles, $script:Lang (see I18n.ps1).
#>

function Write-WidgetLog([string]$Message) {
  try { Add-Content -LiteralPath $script:LogFile -Value "$(Get-Date -Format s) $Message" } catch {}
}

# Escapes text for use inside XAML attribute values.
function ConvertTo-XmlText([string]$Text) { [System.Security.SecurityElement]::Escape($Text) }

<#
  Hides this process's console window, if it has one of its own. Fallback
  for -WindowStyle Hidden; a console shared with another process (e.g. the
  widget was started from a terminal) is left alone.
#>
function Hide-ConsoleWindow {
  try {
    if (-not ('ClaudeSessionWidget.NativeConsole' -as [type])) {
      Add-Type -Namespace ClaudeSessionWidget -Name NativeConsole -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("kernel32.dll")] public static extern uint GetConsoleProcessList(uint[] processList, uint processCount);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
    }
    $h = [ClaudeSessionWidget.NativeConsole]::GetConsoleWindow()
    if ($h -eq [IntPtr]::Zero) { return }
    $ids = New-Object 'uint32[]' 8
    $count = [ClaudeSessionWidget.NativeConsole]::GetConsoleProcessList($ids, 8)
    if ($count -le 1) { [void][ClaudeSessionWidget.NativeConsole]::ShowWindow($h, 0) }   # 0 = SW_HIDE
  } catch {}
}

<#
  Keeps a window out of Alt+Tab (and the taskbar) by giving it the
  WS_EX_TOOLWINDOW extended style and removing WS_EX_APPWINDOW.
  Call before the window is shown; the style is applied once its handle exists.
#>
function Set-ToolWindowStyle {
  param([Parameter(Mandatory)][System.Windows.Window]$Window)
  try {
    if (-not ('ClaudeSessionWidget.NativeWindow' -as [type])) {
      Add-Type -Namespace ClaudeSessionWidget -Name NativeWindow -MemberDefinition @'
[DllImport("user32.dll", EntryPoint = "GetWindowLong")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
[DllImport("user32.dll", EntryPoint = "SetWindowLong")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
'@
    }
  } catch { return }
  $Window.Add_SourceInitialized({
      try {
        $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($this)).Handle
        $GWL_EXSTYLE = -20; $WS_EX_TOOLWINDOW = 0x80; $WS_EX_APPWINDOW = 0x40000
        $style = [ClaudeSessionWidget.NativeWindow]::GetWindowLong($hwnd, $GWL_EXSTYLE)
        $style = ($style -bor $WS_EX_TOOLWINDOW) -band (-bnot $WS_EX_APPWINDOW)
        [void][ClaudeSessionWidget.NativeWindow]::SetWindowLong($hwnd, $GWL_EXSTYLE, $style)
      } catch {}
    })
}

# ------------------------------------------------------- Background scanning

function New-SharedState {
  [hashtable]::Synchronized(@{
      Sessions = @(); Stamp = 0; Stop = $false; Error = $null
      ShowCli = [bool]$script:settings.ShowCli; RefreshMs = [int]$script:settings.RefreshSec * 1000; Wake = $false
    })
}

# Starts the scanner loop in a background runspace; results land in $script:shared.
function Start-SessionScanner {
  param([Parameter(Mandatory)][string]$ScannerPath)
  $script:shared = New-SharedState
  $loop = {
    param($shared, $scannerPath)
    . $scannerPath
    while (-not $shared.Stop) {
      try { $shared.Sessions = @(Get-ClaudeSession -IncludeTerminal:([bool]$shared.ShowCli)); $shared.Error = $null }
      catch { $shared.Error = $_.Exception.Message }
      $shared.Stamp = $shared.Stamp + 1
      $waited = 0
      while ($waited -lt $shared.RefreshMs -and -not $shared.Stop -and -not $shared.Wake) {
        Start-Sleep -Milliseconds 100; $waited += 100
      }
      $shared.Wake = $false
    }
  }
  $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
  try { $iss.ExecutionPolicy = 'Bypass' } catch {}
  $rs = [runspacefactory]::CreateRunspace($iss)
  $rs.Open()
  $ps = [powershell]::Create()
  $ps.Runspace = $rs
  [void]$ps.AddScript($loop).AddArgument($script:shared).AddArgument($ScannerPath)
  $script:ScannerJob = @{ PowerShell = $ps; Runspace = $rs; Handle = $ps.BeginInvoke() }
}

# Demo mode: fixed fake sessions, no scanning at all.
function Start-DemoFeed {
  $script:shared = New-SharedState
  $script:shared.Sessions = @(Get-DemoSession)
  $script:shared.Stamp = 1
  $script:ScannerJob = $null
}

function Stop-SessionScanner {
  if ($script:shared) { $script:shared.Stop = $true }
  $job = $script:ScannerJob
  if (-not $job) { return }
  try { $job.PowerShell.EndInvoke($job.Handle) } catch {}
  try { $job.Runspace.Close() } catch {}
}

# ------------------------------------------------------------------ Window

function Get-MainWindowXaml {
  $C = $script:C
  $title = ConvertTo-XmlText (T 'AppTitle')
  @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$title" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" SizeToContent="WidthAndHeight" ResizeMode="NoResize"
        FontFamily="Segoe UI" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
$script:SharedStyles
  </Window.Resources>
  <Grid>
    <!-- Collapsed state: round icon -->
    <Border x:Name="Bubble" Width="54" Height="54" CornerRadius="27" Margin="14"
            Background="$($C.Bg)" BorderBrush="$($C.Line)" BorderThickness="1.5" Cursor="Hand"
            ToolTip="$title">
      <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="3" Opacity="0.5"/></Border.Effect>
      <Grid>
        <TextBlock x:Name="BubbleIcon" Text="&#x273B;" FontFamily="Segoe UI Symbol" FontSize="27"
                   Foreground="$($C.Accent)" HorizontalAlignment="Center" VerticalAlignment="Center"
                   Margin="0,-2,0,0" RenderTransformOrigin="0.5,0.5">
          <TextBlock.RenderTransform><RotateTransform x:Name="Spin" Angle="0"/></TextBlock.RenderTransform>
        </TextBlock>
        <Border x:Name="Badge" MinWidth="19" Height="19" CornerRadius="9.5" Background="$($C.Accent)"
                HorizontalAlignment="Right" VerticalAlignment="Top" Margin="0,-5,-5,0" Padding="5,0"
                BorderBrush="$($C.Bg)" BorderThickness="2" Visibility="Collapsed">
          <TextBlock x:Name="BadgeText" FontSize="10" FontWeight="Bold" Foreground="$($C.Ink)"
                     HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
      </Grid>
    </Border>

    <!-- Expanded state: card -->
    <Border x:Name="Card" Width="380" CornerRadius="12" Margin="14" Visibility="Collapsed"
            Background="$($C.Bg)" BorderBrush="$($C.Line)" BorderThickness="1">
      <Border.Effect><DropShadowEffect BlurRadius="22" ShadowDepth="4" Opacity="0.5"/></Border.Effect>
      <DockPanel>
        <Grid x:Name="Header" DockPanel.Dock="Top" Margin="14,10,8,8" Background="Transparent">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Text="&#x273B;" FontFamily="Segoe UI Symbol" FontSize="18"
                     Foreground="$($C.Accent)" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5">
            <TextBlock.RenderTransform><RotateTransform x:Name="Spin2" Angle="0"/></TextBlock.RenderTransform>
          </TextBlock>
          <StackPanel Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="$(ConvertTo-XmlText (T 'Header'))" Foreground="$($C.Text)" FontSize="13" FontWeight="SemiBold"/>
            <TextBlock x:Name="Subtitle" Foreground="$($C.Muted)" FontSize="11" Margin="0,1,0,0" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="BtnSettings" Style="{StaticResource IconBtn}" Content="&#xE713;" ToolTip="$(ConvertTo-XmlText (T 'TipSettings'))"/>
            <Button x:Name="BtnPin" Style="{StaticResource IconBtn}" Content="&#xE718;" ToolTip="$(ConvertTo-XmlText (T 'TipPin'))"/>
            <Button x:Name="BtnMin" Style="{StaticResource IconBtn}" Content="&#xE921;" ToolTip="$(ConvertTo-XmlText (T 'TipMin'))"/>
            <Button x:Name="BtnClose" Style="{StaticResource IconBtn}" Content="&#xE8BB;" ToolTip="$(ConvertTo-XmlText (T 'TipHide'))"/>
          </StackPanel>
        </Grid>
        <Border DockPanel.Dock="Top" Height="1" Background="$($C.Line)"/>
        <ScrollViewer MaxHeight="520" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="List" Margin="14,6,14,10"/>
        </ScrollViewer>
      </DockPanel>
    </Border>
  </Grid>
</Window>
"@
}

function Get-RestOpacity { [Math]::Min(1.0, [Math]::Max(0.3, [double]$script:settings.Opacity / 100)) }

function Get-WhereText([string]$Where) {
  if ($Where -eq 'local') { return (T 'Local') }
  if ($Where -eq 'terminal') { return (T 'Terminal') }
  return $Where
}

# ------------------------------------------ Position: anchored bottom-right

function Reset-AnchorIfOffscreen {
  $wa = [System.Windows.SystemParameters]::WorkArea
  $vs = @{
    L = [System.Windows.SystemParameters]::VirtualScreenLeft; T = [System.Windows.SystemParameters]::VirtualScreenTop
    W = [System.Windows.SystemParameters]::VirtualScreenWidth; H = [System.Windows.SystemParameters]::VirtualScreenHeight
  }
  $r = [double]$settings.Right; $b = [double]$settings.Bottom
  if ($r -lt 0 -or $b -lt 0 -or $r -gt $vs.L + $vs.W + 1 -or $b -gt $vs.T + $vs.H + 1 -or $r -lt $vs.L + 60 -or $b -lt $vs.T + 60) {
    $settings.Right = $wa.Right - 4
    $settings.Bottom = $wa.Bottom - 4
  }
}

function Set-Anchor {
  if ($win.ActualWidth -le 0) { return }
  $win.Left = [double]$settings.Right - $win.ActualWidth
  $win.Top = [double]$settings.Bottom - $win.ActualHeight
}

# Drags the window; returns $true when it actually moved (then it is not a click).
function Start-Drag {
  $l = $win.Left; $t = $win.Top
  try { $win.DragMove() } catch {}
  $moved = ([Math]::Abs($win.Left - $l) + [Math]::Abs($win.Top - $t)) -gt 3
  if ($moved) {
    $settings.Right = $win.Left + $win.ActualWidth
    $settings.Bottom = $win.Top + $win.ActualHeight
    Save-WidgetSettings $settings
  }
  return $moved
}

# ------------------------------------------------------- Bubble <-> card

function Set-Expanded([bool]$On) {
  $state.Expanded = $On
  $settings.Expanded = $On
  if ($On) {
    $state.Unseen = 0
    $ui.Card.Visibility = 'Visible'; $ui.Bubble.Visibility = 'Collapsed'
  } else {
    $ui.Card.Visibility = 'Collapsed'; $ui.Bubble.Visibility = 'Visible'
  }
  Update-Chrome
  Save-WidgetSettings $settings
}

function Show-Widget {
  $win.Show(); [void]$win.Activate()
  Set-Expanded $true
}

# -------------------------------------------------------------------- Rows

function Format-Elapsed([double]$Ms) {
  $s = [Math]::Max(0, [Math]::Round($Ms / 1000))
  if ($s -lt 60) { return "$s $(T 'Sec')" }
  $m = [Math]::Floor($s / 60)
  if ($m -lt 60) { return "$m $(T 'Min')" }
  return "$([Math]::Floor($m / 60)) $(T 'Hr') $($m % 60) $(T 'Min')"
}

function New-Text([string]$Text, [string]$Color, [double]$Size = 12, [string]$Weight = 'Normal') {
  $t = New-Object System.Windows.Controls.TextBlock
  $t.Text = $Text; $t.Foreground = Get-Brush $Color; $t.FontSize = $Size; $t.FontWeight = $Weight
  $t.TextTrimming = 'CharacterEllipsis'
  return $t
}

function New-ColumnGrid([string[]]$Widths) {
  $g = New-Object System.Windows.Controls.Grid
  foreach ($w in $Widths) {
    $cd = New-Object System.Windows.Controls.ColumnDefinition
    $cd.Width = ConvertTo-GridLength $w
    [void]$g.ColumnDefinitions.Add($cd)
  }
  return $g
}

# Thin bar + "done/total  %pct" label ("—" without a task list).
function New-ProgressBar($Session) {
  $s = $Session
  $pg = New-ColumnGrid @('*', 'Auto')
  $track = New-Object System.Windows.Controls.Grid
  $track.Height = 5; $track.VerticalAlignment = 'Center'
  $bgT = New-Object System.Windows.Controls.Border
  $bgT.CornerRadius = 2.5; $bgT.Background = Get-Brush $C.Line
  [void]$track.Children.Add($bgT)
  $label = '—'
  if ($s.Total -gt 0) {
    $fillGrid = New-Object System.Windows.Controls.Grid
    $fc1 = New-Object System.Windows.Controls.ColumnDefinition
    $fc1.Width = New-Object System.Windows.GridLength([double][Math]::Max($s.Done, 0.0001), 'Star')
    $fc2 = New-Object System.Windows.Controls.ColumnDefinition
    $fc2.Width = New-Object System.Windows.GridLength([double][Math]::Max($s.Total - $s.Done, 0.0001), 'Star')
    [void]$fillGrid.ColumnDefinitions.Add($fc1); [void]$fillGrid.ColumnDefinitions.Add($fc2)
    $fill = New-Object System.Windows.Controls.Border
    $fill.CornerRadius = 2.5; $fill.Background = Get-Brush $C.Accent
    if ($s.Done -eq 0) { $fill.Visibility = 'Collapsed' }
    [void]$fillGrid.Children.Add($fill)
    [void]$track.Children.Add($fillGrid)
    $label = "$($s.Done)/$($s.Total)  " + ((T 'Percent') -f [Math]::Round(100 * $s.Done / $s.Total))
  }
  [void]$pg.Children.Add($track)
  $cnt = New-Text $label $C.Text2 11
  $cnt.Margin = '10,0,0,0'
  [System.Windows.Controls.Grid]::SetColumn($cnt, 1)
  [void]$pg.Children.Add($cnt)
  return $pg
}

# One accordion row: collapsed = title + progress bar, expanded adds steps and activity.
function New-SessionRow($Session, [double]$Now, [bool]$First) {
  $s = $Session
  $isOpen = [bool]$state.Open[$s.Id]
  $box = New-Object System.Windows.Controls.StackPanel
  $box.Margin = '0,6,0,4'

  if (-not $First) {
    $sep = New-Object System.Windows.Controls.Border
    $sep.Height = 1; $sep.Background = Get-Brush $C.Line; $sep.Margin = '0,0,0,6'; $sep.Opacity = 0.6
    [void]$box.Children.Add($sep)
  }

  # Clickable header: chevron, name, elapsed time and the progress bar below
  $head = New-Object System.Windows.Controls.Border
  $head.Background = [System.Windows.Media.Brushes]::Transparent
  $head.CornerRadius = 6
  $head.Padding = '4,5,4,6'
  $head.Margin = '-4,0,-4,0'
  $head.Cursor = 'Hand'
  $head.Tag = $s.Id
  $head.ToolTip = $s.Cwd
  $head.Add_MouseEnter({ $this.Background = Get-Brush $C.Bg2 })
  $head.Add_MouseLeave({ $this.Background = [System.Windows.Media.Brushes]::Transparent })
  $head.Add_MouseLeftButtonUp({
      $id = [string]$this.Tag
      $state.Open[$id] = -not [bool]$state.Open[$id]
      Update-SessionList
    })

  $hs = New-Object System.Windows.Controls.StackPanel
  $g = New-ColumnGrid @('Auto', '*', 'Auto')
  $chev = New-Text ([string][char]0xE76C) $C.Muted 9
  if ($isOpen) { $chev.Text = [string][char]0xE70D }
  $chev.FontFamily = 'Segoe MDL2 Assets'
  $chev.VerticalAlignment = 'Center'; $chev.Margin = '0,1,8,0'; $chev.Width = 10
  $name = New-Text $s.Name $C.Text 13 'SemiBold'
  [System.Windows.Controls.Grid]::SetColumn($name, 1)
  $time = New-Text (Format-Elapsed ($Now - $s.Since)) $C.Muted 11
  $time.Margin = '8,0,0,0'; $time.VerticalAlignment = 'Center'
  [System.Windows.Controls.Grid]::SetColumn($time, 2)
  [void]$g.Children.Add($chev); [void]$g.Children.Add($name); [void]$g.Children.Add($time)
  [void]$hs.Children.Add($g)

  $bar = New-ProgressBar $s
  $bar.Margin = '18,7,0,0'
  [void]$hs.Children.Add($bar)
  $head.Child = $hs
  [void]$box.Children.Add($head)

  if (-not $isOpen) { return $box }

  # ---- Expanded: details
  $body = New-Object System.Windows.Controls.StackPanel
  $body.Margin = '18,4,0,4'

  $leaf = @(($s.Cwd -split '[\\/]') | Where-Object { $_ })
  $leafName = ''; if ($leaf.Count) { $leafName = $leaf[-1] }
  [void]$body.Children.Add((New-Text "$(Get-WhereText $s.Where) · $leafName" $C.Muted 11))

  if ($s.Total -gt 0) {
    $steps = New-Object System.Windows.Controls.StackPanel
    $steps.Margin = '0,6,0,0'
    foreach ($st in $s.Steps) {
      $t = New-Text '' $C.Text2 12
      $t.Margin = '0,1,0,1'
      $mark = '○  '; $markCol = $C.Dim; $textCol = $C.Muted
      if ($st.Status -eq 'completed') { $mark = '✓  '; $markCol = $C.Green; $textCol = $C.Text2 }
      elseif ($st.Status -eq 'in_progress') { $mark = '▸  '; $markCol = $C.Accent; $textCol = $C.Text }
      $r1 = New-Object System.Windows.Documents.Run $mark; $r1.Foreground = Get-Brush $markCol
      $r2 = New-Object System.Windows.Documents.Run $st.Text; $r2.Foreground = Get-Brush $textCol
      $t.Inlines.Add($r1); $t.Inlines.Add($r2)
      $t.ToolTip = $st.Text
      [void]$steps.Children.Add($t)
    }
    [void]$body.Children.Add($steps)
  }

  $actText = $s.Activity
  if ($actText -eq '@finishing') { $actText = T 'Finishing' }
  if (-not $actText) { $actText = T 'Working' }
  $a = New-Text "⎿  $actText" $C.Muted 11
  $a.FontFamily = 'Cascadia Mono, Consolas'
  $a.Margin = '0,6,0,0'
  $a.ToolTip = $actText
  [void]$body.Children.Add($a)

  [void]$box.Children.Add($body)
  return $box
}

# Rebuilds the card's list: running sessions, then the FINISHED section.
function Update-SessionList {
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $list = @($shared.Sessions)
  $ui.List.Children.Clear()

  if ($list.Count -eq 0 -and $state.Finished.Count -eq 0) {
    $e = New-Text (T 'NoSessions') $C.Muted 12
    $e.HorizontalAlignment = 'Center'; $e.Margin = '0,18,0,14'
    [void]$ui.List.Children.Add($e)
  }

  $first = $true
  foreach ($s in $list) {
    [void]$ui.List.Children.Add((New-SessionRow $s $now $first))
    $first = $false
  }

  if ($state.Finished.Count -gt 0) {
    $hdr = New-ColumnGrid @('*', 'Auto')
    $hdr.Margin = '0,14,0,4'
    $ht = New-Text (T 'Finished') $C.Muted 10 'SemiBold'
    $ht.VerticalAlignment = 'Center'
    [void]$hdr.Children.Add($ht)
    $clr = New-Object System.Windows.Controls.Button
    $clr.Content = (T 'Clear'); $clr.Style = $win.FindResource('TextBtn')
    $clr.Add_Click({ $state.Finished.Clear(); Update-SessionList; Update-Chrome })
    [System.Windows.Controls.Grid]::SetColumn($clr, 1)
    [void]$hdr.Children.Add($clr)
    [void]$ui.List.Children.Add($hdr)

    foreach ($f in $state.Finished) {
      $g = New-ColumnGrid @('*', 'Auto')
      $g.Margin = '0,3,0,3'
      $t = New-Text '' $C.Text2 12
      $r1 = New-Object System.Windows.Documents.Run '✓  '; $r1.Foreground = Get-Brush $C.Green
      $r2 = New-Object System.Windows.Documents.Run $f.Name
      $t.Inlines.Add($r1); $t.Inlines.Add($r2)
      $ago = New-Text ((T 'Ago') -f (Format-Elapsed ($now - $f.At))) $C.Muted 11
      $ago.Margin = '8,0,0,0'
      [System.Windows.Controls.Grid]::SetColumn($ago, 1)
      [void]$g.Children.Add($t); [void]$g.Children.Add($ago)
      [void]$ui.List.Children.Add($g)
    }
  }
}

# --------------------------------------------------------------- Tray icon

# Draws the ✻ glyph in $Hex on a dark circle.
function New-TrayIcon([string]$Hex) {
  $bmp = New-Object System.Drawing.Bitmap 32, 32
  $gr = [System.Drawing.Graphics]::FromImage($bmp)
  $gr.SmoothingMode = 'AntiAlias'
  $gr.TextRenderingHint = 'AntiAliasGridFit'
  $col = [System.Drawing.ColorTranslator]::FromHtml($Hex)
  $gr.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($C.Bg))), 0, 0, 31, 31)
  $font = New-Object System.Drawing.Font('Segoe UI Symbol', 17, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
  $sf = New-Object System.Drawing.StringFormat
  $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $gr.DrawString([string][char]0x273B, $font, (New-Object System.Drawing.SolidBrush $col), (New-Object System.Drawing.RectangleF(0, 1, 32, 32)), $sf)
  $gr.Dispose()
  return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

function Initialize-TrayIcon {
  $script:icoNormal = New-TrayIcon $C.Accent
  $script:icoDone = New-TrayIcon $C.Green
  $script:icoDim = New-TrayIcon $C.Dim

  $script:tray = New-Object System.Windows.Forms.NotifyIcon
  $tray.Icon = $icoNormal
  $tray.Text = (T 'AppTitle')
  $tray.Visible = $true
  $menu = New-Object System.Windows.Forms.ContextMenuStrip
  $miShow = $menu.Items.Add((T 'Show'))
  $miSettings = $menu.Items.Add((T 'SettingsMenu'))
  $script:miTop = $menu.Items.Add((T 'Topmost'))
  $miTop.Checked = $win.Topmost
  [void]$menu.Items.Add('-')
  $miExit = $menu.Items.Add((T 'Exit'))
  $tray.ContextMenuStrip = $menu
  $tray.Add_MouseClick({ param($src, $e) if ($e.Button -eq 'Left') { Show-Widget } })
  $tray.Add_BalloonTipClicked({ Show-Widget })
  $miShow.Add_Click({ Show-Widget })
  $miSettings.Add_Click({ Show-Settings })
  $miTop.Add_Click({ Set-Topmost (-not $win.Topmost) })
  $miExit.Add_Click({ Exit-Widget })
}

function Exit-Widget {
  $shared.Stop = $true
  $tray.Visible = $false
  $tray.Dispose()
  Save-WidgetSettings $settings
  $app.Shutdown()
}

# Starts a new instance (it waits until this one releases the mutex) and exits.
function Restart-Widget {
  $extra = @('-Restart', '-OpenSettings')
  if ($IsDemo) { $extra = @('-Restart', '-Demo', '-DemoView', 'settings', '-Language', [string]$settings.Language) }
  Start-Process -FilePath (Get-PowerShellExe) -ArgumentList (Get-WidgetLaunchArgument -AppDir $AppDir -Extra $extra) -WindowStyle Hidden
  if ($state.SettingsWin) { $state.SettingsWin.Close() }
  Exit-Widget
}

function Set-Topmost([bool]$On) {
  $win.Topmost = $On
  $settings.Topmost = $On
  $miTop.Checked = $On
  Update-Chrome
  Save-WidgetSettings $settings
}

# -------------------------------------------- Subtitle, icon colors, badge

function Update-Chrome {
  $n = @($shared.Sessions).Count
  $sub = T 'NoWork'
  if ($n -gt 0) { $sub = (T 'NRunning') -f $n }
  if ($state.Finished.Count -gt 0) { $sub += ' · ' + ((T 'NFinished') -f $state.Finished.Count) }
  if ($shared.Error) { $sub = (T 'Error') -f $shared.Error }
  $ui.Subtitle.Text = $sub

  if ($state.Unseen -gt 0) {
    $ui.Badge.Visibility = 'Visible'
    $ui.Badge.Background = Get-Brush $C.Green
    $ui.BadgeText.Text = "✓$($state.Unseen)"
  } elseif ($n -gt 0) {
    $ui.Badge.Visibility = 'Visible'
    $ui.Badge.Background = Get-Brush $C.Accent
    $ui.BadgeText.Text = "$n"
  } else {
    $ui.Badge.Visibility = 'Collapsed'
  }
  if ($state.Unseen -le 0 -or -not $settings.Blink) {
    $col = $C.Dim; if ($n -gt 0) { $col = $C.Accent }
    if ($state.Unseen -gt 0) { $col = $C.Green }
    $ui.BubbleIcon.Foreground = Get-Brush $col
    $ui.Bubble.BorderBrush = Get-Brush $C.Line
    if ($state.Unseen -gt 0) { $tray.Icon = $icoDone } else { $tray.Icon = $icoNormal }
  }
  if ($win.Topmost) { $ui.BtnPin.Foreground = Get-Brush $C.Accent } else { $ui.BtnPin.Foreground = Get-Brush $C.Muted }
  $tt = "Claude: $sub"
  $tray.Text = $tt.Substring(0, [Math]::Min(63, $tt.Length))

  # The ✻ slowly spins while something is running
  $want = $n -gt 0
  if ($want -ne $state.Spinning) {
    $state.Spinning = $want
    foreach ($rt in $ui.Spin, $ui.Spin2) {
      if ($want) {
        $anim = New-Object System.Windows.Media.Animation.DoubleAnimation(0, 360, (New-Object System.Windows.Duration ([TimeSpan]::FromSeconds(6))))
        $anim.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $rt.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $anim)
      } else {
        $rt.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
        $rt.Angle = 0
      }
    }
  }
}

# ------------------------------------------------------------------ Timers

# Every 500 ms: handle signals from a second launch, then redraw when a new scan arrived.
function Invoke-DataTick {
  try {
    # Started a second time: show the card or open settings
    if (Test-Path -LiteralPath $SignalFile) {
      $sig = (Get-Content -LiteralPath $SignalFile -Raw -ErrorAction SilentlyContinue)
      Remove-Item -LiteralPath $SignalFile -ErrorAction SilentlyContinue
      if ($sig -and $sig.Trim() -eq 'settings') { Show-Settings } else { Show-Widget }
    }

    if ($shared.Stamp -eq $state.LastStamp) { return }
    $state.LastStamp = $shared.Stamp
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $list = @($shared.Sessions)
    $cur = @{}
    foreach ($s in $list) { $cur[$s.Id] = $s }

    # Sessions that disappeared since the last scan have finished
    if ($null -ne $state.Prev) {
      $ended = @()
      foreach ($id in $state.Prev.Keys) {
        if (-not $cur.ContainsKey($id)) { $ended += $state.Prev[$id] }
      }
      foreach ($e in $ended) {
        for ($k = $state.Finished.Count - 1; $k -ge 0; $k--) { if ($state.Finished[$k].Id -eq $e.Id) { $state.Finished.RemoveAt($k) } }
        $state.Finished.Insert(0, [pscustomobject]@{ Id = $e.Id; Name = $e.Name; At = $now })
      }
      if ($ended.Count -gt 0) {
        if (-not ($state.Expanded -and $win.IsVisible)) { $state.Unseen += $ended.Count }
        if ($settings.Notify) {
          $msg = $ended[0].Name
          if ($ended.Count -gt 1) { $msg = (T 'DoneMany') -f $ended.Count }
          $tray.ShowBalloonTip(5000, (T 'DoneTitle'), $msg, 'Info')
        }
      }
    }
    $state.Prev = $cur

    # Drop finished entries that started again or expired
    $keepMs = [double]$settings.KeepMin * 60000
    for ($k = $state.Finished.Count - 1; $k -ge 0; $k--) {
      $f = $state.Finished[$k]
      if ($cur.ContainsKey($f.Id) -or ($now - $f.At) -gt $keepMs) { $state.Finished.RemoveAt($k) }
    }

    Update-SessionList
    Update-Chrome
  } catch {
    Write-WidgetLog "tick: $($_.Exception.Message)"
  }
}

# Every 550 ms: blink green while a finished job is unseen.
function Invoke-BlinkTick {
  if ($state.Unseen -gt 0 -and $settings.Blink) {
    $state.BlinkOn = -not $state.BlinkOn
    if ($state.BlinkOn) {
      $ui.BubbleIcon.Foreground = Get-Brush $C.Green
      $ui.Bubble.BorderBrush = Get-Brush $C.Green
      $tray.Icon = $icoDone
    } else {
      $ui.BubbleIcon.Foreground = Get-Brush $C.Dim
      $ui.Bubble.BorderBrush = Get-Brush $C.Line
      $tray.Icon = $icoDim
    }
  }
}

# ------------------------------------------------------------------- Setup

<#
  Creates the window, tray icon and timers. $Expanded overrides the start
  state (demo mode); otherwise it follows the OpenMode setting.
#>
function Initialize-MainWindow {
  param([object]$Expanded = $null)
  [xml]$xaml = Get-MainWindowXaml
  $script:win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
  $script:ui = @{}
  foreach ($n in 'Bubble', 'BubbleIcon', 'Spin', 'Spin2', 'Badge', 'BadgeText', 'Card', 'Header',
    'Subtitle', 'BtnSettings', 'BtnPin', 'BtnMin', 'BtnClose', 'List') { $ui[$n] = $win.FindName($n) }

  $win.Topmost = [bool]$settings.Topmost
  Set-ToolWindowStyle -Window $win
  $win.Opacity = Get-RestOpacity
  $win.Add_MouseEnter({ $win.Opacity = 1.0 })
  $win.Add_MouseLeave({ $win.Opacity = Get-RestOpacity })

  $expandedAtStart = [bool]$settings.Expanded
  if ($settings.OpenMode -eq 'icon') { $expandedAtStart = $false }
  if ($settings.OpenMode -eq 'card') { $expandedAtStart = $true }
  if ($null -ne $Expanded) { $expandedAtStart = [bool]$Expanded }
  $script:state = @{
    LastStamp = -1; Prev = $null; Finished = New-Object System.Collections.ArrayList
    Unseen = 0; BlinkOn = $false; Spinning = $false; Open = @{}; Expanded = $expandedAtStart; SettingsWin = $null
  }

  Reset-AnchorIfOffscreen
  $win.Add_SizeChanged({ Set-Anchor })
  $win.Add_Loaded({ Set-Anchor })

  Initialize-TrayIcon

  $ui.Bubble.Add_MouseLeftButtonDown({ if (-not (Start-Drag)) { Set-Expanded $true } })
  $ui.Header.Add_MouseLeftButtonDown({ [void](Start-Drag) })
  $ui.BtnMin.Add_Click({ Set-Expanded $false })
  $ui.BtnSettings.Add_Click({ Show-Settings })
  $ui.BtnClose.Add_Click({
      $win.Hide()
      $tray.ShowBalloonTip(2500, (T 'AppTitle'), (T 'HiddenBody'), 'Info')
    })
  $ui.BtnPin.Add_Click({ Set-Topmost (-not $win.Topmost) })

  $script:dataTimer = New-Object System.Windows.Threading.DispatcherTimer
  $dataTimer.Interval = [TimeSpan]::FromMilliseconds(500)
  $dataTimer.Add_Tick({ Invoke-DataTick })
  $script:blinkTimer = New-Object System.Windows.Threading.DispatcherTimer
  $blinkTimer.Interval = [TimeSpan]::FromMilliseconds(550)
  $blinkTimer.Add_Tick({ Invoke-BlinkTick })
}

# Shows the window and runs the WPF message loop until Exit-Widget.
function Start-WidgetApp {
  param([switch]$OpenSettingsWindow)
  Remove-Item -LiteralPath $SignalFile -ErrorAction SilentlyContinue
  $dataTimer.Start()
  $blinkTimer.Start()
  Set-Expanded $state.Expanded
  Update-SessionList
  Update-Chrome
  $script:app = New-Object System.Windows.Application
  $app.ShutdownMode = 'OnExplicitShutdown'
  $win.Show()
  if ($OpenSettingsWindow) { Show-Settings }
  [void]$app.Run()
}
