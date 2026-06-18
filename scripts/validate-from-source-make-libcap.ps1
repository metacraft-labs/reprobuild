#requires -Version 5
# M9.L.3 end-to-end smoke test for the from-source-make convention.
#
# Runs ``repro build`` against the production libcap source recipe
# (``recipes/packages/source/libcap/``) and verifies the convention's
# stage-copy output materialises the library binary under the canonical
# ``.repro/output/libCap/libcap.so`` path plus the three executables
# (``capsh`` / ``getcap`` / ``setcap``).
#
# **Tool gate**: make + gcc + sh must be on PATH. The dev shell
# (``env.ps1``) provisions gcc + msys2-shipped make + sh but
# host-by-host availability still varies. When any required tool is
# missing the script reports SKIPPED without failing so CI runs that
# don't provision the full make build stack stay green.
#
# libcap was chosen as the M9.L.3 vertical slice (over the kernel) for
# the same reason expat was chosen for M9.L.2 — its source tarball is
# tiny (< 200 KB), the build is single-threaded and finishes in
# seconds on a stock dev box, and the install action lands artefacts at
# predictable ``<staging>/usr/sbin/`` paths the convention's stage-
# copy step knows how to harvest. The kernel recipe's end-to-end build
# is gated behind several deferrals (``.config`` prerequisite, modules
# tree, kbuild install semantics) per the convention's module
# docstring — its unit test exercises the convention's emission graph,
# but an end-to-end script for the kernel is deferred until those
# deferrals close.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$recipeDir = Join-Path $repoRoot 'recipes\packages\source\libcap'
$expectedLibrary = Join-Path $recipeDir '.repro\output\libCap\libcap.so'
$expectedCapsh = Join-Path $recipeDir '.repro\output\capsh\capsh'
$expectedGetcap = Join-Path $recipeDir '.repro\output\getcap\getcap'
$expectedSetcap = Join-Path $recipeDir '.repro\output\setcap\setcap'

if (-not (Test-Path -LiteralPath $recipeDir)) {
  throw "missing recipe dir: $recipeDir"
}

$make = (Get-Command make -ErrorAction SilentlyContinue)
$gcc = (Get-Command gcc -ErrorAction SilentlyContinue)
$sh = (Get-Command sh -ErrorAction SilentlyContinue)
if (-not $make -or -not $gcc -or -not $sh) {
  Write-Host "SKIPPED: from-source-make libcap validation"
  Write-Host "  make: $($make?.Source)"
  Write-Host "  gcc:  $($gcc?.Source)"
  Write-Host "  sh:   $($sh?.Source)"
  Write-Host "  Install via 'scoop install gcc' + MSYS2 (for make + sh) before re-running."
  Write-Host "  M9.L.3 unit test exercises the convention's emission graph;"
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

if (-not (Test-Path -LiteralPath $expectedLibrary)) {
  throw "expected staged library not produced: $expectedLibrary"
}
foreach ($expectedExe in @($expectedCapsh, $expectedGetcap, $expectedSetcap)) {
  if (-not (Test-Path -LiteralPath $expectedExe)) {
    throw "expected staged executable not produced: $expectedExe"
  }
}

Write-Host "OK: from-source-make libcap end-to-end produced:"
Write-Host "  $expectedLibrary"
Write-Host "  $expectedCapsh"
Write-Host "  $expectedGetcap"
Write-Host "  $expectedSetcap"
