#requires -Version 5
# End-to-end M15 verification: build the Python pure-library example via
# the Tier 2b dispatch path and assert the produced wheel (``.whl``) is
# importable.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so the managed nim/gcc/repro tools and
#      the bundled python3 are on PATH.
#   2. Probe for python3 / python; SKIP cleanly if neither resolves.
#   3. Wipe any prior .repro/build/ scratch under the fixture so the
#      build runs cold.
#   4. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   5. Assert exit code 0.
#   6. Locate the produced ``.whl`` under
#      <fixture>/.repro/build/<member>/dist/ and assert it exists / is
#      non-empty.
#   7. Confirm the wheel imports and ``greet`` returns the expected
#      string by running python with the wheel path on sys.path.
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org
# §M15 verification "e2e_python_library_builds_via_standard_provider".

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\python\library-pure'
$scratchInsideFixture = Join-Path $fixture '.repro'
# The Python convention's per-member scratch dir uses the literal member
# name from reprobuild.nim — for library-pure that's the camelCase
# identifier ``pythonLibraryExample``.
$memberDir      = 'pythonLibraryExample'
$expectedDistDir = Join-Path $fixture (Join-Path '.repro\build' (Join-Path $memberDir 'dist'))

# --- ensure `python` is available somewhere ---
$pythonCmd = $null
foreach ($n in @('python3', 'python')) {
  $candidate = Get-Command $n -ErrorAction SilentlyContinue
  if ($candidate) {
    # Reject the Windows Store stub — it prints to stderr instead of
    # actually running. Probe with `--version` and check the exit code.
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
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-python-library.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-python-library.stderr.txt'
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

# --- step 4: verify the wheel imports cleanly ---
$wheelPath = $wheel.FullName
$probe = "import sys; sys.path.insert(0, r'$wheelPath'); import python_library_example; print(python_library_example.greet('test'))"
$probeOutput = & $pythonCmd.Source -c $probe 2>&1
$probeExit = $LASTEXITCODE
if ($probeExit -ne 0) {
  Write-Host "FAIL: wheel-import probe exited $probeExit"
  Write-Host "  output: $probeOutput"
  exit 1
}
$probeText = ($probeOutput | Out-String).Trim()
if ($probeText -ne 'hello, test') {
  Write-Host "FAIL: wheel imported but greet('test') returned '$probeText' (expected 'hello, test')"
  exit 1
}
Write-Host "wheel-import probe: greet('test') -> $probeText"

Write-Host ""
Write-Host "PASS: python/library-pure built via standard provider; wheel produced and imports cleanly"
exit 0
