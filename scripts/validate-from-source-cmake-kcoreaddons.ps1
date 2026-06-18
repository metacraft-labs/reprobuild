#requires -Version 5
# M9.L.1 end-to-end smoke test for the from-source-cmake convention.
#
# Runs ``repro build`` against the production kcoreaddons source recipe
# (``recipes/packages/source/kcoreaddons/``) and verifies the
# convention's stage-copy output materialises the library binary under
# the canonical ``.repro/output/libKF6CoreAddons/libKF6CoreAddons.a``
# path.
#
# **Tool gate**: cmake + ninja + a C/C++ compiler must be on PATH. The
# dev shell (``env.ps1``) provisions gcc + ninja but kcoreaddons also
# requires Qt6 (qt6-base + qt6-tools) which is NOT bundled in the dev
# shell. When any required tool is missing the script reports SKIPPED
# without failing so CI runs that don't provision the full KF6 build
# stack stay green.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$recipeDir = Join-Path $repoRoot 'recipes\packages\source\kcoreaddons'
$expectedLibrary = Join-Path $recipeDir '.repro\output\libKF6CoreAddons\libKF6CoreAddons.a'

if (-not (Test-Path -LiteralPath $recipeDir)) {
  throw "missing recipe dir: $recipeDir"
}

$cmake = (Get-Command cmake -ErrorAction SilentlyContinue)
$ninja = (Get-Command ninja -ErrorAction SilentlyContinue)
$gcc = (Get-Command gcc -ErrorAction SilentlyContinue)
if (-not $cmake -or -not $ninja -or -not $gcc) {
  Write-Host "SKIPPED: from-source-cmake kcoreaddons validation"
  Write-Host "  cmake: $($cmake?.Source)"
  Write-Host "  ninja: $($ninja?.Source)"
  Write-Host "  gcc:   $($gcc?.Source)"
  Write-Host "  Install via 'scoop install cmake ninja' before re-running."
  Write-Host "  M9.L.1 unit test exercises the convention's emission graph;"
  Write-Host "  this end-to-end script is a deferred manual-validation step."
  Write-Host "  (kcoreaddons additionally requires Qt6 — qt6-base + qt6-tools."
  Write-Host "   These are NOT bundled in the dev shell; install separately."
  Write-Host "   The recipe's configure step will fail loudly if Qt6 isn't"
  Write-Host "   discoverable via cmake find_package, which is expected on"
  Write-Host "   most review hosts.)"
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

Write-Host "OK: from-source-cmake kcoreaddons end-to-end produced $expectedLibrary"
