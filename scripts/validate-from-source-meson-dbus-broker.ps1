#requires -Version 5
# M9.L.0 end-to-end smoke test for the from-source-meson convention.
#
# Runs ``repro build`` against the production dbus-broker source recipe
# (``recipes/packages/source/dbus-broker/``) and verifies the convention's
# stage-copy output materialises the broker binary under the canonical
# ``.repro/output/dbusBroker/dbusBroker`` path.
#
# **Tool gate**: meson + ninja + a C compiler must be on PATH. The dev
# shell (``env.ps1``) provisions gcc + ninja but does NOT bundle meson —
# install via ``pip install meson`` on the review host before running
# this script. When meson isn't available the script reports SKIPPED
# without failing so CI runs that don't provision meson stay green.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$recipeDir = Join-Path $repoRoot 'recipes\packages\source\dbus-broker'
$expectedBinary = Join-Path $recipeDir '.repro\output\dbusBroker\dbusBroker'
if ($IsWindows -or $env:OS -eq 'Windows_NT') {
  $expectedBinary = $expectedBinary + '.exe'
}

if (-not (Test-Path -LiteralPath $recipeDir)) {
  throw "missing recipe dir: $recipeDir"
}

$meson = (Get-Command meson -ErrorAction SilentlyContinue)
$ninja = (Get-Command ninja -ErrorAction SilentlyContinue)
$gcc = (Get-Command gcc -ErrorAction SilentlyContinue)
if (-not $meson -or -not $ninja -or -not $gcc) {
  Write-Host "SKIPPED: from-source-meson dbus-broker validation"
  Write-Host "  meson: $($meson?.Source)"
  Write-Host "  ninja: $($ninja?.Source)"
  Write-Host "  gcc:   $($gcc?.Source)"
  Write-Host "  Install meson via 'pip install meson' before re-running."
  Write-Host "  M9.L.0 unit test exercises the convention's emission graph;"
  Write-Host "  this end-to-end script is a deferred manual-validation step."
  exit 0
}

$reproExe = Join-Path $repoRoot 'build\bin\repro.exe'
if (-not (Test-Path -LiteralPath $reproExe)) {
  $reproExe = Join-Path $repoRoot 'build\bin\repro'
}
if (-not (Test-Path -LiteralPath $reproExe)) {
  throw "missing repro CLI binary at build\bin\repro[.exe] — run 'just build' first"
}

# Drop any previous .repro/build + .repro/output so the run is clean.
$reproDir = Join-Path $recipeDir '.repro'
if (Test-Path -LiteralPath $reproDir) {
  Remove-Item -LiteralPath $reproDir -Recurse -Force
}

Push-Location $repoRoot
try {
  & $reproExe build $recipeDir --tool-provisioning=path --no-runquota
  if ($LASTEXITCODE -ne 0) {
    throw "repro build exited $LASTEXITCODE"
  }
} finally {
  Pop-Location
}

if (-not (Test-Path -LiteralPath $expectedBinary)) {
  throw "expected staged binary not produced: $expectedBinary"
}

# --version sanity check: the broker prints just "36" on stdout.
$versionOutput = & $expectedBinary --version 2>&1
if ($LASTEXITCODE -ne 0) {
  throw "dbus-broker --version exited $LASTEXITCODE"
}
if ($versionOutput -notmatch '36') {
  throw "dbus-broker --version output did not contain '36': $versionOutput"
}

Write-Host "OK: from-source-meson dbus-broker end-to-end produced $expectedBinary"
Write-Host "    --version output: $versionOutput"
