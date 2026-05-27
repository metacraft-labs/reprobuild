#requires -Version 5
# End-to-end M17 verification: build the c-cpp-make/library-static
# example via the Tier 2b dispatch path, assert ``libgreet.a`` is
# produced, then link a tiny test program against it to confirm the
# archive is well-formed.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so gcc/repro are on PATH.
#   2. Probe for gcc + ar (with fallback to clang); SKIP if missing.
#   3. Wipe any prior .repro/ scratch under the fixture.
#   4. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   5. Assert exit code 0.
#   6. Locate ``libgreet.a`` under <fixture>/.repro/build/greet/.
#   7. Compile a tiny test program calling ``greet()`` against the
#      archive and run it; assert stdout contains the archive's greeting.
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org
# §M17 — landed alongside the c-cpp-make/binary E2E.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\c-cpp-make\library-static'
$scratchInsideFixture = Join-Path $fixture '.repro'
$memberName     = 'greet'
$expectedArchive = Join-Path $fixture (Join-Path '.repro\build' (Join-Path $memberName ('lib' + $memberName + '.a')))

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

# --- toolchain probe ---
$gcc = Get-Command gcc -ErrorAction SilentlyContinue
$clang = $null
if (-not $gcc) {
  $clang = Get-Command clang -ErrorAction SilentlyContinue
}
if (-not $gcc -and -not $clang) {
  Write-Host "SKIP: neither gcc nor clang on PATH"
  exit 0
}
$cc = if ($gcc) { $gcc.Source } else { $clang.Source }
Write-Host "==> using cc=$cc"

$ar = Get-Command ar -ErrorAction SilentlyContinue
if (-not $ar) {
  Write-Host "SKIP: 'ar' not on PATH"
  exit 0
}
Write-Host "==> using ar=$($ar.Source)"

# --- step 1: clean prior scratch ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}

# --- step 2: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-c-cpp-make-library-static.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-c-cpp-make-library-static.stderr.txt'
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
  Write-Host "--- repro stdout (last 15 lines):"
  Get-Content -LiteralPath $stdoutCapture -Tail 15 | ForEach-Object { Write-Host $_ }
}
if (Test-Path $stderrCapture) {
  $stderrTail = Get-Content -LiteralPath $stderrCapture -Tail 15
  if ($stderrTail) {
    Write-Host "--- repro stderr (last 15 lines):"
    foreach ($line in $stderrTail) { Write-Host $line }
  }
}

if ($exitCode -ne 0) {
  Write-Host "FAIL: repro build exited with code $exitCode"
  exit 1
}

# --- step 3: assert archive exists ---
if (-not (Test-Path -LiteralPath $expectedArchive)) {
  Write-Host "FAIL: expected archive not found at $expectedArchive"
  Write-Host "--- contents of $scratchInsideFixture\build:"
  if (Test-Path (Join-Path $scratchInsideFixture 'build')) {
    Get-ChildItem -LiteralPath (Join-Path $scratchInsideFixture 'build') -Recurse |
      ForEach-Object { Write-Host "  $($_.FullName)" }
  }
  exit 1
}
Write-Host "produced archive: $expectedArchive"
Write-Host "  size: $((Get-Item $expectedArchive).Length) bytes"

# --- step 4: link a tiny test program against the archive ---
$testDir = Join-Path $repoRoot 'build\validate-c-cpp-make-library-static'
if (Test-Path -LiteralPath $testDir) {
  Remove-Item -LiteralPath $testDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $testDir | Out-Null

$testSourcePath = Join-Path $testDir 'use_greet.c'
$testBinaryPath = if ($IsWindows -or $env:OS -eq 'Windows_NT') {
  Join-Path $testDir 'use_greet.exe'
} else {
  Join-Path $testDir 'use_greet'
}

Set-Content -LiteralPath $testSourcePath -Value @"
#include <stdio.h>
#include "greet.h"

int main(void) {
    puts(greet());
    return 0;
}
"@

Write-Host "==> compiling test consumer use_greet.c"
$srcInclude = Join-Path $fixture 'src'
$linkArgs = @('-I', $srcInclude, '-o', $testBinaryPath, $testSourcePath, $expectedArchive)
$linkProc = Start-Process -FilePath $cc -ArgumentList $linkArgs `
  -NoNewWindow -PassThru -Wait
if ($linkProc.ExitCode -ne 0) {
  Write-Host "FAIL: linking against the archive failed (exit $($linkProc.ExitCode))"
  exit 1
}
if (-not (Test-Path -LiteralPath $testBinaryPath)) {
  Write-Host "FAIL: linker did not produce $testBinaryPath"
  exit 1
}

Write-Host "==> running $testBinaryPath"
$consumerOutput = & $testBinaryPath 2>&1 | Out-String
$consumerExit = $LASTEXITCODE
Write-Host "--- consumer exit code: $consumerExit"
Write-Host "--- consumer stdout:"
Write-Host $consumerOutput
if ($consumerExit -ne 0) {
  Write-Host "FAIL: consumer binary exited $consumerExit"
  exit 1
}
$expectedConsumerGreeting = 'hello, world'
if ($consumerOutput -notmatch [regex]::Escape($expectedConsumerGreeting)) {
  Write-Host "FAIL: consumer stdout does not contain '$expectedConsumerGreeting'"
  exit 1
}

Write-Host ""
Write-Host "PASS: c-cpp-make/library-static built; libgreet.a is well-formed"
exit 0
