#Requires -Version 5.1
<#
  Session scanner: finds running Claude sessions and reads their progress.

  This file contains ONLY function definitions and has no top-level side
  effects. It is dot-sourced by the widget, inside the background scanner
  runspace and by tests.

  Public functions:
    ConvertFrom-TranscriptLines -Lines <string[]>
    Get-ClaudeSession [-IncludeTerminal]
#>

# Sessions whose last activity is older than this are ignored (2 hours).
function Get-StaleThresholdMs { 2 * 60 * 60 * 1000 }

function Get-NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

# Claude Code config directory (honours CLAUDE_CONFIG_DIR).
function Get-ClaudeConfigDir {
  if ($env:CLAUDE_CONFIG_DIR) { return $env:CLAUDE_CONFIG_DIR }
  return (Join-Path $env:USERPROFILE '.claude')
}

# Collapses whitespace and truncates to $MaxLength characters with an ellipsis.
function Get-ShortText([string]$Text, [int]$MaxLength = 80) {
  if (-not $Text) { return '' }
  $t = ($Text -replace '\s+', ' ').Trim()
  if ($t.Length -gt $MaxLength) { return $t.Substring(0, $MaxLength - 1) + [char]0x2026 }
  return $t
}

# Last path segment of a Windows or POSIX path.
function Get-LeafName([string]$Path) {
  if (-not $Path) { return '' }
  return (($Path -split '[\\/]') | Where-Object { $_ })[-1]
}

# Reads the interesting lines of a transcript that lives inside a WSL distro:
# the last plan/todo updates plus the last tool calls.
function Read-WslTranscript([string]$Distro, [string]$Path) {
  $sh = "grep -E 'update_plan|TodoWrite|wrap_up' `"`$1`" | tail -n 60`n" +
        "tail -n 300 `"`$1`" | grep '`"tool_use`"' | tail -n 20`n"
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'wsl.exe'
  $psi.Arguments = "-d `"$Distro`" -e sh -s -- `"$Path`""
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

# Same as Read-WslTranscript for a transcript on the local disk.
function Get-TranscriptTail([string]$Path) {
  $plan = @(Select-String -LiteralPath $Path -Pattern 'update_plan|TodoWrite|wrap_up' -Encoding UTF8 |
    Select-Object -Last 60 | ForEach-Object { $_.Line })
  $tail = @(Get-Content -LiteralPath $Path -Tail 300 -Encoding UTF8 |
    Where-Object { $_.Contains('"tool_use"') } | Select-Object -Last 20)
  return $plan + $tail
}

# Short human-readable description of a tool call, e.g. "Bash · Run unit tests".
function Get-ToolText([string]$Name, $ToolInput) {
  $label = $Name
  if ($Name.StartsWith('mcp__')) { $label = ($Name -split '__')[-1] }
  if ($null -eq $ToolInput) { return $label }
  foreach ($k in 'description', 'file_path', 'pattern', 'query', 'url', 'command', 'prompt') {
    $v = $ToolInput.$k
    if ($v) { return "$label · $(Get-ShortText ([string]$v) 70)" }
  }
  return $label
}

function New-EmptyProgress {
  [pscustomobject]@{ Done = 0; Total = 0; Current = ''; Activity = ''; Steps = @() }
}

<#
  Turns transcript JSONL lines into progress information.
  Returns { Done, Total, Current, Activity, Steps[] { Text, Status } }.
  Status is 'pending' | 'in_progress' | 'completed'.
  Activity is the last tool call, or '@finishing' after a wrap_up call
  (the UI translates it).
#>
function ConvertFrom-TranscriptLines {
  [CmdletBinding()]
  param(
    [Parameter(Position = 0)]
    [AllowNull()][AllowEmptyCollection()][AllowEmptyString()]
    [string[]]$Lines
  )
  $steps = New-Object System.Collections.ArrayList
  $activity = ''
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($l in @($Lines)) {
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
          $cur = -1
          for ($k = 0; $k -lt $steps.Count; $k++) { if ($steps[$k].Status -eq 'in_progress') { $cur = $k; break } }
          if ($cur -ge 0) { $steps[$cur].Status = 'completed' }
          for ($k = $cur + 1; $k -lt $steps.Count; $k++) {
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
  $current = @($steps | Where-Object { $_.Status -eq 'in_progress' } | Select-Object -First 1)
  $currentText = ''
  if ($current.Count) { $currentText = $current[0].Text }
  return [pscustomobject]@{
    Done = $done; Total = $steps.Count; Current = $currentText; Activity = $activity
    Steps = @($steps | ForEach-Object { [pscustomobject]@{ Text = $_.Text; Status = $_.Status } })
  }
}

# Finds <id>.jsonl under <claude dir>\projects, first in the folder derived from cwd.
function Find-LocalTranscript([string]$Root, [string]$Id, [string]$Cwd) {
  $slug = $Cwd -replace '[^a-zA-Z0-9]', '-'
  $direct = Join-Path $Root "projects\$slug\$Id.jsonl"
  if (Test-Path -LiteralPath $direct) { return $direct }
  $hit = Get-ChildItem -Path (Join-Path $Root 'projects') -Filter "$Id.jsonl" -Recurse -Depth 1 -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($hit) { return $hit.FullName }
  return $null
}

# Converts the JSON records of a sessions\ folder (one per running claude process)
# into a table: sessionId -> { Status ('busy' | 'idle'), Since, Entrypoint, Name, Cwd, StartedAt }.
function ConvertTo-SessionStatusTable($Records) {
  $table = @{}
  foreach ($r in @($Records)) {
    if (-not $r -or -not $r.sessionId) { continue }
    $since = [double]$r.statusUpdatedAt; if (-not $since) { $since = [double]$r.startedAt }
    $table[[string]$r.sessionId] = [pscustomobject]@{
      Status = [string]$r.status; Since = $since; Entrypoint = [string]$r.entrypoint
      Name = [string]$r.name; Cwd = [string]$r.cwd; StartedAt = [double]$r.startedAt
    }
  }
  return $table
}

# Status of the claude processes on this machine whose process is still alive.
# A record whose process has exited is ignored (its last status may be a stale 'busy').
function Get-LocalSessionStatus([string]$Root) {
  $records = New-Object System.Collections.ArrayList
  foreach ($f in @(Get-ChildItem -Path (Join-Path $Root 'sessions') -Filter '*.json' -ErrorAction SilentlyContinue)) {
    try { $r = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
    $procId = 0
    if (-not [int]::TryParse([string]$r.pid, [ref]$procId)) { continue }
    try { [void][System.Diagnostics.Process]::GetProcessById($procId) } catch { continue }
    [void]$records.Add($r)
  }
  return (ConvertTo-SessionStatusTable $records)
}

# Same as Get-LocalSessionStatus for the claude processes inside a WSL distro (one wsl.exe call).
function Get-WslSessionStatus([string]$Distro) {
  $sh = 'for f in "$HOME"/.claude/sessions/*.json; do [ -f "$f" ] || continue; ' +
        'p=$(basename "$f" .json); kill -0 "$p" 2>/dev/null && { tr -d "\r\n" < "$f"; echo; }; done' + "`n"
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'wsl.exe'
  $psi.Arguments = "-d `"$Distro`" -e sh -s"
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $records = New-Object System.Collections.ArrayList
  try {
    $p = [System.Diagnostics.Process]::Start($psi)
    $p.StandardInput.Write($sh)
    $p.StandardInput.Close()
    [void]$p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    [void]$p.WaitForExit(15000)
    foreach ($line in ($out -split "`n")) {
      if (-not $line.Trim()) { continue }
      try { [void]$records.Add(($line | ConvertFrom-Json)) } catch {}
    }
  } catch {}
  return (ConvertTo-SessionStatusTable $records)
}

<#
  Returns the Claude sessions that are working right now, oldest first:
  { Id, Name, Cwd, Where, Since, Done, Total, Current, Activity, Steps }
  Where is 'local' | 'terminal' | 'SSH' | 'WSL · <distro>'.
  -IncludeTerminal also lists sessions started with the `claude` CLI.
  Parsed transcripts are cached in $script: scope between calls.
#>
function Get-ClaudeSession {
  [CmdletBinding()]
  param([switch]$IncludeTerminal)

  if ($null -eq $script:ScannerMetaCache) { $script:ScannerMetaCache = @{} }
  if ($null -eq $script:ScannerParseCache) { $script:ScannerParseCache = @{} }
  $metaCache = $script:ScannerMetaCache
  $parseCache = $script:ScannerParseCache

  $staleMs = Get-StaleThresholdMs
  $now = Get-NowMs
  $root = Get-ClaudeConfigDir
  $out = New-Object System.Collections.ArrayList
  $seenCli = New-Object 'System.Collections.Generic.HashSet[string]'

  # Live status of each claude process: on this machine, and per WSL distro (read on demand).
  $localStatus = Get-LocalSessionStatus $root
  $wslStatus = @{}

  # --- Sessions of the Claude desktop app (local, WSL, SSH) ---
  $metaFiles = @(Get-ChildItem -Path "$env:LOCALAPPDATA\Claude-Data\*\claude-code-sessions\*\*\local_*.json" -ErrorAction SilentlyContinue)
  foreach ($f in $metaFiles) {
    $stamp = $f.LastWriteTimeUtc.Ticks
    $cached = $metaCache[$f.FullName]
    if ($cached -and $cached.Stamp -eq $stamp) { $m = $cached.Meta }
    else {
      try { $m = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
      $metaCache[$f.FullName] = @{ Stamp = $stamp; Meta = $m }
    }
    if ($m.isArchived) { continue }
    $cli = [string]$m.cliSessionId
    $distro = ''
    if ($m.wslConfig -and $m.wslConfig.distro) { $distro = [string]$m.wslConfig.distro }

    # Preferred signal: the live claude process reports 'busy' or 'idle'.
    $reg = $null
    if ($cli -and $distro) {
      if (-not $wslStatus.ContainsKey($distro)) { $wslStatus[$distro] = Get-WslSessionStatus $distro }
      $reg = $wslStatus[$distro][$cli]
    }
    elseif ($cli -and -not $m.sshRemoteTranscriptPath) {
      $reg = $localStatus[$cli]
    }

    $act = [double]$m.lastActivityAt
    if ($reg) {
      if ($reg.Status -ne 'busy') { continue }
      $since = $reg.Since
    }
    else {
      # Fallback (SSH, or no live process record): the turn is running if the last
      # user message came after the last turn edge.
      $edge = [double]$m.lastTurnEdgeAt
      $userAt = [double]$m.latestUserFrameAt
      if (-not $userAt -or $userAt -lt $edge) { continue }
      if (-not $act) { $act = $userAt }
      if ($now - $act -gt $staleMs) { continue }
      $since = $userAt
    }
    if ($cli) { [void]$seenCli.Add($cli) }

    $where = 'local'
    if ($m.wslConfig -and $m.wslConfig.distro) { $where = "WSL · $($m.wslConfig.distro)" }
    elseif ($m.sshRemoteTranscriptPath) { $where = 'SSH' }

    $key = "$($f.FullName)|$act"
    $parsed = $parseCache[$key]
    if (-not $parsed) {
      $parsed = New-EmptyProgress
      try {
        if ($m.wslConfig -and $m.wslConfig.distro -and $m.sshRemoteTranscriptPath) {
          $parsed = ConvertFrom-TranscriptLines -Lines (Read-WslTranscript $m.wslConfig.distro $m.sshRemoteTranscriptPath)
        }
        elseif (-not $m.sshRemoteTranscriptPath -and $cli) {
          $p = Find-LocalTranscript $root $cli ([string]$m.cwd)
          if ($p) { $parsed = ConvertFrom-TranscriptLines -Lines (Get-TranscriptTail $p) }
        }
      } catch {}
      foreach ($k in @($parseCache.Keys)) { if ($k.StartsWith("$($f.FullName)|")) { $parseCache.Remove($k) } }
      $parseCache[$key] = $parsed
    }

    $name = [string]$m.title
    if (-not $name) { $name = Get-LeafName ([string]$m.cwd) }
    [void]$out.Add([pscustomobject]@{
      Id = [string]$m.sessionId; Name = $name; Cwd = [string]$m.cwd; Where = $where
      Since = $since; Done = $parsed.Done; Total = $parsed.Total
      Current = $parsed.Current; Activity = $parsed.Activity; Steps = $parsed.Steps
    })
  }

  # --- Sessions started from a terminal (claude CLI) ---
  if ($IncludeTerminal) {
    foreach ($sid in @($localStatus.Keys)) {
      $r = $localStatus[$sid]
      if ($r.Status -ne 'busy' -or $r.Entrypoint -eq 'claude-desktop') { continue }
      if ($seenCli.Contains($sid)) { continue }
      $p = Find-LocalTranscript $root $sid $r.Cwd
      $parsed = New-EmptyProgress
      if ($p) {
        $fi = Get-Item -LiteralPath $p
        $mt = [DateTimeOffset]::new($fi.LastWriteTimeUtc).ToUnixTimeMilliseconds()
        if ($now - $mt -gt $staleMs) { continue }
        $key = "$p|$($fi.LastWriteTimeUtc.Ticks)"
        $parsed = $parseCache[$key]
        if (-not $parsed) {
          try { $parsed = ConvertFrom-TranscriptLines -Lines (Get-TranscriptTail $p) } catch { $parsed = New-EmptyProgress }
          $parseCache[$key] = $parsed
        }
      }
      $name = $r.Name
      if (-not $name) { $name = Get-LeafName $r.Cwd }
      [void]$out.Add([pscustomobject]@{
        Id = $sid; Name = $name; Cwd = $r.Cwd; Where = 'terminal'
        Since = $r.Since; Done = $parsed.Done; Total = $parsed.Total
        Current = $parsed.Current; Activity = $parsed.Activity; Steps = $parsed.Steps
      })
    }
  }

  return @($out | Sort-Object Since)
}
