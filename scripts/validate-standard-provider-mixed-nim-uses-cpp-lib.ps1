#requires -Version 5
# End-to-end verification: cross-language mixed Mode 3 workspace where a
# Nim binary calls into a C static library declared in the same
# repro.nim. The Nim convention takes ownership of dispatch because it's
# registered first AND the workspace declares at least one ``uses: nim``
# package; it then emits the C/C++ archive actions for ``uses: gcc/clang``
# packages in-line and wires them into the Nim entrypoint's three-phase
# build graph.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so nim/gcc/repro are on PATH.
#   2. Probe for nim AND gcc (with fallback to clang); SKIP exit 0 if
#      either toolchain is missing.
#   3. Wipe any prior .repro/ scratch under the fixture so the build
#      runs cold.
#   4. Verify ``repro deps refresh --check`` exits 0 (the checked-in
#      ``repro.scanned-deps.nim`` matches the source tree).
#   5. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   6. Assert exit code 0.
#   7. Verify both upstream artefacts exist:
#       * the C archive  : ``<fixture>/.repro/build/mathlib/libmathlib.a``
#       * the Nim binary : ``<fixture>/.repro/build/nimapp/nimapp[.exe]``
#   8. Run the Nim binary and assert stdout contains:
#         "1 + 2 = 3"
#         "hello from nim-uses-cpp-lib"
#      The first line proves the C archive's ``add`` symbol is linked
#      AND callable from Nim (Phase 3 link + ``{.importc.}`` round-trip).
#
# Mode 3 cross-language contract: the Nim convention emits the C archive
# action FIRST (sequenced via depends_on nimapp: mathlib), the Nim
# Phase 1's nim c invocation carries --passC:-I<mathlib>/include so the
# generated .c files resolve ``#include "mathlib/add.h"``, and the Nim
# link argv carries libmathlib.a as a trailing positional. This script
# is the load-bearing end-to-end gate that turns the convention's
# action graph into a working cross-language executable.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\mixed\nim-uses-cpp-lib'
$scratchInsideFixture = Join-Path $fixture '.repro'
$libArchive     = Join-Path $fixture '.repro\build\mathlib\libmathlib.a'
$expectedAddition = '1 + 2 = 3'
$expectedGreeting = 'hello from nim-uses-cpp-lib'

# --- preflight ---
if (-not (Test-Path -LiteralPath $reproExe)) {
  Write-Host "FAIL: missing $reproExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath $providerExe)) {
  Write-Host "FAIL: missing $providerExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'repro.nim'))) {
  Write-Host "FAIL: fixture missing at $fixture -- expected reprobuild-examples checkout"
  exit 1
}

# --- toolchain probe ---
$nim = Get-Command nim -ErrorAction SilentlyContinue
if (-not $nim) {
  Write-Host "SKIP: 'nim' not on PATH (env.ps1 should provide it)"
  exit 0
}
$gcc = Get-Command gcc -ErrorAction SilentlyContinue
$clang = $null
if (-not $gcc) {
  $clang = Get-Command clang -ErrorAction SilentlyContinue
}
if (-not $gcc -and -not $clang) {
  Write-Host "SKIP: neither gcc nor clang on PATH; cannot build mixed nim-uses-cpp-lib"
  exit 0
}
$ar = Get-Command ar -ErrorAction SilentlyContinue
if (-not $ar) {
  Write-Host "SKIP: 'ar' not on PATH; cannot archive the upstream C library"
  exit 0
}
Write-Host "==> using nim=$($nim.Source)"
if ($gcc) {
  Write-Host "==> using gcc=$($gcc.Source)"
} else {
  Write-Host "==> using clang=$($clang.Source)"
}
Write-Host "==> using ar=$($ar.Source)"

# --- step 1: deps refresh --check ---
Write-Host "==> repro deps refresh --check $fixture"
& $reproExe deps refresh --check $fixture
if ($LASTEXITCODE -ne 0) {
  Write-Host "FAIL: deps refresh --check failed; repro.scanned-deps.nim is out of date"
  exit 1
}

# --- step 2: clean prior scratch ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}

# --- step 3: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-mixed-nim-uses-cpp-lib.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-mixed-nim-uses-cpp-lib.stderr.txt'
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
  Write-Host "--- repro stdout (last 20 lines):"
  Get-Content -LiteralPath $stdoutCapture -Tail 20 | ForEach-Object { Write-Host $_ }
}
if (Test-Path $stderrCapture) {
  $stderrTail = Get-Content -LiteralPath $stderrCapture -Tail 20
  if ($stderrTail) {
    Write-Host "--- repro stderr (last 20 lines):"
    foreach ($line in $stderrTail) { Write-Host $line }
  }
}

if ($exitCode -ne 0) {
  Write-Host "FAIL: repro build exited with code $exitCode"
  exit 1
}

# --- step 4: verify archive exists ---
if (-not (Test-Path -LiteralPath $libArchive)) {
  Write-Host "FAIL: expected library archive not found at $libArchive"
  exit 1
}
Write-Host "produced archive: $libArchive ($((Get-Item $libArchive).Length) bytes)"

# --- step 5: locate produced binary ---
$candidates = @(
  (Join-Path $fixture '.repro\build\nimapp\nimapp.exe'),
  (Join-Path $fixture '.repro\build\nimapp\nimapp')
)
$producedBinary = $null
foreach ($candidate in $candidates) {
  if (Test-Path -LiteralPath $candidate) {
    $producedBinary = $candidate
    break
  }
}
if (-not $producedBinary) {
  Write-Host "FAIL: expected Nim binary not found at any of:"
  foreach ($c in $candidates) { Write-Host "    $c" }
  exit 1
}
Write-Host "produced binary: $producedBinary ($((Get-Item $producedBinary).Length) bytes)"

# --- step 6: run and assert greeting + C call result ---
Write-Host "==> running $producedBinary"
$output = & $producedBinary 2>&1 | Out-String
$runExit = $LASTEXITCODE
Write-Host "--- binary exit code: $runExit"
Write-Host "--- binary stdout:"
Write-Host $output

if ($runExit -ne 0) {
  Write-Host "FAIL: produced binary exited with code $runExit"
  exit 1
}
if ($output -notmatch [regex]::Escape($expectedAddition)) {
  Write-Host "FAIL: produced binary stdout does not contain expected addition output '$expectedAddition' (this proves the C archive's add() symbol is linked AND callable from Nim)"
  exit 1
}
if ($output -notmatch [regex]::Escape($expectedGreeting)) {
  Write-Host "FAIL: produced binary stdout does not contain expected greeting '$expectedGreeting'"
  exit 1
}

Write-Host ""
Write-Host "PASS: mixed/nim-uses-cpp-lib built via standard provider; cross-language call to C add() produced 1 + 2 = 3; libmathlib.a archive produced"
exit 0
