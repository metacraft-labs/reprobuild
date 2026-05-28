#requires -Version 5
# End-to-end M24 verification: build the python/pep517-scikit-build-core
# fixture via the Tier 2b dispatch path. The M24 Python convention
# detects the scikit_build_core.build backend in pyproject.toml and
# routes the project through the Mode B crude fallback
# (``python -m build --wheel --no-isolation``). scikit-build-core in
# turn invokes CMake which drives a C compiler to produce the wheel.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1.
#   2. Probe for cmake + a C compiler (gcc/clang/cl). SKIP if either
#      is missing.
#   3. Probe for python3/python + ``scikit_build_core`` + ``build``
#      modules. SKIP on any missing piece.
#   4. Wipe prior scratch under the fixture so the build runs cold.
#   5. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   6. Assert exit code 0.
#   7. Assert at least one ``*.whl`` under ``<fixture>/dist/``.
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org §M24.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\python\pep517-scikit-build-core'
$distDir        = Join-Path $fixture 'dist'

# --- probe cmake ---
$cmakeCmd = Get-Command cmake -ErrorAction SilentlyContinue
if (-not $cmakeCmd) {
  Write-Host "SKIP: cmake not on PATH -- scikit-build-core needs CMake."
  exit 0
}
Write-Host "cmake = $($cmakeCmd.Source)"

# --- probe C compiler ---
$ccCmd = Get-Command gcc -ErrorAction SilentlyContinue
if (-not $ccCmd) { $ccCmd = Get-Command clang -ErrorAction SilentlyContinue }
if (-not $ccCmd) { $ccCmd = Get-Command cl -ErrorAction SilentlyContinue }
if (-not $ccCmd) {
  Write-Host "SKIP: no C compiler (gcc/clang/cl) on PATH."
  exit 0
}
Write-Host "cc = $($ccCmd.Source)"

# --- probe python + modules ---
$pythonCmd = $null
foreach ($n in @('python3', 'python')) {
  $cand = Get-Command $n -ErrorAction SilentlyContinue
  if ($cand) { $pythonCmd = $cand; break }
}
if (-not $pythonCmd) {
  Write-Host "SKIP: python3/python not on PATH -- M24 Mode B uses 'python -m build'."
  exit 0
}
Write-Host "python = $($pythonCmd.Source)"

foreach ($mod in @('scikit_build_core', 'build')) {
  & $pythonCmd.Source -c "import $mod" 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "SKIP: python module '$mod' not importable. Install via: $($pythonCmd.Source) -m pip install $mod"
    exit 0
  }
}
Write-Host "python modules: scikit_build_core + build importable"

# scikit-build-core's CMake driver uses ``find_package(Python ...
# Development.Module)`` which requires both ``Python.h`` headers AND
# the import library. On Windows the embeddable distribution omits
# both; SKIP cleanly when missing.
$pythonPrefix = Split-Path $pythonCmd.Source -Parent
$pythonLibsDir = Join-Path $pythonPrefix 'libs'
$pythonIncludeDir = Join-Path $pythonPrefix 'include'
$hasPythonDevHeaders = (Test-Path -LiteralPath $pythonLibsDir) -and
  (Test-Path -LiteralPath $pythonIncludeDir)
if ($hasPythonDevHeaders) {
  $importLibs = @(Get-ChildItem -LiteralPath $pythonLibsDir -Filter 'python*.lib' -ErrorAction SilentlyContinue)
  $headerFiles = @(Get-ChildItem -LiteralPath $pythonIncludeDir -Filter 'Python.h' -ErrorAction SilentlyContinue)
  $hasPythonDevHeaders = ($importLibs.Count -gt 0) -and ($headerFiles.Count -gt 0)
}
if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
  $hasPythonDevHeaders = $true
}
if (-not $hasPythonDevHeaders) {
  Write-Host "SKIP: Python install lacks development headers + import library (looked under $pythonLibsDir + $pythonIncludeDir). The embeddable Windows Python distribution omits both; scikit-build-core needs a full install."
  exit 0
}
Write-Host "python development headers + import library present"

# --- preflight ---
if (-not (Test-Path -LiteralPath $reproExe)) {
  Write-Host "FAIL: missing $reproExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'reprobuild.nim'))) {
  Write-Host "FAIL: fixture missing at $fixture"
  exit 1
}

# --- wipe prior scratch ---
foreach ($leftover in @('.repro', 'dist', 'build', '_skbuild')) {
  $leftoverPath = Join-Path $fixture $leftover
  if (Test-Path -LiteralPath $leftoverPath) {
    Write-Host "wiping prior $leftoverPath"
    Remove-Item -LiteralPath $leftoverPath -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# --- invoke repro build ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-python-scikit-build-core.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-python-scikit-build-core.stderr.txt'
New-Item -ItemType Directory -Force -Path (Split-Path $stdoutCapture) | Out-Null

Write-Host "==> launching repro.exe build $reproTarget"
$proc = Start-Process -FilePath $reproExe -ArgumentList @(
    'build', $reproTarget,
    '--tool-provisioning=path',
    '--log=actions'
  ) -NoNewWindow -PassThru -Wait `
  -WorkingDirectory $repoRoot `
  -RedirectStandardOutput $stdoutCapture `
  -RedirectStandardError  $stderrCapture
$exitCode = $proc.ExitCode

Write-Host "--- repro exit code: $exitCode"
if (Test-Path $stdoutCapture) {
  Write-Host "--- repro stdout (last 30 lines):"
  Get-Content -LiteralPath $stdoutCapture -Tail 30 | ForEach-Object { Write-Host $_ }
}
if (Test-Path $stderrCapture) {
  $stderrTail = Get-Content -LiteralPath $stderrCapture -Tail 30
  if ($stderrTail) {
    Write-Host "--- repro stderr (last 30 lines):"
    foreach ($line in $stderrTail) { Write-Host $line }
  }
}

if ($exitCode -ne 0) {
  Write-Host "FAIL: repro build exited with code $exitCode"
  exit 1
}

# --- assert the wheel exists ---
if (-not (Test-Path -LiteralPath $distDir)) {
  Write-Host "FAIL: expected dist directory missing at $distDir"
  exit 1
}
$wheels = @(Get-ChildItem -LiteralPath $distDir -Filter '*.whl' -ErrorAction SilentlyContinue)
if ($wheels.Count -eq 0) {
  Write-Host "FAIL: no .whl found under $distDir"
  Write-Host "--- contents of dist:"
  Get-ChildItem -LiteralPath $distDir -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "  $($_.Name)  $($_.Length) bytes" }
  exit 1
}
foreach ($wheel in $wheels) {
  Write-Host "produced wheel: $($wheel.FullName)"
  Write-Host "  size: $($wheel.Length) bytes"
}

Write-Host ""
Write-Host "PASS: python/pep517-scikit-build-core built via M24 Mode B fallback; wheel produced"
exit 0
