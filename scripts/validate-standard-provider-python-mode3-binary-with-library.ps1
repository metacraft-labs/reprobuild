#requires -Version 5
# End-to-end verification: build the python-mode3/binary-with-library
# fixture via the Tier 2b dispatch path and run the produced wrapper
# script.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so nim/python/repro are on PATH.
#   2. Probe for python3/python; SKIP exit 0 if neither is available.
#   3. Wipe any prior .repro/ scratch under the fixture so the build
#      runs cold.
#   4. Verify `repro deps refresh --check` exits 0 (the checked-in
#      ``repro.scanned-deps.nim`` matches the source tree).
#   5. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   6. Assert exit code 0.
#   7. Locate the produced wrapper at
#      <fixture>/.repro/build/calc/calc[.cmd] and run it; assert
#      stdout contains
#      ``hello from python-mode3-binary-with-library, mathlib added 2+3 = 5``.
#   8. Also verify the upstream staged ``mathlib/__init__.py`` was
#      produced alongside.
#
# Mode 3 Python contract (M32 of Mode3-Language-Expansion.milestones.org):
# the convention emits the library stage + byte-compile action FIRST
# (sequenced via depends_on calcPkg: mathlibPkg) and the executable's
# wrapper script PYTHONPATH carries the mathlib staging dir so
# ``from mathlib import add`` in calc/calc/__main__.py resolves at
# runtime. This script is the load-bearing end-to-end gate that turns
# the convention's action graph into a working wrapper script.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\python-mode3\binary-with-library'
$scratchInsideFixture = Join-Path $fixture '.repro'
$memberName     = 'calc'
$stagedInit     = Join-Path $fixture '.repro\build\mathlib\mathlib\__init__.py'
$expectedGreeting = 'hello from python-mode3-binary-with-library, mathlib added 2+3 = 5'

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
$pythonCmd = $null
foreach ($n in @('python3', 'python')) {
  $candidate = Get-Command $n -ErrorAction SilentlyContinue
  if ($candidate) {
    & $candidate.Source --version 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
      $pythonCmd = $candidate
      break
    }
  }
}
if (-not $pythonCmd) {
  Write-Host "SKIP: neither python3 nor python on PATH (env.ps1 should provide the managed install)"
  exit 0
}
Write-Host "==> using python=$($pythonCmd.Source)"

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
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-python-mode3-binary-with-library.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-python-mode3-binary-with-library.stderr.txt'
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

# --- step 4: verify staged library init exists ---
if (-not (Test-Path -LiteralPath $stagedInit)) {
  Write-Host "FAIL: expected staged library __init__.py not found at $stagedInit"
  exit 1
}
Write-Host "produced staged mathlib init: $stagedInit ($((Get-Item $stagedInit).Length) bytes)"

# --- step 5: locate produced wrapper ---
$candidates = @(
  Join-Path $fixture (Join-Path '.repro\build' (Join-Path $memberName ($memberName + '.cmd')))
  Join-Path $fixture (Join-Path '.repro\build' (Join-Path $memberName $memberName))
)
$producedWrapper = $null
foreach ($candidate in $candidates) {
  if (Test-Path -LiteralPath $candidate) {
    $producedWrapper = $candidate
    break
  }
}
if (-not $producedWrapper) {
  Write-Host "FAIL: expected wrapper not found at any of:"
  foreach ($c in $candidates) { Write-Host "    $c" }
  exit 1
}
Write-Host "produced wrapper: $producedWrapper ($((Get-Item $producedWrapper).Length) bytes)"

# --- step 6: run and assert greeting ---
Write-Host "==> running $producedWrapper"
$output = & $producedWrapper 2>&1 | Out-String
$runExit = $LASTEXITCODE
Write-Host "--- wrapper exit code: $runExit"
Write-Host "--- wrapper stdout:"
Write-Host $output

if ($runExit -ne 0) {
  Write-Host "FAIL: produced wrapper exited with code $runExit"
  exit 1
}
if ($output -notmatch [regex]::Escape($expectedGreeting)) {
  Write-Host "FAIL: produced wrapper stdout does not contain expected greeting '$expectedGreeting'"
  exit 1
}

Write-Host ""
Write-Host "PASS: python-mode3/binary-with-library built via standard provider; greeting matched; staged mathlib init produced"
exit 0
