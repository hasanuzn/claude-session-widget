#Requires -Version 5.1
<#
  Claude Oturum Widget'ı
  Claude masaüstü uygulamasında şu anda çalışan oturumları, aktif işi ve
  ilerlemeyi masaüstünde ayrı, küçük bir pencerede gösterir.

  Çalıştırma:  baslat.vbs (konsolsuz)  ya da
               powershell -NoProfile -ExecutionPolicy Bypass -STA -File oturum-widget.ps1
  Deneme:      powershell -NoProfile -ExecutionPolicy Bypass -File oturum-widget.ps1 -Test
#>
param([switch]$Test, [switch]$OpenSettings, [switch]$Restart)

$ErrorActionPreference = 'Stop'
$AppVersion = '1.0.0'
$RepoUrl = 'https://github.com/hasanuzn/claude-session-widget'
$AppDir = $PSScriptRoot
$LogFile = Join-Path $env:TEMP 'oturum-widget.log'

# ======================================================================
#  Veri tarayıcı (arka planda ayrı bir runspace içinde çalışır)
# ======================================================================
$ScannerCode = {
  $STALE_MS = 2 * 60 * 60 * 1000
  $script:metaCache = @{}
  $script:parseCache = @{}

  function Get-NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

  function Get-ClaudeDir {
    if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
    return (Join-Path $env:USERPROFILE '.claude')
  }

  function Get-Short([string]$s, [int]$n = 80) {
    if (-not $s) { return '' }
    $t = ($s -replace '\s+', ' ').Trim()
    if ($t.Length -gt $n) { return $t.Substring(0, $n - 1) + [char]0x2026 }
    return $t
  }

  function Invoke-Wsl([string]$distro, [string]$path) {
    $sh = "grep -E 'update_plan|TodoWrite|wrap_up' `"`$1`" | tail -n 60`n" +
          "tail -n 300 `"`$1`" | grep '`"tool_use`"' | tail -n 20`n"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'wsl.exe'
    $psi.Arguments = "-d `"$distro`" -e sh -s -- `"$path`""
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($sh.Replace("`r", ''))
    $p.StandardInput.Close()
    [void]$p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    [void]$p.WaitForExit(15000)
    return $out -split "`n"
  }

  function Read-LocalTranscript([string]$path) {
    $plan = @(Select-String -LiteralPath $path -Pattern 'update_plan|TodoWrite|wrap_up' -Encoding UTF8 |
      Select-Object -Last 60 | ForEach-Object { $_.Line })
    $tail = @(Get-Content -LiteralPath $path -Tail 300 -Encoding UTF8 |
      Where-Object { $_.Contains('"tool_use"') } | Select-Object -Last 20)
    return $plan + $tail
  }

  function Get-ToolText($name, $inp) {
    $label = $name
    if ($name.StartsWith('mcp__')) { $label = ($name -split '__')[-1] }
    foreach ($k in 'description', 'file_path', 'pattern', 'query', 'url', 'command', 'prompt') {
      $v = $inp.$k
      if ($v) { return "$label · $(Get-Short ([string]$v) 70)" }
    }
    return $label
  }

  function New-Empty { [pscustomobject]@{ Done = 0; Total = 0; Current = ''; Activity = ''; Steps = @() } }

  function Parse-Lines($lines) {
    $steps = New-Object System.Collections.ArrayList
    $activity = ''
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($l in $lines) {
      if (-not $l) { continue }
      $l = $l.TrimEnd("`r")
      if (-not $seen.Add($l)) { continue }
      if (-not $l.Contains('"tool_use"')) { continue }
      try { $r = $l | ConvertFrom-Json } catch { continue }
      if ($r.type -ne 'assistant' -or -not $r.message) { continue }
      foreach ($b in @($r.message.content)) {
        if (-not $b -or $b.type -ne 'tool_use') { continue }
        $n = [string]$b.name
        $i = $b.input
        if ($n.EndsWith('update_plan')) {
          if ($i.items) {
            $steps = New-Object System.Collections.ArrayList
            foreach ($it in @($i.items)) {
              $st = [string]$it.status; if (-not $st) { $st = 'pending' }
              [void]$steps.Add([pscustomobject]@{ Text = [string]$it.content; Status = $st })
            }
          }
          if ($i.advance) {
            $c = -1
            for ($k = 0; $k -lt $steps.Count; $k++) { if ($steps[$k].Status -eq 'in_progress') { $c = $k; break } }
            if ($c -ge 0) { $steps[$c].Status = 'completed' }
            for ($k = $c + 1; $k -lt $steps.Count; $k++) {
              if ($steps[$k].Status -eq 'pending') { $steps[$k].Status = 'in_progress'; break }
            }
          }
          if ($i.done) {
            foreach ($d in @($i.done)) { if ($d -ge 1 -and $d -le $steps.Count) { $steps[$d - 1].Status = 'completed' } }
          }
          if ($null -ne $i.start) {
            $s = [int]$i.start
            if ($s -ge 1 -and $s -le $steps.Count) { $steps[$s - 1].Status = 'in_progress' }
          }
        }
        elseif ($n -eq 'TodoWrite' -and $i.todos) {
          $steps = New-Object System.Collections.ArrayList
          foreach ($t in @($i.todos)) {
            $txt = [string]$t.content
            if ($t.status -eq 'in_progress' -and $t.activeForm) { $txt = [string]$t.activeForm }
            [void]$steps.Add([pscustomobject]@{ Text = $txt; Status = [string]$t.status })
          }
        }
        elseif ($n.EndsWith('wrap_up')) {
          foreach ($s in $steps) { $s.Status = 'completed' }
          $activity = '@finishing'
        }
        else {
          $activity = Get-ToolText $n $i
        }
      }
    }
    $done = @($steps | Where-Object { $_.Status -eq 'completed' }).Count
    $cur = @($steps | Where-Object { $_.Status -eq 'in_progress' } | Select-Object -First 1)
    $curText = ''
    if ($cur.Count) { $curText = $cur[0].Text }
    return [pscustomobject]@{
      Done = $done; Total = $steps.Count; Current = $curText; Activity = $activity
      Steps = @($steps | ForEach-Object { [pscustomobject]@{ Text = $_.Text; Status = $_.Status } })
    }
  }

  function Find-LocalTranscript([string]$root, [string]$id, [string]$cwd) {
    $slug = $cwd -replace '[^a-zA-Z0-9]', '-'
    $direct = Join-Path $root "projects\$slug\$id.jsonl"
    if (Test-Path -LiteralPath $direct) { return $direct }
    $hit = Get-ChildItem -Path (Join-Path $root 'projects') -Filter "$id.jsonl" -Recurse -Depth 1 -ErrorAction SilentlyContinue |
      Select-Object -First 1
    if ($hit) { return $hit.FullName }
    return $null
  }

  function Get-LeafName([string]$p) {
    if (-not $p) { return '' }
    return (($p -split '[\\/]') | Where-Object { $_ })[-1]
  }

  function Invoke-Scan([bool]$showCli = $true) {
    $now = Get-NowMs
    $root = Get-ClaudeDir
    $out = New-Object System.Collections.ArrayList
    $seenCli = New-Object 'System.Collections.Generic.HashSet[string]'

    # --- Masaüstü uygulamasının oturumları (yerel, WSL, SSH) ---
    $metaFiles = @(Get-ChildItem -Path "$env:LOCALAPPDATA\Claude-Data\*\claude-code-sessions\*\*\local_*.json" -ErrorAction SilentlyContinue)
    foreach ($f in $metaFiles) {
      $stamp = $f.LastWriteTimeUtc.Ticks
      $c = $script:metaCache[$f.FullName]
      if ($c -and $c.Stamp -eq $stamp) { $m = $c.Meta }
      else {
        try { $m = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
        $script:metaCache[$f.FullName] = @{ Stamp = $stamp; Meta = $m }
      }
      if ($m.isArchived) { continue }
      $edge = [double]$m.lastTurnEdgeAt
      $userAt = [double]$m.latestUserFrameAt
      # Son kullanıcı mesajı son tur sınırından sonraysa tur hâlâ sürüyor demektir.
      if (-not $userAt -or $userAt -lt $edge) { continue }
      $act = [double]$m.lastActivityAt; if (-not $act) { $act = $userAt }
      if ($now - $act -gt $STALE_MS) { continue }
      $cli = [string]$m.cliSessionId
      if ($cli) { [void]$seenCli.Add($cli) }

      $where = 'local'
      if ($m.wslConfig -and $m.wslConfig.distro) { $where = "WSL · $($m.wslConfig.distro)" }
      elseif ($m.sshRemoteTranscriptPath) { $where = 'SSH' }

      $key = "$($f.FullName)|$act"
      $parsed = $script:parseCache[$key]
      if (-not $parsed) {
        $parsed = New-Empty
        try {
          if ($m.wslConfig -and $m.wslConfig.distro -and $m.sshRemoteTranscriptPath) {
            $parsed = Parse-Lines (Invoke-Wsl $m.wslConfig.distro $m.sshRemoteTranscriptPath)
          }
          elseif (-not $m.sshRemoteTranscriptPath -and $cli) {
            $p = Find-LocalTranscript $root $cli ([string]$m.cwd)
            if ($p) { $parsed = Parse-Lines (Read-LocalTranscript $p) }
          }
        } catch {}
        foreach ($k in @($script:parseCache.Keys)) { if ($k.StartsWith("$($f.FullName)|")) { $script:parseCache.Remove($k) } }
        $script:parseCache[$key] = $parsed
      }

      $name = [string]$m.title
      if (-not $name) { $name = Get-LeafName ([string]$m.cwd) }
      [void]$out.Add([pscustomobject]@{
        Id = [string]$m.sessionId; Name = $name; Cwd = [string]$m.cwd; Where = $where
        Since = $userAt; Done = $parsed.Done; Total = $parsed.Total
        Current = $parsed.Current; Activity = $parsed.Activity; Steps = $parsed.Steps
      })
    }

    # --- Terminalden açılmış (CLI) oturumlar ---
    if ($showCli) {
      $regDir = Join-Path $root 'sessions'
      foreach ($f in @(Get-ChildItem -Path $regDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try { $r = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
        if ($r.status -ne 'busy' -or -not $r.sessionId -or $r.entrypoint -eq 'claude-desktop') { continue }
        if ($seenCli.Contains([string]$r.sessionId)) { continue }
        $p = Find-LocalTranscript $root ([string]$r.sessionId) ([string]$r.cwd)
        $parsed = New-Empty
        if ($p) {
          $fi = Get-Item -LiteralPath $p
          $mt = [DateTimeOffset]::new($fi.LastWriteTimeUtc).ToUnixTimeMilliseconds()
          if ($now - $mt -gt $STALE_MS) { continue }
          $key = "$p|$($fi.LastWriteTimeUtc.Ticks)"
          $parsed = $script:parseCache[$key]
          if (-not $parsed) {
            try { $parsed = Parse-Lines (Read-LocalTranscript $p) } catch { $parsed = New-Empty }
            $script:parseCache[$key] = $parsed
          }
        }
        $name = [string]$r.name
        if (-not $name) { $name = Get-LeafName ([string]$r.cwd) }
        $since = [double]$r.statusUpdatedAt; if (-not $since) { $since = [double]$r.startedAt }
        [void]$out.Add([pscustomobject]@{
          Id = [string]$r.sessionId; Name = $name; Cwd = [string]$r.cwd; Where = 'terminal'
          Since = $since; Done = $parsed.Done; Total = $parsed.Total
          Current = $parsed.Current; Activity = $parsed.Activity; Steps = $parsed.Steps
        })
      }
    }

    return @($out | Sort-Object Since)
  }
}

# ---- Deneme modu: bir kez tara ve yazdır ----
if ($Test) {
  . $ScannerCode
  $found = @(Invoke-Scan $true)
  if (-not $found.Count) { 'No sessions running right now.' }
  $found | ForEach-Object {
    "{0}  [{1}]  {2}/{3}  ▸ {4}  ⎿ {5}" -f $_.Name, $_.Where, $_.Done, $_.Total, $_.Current, $_.Activity
  }
  return
}

# ======================================================================
#  Arayüz
# ======================================================================
try {
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeOturumWidget', [ref]$createdNew)
if (-not $createdNew -and $Restart) {
  try { $createdNew = $mutex.WaitOne(10000) } catch [System.Threading.AbandonedMutexException] { $createdNew = $true }
}
if (-not $createdNew) {
  # Zaten çalışıyor: ondan ayarları ya da kartı açmasını iste.
  $flag = 'show'; if ($OpenSettings) { $flag = 'settings' }
  try { Set-Content -LiteralPath (Join-Path $env:TEMP 'oturum-widget.signal') -Value $flag -Encoding ASCII } catch {}
  return
}

# ---------------------------------------------------------------- Ayarlar
$SettingsDir = Join-Path $env:APPDATA 'ClaudeOturumWidget'
$SettingsFile = Join-Path $SettingsDir 'ayarlar.json'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Session Widget.lnk'
$SignalFile = Join-Path $env:TEMP 'oturum-widget.signal'

$settings = [pscustomobject]@{
  Language = 'auto'    # auto | en | tr
  OpenMode = 'last'     # icon | card | last
  Expanded = $false
  Topmost = $true
  Notify = $true
  Blink = $true
  ShowCli = $true
  RefreshSec = 3
  Opacity = 100
  KeepMin = 30
  Right = -1
  Bottom = -1
}
if (Test-Path -LiteralPath $SettingsFile) {
  try {
    $saved = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $settings.PSObject.Properties.Name) { if ($null -ne $saved.$p) { $settings.$p = $saved.$p } }
  } catch {}
}
function Save-Settings {
  try {
    if (-not (Test-Path -LiteralPath $SettingsDir)) { New-Item -ItemType Directory -Path $SettingsDir | Out-Null }
    $settings | ConvertTo-Json | Set-Content -LiteralPath $SettingsFile -Encoding UTF8
  } catch {}
}

# ------------------------------------------------------------------- Dil
$Strings = @{
  en = @{
    AppTitle = 'Claude sessions'; Header = 'Active sessions'
    TipSettings = 'Settings'; TipPin = 'Always on top'; TipMin = 'Minimize to icon'; TipHide = 'Hide (keeps running in the tray)'
    Sec = 's'; Min = 'min'; Hr = 'h'; Ago = '{0} ago'
    Working = 'Working…'; Finishing = 'Finishing'; NoSessions = 'No sessions running right now'
    Finished = 'FINISHED'; Clear = 'Clear'; Local = 'Local'; Terminal = 'Terminal'
    Show = 'Show'; SettingsMenu = 'Settings…'; Exit = 'Exit'
    NoWork = 'Nothing running'; NRunning = '{0} running'; NFinished = '{0} finished'; Error = 'Error: {0}'
    HiddenBody = 'The widget keeps running in the tray. Click the icon to open it.'
    DoneTitle = '✓ Claude finished'; DoneMany = '{0} sessions finished'
    SettingsTitle = 'Settings'; Close = 'Close'; Version = 'Version {0} · '; Quit = 'Quit widget'
    General = 'GENERAL'; Notifications = 'NOTIFICATIONS'; Data = 'DATA'
    Startup = 'Start with Windows'; StartupD = 'Runs automatically when you sign in.'
    Topmost = 'Always on top'; TopmostD = 'Keeps the widget above other windows.'
    OpenMode = 'On start'; OpenModeD = 'How the widget appears when it starts.'
    OIcon = 'Icon'; OCard = 'Card'; OLast = 'Last state'
    Language = 'Language'; LanguageD = 'Auto follows the Windows display language.'; LAuto = 'Auto'
    Notify = 'Windows notification'; NotifyD = 'Notify when a session finishes its work.'
    Blink = 'Blink the icon'; BlinkD = 'Blinks green while a finished job is unseen.'
    Cli = 'Show terminal sessions'; CliD = 'Also lists sessions started with the claude command.'
    Refresh = 'Refresh interval'; RefreshD = 'How often sessions are scanned.'
    Keep = 'Keep finished'; KeepD = 'How long finished jobs stay in the list.'
    Opacity = 'Transparency'; OpacityD = 'Becomes fully opaque while the mouse is over it.'
  }
  tr = @{
    AppTitle = 'Claude oturumları'; Header = 'Aktif oturumlar'
    TipSettings = 'Ayarlar'; TipPin = 'Her zaman üstte'; TipMin = 'Simgeye küçült'; TipHide = 'Gizle (sistem tepsisinde kalır)'
    Sec = 'sn'; Min = 'dk'; Hr = 'sa'; Ago = '{0} önce'
    Working = 'Çalışıyor…'; Finishing = 'Bitiriyor'; NoSessions = 'Şu anda çalışan oturum yok'
    Finished = 'BİTENLER'; Clear = 'Temizle'; Local = 'Yerel'; Terminal = 'Terminal'
    Show = 'Göster'; SettingsMenu = 'Ayarlar…'; Exit = 'Çıkış'
    NoWork = 'Çalışan iş yok'; NRunning = '{0} oturum çalışıyor'; NFinished = '{0} bitti'; Error = 'Hata: {0}'
    HiddenBody = 'Widget tepside çalışmaya devam ediyor. Açmak için simgeye tıklayın.'
    DoneTitle = '✓ Claude işi bitti'; DoneMany = '{0} oturum işini bitirdi'
    SettingsTitle = 'Ayarlar'; Close = 'Kapat'; Version = 'Sürüm {0} · '; Quit = "Widget'tan çık"
    General = 'GENEL'; Notifications = 'BİLDİRİMLER'; Data = 'VERİ'
    Startup = 'Windows açılınca başlat'; StartupD = 'Oturum açtığınızda widget kendiliğinden çalışır.'
    Topmost = 'Her zaman üstte'; TopmostD = 'Widget diğer pencerelerin üstünde kalır.'
    OpenMode = 'Açılışta'; OpenModeD = 'Widget başlarken nasıl görünsün.'
    OIcon = 'Simge'; OCard = 'Kart'; OLast = 'Son hâli'
    Language = 'Dil'; LanguageD = 'Otomatik, Windows görüntü dilini izler.'; LAuto = 'Otomatik'
    Notify = 'Windows bildirimi'; NotifyD = 'Bir oturum işini bitirince bildirim gönderir.'
    Blink = 'Simge yanıp sönsün'; BlinkD = 'Bakılmamış biten iş varken simge yeşil yanıp söner.'
    Cli = 'Terminal oturumlarını göster'; CliD = 'claude komutuyla terminalden açılan oturumları da listeler.'
    Refresh = 'Yenileme aralığı'; RefreshD = 'Oturumlar ne sıklıkla taransın.'
    Keep = 'Bitenleri tut'; KeepD = 'Biten işler listede ne kadar kalsın.'
    Opacity = 'Şeffaflık'; OpacityD = 'Fare üzerine gelince tam opak olur.'
  }
}
function Resolve-Language([string]$pref) {
  if ($pref -eq 'en' -or $pref -eq 'tr') { return $pref }
  if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'tr') { return 'tr' }
  return 'en'
}
$Lang = Resolve-Language ([string]$settings.Language)
function T([string]$key) {
  $v = $Strings[$Lang][$key]
  if ($null -eq $v) { $v = $Strings['en'][$key] }
  if ($null -eq $v) { return $key }
  return $v
}
function Get-WhereText([string]$w) {
  if ($w -eq 'local') { return (T 'Local') }
  if ($w -eq 'terminal') { return (T 'Terminal') }
  return $w
}

function Get-Startup { Test-Path -LiteralPath $StartupLnk }
function Set-Startup([bool]$on) {
  if ($on) {
    $sh = New-Object -ComObject WScript.Shell
    $lnk = $sh.CreateShortcut($StartupLnk)
    $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
    $lnk.Arguments = "`"$(Join-Path $AppDir 'baslat.vbs')`""
    $lnk.WorkingDirectory = $AppDir
    $lnk.Description = 'Claude Session Widget'
    $ico = Join-Path $AppDir 'widget.ico'
    if (Test-Path -LiteralPath $ico) { $lnk.IconLocation = $ico }
    $lnk.Save()
  } else {
    Remove-Item -LiteralPath $StartupLnk -ErrorAction SilentlyContinue
  }
}

# ---------------------------------------------------------- Arka plan tarama
$shared = [hashtable]::Synchronized(@{
    Sessions = @(); Stamp = 0; Stop = $false; Error = $null
    ShowCli = [bool]$settings.ShowCli; RefreshMs = [int]$settings.RefreshSec * 1000; Wake = $false
  })
$loop = {
  param($shared, $code)
  . ([scriptblock]::Create($code))
  while (-not $shared.Stop) {
    try { $shared.Sessions = @(Invoke-Scan ([bool]$shared.ShowCli)); $shared.Error = $null }
    catch { $shared.Error = $_.Exception.Message }
    $shared.Stamp = $shared.Stamp + 1
    $waited = 0
    while ($waited -lt $shared.RefreshMs -and -not $shared.Stop -and -not $shared.Wake) {
      Start-Sleep -Milliseconds 100; $waited += 100
    }
    $shared.Wake = $false
  }
}
$rs = [runspacefactory]::CreateRunspace()
$rs.Open()
$bg = [powershell]::Create()
$bg.Runspace = $rs
[void]$bg.AddScript($loop).AddArgument($shared).AddArgument($ScannerCode.ToString())
$bgHandle = $bg.BeginInvoke()

# ------------------------------------------------------------------ Renkler
$C = @{
  Bg = '#262624'; Bg2 = '#30302E'; Line = '#3D3D3A'; Text = '#F0EEE6'; Text2 = '#C2C0B6'
  Muted = '#8F8D86'; Accent = '#D97757'; Green = '#7FB77E'; Dim = '#55544F'; Ink = '#1F1E1D'
}
function Brush([string]$hex) { (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex) }
function ConvertTo-GridLength([string]$v) { (New-Object System.Windows.GridLengthConverter).ConvertFromString($v) }

$SharedStyles = @"
    <Style x:Key="IconBtn" TargetType="Button">
      <Setter Property="Foreground" Value="$($C.Muted)"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Width" Value="26"/>
      <Setter Property="Height" Value="26"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="$($C.Bg2)"/>
                <Setter Property="Foreground" Value="$($C.Text)"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="TextBtn" TargetType="Button">
      <Setter Property="Foreground" Value="$($C.Muted)"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="Transparent" CornerRadius="5" Padding="8,4">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="$($C.Bg2)"/>
                <Setter Property="Foreground" Value="$($C.Text)"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="track" Width="36" Height="20" CornerRadius="10" Background="$($C.Line)">
              <Ellipse x:Name="thumb" Width="14" Height="14" Fill="$($C.Text2)" HorizontalAlignment="Left" Margin="3,0,0,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="$($C.Accent)"/>
                <Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="thumb" Property="Margin" Value="0,0,3,0"/>
                <Setter TargetName="thumb" Property="Fill" Value="#FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Pill" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="$($C.Text2)"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="4,0,0,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="b" CornerRadius="6" Padding="10,4" Background="$($C.Bg2)" BorderBrush="$($C.Line)" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="BorderBrush" Value="$($C.Muted)"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="b" Property="Background" Value="$($C.Accent)"/>
                <Setter TargetName="b" Property="BorderBrush" Value="$($C.Accent)"/>
                <Setter Property="Foreground" Value="$($C.Ink)"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
"@

# ------------------------------------------------------------ Ana pencere
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$(T 'AppTitle')" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" SizeToContent="WidthAndHeight" ResizeMode="NoResize"
        FontFamily="Segoe UI" UseLayoutRounding="True" TextOptions.TextFormattingMode="Display">
  <Window.Resources>
$SharedStyles
  </Window.Resources>
  <Grid>
    <!-- Kapalı hal: yuvarlak simge -->
    <Border x:Name="Bubble" Width="54" Height="54" CornerRadius="27" Margin="14"
            Background="$($C.Bg)" BorderBrush="$($C.Line)" BorderThickness="1.5" Cursor="Hand"
            ToolTip="$(T 'AppTitle')">
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

    <!-- Açık hal: kart -->
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
            <TextBlock Text="$(T 'Header')" Foreground="$($C.Text)" FontSize="13" FontWeight="SemiBold"/>
            <TextBlock x:Name="Subtitle" Foreground="$($C.Muted)" FontSize="11" Margin="0,1,0,0" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="BtnSettings" Style="{StaticResource IconBtn}" Content="&#xE713;" ToolTip="$(T 'TipSettings')"/>
            <Button x:Name="BtnPin" Style="{StaticResource IconBtn}" Content="&#xE718;" ToolTip="$(T 'TipPin')"/>
            <Button x:Name="BtnMin" Style="{StaticResource IconBtn}" Content="&#xE921;" ToolTip="$(T 'TipMin')"/>
            <Button x:Name="BtnClose" Style="{StaticResource IconBtn}" Content="&#xE8BB;" ToolTip="$(T 'TipHide')"/>
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

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$ui = @{}
foreach ($n in 'Bubble', 'BubbleIcon', 'Spin', 'Spin2', 'Badge', 'BadgeText', 'Card', 'Header',
  'Subtitle', 'BtnSettings', 'BtnPin', 'BtnMin', 'BtnClose', 'List') { $ui[$n] = $win.FindName($n) }

$win.Topmost = [bool]$settings.Topmost
function Get-RestOpacity { [Math]::Min(1.0, [Math]::Max(0.3, [double]$settings.Opacity / 100)) }
$win.Opacity = Get-RestOpacity
$win.Add_MouseEnter({ $win.Opacity = 1.0 })
$win.Add_MouseLeave({ $win.Opacity = Get-RestOpacity })

# --- Durum ---
$expandedAtStart = [bool]$settings.Expanded
if ($settings.OpenMode -eq 'icon') { $expandedAtStart = $false }
if ($settings.OpenMode -eq 'card') { $expandedAtStart = $true }
$state = @{
  LastStamp = -1; Prev = $null; Finished = New-Object System.Collections.ArrayList
  Unseen = 0; BlinkOn = $false; Spinning = $false; Open = @{}; Expanded = $expandedAtStart; SettingsWin = $null
}

# --- Konum: sağ alt köşeye sabitli ---
$wa = [System.Windows.SystemParameters]::WorkArea
function Reset-AnchorIfOffscreen {
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
Reset-AnchorIfOffscreen
function Set-Anchor {
  if ($win.ActualWidth -le 0) { return }
  $win.Left = [double]$settings.Right - $win.ActualWidth
  $win.Top = [double]$settings.Bottom - $win.ActualHeight
}
$win.Add_SizeChanged({ Set-Anchor })
$win.Add_Loaded({ Set-Anchor })

function Start-Drag {
  $l = $win.Left; $t = $win.Top
  try { $win.DragMove() } catch {}
  $moved = ([Math]::Abs($win.Left - $l) + [Math]::Abs($win.Top - $t)) -gt 3
  if ($moved) {
    $settings.Right = $win.Left + $win.ActualWidth
    $settings.Bottom = $win.Top + $win.ActualHeight
    Save-Settings
  }
  return $moved
}

# --- Görünüm geçişleri ---
function Set-Expanded([bool]$on) {
  $state.Expanded = $on
  $settings.Expanded = $on
  if ($on) {
    $state.Unseen = 0
    $ui.Card.Visibility = 'Visible'; $ui.Bubble.Visibility = 'Collapsed'
  } else {
    $ui.Card.Visibility = 'Collapsed'; $ui.Bubble.Visibility = 'Visible'
  }
  Update-Chrome
  Save-Settings
}

function Show-Widget {
  $win.Show(); [void]$win.Activate()
  Set-Expanded $true
}

# --- Satırlar ---
function Format-Elapsed([double]$ms) {
  $s = [Math]::Max(0, [Math]::Round($ms / 1000))
  if ($s -lt 60) { return "$s $(T 'Sec')" }
  $m = [Math]::Floor($s / 60)
  if ($m -lt 60) { return "$m $(T 'Min')" }
  return "$([Math]::Floor($m / 60)) $(T 'Hr') $($m % 60) $(T 'Min')"
}

function New-Text([string]$text, [string]$color, [double]$size = 12, [string]$weight = 'Normal') {
  $t = New-Object System.Windows.Controls.TextBlock
  $t.Text = $text; $t.Foreground = Brush $color; $t.FontSize = $size; $t.FontWeight = $weight
  $t.TextTrimming = 'CharacterEllipsis'
  return $t
}

function New-Cols([string[]]$widths) {
  $g = New-Object System.Windows.Controls.Grid
  foreach ($w in $widths) {
    $cd = New-Object System.Windows.Controls.ColumnDefinition
    $cd.Width = ConvertTo-GridLength $w
    [void]$g.ColumnDefinitions.Add($cd)
  }
  return $g
}

function New-ProgressBar($s) {
  $pg = New-Cols @('*', 'Auto')
  $track = New-Object System.Windows.Controls.Grid
  $track.Height = 5; $track.VerticalAlignment = 'Center'
  $bgT = New-Object System.Windows.Controls.Border
  $bgT.CornerRadius = 2.5; $bgT.Background = Brush $C.Line
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
    $fill.CornerRadius = 2.5; $fill.Background = Brush $C.Accent
    if ($s.Done -eq 0) { $fill.Visibility = 'Collapsed' }
    [void]$fillGrid.Children.Add($fill)
    [void]$track.Children.Add($fillGrid)
    $label = "$($s.Done)/$($s.Total)  %$([Math]::Round(100 * $s.Done / $s.Total))"
  }
  [void]$pg.Children.Add($track)
  $cnt = New-Text $label $C.Text2 11
  $cnt.Margin = '10,0,0,0'
  [System.Windows.Controls.Grid]::SetColumn($cnt, 1)
  [void]$pg.Children.Add($cnt)
  return $pg
}

function New-SessionRow($s, [double]$now, [bool]$first) {
  $isOpen = [bool]$state.Open[$s.Id]
  $box = New-Object System.Windows.Controls.StackPanel
  $box.Margin = '0,6,0,4'

  if (-not $first) {
    $sep = New-Object System.Windows.Controls.Border
    $sep.Height = 1; $sep.Background = Brush $C.Line; $sep.Margin = '0,0,0,6'; $sep.Opacity = 0.6
    [void]$box.Children.Add($sep)
  }

  # Tıklanabilir başlık: ok, ad, süre ve altında ilerleme çubuğu
  $head = New-Object System.Windows.Controls.Border
  $head.Background = [System.Windows.Media.Brushes]::Transparent
  $head.CornerRadius = 6
  $head.Padding = '4,5,4,6'
  $head.Margin = '-4,0,-4,0'
  $head.Cursor = 'Hand'
  $head.Tag = $s.Id
  $head.ToolTip = $s.Cwd
  $head.Add_MouseEnter({ $this.Background = Brush $C.Bg2 })
  $head.Add_MouseLeave({ $this.Background = [System.Windows.Media.Brushes]::Transparent })
  $head.Add_MouseLeftButtonUp({
      $id = [string]$this.Tag
      $state.Open[$id] = -not [bool]$state.Open[$id]
      Render-List
    })

  $hs = New-Object System.Windows.Controls.StackPanel
  $g = New-Cols @('Auto', '*', 'Auto')
  $chev = New-Text ([string][char]0xE76C) $C.Muted 9
  if ($isOpen) { $chev.Text = [string][char]0xE70D }
  $chev.FontFamily = 'Segoe MDL2 Assets'
  $chev.VerticalAlignment = 'Center'; $chev.Margin = '0,1,8,0'; $chev.Width = 10
  $name = New-Text $s.Name $C.Text 13 'SemiBold'
  [System.Windows.Controls.Grid]::SetColumn($name, 1)
  $time = New-Text (Format-Elapsed ($now - $s.Since)) $C.Muted 11
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

  # ---- Açık hâl: ayrıntılar
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
      $r1 = New-Object System.Windows.Documents.Run $mark; $r1.Foreground = Brush $markCol
      $r2 = New-Object System.Windows.Documents.Run $st.Text; $r2.Foreground = Brush $textCol
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

function Render-List {
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
    $hdr = New-Cols @('*', 'Auto')
    $hdr.Margin = '0,14,0,4'
    $ht = New-Text (T 'Finished') $C.Muted 10 'SemiBold'
    $ht.VerticalAlignment = 'Center'
    [void]$hdr.Children.Add($ht)
    $clr = New-Object System.Windows.Controls.Button
    $clr.Content = (T 'Clear'); $clr.Style = $win.FindResource('TextBtn')
    $clr.Add_Click({ $state.Finished.Clear(); Render-List; Update-Chrome })
    [System.Windows.Controls.Grid]::SetColumn($clr, 1)
    [void]$hdr.Children.Add($clr)
    [void]$ui.List.Children.Add($hdr)

    foreach ($f in $state.Finished) {
      $g = New-Cols @('*', 'Auto')
      $g.Margin = '0,3,0,3'
      $t = New-Text '' $C.Text2 12
      $r1 = New-Object System.Windows.Documents.Run '✓  '; $r1.Foreground = Brush $C.Green
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

# ------------------------------------------------------- Sistem tepsisi
function New-TrayIcon([string]$hex) {
  $bmp = New-Object System.Drawing.Bitmap 32, 32
  $gr = [System.Drawing.Graphics]::FromImage($bmp)
  $gr.SmoothingMode = 'AntiAlias'
  $gr.TextRenderingHint = 'AntiAliasGridFit'
  $col = [System.Drawing.ColorTranslator]::FromHtml($hex)
  $gr.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($C.Bg))), 0, 0, 31, 31)
  $font = New-Object System.Drawing.Font('Segoe UI Symbol', 17, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
  $sf = New-Object System.Drawing.StringFormat
  $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $gr.DrawString([string][char]0x273B, $font, (New-Object System.Drawing.SolidBrush $col), (New-Object System.Drawing.RectangleF(0, 1, 32, 32)), $sf)
  $gr.Dispose()
  return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$icoNormal = New-TrayIcon $C.Accent
$icoDone = New-TrayIcon $C.Green
$icoDim = New-TrayIcon $C.Dim

# Kısayollar için simge dosyası
$IconFile = Join-Path $AppDir 'widget.ico'
if (-not (Test-Path -LiteralPath $IconFile)) {
  try { $fs = [System.IO.File]::Create($IconFile); $icoNormal.Save($fs); $fs.Close() } catch {}
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $icoNormal
$tray.Text = (T 'AppTitle')
$tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = $menu.Items.Add((T 'Show'))
$miSettings = $menu.Items.Add((T 'SettingsMenu'))
$miTop = $menu.Items.Add((T 'Topmost'))
$miTop.Checked = $win.Topmost
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add((T 'Exit'))
$tray.ContextMenuStrip = $menu
$tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq 'Left') { Show-Widget } })
$tray.Add_BalloonTipClicked({ Show-Widget })
$miShow.Add_Click({ Show-Widget })
$miSettings.Add_Click({ Show-Settings })
$miTop.Add_Click({ Set-Topmost (-not $win.Topmost) })
$miExit.Add_Click({ Exit-Widget })

function Exit-Widget {
  $shared.Stop = $true
  $tray.Visible = $false
  $tray.Dispose()
  Save-Settings
  $app.Shutdown()
}

function Restart-Widget {
  # Yeni örnek, bu örnek kapanıp kilidi bırakana kadar bekler.
  Start-Process -FilePath (Join-Path $env:WINDIR 'System32\wscript.exe') -ArgumentList "`"$(Join-Path $AppDir 'baslat.vbs')`" -Restart -OpenSettings"
  if ($state.SettingsWin) { $state.SettingsWin.Close() }
  Exit-Widget
}

function Set-Topmost([bool]$on) {
  $win.Topmost = $on
  $settings.Topmost = $on
  $miTop.Checked = $on
  Update-Chrome
  Save-Settings
}

# --------------------------------------------------- Başlık/simge/rozet
function Update-Chrome {
  $n = @($shared.Sessions).Count
  $sub = T 'NoWork'
  if ($n -gt 0) { $sub = (T 'NRunning') -f $n }
  if ($state.Finished.Count -gt 0) { $sub += ' · ' + ((T 'NFinished') -f $state.Finished.Count) }
  if ($shared.Error) { $sub = (T 'Error') -f $shared.Error }
  $ui.Subtitle.Text = $sub

  if ($state.Unseen -gt 0) {
    $ui.Badge.Visibility = 'Visible'
    $ui.Badge.Background = Brush $C.Green
    $ui.BadgeText.Text = "✓$($state.Unseen)"
  } elseif ($n -gt 0) {
    $ui.Badge.Visibility = 'Visible'
    $ui.Badge.Background = Brush $C.Accent
    $ui.BadgeText.Text = "$n"
  } else {
    $ui.Badge.Visibility = 'Collapsed'
  }
  if ($state.Unseen -le 0 -or -not $settings.Blink) {
    $col = $C.Dim; if ($n -gt 0) { $col = $C.Accent }
    if ($state.Unseen -gt 0) { $col = $C.Green }
    $ui.BubbleIcon.Foreground = Brush $col
    $ui.Bubble.BorderBrush = Brush $C.Line
    if ($state.Unseen -gt 0) { $tray.Icon = $icoDone } else { $tray.Icon = $icoNormal }
  }
  if ($win.Topmost) { $ui.BtnPin.Foreground = Brush $C.Accent } else { $ui.BtnPin.Foreground = Brush $C.Muted }
  $tt = "Claude: $sub"
  $tray.Text = $tt.Substring(0, [Math]::Min(63, $tt.Length))

  # Çalışırken ✻ yavaşça döner
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

# ------------------------------------------------------- Ayarlar penceresi
function New-ToggleRowXaml([string]$name, [string]$title, [string]$desc) {
@"
      <Grid Margin="0,8,0,8">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel Margin="0,0,12,0">
          <TextBlock Text="$title" Foreground="$($C.Text)" FontSize="12.5"/>
          <TextBlock Text="$desc" Foreground="$($C.Muted)" FontSize="11" TextWrapping="Wrap" Margin="0,2,0,0"/>
        </StackPanel>
        <CheckBox x:Name="$name" Grid.Column="1" Style="{StaticResource Switch}"/>
      </Grid>
"@
}
function New-PillRowXaml([string]$prefix, [string]$title, [string]$desc, $options) {
  $pills = ($options | ForEach-Object {
      "<RadioButton x:Name=`"$prefix$($_[0])`" GroupName=`"$prefix`" Style=`"{StaticResource Pill}`" Content=`"$($_[1])`"/>"
    }) -join ''
@"
      <Grid Margin="0,8,0,8">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <StackPanel Margin="0,0,12,0" VerticalAlignment="Center">
          <TextBlock Text="$title" Foreground="$($C.Text)" FontSize="12.5"/>
          <TextBlock Text="$desc" Foreground="$($C.Muted)" FontSize="11" TextWrapping="Wrap" Margin="0,2,0,0"/>
        </StackPanel>
        <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">$pills</StackPanel>
      </Grid>
"@
}
function New-SectionXaml([string]$t) {
  "<TextBlock Text=`"$t`" Foreground=`"$($C.Muted)`" FontSize=`"10`" FontWeight=`"SemiBold`" Margin=`"0,14,0,2`"/>"
}

$OpenOpts = @(@('icon', (T 'OIcon')), @('card', (T 'OCard')), @('last', (T 'OLast')))
$LangOpts = @(@('auto', (T 'LAuto')), @('en', 'English'), @('tr', 'Türkçe'))
$RefreshOpts = @(@('2', "2 $(T 'Sec')"), @('3', "3 $(T 'Sec')"), @('5', "5 $(T 'Sec')"), @('10', "10 $(T 'Sec')"))
$OpacityOpts = @(@('100', '100%'), @('90', '90%'), @('80', '80%'), @('70', '70%'), @('60', '60%'))
$KeepOpts = @(@('15', "15 $(T 'Min')"), @('30', "30 $(T 'Min')"), @('60', "1 $(T 'Hr')"))

function Show-Settings {
  if ($state.SettingsWin) { $state.SettingsWin.Activate() | Out-Null; return }

  $body = (New-SectionXaml (T 'General')) +
    (New-ToggleRowXaml 'OptStartup' (T 'Startup') (T 'StartupD')) +
    (New-ToggleRowXaml 'OptTopmost' (T 'Topmost') (T 'TopmostD')) +
    (New-PillRowXaml 'OptOpen_' (T 'OpenMode') (T 'OpenModeD') $OpenOpts) +
    (New-PillRowXaml 'OptLang_' (T 'Language') (T 'LanguageD') $LangOpts) +
    (New-PillRowXaml 'OptOpacity_' (T 'Opacity') (T 'OpacityD') $OpacityOpts) +
    (New-SectionXaml (T 'Notifications')) +
    (New-ToggleRowXaml 'OptNotify' (T 'Notify') (T 'NotifyD')) +
    (New-ToggleRowXaml 'OptBlink' (T 'Blink') (T 'BlinkD')) +
    (New-SectionXaml (T 'Data')) +
    (New-ToggleRowXaml 'OptCli' (T 'Cli') (T 'CliD')) +
    (New-PillRowXaml 'OptRefresh_' (T 'Refresh') (T 'RefreshD') $RefreshOpts) +
    (New-PillRowXaml 'OptKeep_' (T 'Keep') (T 'KeepD') $KeepOpts)

  [xml]$sx = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Session Widget · $(T 'SettingsTitle')" Width="460" SizeToContent="Height" WindowStyle="None"
        AllowsTransparency="True" Background="Transparent" Topmost="True" ResizeMode="NoResize"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
$SharedStyles
  </Window.Resources>
  <Border CornerRadius="12" Margin="14" Background="$($C.Bg)" BorderBrush="$($C.Line)" BorderThickness="1">
    <Border.Effect><DropShadowEffect BlurRadius="24" ShadowDepth="4" Opacity="0.55"/></Border.Effect>
    <StackPanel>
      <Grid x:Name="SHeader" Margin="18,12,10,10" Background="Transparent">
        <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock Text="&#x273B;" FontFamily="Segoe UI Symbol" FontSize="18" Foreground="$($C.Accent)" VerticalAlignment="Center"/>
        <TextBlock Grid.Column="1" Text="$(T 'SettingsTitle')" Foreground="$($C.Text)" FontSize="14" FontWeight="SemiBold" Margin="10,0,0,0" VerticalAlignment="Center"/>
        <Button x:Name="SClose" Grid.Column="2" Style="{StaticResource IconBtn}" Content="&#xE8BB;" ToolTip="$(T 'Close')"/>
      </Grid>
      <Border Height="1" Background="$($C.Line)"/>
      <StackPanel Margin="18,2,18,10">
$body
      </StackPanel>
      <Border Height="1" Background="$($C.Line)"/>
      <Grid Margin="18,10,12,12">
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
        <TextBlock VerticalAlignment="Center" FontSize="11" Foreground="$($C.Muted)">
          <Run Text="$((T 'Version') -f $AppVersion)"/><Hyperlink x:Name="SLink" Foreground="$($C.Accent)" TextDecorations="{x:Null}">GitHub</Hyperlink>
        </TextBlock>
        <Button x:Name="SQuit" Grid.Column="1" Style="{StaticResource TextBtn}" Content="$(T 'Quit')"/>
      </Grid>
    </StackPanel>
  </Border>
</Window>
"@
  $sw = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $sx))
  $state.SettingsWin = $sw
  $f = { param($n) $sw.FindName($n) }

  # Mevcut değerler
  (& $f 'OptStartup').IsChecked = (Get-Startup)
  (& $f 'OptTopmost').IsChecked = [bool]$settings.Topmost
  (& $f 'OptNotify').IsChecked = [bool]$settings.Notify
  (& $f 'OptBlink').IsChecked = [bool]$settings.Blink
  (& $f 'OptCli').IsChecked = [bool]$settings.ShowCli
  $o = & $f "OptOpen_$($settings.OpenMode)"; if ($o) { $o.IsChecked = $true }
  $langPref = [string]$settings.Language; if ($langPref -ne 'en' -and $langPref -ne 'tr') { $langPref = 'auto' }
  $o = & $f "OptLang_$langPref"; if ($o) { $o.IsChecked = $true }
  $o = & $f "OptRefresh_$($settings.RefreshSec)"; if ($o) { $o.IsChecked = $true }
  $o = & $f "OptKeep_$($settings.KeepMin)"; if ($o) { $o.IsChecked = $true }
  $o = & $f "OptOpacity_$($settings.Opacity)"; if ($o) { $o.IsChecked = $true }

  # Değişiklikler hemen uygulanır ve kaydedilir
  $startup = & $f 'OptStartup'
  $startup.Add_Click({ try { Set-Startup ([bool]$this.IsChecked) } catch { $this.IsChecked = (Get-Startup) } })
  (& $f 'OptTopmost').Add_Click({ Set-Topmost ([bool]$this.IsChecked) })
  (& $f 'OptNotify').Add_Click({ $settings.Notify = [bool]$this.IsChecked; Save-Settings })
  (& $f 'OptBlink').Add_Click({ $settings.Blink = [bool]$this.IsChecked; Save-Settings; Update-Chrome })
  (& $f 'OptCli').Add_Click({
      $settings.ShowCli = [bool]$this.IsChecked; $shared.ShowCli = $settings.ShowCli; $shared.Wake = $true; Save-Settings
    })
  foreach ($opt in $OpenOpts) {
    (& $f "OptOpen_$($opt[0])").Add_Checked({ $settings.OpenMode = $this.Name.Substring(8); Save-Settings })
  }
  foreach ($opt in $LangOpts) {
    (& $f "OptLang_$($opt[0])").Add_Checked({
        $pick = $this.Name.Substring(8)
        if ($pick -eq [string]$settings.Language) { return }
        $settings.Language = $pick; Save-Settings
        if ((Resolve-Language $pick) -ne $Lang) { Restart-Widget }
      })
  }
  foreach ($opt in $RefreshOpts) {
    (& $f "OptRefresh_$($opt[0])").Add_Checked({
        $settings.RefreshSec = [int]$this.Name.Substring(11); $shared.RefreshMs = $settings.RefreshSec * 1000; Save-Settings
      })
  }
  foreach ($opt in $OpacityOpts) {
    (& $f "OptOpacity_$($opt[0])").Add_Checked({
        $settings.Opacity = [int]$this.Name.Substring(11); Save-Settings
        # Seçerken etkisi görünsün diye kısa süre uygulanır
        $win.Opacity = Get-RestOpacity
      })
  }
  foreach ($opt in $KeepOpts) {
    (& $f "OptKeep_$($opt[0])").Add_Checked({ $settings.KeepMin = [int]$this.Name.Substring(8); Save-Settings })
  }

  (& $f 'SHeader').Add_MouseLeftButtonDown({ try { $state.SettingsWin.DragMove() } catch {} })
  (& $f 'SClose').Add_Click({ $state.SettingsWin.Close() })
  (& $f 'SQuit').Add_Click({ $state.SettingsWin.Close(); Exit-Widget })
  (& $f 'SLink').Add_Click({ try { Start-Process $RepoUrl } catch {} })
  $sw.Add_Closed({ $state.SettingsWin = $null })
  $sw.Show()
  [void]$sw.Activate()
}

# ---------------------------------------------------------------- Olaylar
$ui.Bubble.Add_MouseLeftButtonDown({ if (-not (Start-Drag)) { Set-Expanded $true } })
$ui.Header.Add_MouseLeftButtonDown({ [void](Start-Drag) })
$ui.BtnMin.Add_Click({ Set-Expanded $false })
$ui.BtnSettings.Add_Click({ Show-Settings })
$ui.BtnClose.Add_Click({
    $win.Hide()
    $tray.ShowBalloonTip(2500, (T 'AppTitle'), (T 'HiddenBody'), 'Info')
  })
$ui.BtnPin.Add_Click({ Set-Topmost (-not $win.Topmost) })

# -------------------------------- Veri zamanlayıcısı: yeni tarama geldikçe çiz
$dataTimer = New-Object System.Windows.Threading.DispatcherTimer
$dataTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$dataTimer.Add_Tick({
    try {
      # İkinci kez başlatıldıysa: göster ya da ayarları aç
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

      # Yeniden başlayanları ve süresi dolanları bitenlerden çıkar
      $keepMs = [double]$settings.KeepMin * 60000
      for ($k = $state.Finished.Count - 1; $k -ge 0; $k--) {
        $f = $state.Finished[$k]
        if ($cur.ContainsKey($f.Id) -or ($now - $f.At) -gt $keepMs) { $state.Finished.RemoveAt($k) }
      }

      Render-List
      Update-Chrome
    } catch {
      Add-Content -LiteralPath $LogFile -Value "$(Get-Date -f s) tick: $($_.Exception.Message)"
    }
  })
$dataTimer.Start()

# ------------------------------------------------- Yanıp sönme zamanlayıcısı
$blinkTimer = New-Object System.Windows.Threading.DispatcherTimer
$blinkTimer.Interval = [TimeSpan]::FromMilliseconds(550)
$blinkTimer.Add_Tick({
    if ($state.Unseen -gt 0 -and $settings.Blink) {
      $state.BlinkOn = -not $state.BlinkOn
      if ($state.BlinkOn) {
        $ui.BubbleIcon.Foreground = Brush $C.Green
        $ui.Bubble.BorderBrush = Brush $C.Green
        $tray.Icon = $icoDone
      } else {
        $ui.BubbleIcon.Foreground = Brush $C.Dim
        $ui.Bubble.BorderBrush = Brush $C.Line
        $tray.Icon = $icoDim
      }
    }
  })
$blinkTimer.Start()

# ---------------------------------------------------------------- Başlat
Remove-Item -LiteralPath $SignalFile -ErrorAction SilentlyContinue
Set-Expanded $state.Expanded
Render-List
Update-Chrome
$app = New-Object System.Windows.Application
$app.ShutdownMode = 'OnExplicitShutdown'
$win.Show()
if ($OpenSettings) { Show-Settings }
[void]$app.Run()

$shared.Stop = $true
try { $bg.EndInvoke($bgHandle) } catch {}
$rs.Close()
$mutex.ReleaseMutex()
}
catch {
  Add-Content -LiteralPath $LogFile -Value "$(Get-Date -f s) $($_.Exception.Message)`n$($_.ScriptStackTrace)"
  try { [System.Windows.MessageBox]::Show("Claude Session Widget could not start / başlatılamadı:`n$($_.Exception.Message)") | Out-Null } catch {}
}
