#requires -Version 5
# End-to-end M39 verification: build the c-cpp-meson/hello-binary example
# via the Tier 2b dispatch path and run the produced executable.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so gcc/repro are on PATH.
#   2. Probe for gcc/clang, meson, and ninja. SKIP exit 0 if any
#      required tool is missing. On Windows, attempt to lift meson
#      from the managed Python's Scripts dir
#      (``D:/metacraft-dev-deps/python/3.12.10/Scripts``) when
#      ``Get-Command meson`` doesn't resolve via PATH alone — this is
#      the supported provisioning path for hosts that ``python -m pip
#      install meson`` into the managed Python.
#   3. Wipe any prior .repro/ scratch under the fixture so the build
#      runs cold.
#   4. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   5. Assert exit code 0.
#   6. Locate the produced ``hello`` (or ``hello.exe``) under
#      <fixture>/.repro/build/meson/ and run it; assert stdout contains
#      ``hello from c-cpp-meson-hello-binary``.
#
# Per reprobuild-specs/Mode3-Language-Expansion.milestones.org §M39.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\c-cpp-meson\hello-binary'
$scratchInsideFixture = Join-Path $fixture '.repro'
$expectedGreeting = 'hello from c-cpp-meson-hello-binary'

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
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'meson.build'))) {
  Write-Host "FAIL: fixture missing meson.build at $fixture"
  exit 1
}

# --- toolchain probe ---
$gcc = Get-Command gcc -ErrorAction SilentlyContinue
$clang = $null
if (-not $gcc) {
  $clang = Get-Command clang -ErrorAction SilentlyContinue
}
if (-not $gcc -and -not $clang) {
  Write-Host "SKIP: neither gcc nor clang on PATH; cannot build c-cpp-meson/hello-binary"
  exit 0
}
$mesonCmd = Get-Command meson -ErrorAction SilentlyContinue
if (-not $mesonCmd) {
  # Common provisioning path on Windows: pip-installed meson lives at
  # <managed-python>\Scripts\meson.exe. Prepend Scripts dir to PATH if
  # we find it.
  $pythonScriptsCandidates = @(
    'D:\metacraft-dev-deps\python\3.12.10\Scripts'
  )
  foreach ($d in $pythonScriptsCandidates) {
    if (Test-Path -LiteralPath (Join-Path $d 'meson.exe')) {
      if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $d })) {
        $env:PATH = "$d;$env:PATH"
      }
      $mesonCmd = Get-Command meson -ErrorAction SilentlyContinue
      break
    }
  }
}
if (-not $mesonCmd) {
  Write-Host "SKIP: 'meson' not on PATH (M39 c-cpp-meson convention needs stock meson); run 'python -m pip install meson' to provision into the managed Python's Scripts dir"
  exit 0
}
$ninjaCmd = Get-Command ninja -ErrorAction SilentlyContinue
if (-not $ninjaCmd) {
  Write-Host "SKIP: 'ninja' not on PATH (M39 c-cpp-meson convention uses meson's default ninja backend)"
  exit 0
}

if ($gcc) {
  Write-Host "==> using gcc=$($gcc.Source)"
} else {
  Write-Host "==> using clang=$($clang.Source)"
}
Write-Host "==> using meson=$($mesonCmd.Source)"
Write-Host "==> using ninja=$($ninjaCmd.Source)"

# --- step 1: clean prior scratch ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}

# --- step 2: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-c-cpp-meson-hello-binary.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-c-cpp-meson-hello-binary.stderr.txt'
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
  Join-Path $fixture '.repro\build\meson\hello.exe'
  Join-Path $fixture '.repro\build\meson\hello'
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
  $mesonBuildDir = Join-Path $scratchInsideFixture 'build\meson'
  if (Test-Path $mesonBuildDir) {
    Write-Host "--- contents of ${mesonBuildDir}:"
    Get-ChildItem -LiteralPath $mesonBuildDir -Recurse |
      ForEach-Object { Write-Host "  $($_.FullName)" }
  } else {
    Write-Host "  (no meson build dir)"
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
Write-Host "PASS: c-cpp-meson/hello-binary built via standard provider; greeting matched"
exit 0
