# Builds Agent Signal Bar for Windows, runs the lamp parity tests and stages a
# self-contained folder with windeployqt.
#
#   powershell -ExecutionPolicy Bypass -File Integrations\Windows\build.ps1 -QtDir C:\Qt\6.8.3\msvc2022_64
#
# Run from a "x64 Native Tools Command Prompt for VS 2022" (or after vcvars64.bat) so
# cl.exe and nmake are on PATH. Qt 6.8 or newer is required (Popup.Window popups).
# Clone the repository to an ASCII-only path: rcc cannot open .qrc files under
# non-ASCII folders, and the test embeds its golden-file path at compile time.
param(
    [Parameter(Mandatory = $true)][string]$QtDir,
    [string]$BuildDir = "$env:TEMP\asb-windows-build",
    [string]$Version = "0.1.0",
    [switch]$SkipTests
)
$ErrorActionPreference = "Stop"
$Source = $PSScriptRoot
$qmake = Join-Path $QtDir "bin\qmake.exe"
$deploy = Join-Path $QtDir "bin\windeployqt.exe"
if (-not (Test-Path $qmake)) { throw "qmake not found: $qmake" }
$make = if (Get-Command jom -ErrorAction SilentlyContinue) { "jom" } else { "nmake" }
$env:ASB_WINDOWS_VERSION = $Version
$env:PATH = "$(Join-Path $QtDir 'bin');$env:PATH"

if (-not $SkipTests) {
    $testDir = Join-Path $BuildDir "tests"
    New-Item -ItemType Directory -Force $testDir | Out-Null
    Push-Location $testDir
    & $qmake (Join-Path $Source "tests\signalmodel.pro") "CONFIG+=release"
    & $make
    if ($LASTEXITCODE -ne 0) { throw "test build failed" }
    & .\release\tst_signalmodel.exe
    if ($LASTEXITCODE -ne 0) { throw "lamp parity tests failed" }
    Pop-Location
}

$appDir = Join-Path $BuildDir "app"
New-Item -ItemType Directory -Force $appDir | Out-Null
Push-Location $appDir
& $qmake (Join-Path $Source "agent-signal-bar-windows.pro") "CONFIG+=release"
& $make
if ($LASTEXITCODE -ne 0) { throw "app build failed" }
Pop-Location

$stage = Join-Path $BuildDir "AgentSignalBar"
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item (Join-Path $appDir "release\AgentSignalBar.exe") $stage
& $deploy --release --qmldir (Join-Path $Source "qml") --no-translations (Join-Path $stage "AgentSignalBar.exe")
if ($LASTEXITCODE -ne 0) { throw "windeployqt failed" }

Write-Host ""
Write-Host "Staged: $stage"
Write-Host "Screenshots: $stage\AgentSignalBar.exe --capture `"$BuildDir\capture`""
