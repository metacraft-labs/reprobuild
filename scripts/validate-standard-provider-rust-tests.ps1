#requires -Version 5
# End-to-end M22 verification: build the rust/library-with-tests
# ``#test`` target via the Tier 2b dispatch path and assert the
# per-integration-test ``rustc --test`` compile + run pair executes
# successfully.
#
# **Scope at M22 (Part B)**: the Rust convention discovers every
# ``tests/<name>.rs`` integration test (reported by ``cargo metadata``
# as ``kind=["test"]``) and emits one ``rustc --test`` compile action
# producing the test harness binary, then a run action that invokes it.
# A ``fs.stamp`` companion fires after the run for cache-invalidation.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\rust\library-with-tests'
$scratchInsideFixture = Join-Path $fixture '.repro'
$crateScratch   = Join-Path $fixture '.repro\build\rust_library_with_tests_example'
$testsDir       = Join-Path $crateScratch 'tests'

# --- ensure rustc/cargo available (mirror the M9 harness probe) ---
$rustc = Get-Command rustc -ErrorAction SilentlyContinue
$cargo = Get-Command cargo -ErrorAction SilentlyContinue
if (-not $rustc -or -not $cargo) {
  $rustupStableBin = 'D:\metacraft-dev-deps\rustup\toolchains\stable-x86_64-pc-windows-msvc\bin'
  if (Test-Path -LiteralPath (Join-Path $rustupStableBin 'rustc.exe')) {
    $env:PATH = "$rustupStableBin;$env:PATH"
    $rustc = Get-Command rustc -ErrorAction SilentlyContinue
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
  }
}
if (-not $rustc -or -not $cargo) {
  Write-Host "SKIP: rustc/cargo not on PATH; M22 Rust test-target gate skipped."
  exit 0
}
Write-Host "rustc = $($rustc.Source)"
Write-Host "cargo = $($cargo.Source)"

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
$testsSrcDir = Join-Path $fixture 'tests'
if (-not (Test-Path -LiteralPath $testsSrcDir)) {
  Write-Host "FAIL: fixture missing tests/ directory at $testsSrcDir"
  exit 1
}
$testFiles = @(Get-ChildItem -LiteralPath $testsSrcDir -Filter '*.rs' -ErrorAction SilentlyContinue)
if ($testFiles.Count -lt 1) {
  Write-Host "FAIL: fixture has no tests/*.rs files under $testsSrcDir"
  exit 1
}
Write-Host "discovered test files:"
foreach ($t in $testFiles) { Write-Host "  $($t.Name)" }

# --- step 1: wipe prior scratch + cargo target ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}
$cargoTarget = Join-Path $fixture 'target'
if (Test-Path -LiteralPath $cargoTarget) {
  Remove-Item -LiteralPath $cargoTarget -Recurse -Force
}

# --- step 2: invoke `repro build .#test` ---
$reproTarget = "$fixture#test"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-rust-tests.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-rust-tests.stderr.txt'
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
  Write-Host "--- repro stdout (last 40 lines):"
  Get-Content -LiteralPath $stdoutCapture -Tail 40 | ForEach-Object { Write-Host $_ }
}
if (Test-Path $stderrCapture) {
  $stderrTail = Get-Content -LiteralPath $stderrCapture -Tail 40
  if ($stderrTail) {
    Write-Host "--- repro stderr (last 40 lines):"
    foreach ($line in $stderrTail) { Write-Host $line }
  }
}

if ($exitCode -ne 0) {
  Write-Host "FAIL: repro build .#test exited with code $exitCode"
  exit 1
}

# --- step 3: assert the test harness binary + stamp exist ---
if (-not (Test-Path -LiteralPath $testsDir)) {
  Write-Host "FAIL: expected tests dir missing at $testsDir"
  exit 1
}
$binaries = @(Get-ChildItem -LiteralPath $testsDir -Filter '*.exe' -ErrorAction SilentlyContinue)
$stamps = @(Get-ChildItem -LiteralPath $testsDir -Filter '*.stamp' -ErrorAction SilentlyContinue)
Write-Host "--- artefacts under ${testsDir}:"
foreach ($b in $binaries) { Write-Host "    $($b.Name)" }
foreach ($s in $stamps)   { Write-Host "    $($s.Name)" }
if ($binaries.Count -lt 1) {
  Write-Host "FAIL: no test harness binaries produced under $testsDir"
  exit 1
}
if ($stamps.Count -lt 1) {
  Write-Host "FAIL: no *.stamp files produced under $testsDir"
  exit 1
}

# --- step 4: probe action log for the rust-test action shape ---
$logText = if (Test-Path $stdoutCapture) { Get-Content -LiteralPath $stdoutCapture -Raw } else { '' }
$hasCompile = $logText -match 'rustc-test-compile|rust\.rustc-test-compile'
$hasRun     = $logText -match 'rustc-test-run|rust\.rustc-test-run'
Write-Host "--- fragment shape probe:"
Write-Host "    rustc --test compile action: $hasCompile"
Write-Host "    test-binary run action     : $hasRun"
if (-not ($hasCompile -and $hasRun)) {
  Write-Host "FAIL: expected both compile + run actions in the action log"
  exit 1
}

Write-Host ""
Write-Host "PASS: rust/library-with-tests#test built via standard provider; $($binaries.Count) test binary/binaries + $($stamps.Count) stamp(s) produced"
exit 0
