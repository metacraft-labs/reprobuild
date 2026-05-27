#requires -Version 5
# End-to-end M17 verification: build the c-cpp-make/binary example via
# the Tier 2b dispatch path and run the produced executable.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so gcc/repro are on PATH.
#   2. Probe for gcc (with fallback to clang); SKIP exit 0 if neither
#      is available.
#   3. Wipe any prior .repro/ scratch under the fixture so the build
#      runs cold.
#   4. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   5. Assert exit code 0.
#   6. Locate the produced ``hello`` (or ``hello.exe``) under
#      <fixture>/.repro/build/hello/ and run it; assert stdout contains
#      ``hello from c-cpp-make-binary``.
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org
# §M17 verification "e2e_c_cpp_make_binary_builds_via_standard_provider".

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\c-cpp-make\binary'
$scratchInsideFixture = Join-Path $fixture '.repro'
$memberName     = 'hello'
$expectedGreeting = 'hello from c-cpp-make-binary'

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
  Write-Host "FAIL: fixture missing at $fixture -- expected reprobuild-examples checkout"
  exit 1
}

# --- toolchain probe ---
$gcc = Get-Command gcc -ErrorAction SilentlyContinue
$clang = $null
if (-not $gcc) {
  $clang = Get-Command clang -ErrorAction SilentlyContinue
}
if (-not $gcc -and -not $clang) {
  Write-Host "SKIP: neither gcc nor clang on PATH; cannot build c-cpp-make/binary"
  exit 0
}
if ($gcc) {
  Write-Host "==> using gcc=$($gcc.Source)"
} else {
  Write-Host "==> using clang=$($clang.Source)"
}

# --- step 1: clean prior scratch ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}

# --- step 2: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-c-cpp-make-binary.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-c-cpp-make-binary.stderr.txt'
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

# --- step 3: locate produced binary ---
$candidates = @(
  Join-Path $fixture (Join-Path '.repro\build' (Join-Path $memberName ($memberName + '.exe')))
  Join-Path $fixture (Join-Path '.repro\build' (Join-Path $memberName $memberName))
)
$producedBinary = $null
foreach ($candidate in $candidates) {
  if (Test-Path -LiteralPath $candidate) {
    $producedBinary = $candidate
    break
  }
}
if (-not $producedBinary) {
  Write-Host "FAIL: expected binary not found at any of:"
  foreach ($c in $candidates) { Write-Host "    $c" }
  Write-Host "--- contents of $scratchInsideFixture\build:"
  if (Test-Path (Join-Path $scratchInsideFixture 'build')) {
    Get-ChildItem -LiteralPath (Join-Path $scratchInsideFixture 'build') -Recurse |
      ForEach-Object { Write-Host "  $($_.FullName)" }
  } else {
    Write-Host "  (no build dir)"
  }
  exit 1
}
Write-Host "produced binary: $producedBinary"
Write-Host "  size: $((Get-Item $producedBinary).Length) bytes"

# --- step 4: run and assert greeting ---
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
if ($output -notmatch [regex]::Escape($expectedGreeting)) {
  Write-Host "FAIL: produced binary stdout does not contain expected greeting '$expectedGreeting'"
  exit 1
}

Write-Host ""
Write-Host "PASS: c-cpp-make/binary built via standard provider; greeting matched"
exit 0
