#requires -Version 5
# End-to-end M15 verification: build the Python console-script example
# via the Tier 2b dispatch path and assert the produced wheel
# (``.whl``) carries the declared ``[project.scripts]`` entry point.
#
# **Scope at M15**: the Python convention emits only the wheel-build
# action; the spec's A5 venv + ``installer`` step that materialises an
# executable launcher under ``<out>/Scripts/<name>.exe`` (Windows) is
# deferred to a follow-up milestone. Until that lands this script
# verifies only that:
#
#   1. The wheel is produced.
#   2. The wheel's ``entry_points.txt`` metadata declares the
#      ``[console_scripts]`` ``python-console-script = ...`` line from
#      ``pyproject.toml``'s ``[project.scripts]`` block. That's the only
#      runtime evidence we have today that the console-script surface
#      survived the Mode A wheel build.
#
# Once Action 2 (wrapper emission) lands the script will additionally
# invoke the launcher and assert its stdout.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1.
#   2. Probe for python3 / python; SKIP cleanly if neither resolves.
#   3. Wipe any prior .repro/build/ scratch under the fixture.
#   4. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   5. Assert exit code 0.
#   6. Locate the wheel and assert it carries the expected entry-point.
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org §M15.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\python\console-script'
$scratchInsideFixture = Join-Path $fixture '.repro'
$memberDir      = 'python_console_script'
$expectedDistDir = Join-Path $fixture (Join-Path '.repro\build' (Join-Path $memberDir 'dist'))

# --- ensure `python` is available somewhere ---
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
  Write-Host "SKIP: neither 'python3' nor 'python' available on PATH. M15 e2e gate skipped."
  exit 0
}
Write-Host "python = $($pythonCmd.Source)"
& $pythonCmd.Source --version

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

# --- step 1: clean prior scratch ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}

# --- step 2: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-python-console-script.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-python-console-script.stderr.txt'
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
  Write-Host "--- repro stdout (last 30 lines):"
  Get-Content -LiteralPath $stdoutCapture -Tail 30 | ForEach-Object { Write-Host $_ }
}
if (Test-Path $stderrCapture) {
  $stderrTail = Get-Content -LiteralPath $stderrCapture -Tail 30
  if ($stderrTail) {
    Write-Host "--- repro stderr (last 30 lines):"
    foreach ($line in $stderrTail) { Write-Host $line }
  }
}

if ($exitCode -ne 0) {
  Write-Host "FAIL: repro build exited with code $exitCode"
  exit 1
}

# --- step 3: assert wheel exists ---
if (-not (Test-Path -LiteralPath $expectedDistDir)) {
  Write-Host "FAIL: expected dist dir not found at $expectedDistDir"
  exit 1
}
$wheels = @(Get-ChildItem -LiteralPath $expectedDistDir -Filter '*.whl' -ErrorAction SilentlyContinue)
if ($wheels.Count -eq 0) {
  Write-Host "FAIL: no .whl under $expectedDistDir"
  Write-Host "--- contents of ${expectedDistDir}:"
  Get-ChildItem -LiteralPath $expectedDistDir -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "  $($_.Name)  $($_.Length) bytes" }
  exit 1
}
$wheel = $wheels[0]
if ($wheel.Length -le 0) {
  Write-Host "FAIL: produced wheel $($wheel.FullName) is empty"
  exit 1
}
Write-Host "produced wheel: $($wheel.FullName) ($($wheel.Length) bytes)"

# --- step 4: verify the wheel carries the console-script entry-point ---
# Read entry_points.txt out of the wheel using the stdlib zipfile module
# rather than installing or unpacking the wheel.
$probe = @"
import sys, zipfile
wheel_path = sys.argv[1]
with zipfile.ZipFile(wheel_path) as zf:
    for name in zf.namelist():
        if name.endswith('entry_points.txt'):
            text = zf.read(name).decode('utf-8')
            print('ENTRY_POINTS_TXT_START')
            print(text)
            print('ENTRY_POINTS_TXT_END')
            sys.exit(0)
print('NO_ENTRY_POINTS_TXT')
sys.exit(2)
"@
$entryOutput = & $pythonCmd.Source -c $probe $wheel.FullName 2>&1
$entryExit = $LASTEXITCODE
$entryText = ($entryOutput | Out-String)
Write-Host "--- entry_points.txt probe output:"
Write-Host $entryText
if ($entryExit -ne 0) {
  Write-Host "FAIL: wheel has no entry_points.txt (exit $entryExit)"
  exit 1
}
if ($entryText -notmatch 'python-console-script\s*=\s*python_console_script\.cli:main') {
  Write-Host "FAIL: entry_points.txt does not declare the expected console-script binding"
  exit 1
}
Write-Host "entry_points.txt declares the expected python-console-script binding"

Write-Host ""
Write-Host "PASS (partial): python/console-script wheel built and entry-point recorded."
Write-Host "NOTE: launcher wrapper emission (Action 2 / installer) deferred to a follow-up M."
exit 0
