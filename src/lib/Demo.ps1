#Requires -Version 5.1
<#
  Fake data for demo mode (-Demo), used for README screenshots.
  Never reads real sessions. Only function definitions, no side effects.
#>

# Three made-up sessions in the same shape as Get-ClaudeSession returns.
function Get-DemoSession {
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $min = 60 * 1000
  return @(
    [pscustomobject]@{
      Id = 'demo-1'; Name = 'Refactor auth module'; Cwd = 'C:\Projects\acme-web'; Where = 'local'
      Since = $now - 7 * $min; Done = 3; Total = 5
      Current = 'Run the test suite'; Activity = 'Bash · Run unit tests'
      Steps = @(
        [pscustomobject]@{ Text = 'Read the current auth flow'; Status = 'completed' }
        [pscustomobject]@{ Text = 'Extract token helpers'; Status = 'completed' }
        [pscustomobject]@{ Text = 'Update login handler'; Status = 'completed' }
        [pscustomobject]@{ Text = 'Run the test suite'; Status = 'in_progress' }
        [pscustomobject]@{ Text = 'Summarize the changes'; Status = 'pending' }
      )
    }
    [pscustomobject]@{
      Id = 'demo-2'; Name = 'Write API docs'; Cwd = '/home/dev/api-server'; Where = 'WSL · Ubuntu'
      Since = $now - 3 * $min; Done = 1; Total = 4
      Current = 'Document the endpoints'; Activity = 'Read · /home/dev/api-server/routes/users.ts'
      Steps = @(
        [pscustomobject]@{ Text = 'List the public endpoints'; Status = 'completed' }
        [pscustomobject]@{ Text = 'Document the endpoints'; Status = 'in_progress' }
        [pscustomobject]@{ Text = 'Add request examples'; Status = 'pending' }
        [pscustomobject]@{ Text = 'Review for accuracy'; Status = 'pending' }
      )
    }
    [pscustomobject]@{
      Id = 'demo-3'; Name = 'Fix flaky CI job'; Cwd = 'C:\Projects\build-tools'; Where = 'terminal'
      Since = $now - 45 * 1000; Done = 0; Total = 0
      Current = ''; Activity = 'Grep · retry|timeout'; Steps = @()
    }
  )
}

# One entry for the "Finished" list: { Id, Name, At }.
function Get-DemoFinished {
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  return @([pscustomobject]@{ Id = 'demo-done'; Name = 'Update dependencies'; At = $now - 4 * 60 * 1000 })
}
