#requires -Version 5
# M9.L.2 end-to-end smoke test for the from-source-autotools convention.
#
# Runs ``repro build`` against the production expat source recipe
# (``recipes/packages/source/expat/``) and verifies the convention's
# stage-copy output materialises the library binary under the canonical
# ``.repro/output/libExpat/libexpat.so`` path.
#
# **Tool gate**: make + gcc + sh must be on PATH. The dev shell
# (``env.ps1``) provisions gcc + msys2-shipped make + sh but
# host-by-host availability still varies. When any required tool is
# missing the script reports SKIPPED without failing so CI runs that
# don't provision the full autotools build stack stay green.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$recipeDir = Join-Path $repoRoot 'recipes\packages\source\expat'
$expectedLibrary = Join-Path $recipeDir '.repro\output\libExpat\libexpat.so'

if (-not (Test-Path -LiteralPath $recipeDir)) {
  throw "missing recipe dir: $recipeDir"
}

$make = (Get-Command make -ErrorAction SilentlyContinue)
$gcc = (Get-Command gcc -ErrorAction SilentlyContinue)
$sh = (Get-Command sh -ErrorAction SilentlyContinue)
if (-not $make -or -not $gcc -or -not $sh) {
  Write-Host "SKIPPED: from-source-autotools expat validation"
  Write-Host "  make: $($make?.Source)"
  Write-Host "  gcc:  $($gcc?.Source)"
  Write-Host "  sh:   $($sh?.Source)"
  Write-Host "  Install via 'scoop install gcc' + MSYS2 (for make + sh) before re-running."
  Write-Host "  M9.L.2 unit test exercises the convention's emission graph;"
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

Write-Host "OK: from-source-autotools expat end-to-end produced $expectedLibrary"
