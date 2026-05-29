#requires -Version 5
# End-to-end verification: M35 cross-language Mode 3 workspace where a
# Nim binary calls into a Rust static library declared in the same
# repro.nim (FORWARD direction). Mirror of the M34 ``rust-uses-cpp-lib``
# wiring but routed in the OTHER direction: Nim -> Rust instead of
# Rust -> C.
#
# The Nim convention takes ownership of the workspace because it's
# registered first AND ``nimapp``'s ``uses:`` block names ``nim``. It
# then:
#
#   1. Emits the Rust library archive for ``addlib`` with
#      ``rustc --crate-type=staticlib -C panic=abort``. The archive
#      contains the user-exported ``rust_add`` symbol (via
#      ``#[no_mangle] pub extern "C"``); the library uses ``#![no_std]``
#      to keep the archive small and avoid MSVC-rustc + MinGW-gcc ABI
#      mismatches.
#   2. Emits Nim's three-phase pipeline for ``nimapp``. Phase 3's gcc
#      link picks up ``.repro/build/addlib/libaddlib.a`` as a trailing
#      positional + the platform-specific Rust runtime libs (Windows
#      MinGW: ``-lws2_32 -luserenv -ladvapi32 -lbcrypt -lntdll``;
#      POSIX: ``-lpthread -ldl -lm``). Build sequencing strictly orders
#      the rustc staticlib emit before the Nim link.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so nim/gcc/repro are on PATH; prepend
#      the rustup stable bin so rustc resolves.
#   2. Probe for rustc AND gcc AND nim; SKIP exit 0 if any toolchain is
#      missing.
#   3. Wipe any prior .repro/ scratch under the fixture so the build
#      runs cold.
#   4. Verify ``repro deps refresh --check`` exits 0.
#   5. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   6. Assert exit code 0.
#   7. Verify both upstream artefacts exist:
#       * the Rust archive : ``<fixture>/.repro/build/addlib/libaddlib.a``
#       * the Nim binary   : ``<fixture>/.repro/build/nimapp/nimapp[.exe]``
#   8. Run the Nim binary and assert stdout contains:
#         "nim says: rust added 2+3 = 5"
#         "hello from nim-uses-rust-lib"
#      The first line proves the Rust archive's ``rust_add`` symbol is
#      linked AND callable from Nim (the cross-language round-trip).

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\mixed\nim-uses-rust-lib'
$scratchInsideFixture = Join-Path $fixture '.repro'
$libArchive     = Join-Path $fixture '.repro\build\addlib\libaddlib.a'
$expectedAddition = 'nim says: rust added 2+3 = 5'
$expectedGreeting = 'hello from nim-uses-rust-lib'

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
$rustc = Get-Command rustc -ErrorAction SilentlyContinue
if (-not $rustc) {
  $rustupStableBin = 'D:\metacraft-dev-deps\rustup\toolchains\stable-x86_64-pc-windows-msvc\bin'
  if (Test-Path -LiteralPath (Join-Path $rustupStableBin 'rustc.exe')) {
    $env:PATH = "$rustupStableBin;$env:PATH"
    $rustc = Get-Command rustc -ErrorAction SilentlyContinue
  }
}
if (-not $rustc) {
  Write-Host "SKIP: 'rustc' not on PATH and no rustup stable under D:/metacraft-dev-deps/rustup"
  exit 0
}
$gcc = Get-Command gcc -ErrorAction SilentlyContinue
$clang = $null
if (-not $gcc) {
  $clang = Get-Command clang -ErrorAction SilentlyContinue
}
if (-not $gcc -and -not $clang) {
  Write-Host "SKIP: neither gcc nor clang on PATH; cannot link Nim binary"
  exit 0
}
$nim = Get-Command nim -ErrorAction SilentlyContinue
if (-not $nim) {
  Write-Host "SKIP: 'nim' not on PATH"
  exit 0
}
$ar = Get-Command ar -ErrorAction SilentlyContinue
if (-not $ar) {
  Write-Host "SKIP: 'ar' not on PATH"
  exit 0
}
Write-Host "==> using rustc=$($rustc.Source)"
if ($gcc) {
  Write-Host "==> using gcc=$($gcc.Source)"
} else {
  Write-Host "==> using clang=$($clang.Source)"
}
Write-Host "==> using nim=$($nim.Source)"
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
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-mixed-nim-uses-rust-lib.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-mixed-nim-uses-rust-lib.stderr.txt'
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

# --- step 6: run and assert greeting + Rust call result ---
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
  Write-Host "FAIL: produced binary stdout does not contain expected addition output '$expectedAddition' (this proves the Rust archive's rust_add() symbol is linked AND callable from Nim)"
  exit 1
}
if ($output -notmatch [regex]::Escape($expectedGreeting)) {
  Write-Host "FAIL: produced binary stdout does not contain expected greeting '$expectedGreeting'"
  exit 1
}

Write-Host ""
Write-Host "PASS: mixed/nim-uses-rust-lib built via standard provider; cross-language call from Nim to Rust rust_add() produced 2 + 3 = 5; libaddlib.a archive produced (staticlib via cConsumable flag derived from depends_on edge)"
exit 0
