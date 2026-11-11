#Requires -Version 5.1
<#
  Tests for src/lib/Scanner.ps1 (transcript parsing and session discovery).

  Requires Pester 5 or newer (uses BeforeAll/BeforeDiscovery scoping and the
  "Should -Be" syntax). Windows PowerShell 5.1 ships with Pester 3.4, which
  cannot run these tests. Install Pester 5 once:

    Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force -SkipPublisherCheck

  Then run everything with:  powershell -File tools\Invoke-Tests.ps1
  or just this file with:    Invoke-Pester -Path tests\Scanner.Tests.ps1 -Output Detailed
#>

BeforeAll {
  $script:RepoRoot = Split-Path -Parent $PSScriptRoot
  $script:FixtureDir = Join-Path $PSScriptRoot 'fixtures'
  . (Join-Path $script:RepoRoot 'src\lib\Scanner.ps1')

  # U+00B7 middle dot and U+2026 ellipsis, written as code points so this
  # file stays ASCII-safe.
  $script:Dot = [string][char]0x00B7
  $script:Ellipsis = [string][char]0x2026

  function Read-Fixture([string]$Name) {
    $path = Join-Path $script:FixtureDir $Name
    return [string[]]@(Get-Content -LiteralPath $path -Encoding UTF8)
  }

  function ConvertFrom-Fixture([string]$Name) {
    return ConvertFrom-TranscriptLines -Lines (Read-Fixture $Name)
  }

  # Builds one assistant transcript line holding a single tool_use block.
  function New-ToolLine([string]$Name, [hashtable]$ToolInput, [string]$Uuid = ([guid]::NewGuid().ToString())) {
    $record = [ordered]@{
      type    = 'assistant'
      uuid    = $Uuid
      message = [ordered]@{
        role    = 'assistant'
        content = @([ordered]@{ type = 'tool_use'; id = "toolu_$Uuid"; name = $Name; input = $ToolInput })
      }
    }
    return ($record | ConvertTo-Json -Depth 10 -Compress)
  }

  function Get-Statuses($Result) { return (@($Result.Steps | ForEach-Object { $_.Status }) -join ',') }
}

Describe 'ConvertFrom-TranscriptLines' {

  Context 'update_plan items' {
    It 'replaces the whole step list with the latest items' {
      $r = ConvertFrom-Fixture 'plan-items.jsonl'
      $r.Total | Should -Be 4
      $r.Done | Should -Be 1
      $r.Current | Should -Be 'Write Pester tests'
      @($r.Steps).Count | Should -Be 4
      $r.Steps[0].Text | Should -Be 'Look at the repo'
      $r.Steps[3].Text | Should -Be 'Package a release'
    }

    It 'defaults a missing status to pending' {
      $r = ConvertFrom-Fixture 'plan-items.jsonl'
      $r.Steps[3].Status | Should -Be 'pending'
      Get-Statuses $r | Should -Be 'completed,in_progress,pending,pending'
    }

    It 'does not let tool_result lines from the user affect the plan' {
      $lines = Read-Fixture 'plan-items.jsonl'
      $r = ConvertFrom-TranscriptLines -Lines $lines[0..2]
      $r.Total | Should -Be 3
      $r.Current | Should -Be 'Look at the repo'
    }
  }

  Context 'update_plan advance' {
    It 'completes the in_progress step and starts the next pending one, once per call' {
      $r = ConvertFrom-Fixture 'plan-advance.jsonl'
      Get-Statuses $r | Should -Be 'completed,completed,in_progress'
      $r.Done | Should -Be 2
      $r.Total | Should -Be 3
      $r.Current | Should -Be 'Write tests'
    }

    It 'completes the last step when there is nothing pending after it' {
      $lines = @(Read-Fixture 'plan-advance.jsonl') + (New-ToolLine 'mcp__ccd_turn__update_plan' @{ advance = $true })
      $r = ConvertFrom-TranscriptLines -Lines $lines
      Get-Statuses $r | Should -Be 'completed,completed,completed'
      $r.Done | Should -Be 3
      $r.Current | Should -Be ''
    }

    It 'starts the first pending step when nothing is in progress' {
      $lines = @(
        (New-ToolLine 'mcp__ccd_turn__update_plan' @{ items = @(@{ content = 'A'; status = 'pending' }, @{ content = 'B'; status = 'pending' }) })
        (New-ToolLine 'mcp__ccd_turn__update_plan' @{ advance = $true })
      )
      $r = ConvertFrom-TranscriptLines -Lines $lines
      Get-Statuses $r | Should -Be 'in_progress,pending'
      $r.Current | Should -Be 'A'
    }
  }

  Context 'update_plan done / start' {
    It 'marks 1-based done indexes completed and start index in_progress' {
      $r = ConvertFrom-Fixture 'plan-done-start.jsonl'
      Get-Statuses $r | Should -Be 'completed,completed,in_progress,pending'
      $r.Done | Should -Be 2
      $r.Total | Should -Be 4
      $r.Current | Should -Be 'Fix it'
    }

    It 'ignores out-of-range done and start indexes' {
      $lines = @(
        (New-ToolLine 'mcp__ccd_turn__update_plan' @{ items = @(@{ content = 'A'; status = 'pending' }) })
        (New-ToolLine 'mcp__ccd_turn__update_plan' @{ done = @(0, 2, 7); start = 5 })
      )
      $r = ConvertFrom-TranscriptLines -Lines $lines
      Get-Statuses $r | Should -Be 'pending'
      $r.Done | Should -Be 0
    }
  }

  Context 'TodoWrite' {
    It 'replaces the list and shows activeForm for the in_progress item' {
      $r = ConvertFrom-Fixture 'todowrite.jsonl'
      $r.Total | Should -Be 3
      $r.Done | Should -Be 1
      $r.Current | Should -Be 'Fixing type errors'
      $r.Steps[0].Text | Should -Be 'Run the linter'
      $r.Steps[1].Text | Should -Be 'Fixing type errors'
      $r.Steps[2].Text | Should -Be 'Write changelog'
      Get-Statuses $r | Should -Be 'completed,in_progress,pending'
    }
  }

  Context 'wrap_up' {
    It 'marks every step completed and sets Activity to @finishing' {
      $r = ConvertFrom-Fixture 'wrap-up.jsonl'
      $r.Done | Should -Be 3
      $r.Total | Should -Be 3
      Get-Statuses $r | Should -Be 'completed,completed,completed'
      $r.Current | Should -Be ''
      $r.Activity | Should -Be '@finishing'
    }
  }

  Context 'Activity label' {
    It 'uses the last tool call, preferring description over command (Bash)' {
      $r = ConvertFrom-Fixture 'activity.jsonl'
      $r.Activity | Should -Be "Bash $script:Dot Run Pester tests"
      $r.Total | Should -Be 0
    }

    It 'falls back to command when there is no description' {
      $r = ConvertFrom-TranscriptLines -Lines @(New-ToolLine 'Bash' @{ command = 'git status' })
      $r.Activity | Should -Be "Bash $script:Dot git status"
    }

    It 'uses the part after the last __ for mcp__ tools' {
      $r = ConvertFrom-TranscriptLines -Lines @(New-ToolLine 'mcp__claude-in-chrome__navigate' @{ url = 'https://example.com/docs' })
      $r.Activity | Should -Be "navigate $script:Dot https://example.com/docs"
    }

    It 'uses file_path for Read' {
      $r = ConvertFrom-TranscriptLines -Lines @(New-ToolLine 'Read' @{ file_path = 'C:\repo\README.md' })
      $r.Activity | Should -Be "Read $script:Dot C:\repo\README.md"
    }

    It 'shows only the label when no known input key is present' {
      $r = ConvertFrom-TranscriptLines -Lines @(New-ToolLine 'mcp__sqlcl__sql_run' @{ sql = 'select 1 from dual' })
      $r.Activity | Should -Be 'sql_run'
    }

    It 'collapses whitespace and truncates the detail to 70 characters' {
      $long = "echo   one`n" + ('x' * 100)
      $r = ConvertFrom-TranscriptLines -Lines @(New-ToolLine 'Bash' @{ command = $long })
      $prefix = "Bash $script:Dot "
      $r.Activity.StartsWith($prefix) | Should -Be $true
      $detail = $r.Activity.Substring($prefix.Length)
      $detail.Length | Should -Be 70
      $detail.StartsWith('echo one x') | Should -Be $true
      $detail.EndsWith($script:Ellipsis) | Should -Be $true
    }

    It 'does not change the plan for ordinary tools' {
      $lines = @(Read-Fixture 'plan-items.jsonl') + (New-ToolLine 'Bash' @{ command = 'dir' })
      $r = ConvertFrom-TranscriptLines -Lines $lines
      $r.Total | Should -Be 4
      $r.Current | Should -Be 'Write Pester tests'
      $r.Activity | Should -Be "Bash $script:Dot dir"
    }
  }

  Context 'Duplicate lines' {
    It 'applies an identical line only once' {
      $r = ConvertFrom-Fixture 'duplicates.jsonl'
      Get-Statuses $r | Should -Be 'completed,in_progress,pending'
      $r.Done | Should -Be 1
      $r.Current | Should -Be 'Second'
    }

    It 'treats lines differing only by a trailing CR as duplicates' {
      $lines = Read-Fixture 'duplicates.jsonl'
      $r = ConvertFrom-TranscriptLines -Lines @($lines[0], $lines[1], ($lines[1] + "`r"))
      $r.Done | Should -Be 1
    }
  }

  Context 'Malformed input' {
    It 'skips malformed JSON and non-assistant records without throwing' {
      { ConvertFrom-Fixture 'malformed.jsonl' } | Should -Not -Throw
      $r = ConvertFrom-Fixture 'malformed.jsonl'
      Get-Statuses $r | Should -Be 'completed,in_progress'
      $r.Current | Should -Be 'Report'
      $r.Activity | Should -Be ''
    }
  }

  Context 'Empty input' {
    It 'returns an empty result for an empty array' {
      $r = ConvertFrom-TranscriptLines -Lines @()
      $r.Done | Should -Be 0
      $r.Total | Should -Be 0
      $r.Current | Should -Be ''
      $r.Activity | Should -Be ''
      @($r.Steps).Count | Should -Be 0
    }

    It 'returns an empty result for blank lines' {
      $r = ConvertFrom-TranscriptLines -Lines @('', '   ', "`r")
      $r.Total | Should -Be 0
      $r.Activity | Should -Be ''
    }
  }
}

Describe 'Get-ClaudeSession' {
  BeforeAll {
    $script:SavedEnv = @{
      LOCALAPPDATA      = $env:LOCALAPPDATA
      USERPROFILE       = $env:USERPROFILE
      CLAUDE_CONFIG_DIR = $env:CLAUDE_CONFIG_DIR
    }
    $script:Sandbox = Join-Path $TestDrive 'sandbox'
    $script:ClaudeDir = Join-Path $script:Sandbox '.claude'
    New-Item -ItemType Directory -Path (Join-Path $script:Sandbox 'AppData\Local') -Force | Out-Null
    New-Item -ItemType Directory -Path $script:ClaudeDir -Force | Out-Null
    $env:LOCALAPPDATA = Join-Path $script:Sandbox 'AppData\Local'
    $env:USERPROFILE = $script:Sandbox
    $env:CLAUDE_CONFIG_DIR = $script:ClaudeDir
  }

  AfterAll {
    foreach ($k in $script:SavedEnv.Keys) {
      $v = $script:SavedEnv[$k]
      if ($null -eq $v) { Remove-Item -LiteralPath "Env:\$k" -ErrorAction SilentlyContinue }
      else { Set-Item -LiteralPath "Env:\$k" -Value $v }
    }
  }

  It 'returns nothing when there are no Claude sessions' {
    @(Get-ClaudeSession -IncludeTerminal).Count | Should -Be 0
  }

  Context 'with a busy terminal (CLI) session' {
    BeforeAll {
      $id = '7b1c2d3e-4f5a-4b6c-8d7e-9f0a1b2c3d4e'
      $cwd = 'C:\work\demo-project'
      $slug = $cwd -replace '[^a-zA-Z0-9]', '-'
      $projDir = Join-Path $script:ClaudeDir "projects\$slug"
      $regDir = Join-Path $script:ClaudeDir 'sessions'
      New-Item -ItemType Directory -Path $projDir, $regDir -Force | Out-Null
      Copy-Item -LiteralPath (Join-Path $script:FixtureDir 'plan-done-start.jsonl') -Destination (Join-Path $projDir "$id.jsonl")
      # A copy keeps the fixture's old timestamp; make it fresh or the session counts as stale.
      (Get-Item -LiteralPath (Join-Path $projDir "$id.jsonl")).LastWriteTime = Get-Date
      $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      # The record's process must be alive, so use the test runner's own PID.
      $reg = [ordered]@{
        pid = $PID; sessionId = $id; cwd = $cwd; name = 'Demo session'; status = 'busy'
        entrypoint = 'cli'; startedAt = $now - 60000; statusUpdatedAt = $now - 1000
      }
      [System.IO.File]::WriteAllText((Join-Path $regDir "$PID.json"), ($reg | ConvertTo-Json -Compress))

      # A 'busy' record left behind by a process that has exited must be ignored.
      $deadId = '0d0d0d0d-1111-4222-8333-944444444444'
      Copy-Item -LiteralPath (Join-Path $script:FixtureDir 'plan-done-start.jsonl') -Destination (Join-Path $projDir "$deadId.jsonl")
      $dead = [ordered]@{
        pid = 999999; sessionId = $deadId; cwd = $cwd; name = 'Crashed session'; status = 'busy'
        entrypoint = 'cli'; startedAt = $now - 60000; statusUpdatedAt = $now - 1000
      }
      [System.IO.File]::WriteAllText((Join-Path $regDir '999999.json'), ($dead | ConvertTo-Json -Compress))
    }

    It 'ignores a busy record whose process has exited' {
      @(Get-ClaudeSession -IncludeTerminal | Where-Object { $_.Name -eq 'Crashed session' }).Count | Should -Be 0
    }

    It 'lists it with -IncludeTerminal and parses its transcript' {
      $s = @(Get-ClaudeSession -IncludeTerminal)
      $s.Count | Should -Be 1
      $s[0].Id | Should -Be '7b1c2d3e-4f5a-4b6c-8d7e-9f0a1b2c3d4e'
      $s[0].Name | Should -Be 'Demo session'
      $s[0].Where | Should -Be 'terminal'
      $s[0].Done | Should -Be 2
      $s[0].Total | Should -Be 4
      $s[0].Current | Should -Be 'Fix it'
    }

    It 'hides it without -IncludeTerminal' {
      @(Get-ClaudeSession).Count | Should -Be 0
    }
  }
}
