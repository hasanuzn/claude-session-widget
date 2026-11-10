#Requires -Version 5.1
<#
  Checks the UI string tables in src/lang/*.psd1.

  Requires Pester 5 or newer (see tests/Scanner.Tests.ps1 for install notes).
  Every language file must load with Import-PowerShellDataFile, define a
  non-empty _Name and have exactly the same keys as en.psd1.
#>

BeforeDiscovery {
  $langDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\lang'
  $LangCases = @(Get-ChildItem -Path $langDir -Filter '*.psd1' -File -ErrorAction SilentlyContinue |
    Sort-Object Name |
    ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
  $OtherLangCases = @($LangCases | Where-Object { $_.Name -ne 'en.psd1' })
}

BeforeAll {
  $script:LangDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\lang'
  $script:EnPath = Join-Path $script:LangDir 'en.psd1'
}

Describe 'Language files' {
  It 'en.psd1 exists (reference language)' {
    Test-Path -LiteralPath $script:EnPath | Should -Be $true
  }

  It '<Name> loads with Import-PowerShellDataFile' -ForEach $LangCases {
    { Import-PowerShellDataFile -Path $Path } | Should -Not -Throw
    $data = Import-PowerShellDataFile -Path $Path
    $data | Should -BeOfType [hashtable]
    $data.Count | Should -BeGreaterThan 1
  }

  It '<Name> has a non-empty _Name' -ForEach $LangCases {
    $data = Import-PowerShellDataFile -Path $Path
    $data.ContainsKey('_Name') | Should -Be $true
    [string]::IsNullOrWhiteSpace([string]$data['_Name']) | Should -Be $false
  }

  It '<Name> has exactly the same keys as en.psd1' -ForEach $OtherLangCases {
    $en = Import-PowerShellDataFile -Path $script:EnPath
    $data = Import-PowerShellDataFile -Path $Path
    $missing = @($en.Keys | Where-Object { -not $data.ContainsKey($_) } | Sort-Object)
    $extra = @($data.Keys | Where-Object { -not $en.ContainsKey($_) } | Sort-Object)
    ($missing -join ', ') | Should -Be '' -Because "these keys from en.psd1 are missing in $Name"
    ($extra -join ', ') | Should -Be '' -Because "these keys in $Name do not exist in en.psd1"
  }
}
