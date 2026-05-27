#requires -Version 5
# End-to-end M13 verification: build the Rust library example via the
# Tier 2b dispatch path and assert the produced rlib exists.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so the managed nim/gcc/repro tools are
#      on PATH. The dev shell does NOT (yet) provision rustc/cargo; fall
#      back to the rustup stable toolchain under
#      D:/metacraft-dev-deps/rustup/toolchains.
#   2. Wipe any prior .repro/build/ scratch under the fixture so the
#      build runs cold.
#   3. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   4. Assert exit code 0.
#   5. Locate the produced rlib under <fixture>/.repro/build/<crate>/bin/
#      and confirm it exists. No "runnable binary" check — a static
#      library archive isn't an executable.
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org
# §M13 verification "e2e_rust_library_builds_via_standard_provider".

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\rust\library'
$scratchInsideFixture = Join-Path $fixture '.repro'
$crateName      = 'rust_library_example'
# The Rust convention emits ``lib<crateName>-<stableHash>.rlib`` under
# ``<fixture>/.repro/build/<crateName>/bin/``. The hash is derived from
# ``<crateName>@<edition>`` and is stable across runs, but we glob for
# the rlib rather than hard-coding the hash so future edition bumps
# don't silently desync the test.
$expectedBinDir = Join-Path $fixture (Join-Path '.repro\build' (Join-Path $crateName 'bin'))

# --- ensure rustc + cargo are available somewhere ---
$rustcCmd = Get-Command rustc -ErrorAction SilentlyContinue
$cargoCmd = Get-Command cargo -ErrorAction SilentlyContinue
if (-not $rustcCmd -or -not $cargoCmd) {
  $rustupStableBin = 'D:\metacraft-dev-deps\rustup\toolchains\stable-x86_64-pc-windows-msvc\bin'
  if (Test-Path -LiteralPath (Join-Path $rustupStableBin 'rustc.exe')) {
    Write-Host "rustc/cargo not on PATH; falling back to rustup stable at $rustupStableBin"
    $env:PATH = "$rustupStableBin;$env:PATH"
    $rustcCmd = Get-Command rustc -ErrorAction SilentlyContinue
    $cargoCmd = Get-Command cargo -ErrorAction SilentlyContinue
  }
}
if (-not $rustcCmd -or -not $cargoCmd) {
  Write-Host "SKIP: rustc/cargo not available -- the M13 e2e gate needs both on PATH."
  exit 0
}
Write-Host "rustc = $((Get-Command rustc).Source)"
Write-Host "cargo = $((Get-Command cargo).Source)"

# --- preflight ---
if (-not (Test-Path -LiteralPath $reproExe)) {
  Write-Host "FAIL: missing $reproExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath $providerExe)) {
  Write-Host "FAIL: missing $providerExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'reprobuild.nim'))) {
  Write-Host "FAIL: fixture missing at $fixture"
  exit 1
}

# --- step 1: clean prior scratch ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}
$leftoverTarget = Join-Path $fixture 'target'
if (Test-Path -LiteralPath $leftoverTarget) {
  Write-Host "wiping leftover target dir $leftoverTarget"
  Remove-Item -LiteralPath $leftoverTarget -Recurse -Force
}

# --- step 2: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-rust-library.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-rust-library.stderr.txt'
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

# --- step 3: assert the rlib exists ---
if (-not (Test-Path -LiteralPath $expectedBinDir)) {
  Write-Host "FAIL: expected bin dir not found at $expectedBinDir"
  exit 1
}
$rlibs = @(Get-ChildItem -LiteralPath $expectedBinDir -Filter "lib${crateName}-*.rlib" -ErrorAction SilentlyContinue)
if ($rlibs.Count -eq 0) {
  Write-Host "FAIL: no rlib matching 'lib${crateName}-*.rlib' under $expectedBinDir"
  Write-Host "--- contents of ${expectedBinDir}:"
  Get-ChildItem -LiteralPath $expectedBinDir -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "  $($_.Name)  $($_.Length) bytes" }
  exit 1
}
$rlib = $rlibs[0]
Write-Host "produced rlib: $($rlib.FullName)"
Write-Host "  size: $($rlib.Length) bytes"

if ($rlib.Length -le 0) {
  Write-Host "FAIL: produced rlib is empty"
  exit 1
}

Write-Host ""
Write-Host "PASS: rust/library built via standard provider; rlib produced"
exit 0
