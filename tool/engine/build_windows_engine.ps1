# Builds Flutter's Windows engine with windows_text.patch applied.
#
#   powershell -ExecutionPolicy Bypass -File tool\engine\build_windows_engine.ps1
#   ... -Mode release      also (or only) out\host_release
#   ... -Mode both
#
# Needs depot_tools on PATH, Visual Studio 2022 with "Desktop development with
# C++" and the Windows SDK's Debugging Tools, and long paths enabled. See
# tool\engine\README.md.
param(
  [string]$FlutterDir = 'C:\src\flutter-wintext',
  [string]$Tag = '3.47.5',
  [ValidateSet('debug', 'release', 'both')][string]$Mode = 'debug',
  [switch]$SkipSync
)

$ErrorActionPreference = 'Stop'
$patch = Join-Path $PSScriptRoot 'windows_text.patch'

function Run([string]$exe, [string[]]$arguments) {
  Write-Host "> $exe $($arguments -join ' ')" -ForegroundColor Cyan
  & $exe @arguments
  if ($LASTEXITCODE -ne 0) { throw "$exe failed ($LASTEXITCODE)" }
}

# Runs a command for its exit code. Windows PowerShell turns a redirected
# stderr line into an error under 'Stop', so this one runs under 'Continue'.
function Probe([string]$exe, [string[]]$arguments) {
  $saved = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $exe @arguments 2>$null
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = "$output".Trim() }
  } finally {
    $ErrorActionPreference = $saved
  }
}

foreach ($tool in 'git', 'gclient', 'python3', 'ninja') {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    throw "$tool is not on PATH (depot_tools provides gclient, python3 and ninja)"
  }
}

# depot_tools would otherwise fetch Google's internal toolchain.
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'

if (-not (Test-Path $FlutterDir)) {
  # Blobless: full history (the tool reads the tag) without the full download.
  # LF endings, so the patch's context matches whatever core.autocrlf says.
  Run git @('clone', '--filter=blob:none', '--config', 'core.autocrlf=false',
    '--branch', $Tag, 'https://github.com/flutter/flutter.git', $FlutterDir)
}

Push-Location $FlutterDir
try {
  $head = (Probe git @('describe', '--tags', '--exact-match')).Output
  if ($head -ne $Tag) {
    throw "$FlutterDir is at '$head', not $Tag; the engine must match the app's Flutter"
  }

  if (-not (Test-Path '.gclient')) {
    Copy-Item 'engine\scripts\standard.gclient' '.gclient'
  }
  if (-not $SkipSync) {
    Run gclient @('sync', '-D', '--no-history')
  }

  if ((Probe git @('apply', '--reverse', '--check', $patch)).Code -eq 0) {
    Write-Host 'windows_text.patch already applied'
  } else {
    Run git @('apply', $patch)
  }
} finally {
  Pop-Location
}

Push-Location (Join-Path $FlutterDir 'engine\src')
try {
  if ($Mode -in 'debug', 'both') {
    Run python3 @('flutter\tools\gn', '--runtime-mode=debug', '--no-lto')
    Run ninja @('-C', 'out\host_debug')
  }
  if ($Mode -in 'release', 'both') {
    Run python3 @('flutter\tools\gn', '--runtime-mode=release', '--no-lto')
    Run ninja @('-C', 'out\host_release')
  }
} finally {
  Pop-Location
}

$flutter = Join-Path $FlutterDir 'bin\flutter.bat'
Write-Host ''
Write-Host 'Done. From the app folder:' -ForegroundColor Green
if ($Mode -in 'debug', 'both') {
  Write-Host "  $flutter run -d windows --local-engine=host_debug --local-engine-host=host_debug"
}
if ($Mode -in 'release', 'both') {
  Write-Host "  $flutter build windows --release --local-engine=host_release --local-engine-host=host_release"
  Write-Host "  or copy $FlutterDir\engine\src\out\host_release\flutter_windows.dll over a stock $Tag build's"
}
