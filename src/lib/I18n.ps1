#Requires -Version 5.1
<#
  Translations. Each language is a file src\lang\<code>.psd1 holding a
  hashtable of UI strings; its _Name key is the language's own name
  (e.g. 'Türkçe'). Adding a language = dropping a new .psd1 file there.

  Import-Strings loads English plus the chosen language into $script:Strings
  and sets $script:Lang; T looks a key up (chosen language -> English -> key).
#>

function Get-LangDirectory { Join-Path (Split-Path -Parent $PSScriptRoot) 'lang' }

# Returns the available languages as { Code, Name }, sorted by code.
function Get-AvailableLanguage {
  [CmdletBinding()]
  param([string]$Path = (Get-LangDirectory))
  foreach ($f in @(Get-ChildItem -LiteralPath $Path -Filter '*.psd1' -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $code = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    $name = $code
    try {
      $data = Import-PowerShellDataFile -LiteralPath $f.FullName
      if ($data._Name) { $name = [string]$data._Name }
    } catch { continue }
    [pscustomobject]@{ Code = $code; Name = $name }
  }
}

<#
  Turns a language preference ('auto' or a code such as 'tr') into the code
  of an existing language file. 'auto' or an unknown code follows the Windows
  display language when a matching file exists, else English.
#>
function Resolve-Language {
  [CmdletBinding()]
  param([string]$Preference = 'auto', [string]$Path = (Get-LangDirectory))
  $has = { param($c) $c -and (Test-Path -LiteralPath (Join-Path $Path "$c.psd1")) }
  if ($Preference -and $Preference -ne 'auto' -and (& $has $Preference)) { return $Preference }
  $ui = [Globalization.CultureInfo]::CurrentUICulture
  foreach ($c in $ui.Name, $ui.TwoLetterISOLanguageName) { if (& $has $c) { return $c } }
  return 'en'
}

# Loads English and $Language into $script:Strings and sets $script:Lang.
function Import-Strings {
  [CmdletBinding()]
  param([string]$Language = 'en', [string]$Path = (Get-LangDirectory))
  $table = @{}
  foreach ($code in @('en', $Language) | Select-Object -Unique) {
    $file = Join-Path $Path "$code.psd1"
    if (Test-Path -LiteralPath $file) {
      try { $table[$code] = Import-PowerShellDataFile -LiteralPath $file } catch { $table[$code] = @{} }
    } else { $table[$code] = @{} }
  }
  $script:Strings = $table
  $script:Lang = $Language
}

# Translated text for $Key: current language, then English, then the key itself.
function T([string]$Key) {
  $v = $null
  if ($script:Strings) {
    $cur = $script:Strings[[string]$script:Lang]
    if ($cur) { $v = $cur[$Key] }
    if ($null -eq $v -and $script:Strings['en']) { $v = $script:Strings['en'][$Key] }
  }
  if ($null -eq $v) { return $Key }
  return [string]$v
}
