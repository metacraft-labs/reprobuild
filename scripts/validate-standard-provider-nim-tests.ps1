#requires -Version 5
# End-to-end M22 verification: build the nim/library-with-tests
# ``#test`` target via the Tier 2b dispatch path and assert the
# per-test ``nim c -r`` action executes successfully.
#
# **Scope at M22 (Part A)**: the Nim convention discovers
# ``tests/test_*.nim`` and emits one ``nim c -r ... <test.nim>`` action
# per file, paired with an ``fs.stamp`` companion writing
# ``<scratch>/tests/<stem>.stamp`` on success.
#
# This script asserts:
#   1. ``repro build <fixture>#test`` exits 0.
#   2. The stamp file is produced under
#      ``<fixture>/.repro/build/tests/`` for every discovered test.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\nim\library-with-tests'
$scratchInsideFixture = Join-Path $fixture '.repro'
$stampsDir      = Join-Path $fixture '.repro\build\tests'

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
$testFiles = @(Get-ChildItem -LiteralPath $testsSrcDir -Filter 'test_*.nim' -ErrorAction SilentlyContinue)
if ($testFiles.Count -lt 1) {
  Write-Host "FAIL: fixture has no tests/test_*.nim files under $testsSrcDir"
  exit 1
}
Write-Host "discovered test files:"
foreach ($t in $testFiles) { Write-Host "  $($t.Name)" }

# --- step 1: wipe prior scratch ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}

# --- step 2: invoke `repro build .#test` ---
$reproTarget = "$fixture#test"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-nim-tests.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-nim-tests.stderr.txt'
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

# --- step 3: assert at least one stamp file produced ---
if (-not (Test-Path -LiteralPath $stampsDir)) {
  Write-Host "FAIL: expected stamps dir missing at $stampsDir"
  exit 1
}
$stamps = @(Get-ChildItem -LiteralPath $stampsDir -Filter '*.stamp' -ErrorAction SilentlyContinue)
Write-Host "--- stamps produced under ${stampsDir}:"
foreach ($s in $stamps) { Write-Host "    $($s.Name)" }
if ($stamps.Count -lt 1) {
  Write-Host "FAIL: no *.stamp files produced under $stampsDir"
  exit 1
}
if ($stamps.Count -lt $testFiles.Count) {
  Write-Host "FAIL: expected $($testFiles.Count) stamp(s), found $($stamps.Count)"
  exit 1
}

# --- step 4: probe action log for the per-test action shape ---
$logText = if (Test-Path $stdoutCapture) { Get-Content -LiteralPath $stdoutCapture -Raw } else { '' }
$hasTestRun = $logText -match 'nim-test-run|nim\.c\.test-run'
Write-Host "--- fragment shape probe:"
Write-Host "    nim c -r test run action: $hasTestRun"
if (-not $hasTestRun) {
  Write-Host "FAIL: expected at least one nim-test-run action in the action log"
  exit 1
}

Write-Host ""
Write-Host "PASS: nim/library-with-tests#test built via standard provider; $($stamps.Count) stamp(s) produced"
exit 0
