#requires -Version 5
# End-to-end verification: M35 cross-language Mode 3 workspace where a
# Rust binary calls into a Nim static library declared in the same
# repro.nim (REVERSE direction). Closes the loop opened by
# validate-standard-provider-mixed-nim-uses-rust-lib.ps1 (Nim -> Rust);
# this script routes Rust -> Nim.
#
# The Nim convention takes ownership of the WHOLE workspace because
# it's registered first AND ``nimaddlib``'s ``uses:`` block names
# ``nim``. It then:
#
#   1. Emits the Nim archive for ``nimaddlib`` with ``--noMain`` so the
#      archive's ``main`` symbol does NOT collide with the Rust binary's
#      own entry point. ``--noMain`` is driven by the ``cConsumable``
#      flag the convention derives from ``depends_on rustapp: nimaddlib``
#      (Rust executable consumes Nim library -> cConsumable=true).
#   2. Emits a single ``rustc --crate-type=bin`` action for ``rustapp``.
#      The link argv carries ``-L native=<dir>`` + ``-l static=nimaddlib``;
#      on Windows the rustc invocation is forced to
#      ``--target x86_64-pc-windows-gnu`` so rustc uses the gcc-mingw
#      linker (the MinGW gcc-compiled Nim archive references symbols
#      like ``__mingw_printf`` / ``__emutls_get_address`` that the
#      default MSVC link.exe cannot resolve). Build sequencing
#      strictly orders the Nim archive before the rustc link.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so nim/gcc/repro are on PATH; prepend
#      the rustup stable bin so rustc resolves.
#   2. Probe for rustc + gcc + nim + ar + (Windows only) the
#      x86_64-pc-windows-gnu rustup target. SKIP exit 0 if any
#      toolchain or target is missing.
#   3. Wipe any prior .repro/ scratch under the fixture so the build
#      runs cold.
#   4. Verify ``repro deps refresh --check`` exits 0.
#   5. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   6. Assert exit code 0.
#   7. Verify both upstream artefacts exist:
#       * the Nim archive  : ``<fixture>/.repro/build/nimaddlib/libnimaddlib.a``
#       * the Rust binary  : ``<fixture>/.repro/build/rustapp/rustapp[.exe]``
#   8. Run the Rust binary and assert stdout contains:
#         "rust says: nim added 2+3 = 5"
#         "hello from rust-uses-nim-lib"
#      The first line proves the Nim archive's ``nimAdd`` symbol is
#      linked AND callable from Rust (the cross-language round-trip).

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\mixed\rust-uses-nim-lib'
$scratchInsideFixture = Join-Path $fixture '.repro'
$libArchive     = Join-Path $fixture '.repro\build\nimaddlib\libnimaddlib.a'
$expectedAddition = 'rust says: nim added 2+3 = 5'
$expectedGreeting = 'hello from rust-uses-nim-lib'

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
  Write-Host "SKIP: neither gcc nor clang on PATH; cannot build Nim library"
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
# Windows-only: the convention switches rustc to
# ``--target x86_64-pc-windows-gnu`` so the gcc-mingw linker can
# resolve the MinGW gcc-compiled Nim archive's runtime symbols. Probe
# the target rustup folder; SKIP cleanly if it's not installed (the
# managed-Rust shell can re-run ``rustup target add x86_64-pc-windows-gnu``
# to enable this fixture on Windows).
$IsWindowsHost = $true
try { $IsWindowsHost = $IsWindows } catch { $IsWindowsHost = $true }
if ($IsWindowsHost) {
  $rustcDir = Split-Path -Parent $rustc.Source
  # rustc binary lives at <toolchain>/bin/rustc.exe; the rustlib dir is
  # <toolchain>/lib/rustlib/<target>. Walk two parents to reach the
  # toolchain root.
  $toolchainRoot = Split-Path -Parent $rustcDir
  $gnuTargetDir = Join-Path $toolchainRoot 'lib\rustlib\x86_64-pc-windows-gnu'
  if (-not (Test-Path -LiteralPath $gnuTargetDir)) {
    Write-Host "SKIP: x86_64-pc-windows-gnu rustup target not installed at $gnuTargetDir;"
    Write-Host "      Windows requires the gnu target because rustc's MSVC link.exe cannot"
    Write-Host "      resolve the MinGW gcc-compiled Nim archive's runtime symbols"
    Write-Host "      (__mingw_printf, __emutls_get_address). Install via:"
    Write-Host "          rustup target add x86_64-pc-windows-gnu"
    exit 0
  }
  Write-Host "==> rustup target x86_64-pc-windows-gnu installed at $gnuTargetDir"
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
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-mixed-rust-uses-nim-lib.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-mixed-rust-uses-nim-lib.stderr.txt'
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
  (Join-Path $fixture '.repro\build\rustapp\rustapp.exe'),
  (Join-Path $fixture '.repro\build\rustapp\rustapp')
)
$producedBinary = $null
foreach ($candidate in $candidates) {
  if (Test-Path -LiteralPath $candidate) {
    $producedBinary = $candidate
    break
  }
}
if (-not $producedBinary) {
  Write-Host "FAIL: expected Rust binary not found at any of:"
  foreach ($c in $candidates) { Write-Host "    $c" }
  exit 1
}
Write-Host "produced binary: $producedBinary ($((Get-Item $producedBinary).Length) bytes)"

# --- step 6: run and assert greeting + Nim call result ---
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
  Write-Host "FAIL: produced binary stdout does not contain expected addition output '$expectedAddition' (this proves the Nim archive's nimAdd symbol is linked AND callable from Rust)"
  exit 1
}
if ($output -notmatch [regex]::Escape($expectedGreeting)) {
  Write-Host "FAIL: produced binary stdout does not contain expected greeting '$expectedGreeting'"
  exit 1
}

Write-Host ""
Write-Host "PASS: mixed/rust-uses-nim-lib built via standard provider; cross-language call from Rust to Nim nimAdd produced 2 + 3 = 5; libnimaddlib.a archive produced (with --noMain via cConsumable flag derived from depends_on edge)"
exit 0
