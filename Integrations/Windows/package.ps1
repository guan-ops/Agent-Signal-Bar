# Builds the Windows release (the counterpart of script/package_release.sh):
#   AgentSignalBar-<tag>-windows-x64-setup.exe   Inno Setup installer, per user, no admin rights
#   AgentSignalBar-<tag>-windows-x64.zip         the same app folder, portable
#   AgentSignalBar-windows-x64-appcast.xml       Sparkle appcast read by the in-app updater
#   AgentSignalBar-windows-SHA256SUMS.txt
#
#   powershell -ExecutionPolicy Bypass -File Integrations\Windows\package.ps1 -QtDir C:\Qt\6.8.3\msvc2022_64
#
# Run from an "x64 Native Tools Command Prompt for VS 2022" (as build.ps1), with Inno Setup 6.7.
# Inputs:
#   VERSION (repository root)   VERSION and BUILD, unless -Version / -Build are given.
#   SPARKLE_PRIVATE_KEY         or -EdKeyFile: the Sparkle EdDSA key (generate_keys -x) that signs the
#                               installer for the appcast. Required in CI; without it there is no appcast.
#   WINDOWS_CERTIFICATE_PFX     base64 .pfx (+ WINDOWS_CERTIFICATE_PASSWORD), or -CertificateThumbprint
#                               for a certificate in the user store: Authenticode-signs AgentSignalBar.exe,
#                               agent-signal.exe, the installer and its uninstaller. Optional; unsigned
#                               builds work but Windows SmartScreen warns about them.
param(
    [Parameter(Mandatory = $true)][string]$QtDir,
    [string]$OutDir = (Join-Path $PSScriptRoot "..\..\dist"),
    [string]$Version,
    [string]$Build,
    [string]$Tag,
    [string]$EdKeyFile,
    [string]$CertificateThumbprint,
    [string]$TimestampUrl = "http://timestamp.digicert.com",
    # SUFeedURL and SUPublicEDKey: the macOS release's public key, so one SPARKLE_PRIVATE_KEY signs both.
    [string]$UpdateFeed = "https://github.com/guan-ops/Agent-Signal-Bar/releases/latest/download/AgentSignalBar-windows-x64-appcast.xml",
    [string]$UpdatePublicKey = "lEr2AUplk4vAvH+IwB4DygGqobWmBkbyy1YYr1nRy70=",
    [string]$DownloadUrlPrefix,
    [switch]$SkipTests
)
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path

$values = @{}
Get-Content (Join-Path $root "VERSION") | ForEach-Object {
    if ($_ -match '^\s*([A-Z]+)\s*=\s*(\S+)\s*$') { $values[$Matches[1]] = $Matches[2] }
}
if (-not $Version) { $Version = $values["VERSION"] }
if (-not $Build) { $Build = $values["BUILD"] }
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid version: $Version" }
if ($Build -notmatch '^\d+$' -or $Build -eq "0") { throw "Invalid build number: $Build" }
if (-not $Tag) { $Tag = if ($env:GITHUB_REF_NAME -match '^v\d+\.\d+\.\d+$') { $env:GITHUB_REF_NAME } else { "v$Version" } }
if (-not $DownloadUrlPrefix) { $DownloadUrlPrefix = "https://github.com/guan-ops/Agent-Signal-Bar/releases/download/$Tag/" }

$base = "AgentSignalBar-$Tag-windows-x64"
$OutDir = [IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force $OutDir | Out-Null
# A clean work folder: nmake does not rebuild when only a define (the build number) changes.
$work = Join-Path $env:TEMP "asb-windows-release"
if (Test-Path $work) { Remove-Item -Recurse -Force $work }
New-Item -ItemType Directory -Force $work | Out-Null
$stage = Join-Path $work "AgentSignalBar"
$make = if (Get-Command jom -ErrorAction SilentlyContinue) { "jom" } else { "nmake" }

# 1. The app folder, tests included, built as a release with the updater configured.
$buildArgs = @{
    QtDir = $QtDir; BuildDir = (Join-Path $work "build"); InstallDir = $stage
    Version = $Version; Build = $Build; UpdateFeed = $UpdateFeed; UpdatePublicKey = $UpdatePublicKey
}
if ($SkipTests) { $buildArgs.SkipTests = $true }
& (Join-Path $PSScriptRoot "build.ps1") @buildArgs
$env:PATH = "$(Join-Path $QtDir 'bin');$env:PATH"

# 2. sign_update (Sparkle's tool of that name, for the Windows appcast).
$toolDir = Join-Path $work "sign_update"
New-Item -ItemType Directory -Force $toolDir | Out-Null
Push-Location $toolDir
& (Join-Path $QtDir "bin\qmake.exe") (Join-Path $PSScriptRoot "tools\sign_update\sign_update.pro") "CONFIG+=release" | Out-Host
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "qmake failed: sign_update" }
& $make | Out-Host
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "build failed: sign_update" }
Pop-Location
$signUpdate = Join-Path $toolDir "release\sign_update.exe"

# 3. Authenticode signing, when a certificate is available.
$signArgs = $null
$pfx = $null
if ($CertificateThumbprint) {
    $signArgs = @("/sha1", $CertificateThumbprint)
} elseif ($env:WINDOWS_CERTIFICATE_PFX) {
    $pfx = Join-Path $work "certificate.pfx"
    [IO.File]::WriteAllBytes($pfx, [Convert]::FromBase64String($env:WINDOWS_CERTIFICATE_PFX))
    $signArgs = @("/f", $pfx)
    if ($env:WINDOWS_CERTIFICATE_PASSWORD) { $signArgs += @("/p", $env:WINDOWS_CERTIFICATE_PASSWORD) }
}
$signtool = $null
if ($signArgs) {
    $found = Get-Command signtool -ErrorAction SilentlyContinue
    $signtool = if ($found) { $found.Source } else {
        Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\*\x64\signtool.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $signtool) { throw "signtool.exe not found (Windows SDK)" }
}
function Set-Signature([string]$Path) {
    & $signtool sign /fd sha256 /tr $TimestampUrl /td sha256 @signArgs $Path | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "signtool failed: $Path" }
}
try {
    if ($signArgs) {
        Set-Signature (Join-Path $stage "AgentSignalBar.exe")
        Set-Signature (Join-Path $stage "agent-signal.exe")
    } else {
        Write-Warning "No code-signing certificate: the executables and the installer are unsigned (SmartScreen warns)."
    }

    # 4. The installer.
    $iscc = @((Get-Command ISCC -ErrorAction SilentlyContinue | ForEach-Object Source)) + (
        @("7", "6") | ForEach-Object {
            "${env:ProgramFiles(x86)}\Inno Setup $_\ISCC.exe", "$env:ProgramFiles\Inno Setup $_\ISCC.exe",
            "$env:LOCALAPPDATA\Programs\Inno Setup $_\ISCC.exe" }) |
        Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $iscc) { throw "Inno Setup (ISCC.exe) not found; install it with: winget install JRSoftware.InnoSetup" }
    $isccArgs = @("/Q", "/DAppVersion=$Version", "/DAppBuild=$Build", "/DSourceDir=$stage", "/DOutputDir=$OutDir",
                  "/DOutputName=$base-setup")
    if ($signArgs) {
        # ISCC signs the uninstaller and the setup with this command; $f is the quoted file name.
        $quoted = ($signArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
        $isccArgs += @("/DSignToolName=asbsign", "/Sasbsign=`"$signtool`" sign /fd sha256 /tr $TimestampUrl /td sha256 $quoted `$f")
    }
    & $iscc @isccArgs (Join-Path $PSScriptRoot "installer\AgentSignalBar.iss") | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed" }
} finally {
    if ($pfx -and (Test-Path $pfx)) { Remove-Item -Force $pfx }
}
$setup = Join-Path $OutDir "$base-setup.exe"

# 5. The portable zip (an AgentSignalBar folder).
$zip = Join-Path $OutDir "$base.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }
Compress-Archive -Path $stage -DestinationPath $zip

# 6. The appcast, signed like macOS's generate_appcast does it (EdDSA over the whole installer).
$appcast = Join-Path $OutDir "AgentSignalBar-windows-x64-appcast.xml"
if (Test-Path $appcast) { Remove-Item -Force $appcast }
if ($EdKeyFile -or $env:SPARKLE_PRIVATE_KEY) {
    # The CI secret goes through stdin, never to a file.
    $signed = if ($EdKeyFile) { & $signUpdate $setup --ed-key-file $EdKeyFile --expect-public-key $UpdatePublicKey }
              else { $env:SPARKLE_PRIVATE_KEY | & $signUpdate $setup --ed-key-file - --expect-public-key $UpdatePublicKey }
    if ($LASTEXITCODE -ne 0) { throw "sign_update failed (does the key belong to $UpdatePublicKey?)" }
    if ("$signed" -notmatch 'sparkle:edSignature="([^"]+)" length="(\d+)"') { throw "Unexpected sign_update output: $signed" }
    $signature = $Matches[1]
    $length = $Matches[2]
    & $signUpdate --verify $setup $signature --public-key-value $UpdatePublicKey | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "The installer's signature does not verify against $UpdatePublicKey" }

    $notesFile = @((Join-Path $root "docs\releases\$Tag.md"), (Join-Path $root "docs\releases\v$Version.md")) |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    $description = ""
    if ($notesFile) {
        $notes = (Get-Content -Raw -Encoding UTF8 $notesFile) -replace '\]\]>', ']]]]><![CDATA[>'
        $description = "      <description sparkle:format=`"markdown`"><![CDATA[$notes]]></description>`n"
    }
    $pubDate = [DateTime]::UtcNow.ToString("ddd, dd MMM yyyy HH:mm:ss '+0000'", [Globalization.CultureInfo]::InvariantCulture)
    $xml = @"
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <title>Agent Signal Bar for Windows</title>
    <item>
      <title>$Version</title>
      <pubDate>$pubDate</pubDate>
      <sparkle:version>$Build</sparkle:version>
      <sparkle:shortVersionString>$Version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>10.0.17763</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/guan-ops/Agent-Signal-Bar/releases/tag/$Tag</sparkle:fullReleaseNotesLink>
$description      <enclosure url="$DownloadUrlPrefix$base-setup.exe" length="$length" type="application/octet-stream" sparkle:os="windows" sparkle:edSignature="$signature"/>
    </item>
  </channel>
</rss>
"@
    [IO.File]::WriteAllText($appcast, $xml.Replace("`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
} elseif ($env:CI -or $env:GITHUB_ACTIONS) {
    throw "SPARKLE_PRIVATE_KEY is required in CI to sign the Windows appcast."
} else {
    Write-Warning "No EdDSA key (SPARKLE_PRIVATE_KEY or -EdKeyFile): no appcast, so the in-app updater cannot offer this build."
}

# 7. Checksums of what was produced here.
$sums = Join-Path $OutDir "AgentSignalBar-windows-SHA256SUMS.txt"
@($setup, $zip, $appcast) | Where-Object { Test-Path $_ } | ForEach-Object {
    "{0}  {1}" -f (Get-FileHash $_ -Algorithm SHA256).Hash.ToLower(), (Split-Path $_ -Leaf)
} | Set-Content -Encoding ascii $sums

Write-Host ""
Write-Host "Installer: $setup"
Write-Host "Portable:  $zip"
if (Test-Path $appcast) { Write-Host "Appcast:   $appcast" }
Write-Host "Checksums: $sums"
