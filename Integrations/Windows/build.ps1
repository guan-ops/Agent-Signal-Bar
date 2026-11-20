# Builds Agent Signal Bar for Windows, runs the tests and installs a self-contained folder
# (AgentSignalBar.exe, agent-signal.exe for Claude Code hooks, Qt runtime) with windeployqt.
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

# Refuse before deleting anything: a running copy, or a folder that is not an install.
if (Get-Process -Name "AgentSignalBar" -ErrorAction SilentlyContinue) { throw "Quit Agent Signal Bar first" }
if ((Test-Path $InstallDir) -and (Get-ChildItem $InstallDir -Force | Select-Object -First 1) `
        -and -not (Test-Path (Join-Path $InstallDir "AgentSignalBar.exe"))) {
    throw "$InstallDir is not empty and holds no AgentSignalBar.exe; choose another -InstallDir"
}

if (-not $SkipTests) {
    $lampTests = Build-Project "tests" "tests\signalmodel.pro"
    & (Join-Path $lampTests "release\tst_signalmodel.exe") | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "lamp parity tests failed" }
    $codexTests = Build-Project "tests-codex" "tests\codex.pro"
    & (Join-Path $codexTests "release\tst_codex.exe") | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "data layer tests failed" }
}

$appDir = Build-Project "app" "agent-signal-bar-windows.pro"
$cliDir = Build-Project "cli" "cli\agent-signal.pro"

if (Test-Path $InstallDir) { Remove-Item -Recurse -Force $InstallDir }
New-Item -ItemType Directory -Force $InstallDir | Out-Null
Copy-Item (Join-Path $appDir "release\AgentSignalBar.exe") $InstallDir
Copy-Item (Join-Path $cliDir "release\agent-signal.exe") $InstallDir
& $deploy --release --qmldir (Join-Path $Source "qml") --no-translations (Join-Path $InstallDir "AgentSignalBar.exe") | Out-Host
if ($LASTEXITCODE -ne 0) { throw "windeployqt failed" }

Write-Host ""
Write-Host "Installed: $InstallDir"
Write-Host "Run:         $InstallDir\AgentSignalBar.exe"
Write-Host "Codex check: start /wait $InstallDir\AgentSignalBar.exe --probe 10"
Write-Host "Hook state:  $InstallDir\agent-signal.exe status"
Write-Host "Screenshots: $InstallDir\AgentSignalBar.exe --capture `"$BuildDir\capture`""
