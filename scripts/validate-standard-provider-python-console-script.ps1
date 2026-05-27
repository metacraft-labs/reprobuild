#requires -Version 5
# End-to-end M20 verification: build the Python console-script example
# via the Tier 2b dispatch path and assert the produced runnable
# launcher (``<install>/Scripts/<name>.exe`` on Windows;
# ``<install>/bin/<name>`` on POSIX) executes ``cli.main()`` and prints
# the expected greeting.
#
# **Scope at M20**: the Python convention's A5 sub-graph now lands an
# ``installer``-based unpack action after the wheel-build action; this
# materialises the wheel into a per-member ``install/`` tree with the
# console-script launcher under ``Scripts/``. The launcher's bundled
# ``__main__.py`` carries a monkey-patched preamble that prepends
# ``<install>/site/`` to ``sys.path`` so the produced binary runs
# without any caller-supplied ``PYTHONPATH``.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1.
#   2. Probe for python3 / python; SKIP cleanly if neither resolves.
#   3. Wipe any prior .repro/build/ scratch under the fixture.
#   4. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   5. Assert exit code 0.
#   6. Locate the wheel and confirm ``entry_points.txt`` declares the
#      ``[console_scripts]`` binding (back-compat with the M15 partial
#      surface — preserves the regression signal if A5 ships but the
#      wheel itself drops the entry-point metadata).
#   7. Locate the produced launcher at
#      ``<install>/Scripts/<name>.exe`` (Windows) /
#      ``<install>/bin/<name>`` (POSIX) and run it; assert exit 0 + the
#      expected greeting on stdout. THIS is the M20 graduation criterion.
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org §M20
# verification "e2e_python_console_script_shim_runs".

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
$expectedInstallDir = Join-Path $fixture (Join-Path '.repro\build' (Join-Path $memberDir 'install'))
# The launcher script name comes verbatim from pyproject.toml's
# [project.scripts] key (``python-console-script``). On Windows the
# installer appends ``.exe``; on POSIX the bare name is used.
$launcherName = 'python-console-script'
if ($IsWindows -or $env:OS -eq 'Windows_NT') {
  $expectedShimPath = Join-Path $expectedInstallDir (Join-Path 'Scripts' ($launcherName + '.exe'))
} else {
  $expectedShimPath = Join-Path $expectedInstallDir (Join-Path 'bin' $launcherName)
}
$expectedGreeting = 'hello from python-console-script'

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
  Write-Host "SKIP: neither 'python3' nor 'python' available on PATH. M20 e2e gate skipped."
  exit 0
}
Write-Host "python = $($pythonCmd.Source)"
& $pythonCmd.Source --version

# --- ensure `installer` is importable ---
# M20 A5 depends on the PyPA ``installer`` package being importable from
# the bundled Python. The convention's hook script imports
# ``installer``; if it's not on the interpreter's sys.path the action
# fails at build time with ``ModuleNotFoundError``.
& $pythonCmd.Source -c "import installer" 2>$null
if ($LASTEXITCODE -ne 0) {
  Write-Host "SKIP: 'installer' python package not importable from $($pythonCmd.Source); install via 'python3 -m pip install installer' or rely on the catalog entry. M20 e2e gate skipped."
  exit 0
}

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
# rather than installing or unpacking the wheel. M15 PASS-partial gate
# retained as a back-compat sanity check: if A5 silently produces a shim
# but the wheel's entry_points.txt is dropped, this step catches the
# regression before the launcher-runs step potentially fakes success
# with a stale shim.
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

# --- step 5: M20 — verify the produced shim runs ---
if (-not (Test-Path -LiteralPath $expectedInstallDir)) {
  Write-Host "FAIL: expected install dir missing at $expectedInstallDir"
  Write-Host "--- contents of fixture scratch:"
  Get-ChildItem -LiteralPath (Join-Path $fixture '.repro\build') -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 30 | ForEach-Object { Write-Host "  $($_.FullName)" }
  exit 1
}
if (-not (Test-Path -LiteralPath $expectedShimPath)) {
  Write-Host "FAIL: expected shim missing at $expectedShimPath"
  Write-Host "--- contents of install dir:"
  Get-ChildItem -LiteralPath $expectedInstallDir -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "  $($_.FullName)" }
  exit 1
}
$shimItem = Get-Item -LiteralPath $expectedShimPath
if ($shimItem.Length -le 0) {
  Write-Host "FAIL: produced shim $expectedShimPath is empty"
  exit 1
}
Write-Host "produced shim: $expectedShimPath ($($shimItem.Length) bytes)"

Write-Host "==> launching shim: $expectedShimPath"
$shimOutput = & $expectedShimPath 2>&1
$shimExit = $LASTEXITCODE
$shimText = ($shimOutput | Out-String).Trim()
Write-Host "--- shim exit: $shimExit"
Write-Host "--- shim output: $shimText"
if ($shimExit -ne 0) {
  Write-Host "FAIL: shim exited $shimExit (expected 0)"
  exit 1
}
if ($shimText -notmatch [regex]::Escape($expectedGreeting)) {
  Write-Host "FAIL: shim stdout missing expected greeting '$expectedGreeting'; got: '$shimText'"
  exit 1
}
Write-Host "shim runs and prints '$expectedGreeting'"

Write-Host ""
Write-Host "PASS - shim runs: python/console-script built via standard provider; wheel produced, console-script launcher emitted, and the launcher executes the declared entry-point."
exit 0
