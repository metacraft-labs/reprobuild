#requires -Version 5
# End-to-end M22 verification: build the go/library-with-tests
# ``#test`` target via the Tier 2b dispatch path and assert the
# per-package ``go test -count=1 <importPath>`` action executes
# successfully.
#
# **Scope at M22 (Part C)**: the Go convention discovers every
# package shipping ``*_test.go`` files (reported by ``go list``'s
# ``TestGoFiles`` / ``XTestGoFiles`` arrays) and emits one ``go test``
# action per package, paired with an ``fs.stamp`` companion that marks
# success under ``<scratch>/<projectEntry>/tests/<sanitized>.stamp``.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\go\library-with-tests'
$scratchInsideFixture = Join-Path $fixture '.repro'
$entry          = 'go_library_with_tests_example'
$testsDir       = Join-Path $fixture (Join-Path '.repro\build' (Join-Path $entry 'tests'))

# --- ensure go available (mirror the M9 harness probe) ---
$goCmd = Get-Command go -ErrorAction SilentlyContinue
if (-not $goCmd) {
  $goRoot = 'D:/metacraft-dev-deps/go'
  $candidates = @()
  if (Test-Path -LiteralPath $goRoot) {
    foreach ($verDir in Get-ChildItem -LiteralPath $goRoot -Directory -ErrorAction SilentlyContinue) {
      $candidate = Join-Path $verDir.FullName 'go\bin\go.exe'
      if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
    }
  }
  if ($candidates.Count -gt 0) {
    $picked = $candidates | Sort-Object | Select-Object -Last 1
    $binDir = Split-Path -Parent $picked
    $env:PATH = "$binDir;$env:PATH"
    $goCmd = Get-Command go -ErrorAction SilentlyContinue
  }
}
if (-not $goCmd) {
  Write-Host "SKIP: 'go' not available. M22 Go test-target gate skipped."
  exit 0
}
Write-Host "go = $($goCmd.Source)"

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
$testFiles = @(Get-ChildItem -LiteralPath $fixture -Filter '*_test.go' -ErrorAction SilentlyContinue)
if ($testFiles.Count -lt 1) {
  Write-Host "FAIL: fixture has no *_test.go files at $fixture"
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
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-go-tests.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-go-tests.stderr.txt'
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
if (-not (Test-Path -LiteralPath $testsDir)) {
  Write-Host "FAIL: expected tests dir missing at $testsDir"
  exit 1
}
$stamps = @(Get-ChildItem -LiteralPath $testsDir -Filter '*.stamp' -ErrorAction SilentlyContinue)
Write-Host "--- stamps produced under ${testsDir}:"
foreach ($s in $stamps) { Write-Host "    $($s.Name)" }
if ($stamps.Count -lt 1) {
  Write-Host "FAIL: no *.stamp files produced under $testsDir"
  exit 1
}

# --- step 4: probe action log for the go-test action shape ---
$logText = if (Test-Path $stdoutCapture) { Get-Content -LiteralPath $stdoutCapture -Raw } else { '' }
$hasTest = $logText -match 'go-test-run|go\.test-run'
Write-Host "--- fragment shape probe:"
Write-Host "    go test run action: $hasTest"
if (-not $hasTest) {
  Write-Host "FAIL: expected at least one go-test-run action in the action log"
  exit 1
}

Write-Host ""
Write-Host "PASS: go/library-with-tests#test built via standard provider; $($stamps.Count) stamp(s) produced"
exit 0
