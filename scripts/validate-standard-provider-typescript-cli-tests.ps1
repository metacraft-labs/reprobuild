#requires -Version 5
# End-to-end M21 verification: build the typescript-cli ``#test`` target
# via the Tier 2b dispatch path and assert the bundled node test runner
# executes and reports pass for every discovered test file.
#
# **Scope at M21 (A7)**: the JS/TS convention discovers
# ``test/**/*.test.{ts,js}`` (and ``src/**/*.test.{ts,js}``) and emits a
# single ``node --test --import=tsx <test files>`` action under a
# non-default ``test`` target.
#
# This script asserts:
#   1. ``repro build <fixture>#test`` exits 0.
#   2. The build's stderr (or stdout) reports node's test runner output
#      (TAP-style ``# pass <n>`` summary).
#
# The action has no file outputs (it's a verification action) so the
# load-bearing signal is repro's exit code combined with the test
# runner's pass count.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\javascript-typescript\typescript-cli'

# --- ensure `node` (and `npx`) is available somewhere ---
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
  $nodeRoot = 'D:\metacraft-dev-deps\node'
  if (Test-Path -LiteralPath $nodeRoot) {
    $candidates = @()
    foreach ($verDir in Get-ChildItem -LiteralPath $nodeRoot -Directory -ErrorAction SilentlyContinue) {
      foreach ($inner in Get-ChildItem -LiteralPath $verDir.FullName -Directory -ErrorAction SilentlyContinue) {
        $candidate = Join-Path $inner.FullName 'node.exe'
        if (Test-Path -LiteralPath $candidate) {
          $candidates += $candidate
        }
      }
    }
    if ($candidates.Count -gt 0) {
      $picked = $candidates | Sort-Object | Select-Object -Last 1
      $binDir = Split-Path -Parent $picked
      $env:PATH = "$binDir;$env:PATH"
      $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    }
  }
}
if (-not $nodeCmd) {
  Write-Host "SKIP: 'node' not available. M21 test-target gate skipped."
  exit 0
}
$npxCmd = Get-Command npx -ErrorAction SilentlyContinue
if (-not $npxCmd) {
  Write-Host "SKIP: 'npx' not available. M21 test-target gate skipped."
  exit 0
}
Write-Host "node = $($nodeCmd.Source)"
Write-Host "npx  = $($npxCmd.Source)"
& $nodeCmd.Source --version

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
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'package-lock.json'))) {
  Write-Host "FAIL: fixture missing package-lock.json -- run 'npm install --package-lock-only' first"
  exit 1
}
$testDir = Join-Path $fixture 'test'
if (-not (Test-Path -LiteralPath $testDir)) {
  Write-Host "FAIL: fixture missing test/ directory at $testDir"
  exit 1
}

# --- step 1: invoke `repro build .#test` ---
# Don't wipe scratch on a clean run path — the test target inherits
# the npm-ci action from the default build, so reusing the install is
# fine and skips the ~2s npm-ci hit. If a previous default build hasn't
# been run, the test target's deps include npm-ci so it'll run from
# scratch.
$reproTarget = "$fixture#test"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-typescript-cli-tests.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-typescript-cli-tests.stderr.txt'
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
  Write-Host "--- repro stdout (last 60 lines):"
  Get-Content -LiteralPath $stdoutCapture -Tail 60 | ForEach-Object { Write-Host $_ }
}
if (Test-Path $stderrCapture) {
  $stderrTail = Get-Content -LiteralPath $stderrCapture -Tail 60
  if ($stderrTail) {
    Write-Host "--- repro stderr (last 60 lines):"
    foreach ($line in $stderrTail) { Write-Host $line }
  }
}

if ($exitCode -ne 0) {
  Write-Host "FAIL: repro build .#test exited with code $exitCode"
  exit 1
}

# --- step 2: assert the test runner reported passes ---
# Node's --test default reporter (the human-readable "spec" reporter on
# modern node) emits Unicode-prefixed summary lines: ``ℹ tests 2``,
# ``ℹ pass 2``, ``ℹ fail 0``. The TAP reporter (older node, or
# ``--test-reporter=tap``) emits ``# pass 2`` / ``# fail 0`` instead.
# Accept either shape: match on the ``pass <N>`` / ``fail <N>``
# substring with leading whitespace+prefix.
$combined = ''
if (Test-Path $stdoutCapture) {
  $combined += (Get-Content -LiteralPath $stdoutCapture -Raw)
}
if (Test-Path $stderrCapture) {
  $combined += "`n" + (Get-Content -LiteralPath $stderrCapture -Raw)
}
$lines = $combined -split "`n"

$passLine = $lines | Where-Object { $_ -match 'pass\s+(\d+)' -and ($_ -match '^\s*#\s' -or $_ -match '^\s*\S\s*pass') } | Select-Object -First 1
if (-not $passLine) {
  Write-Host "FAIL: node --test pass-line not found in captured output. Tests did not execute or did not report summary."
  exit 1
}
if ($passLine -match 'pass\s+(\d+)') {
  $passCount = [int]$Matches[1]
  if ($passCount -lt 1) {
    Write-Host "FAIL: test summary reports pass=$passCount; expected >=1"
    exit 1
  }
  Write-Host "test summary: $($passLine.Trim())"
} else {
  Write-Host "FAIL: could not parse pass count from line: $passLine"
  exit 1
}

# Also check no failures.
$failLine = $lines | Where-Object { $_ -match 'fail\s+(\d+)' -and ($_ -match '^\s*#\s' -or $_ -match '^\s*\S\s*fail') } | Select-Object -First 1
if ($failLine -and $failLine -match 'fail\s+(\d+)') {
  $failCount = [int]$Matches[1]
  if ($failCount -gt 0) {
    Write-Host "FAIL: test summary reports fail=$failCount (>0)"
    exit 1
  }
  Write-Host "test summary: $($failLine.Trim())"
}

Write-Host ""
Write-Host "PASS: javascript-typescript/typescript-cli#test built via standard provider; node --test runner reported pass>=1, fail=0"
exit 0
