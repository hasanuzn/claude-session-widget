# Claude Session Widget - one-line install
#   irm https://raw.githubusercontent.com/hasanuzn/claude-session-widget/main/get.ps1 | iex
#
# ASCII only on purpose, so it runs cleanly through "irm | iex".
# Downloads the repository, extracts it to a temp folder and runs install.ps1.

$ErrorActionPreference = 'Stop'
$Repo = 'hasanuzn/claude-session-widget'
$Branch = 'main'

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$tmp = Join-Path $env:TEMP ('claude-session-widget-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  Write-Host "  Downloading github.com/$Repo ($Branch)" -ForegroundColor Cyan
  $zip = Join-Path $tmp 'repo.zip'
  Invoke-WebRequest -Uri "https://github.com/$Repo/archive/refs/heads/$Branch.zip" -OutFile $zip -UseBasicParsing
  Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
  $root = Get-ChildItem -LiteralPath $tmp -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'install.ps1') } |
    Select-Object -First 1 -ExpandProperty FullName
  if (-not $root) { throw 'install.ps1 was not found in the archive.' }
  Get-ChildItem -LiteralPath $root -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
  & "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'install.ps1')
}
finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
