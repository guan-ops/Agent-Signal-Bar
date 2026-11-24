# Regenerates Integrations/Windows/translations.json from the macOS translation tables
# (AppLocalization.uiText, signalNames and signalSummaries in AppLanguage.swift):
#
#   powershell -ExecutionPolicy Bypass -File Integrations\Windows\tests\extract_translations.ps1
#
# The output maps each language code (zh-Hant, ja, ko, es, fr, de, pt) to {English: translation}.
# Simplified Chinese and English need no table: every string carries both. As on macOS, a string
# missing from a language's table is shown in English.
param(
    [string]$Swift = "$PSScriptRoot\..\..\..\Sources\AgentSignalLight\Support\AppLanguage.swift",
    [string]$Out = "$PSScriptRoot\..\translations.json"
)
$ErrorActionPreference = "Stop"

$languages = [ordered]@{ zhHant = "zh-Hant"; ja = "ja"; ko = "ko"; es = "es"; fr = "fr"; de = "de"; pt = "pt" }
$str = '"((?:[^"\\]|\\.)*)"'
$entry = '^\s*' + $str + ':\s*localized\(zhHant:\s*' + $str + ',\s*ja:\s*' + $str + ',\s*ko:\s*' + $str +
    ',\s*es:\s*' + $str + ',\s*fr:\s*' + $str + ',\s*de:\s*' + $str + ',\s*pt:\s*' + $str + '\)'
$alias = '^\s*' + $str + ':\s*uiText\[' + $str + '\]'

function Unescape([string]$value) { $value.Replace('\"', '"').Replace('\\', '\') }

$byEnglish = [ordered]@{}
$count = 0
foreach ($line in [System.IO.File]::ReadAllLines((Resolve-Path $Swift), [System.Text.Encoding]::UTF8)) {
    $m = [regex]::Match($line, $entry)
    if ($m.Success) {
        $values = @{}
        $i = 2
        foreach ($code in $languages.Values) { $values[$code] = Unescape $m.Groups[$i].Value; $i++ }
        $byEnglish[(Unescape $m.Groups[1].Value)] = $values
        $count++
        continue
    }
    $a = [regex]::Match($line, $alias)
    if ($a.Success) {
        $ref = Unescape $a.Groups[2].Value
        if (-not $byEnglish.Contains($ref)) { throw "alias to unknown entry: $ref" }
        $byEnglish[(Unescape $a.Groups[1].Value)] = $byEnglish[$ref]
        $count++
    }
}
if ($count -lt 200) { throw "only $count entries found; has AppLanguage.swift changed shape?" }

$result = [ordered]@{}
foreach ($code in $languages.Values) {
    $table = [ordered]@{}
    foreach ($english in $byEnglish.Keys) { $table[$english] = $byEnglish[$english][$code] }
    $result[$code] = $table
}
$json = $result | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText((Join-Path (Resolve-Path (Split-Path $Out)) (Split-Path $Out -Leaf)), $json,
    (New-Object System.Text.UTF8Encoding($false)))
Write-Host "$count entries -> $Out"
