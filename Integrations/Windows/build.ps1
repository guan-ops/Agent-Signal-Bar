# Builds Agent Signal Bar for Windows, runs the tests and installs a self-contained folder
# (AgentSignalBar.exe, agent-signal.exe for Claude Code hooks, Qt runtime via windeployqt,
# MSVC runtime DLLs) that also runs on PCs without the Visual C++ Redistributable.
#
#   powershell -ExecutionPolicy Bypass -File Integrations\Windows\build.ps1 -QtDir C:\Qt\6.8.3\msvc2022_64
#
# Run from a "x64 Native Tools Command Prompt for VS 2022" (or after vcvars64.bat) so
# cl.exe and nmake are on PATH. Qt 6.8 or newer is required (Popup.Window popups).
# Clone the repository to an ASCII-only path: rcc cannot open .qrc files under
# non-ASCII folders, and the tests embed their golden-file paths at compile time.
#
# The install folder must be permanent: Claude Code hooks point at agent-signal.exe there.
# Quit Agent Signal Bar before rebuilding, or the old files cannot be replaced.
param(
    [Parameter(Mandatory = $true)][string]$QtDir,
    [string]$BuildDir = "$env:TEMP\asb-windows-build",
    [string]$InstallDir = "$env:LOCALAPPDATA\Programs\AgentSignalBar",
    [string]$Version = "0.1.0",
    # Release builds (package.ps1): the build number compared with the appcast (sparkle:version), and
    # the appcast URL and EdDSA public key. Without a feed and key the in-app updater is off.
    [string]$Build = "0",
    [string]$UpdateFeed = "",
    [string]$UpdatePublicKey = "",
    [switch]$SkipTests
)
$ErrorActionPreference = "Stop"
$Source = $PSScriptRoot
$qmake = Join-Path $QtDir "bin\qmake.exe"
$deploy = Join-Path $QtDir "bin\windeployqt.exe"
if (-not (Test-Path $qmake)) { throw "qmake not found: $qmake" }
$make = if (Get-Command jom -ErrorAction SilentlyContinue) { "jom" } else { "nmake" }
$env:ASB_WINDOWS_VERSION = $Version
$env:ASB_WINDOWS_BUILD = $Build
$env:ASB_WINDOWS_UPDATE_FEED = $UpdateFeed
$env:ASB_WINDOWS_UPDATE_PUBLIC_KEY = $UpdatePublicKey
$env:PATH = "$(Join-Path $QtDir 'bin');$env:PATH"

# Native tool output goes to the host: a PowerShell function returns everything written to
# its output stream, which would otherwise end up in the returned folder path.
function Build-Project([string]$Name, [string]$ProFile) {
    $dir = Join-Path $BuildDir $Name
    New-Item -ItemType Directory -Force $dir | Out-Null
    Push-Location $dir
    & $qmake (Join-Path $Source $ProFile) "CONFIG+=release" | Out-Host
    if ($LASTEXITCODE -ne 0) { Pop-Location; throw "qmake failed: $ProFile" }
    & $make | Out-Host
    if ($LASTEXITCODE -ne 0) { Pop-Location; throw "build failed: $ProFile" }
    Pop-Location
    return $dir
}

# QtTest writes nothing to a redirected stdout on Windows, so a logged build would only say
# "tests failed". Log to a file instead and show everything but the PASS lines.
function Run-Tests([string]$Dir, [string]$Exe, [string]$What) {
    $results = Join-Path $Dir "results.txt"
    & (Join-Path $Dir "release\$Exe") -o "$results,txt"
    $code = $LASTEXITCODE
    if (Test-Path $results) { Get-Content $results -Encoding UTF8 | Where-Object { $_ -notmatch '^PASS ' } | Out-Host }
    if ($code -ne 0) { throw "$What failed" }
}

# Refuse before deleting anything: a running copy, or a folder that is not an install.
# Only a copy running from the install folder matters (package.ps1 stages to another folder).
$installFull = [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\') + '\'
if (Get-Process -Name "AgentSignalBar" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($installFull, [StringComparison]::OrdinalIgnoreCase) }) {
    throw "Quit Agent Signal Bar first"
}
if ((Test-Path $InstallDir) -and (Get-ChildItem $InstallDir -Force | Select-Object -First 1) `
        -and -not (Test-Path (Join-Path $InstallDir "AgentSignalBar.exe"))) {
    throw "$InstallDir is not empty and holds no AgentSignalBar.exe; choose another -InstallDir"
}

if (-not $SkipTests) {
    Run-Tests (Build-Project "tests" "tests\signalmodel.pro") "tst_signalmodel.exe" "lamp parity tests"
    Run-Tests (Build-Project "tests-codex" "tests\codex.pro") "tst_codex.exe" "data layer tests"
}

$appDir = Build-Project "app" "agent-signal-bar-windows.pro"
$cliDir = Build-Project "cli" "cli\agent-signal.pro"

if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
New-Item -ItemType Directory -Force $InstallDir | Out-Null
Copy-Item (Join-Path $appDir "release\AgentSignalBar.exe") $InstallDir
Copy-Item (Join-Path $cliDir "release\agent-signal.exe") $InstallDir
# windeployqt only drops the 25 MB vc_redist.x64.exe installer next to the app. Copy the MSVC
# runtime DLLs themselves (app-local deployment): without them agent-signal.exe cannot start on
# a PC lacking the Redistributable, and every Claude Code hook would raise a missing-DLL error.
$crt = $null
if ($env:VCToolsRedistDir) {
    $crt = Get-ChildItem (Join-Path $env:VCToolsRedistDir "x64") -Directory -Filter "Microsoft.VC*.CRT" -ErrorAction SilentlyContinue |
        Select-Object -First 1
}
$deployArgs = @("--release")
if ($crt) { $deployArgs += "--no-compiler-runtime" } # an if expression would unroll a one-item array
& $deploy @deployArgs --qmldir (Join-Path $Source "qml") --no-translations (Join-Path $InstallDir "AgentSignalBar.exe") | Out-Host
if ($LASTEXITCODE -ne 0) { throw "windeployqt failed" }
if ($crt) {
    Copy-Item (Join-Path $crt.FullName "*.dll") $InstallDir
} else {
    Write-Warning "MSVC runtime DLLs not found (VCToolsRedistDir is not set): the folder needs the Visual C++ Redistributable. Run from the x64 Native Tools Command Prompt."
}

Write-Host ""
Write-Host "Installed: $InstallDir"
Write-Host "Run:         $InstallDir\AgentSignalBar.exe"
Write-Host "Codex check: start /wait $InstallDir\AgentSignalBar.exe --probe 10"
Write-Host "Hook state:  $InstallDir\agent-signal.exe status"
Write-Host "Screenshots: $InstallDir\AgentSignalBar.exe --capture `"$BuildDir\capture`""
