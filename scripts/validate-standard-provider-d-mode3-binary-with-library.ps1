#requires -Version 5
# End-to-end verification: build the d-mode3/binary-with-library
# fixture via the Tier 2b dispatch path and run the produced executable.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so the host toolchain is on PATH.
#   2. Probe for a D compiler (ldmd2/dmd/ldc2 on PATH or under
#      D:/metacraft-dev-deps/ldc/<v>/); SKIP exit 0 if missing.
#   3. Wipe any prior .repro/ scratch under the fixture so the build
#      runs cold.
#   4. Verify ``repro deps refresh --check`` exits 0.
#   5. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   6. Assert exit code 0.
#   7. Locate the produced ``dcalc[.exe]`` under
#      <fixture>/.repro/build/dcalc/ and run it; assert stdout
#      contains the expected greeting.
#   8. Also verify the upstream library archive ``libdlib.a`` was
#      produced.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\d-mode3\binary-with-library'
$scratchInsideFixture = Join-Path $fixture '.repro'
$memberName     = 'dcalc'
$libArchive     = Join-Path $fixture '.repro\build\dlib\libdlib.a'
$expectedGreeting = 'hello from d-mode3-binary-with-library, dlib added 2+3 = 5'

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
# Preferred order: ldmd2 (avoids LDC's ldc2 host-CPU detection crash
# on some recent AMD CPUs), then dmd, then ldc2. Fall back to the
# bundled LDC under D:/metacraft-dev-deps/ldc/<v>/.
$dCompiler = Get-Command ldmd2 -ErrorAction SilentlyContinue
if (-not $dCompiler) { $dCompiler = Get-Command dmd -ErrorAction SilentlyContinue }
if (-not $dCompiler) { $dCompiler = Get-Command ldc2 -ErrorAction SilentlyContinue }
if (-not $dCompiler) {
  $ldcRoot = 'D:\metacraft-dev-deps\ldc'
  if (Test-Path -LiteralPath $ldcRoot) {
    foreach ($verDir in Get-ChildItem -LiteralPath $ldcRoot -Directory -ErrorAction SilentlyContinue) {
      foreach ($inner in Get-ChildItem -LiteralPath $verDir.FullName -Directory -ErrorAction SilentlyContinue) {
        $candidate = Join-Path $inner.FullName 'bin\ldmd2.exe'
        if (Test-Path -LiteralPath $candidate) {
          $binDir = Split-Path -Parent $candidate
          $env:PATH = "$binDir;$env:PATH"
          $dCompiler = Get-Command ldmd2 -ErrorAction SilentlyContinue
          break
        }
      }
      if ($dCompiler) { break }
    }
  }
}
if (-not $dCompiler) {
  Write-Host "SKIP: no D compiler (ldmd2/dmd/ldc2) on PATH and not under D:/metacraft-dev-deps/ldc/ (download LDC from github.com/ldc-developers/ldc/releases)"
  exit 0
}
Write-Host "==> using D compiler=$($dCompiler.Source)"

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
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-d-mode3-binary-with-library.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-d-mode3-binary-with-library.stderr.txt'
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

# --- step 4: verify archive exists ---
if (-not (Test-Path -LiteralPath $libArchive)) {
  Write-Host "FAIL: expected library archive not found at $libArchive"
  exit 1
}
Write-Host "produced archive: $libArchive ($((Get-Item $libArchive).Length) bytes)"

# --- step 5: locate produced binary ---
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
  exit 1
}
Write-Host "produced binary: $producedBinary ($((Get-Item $producedBinary).Length) bytes)"

# --- step 6: run and assert greeting ---
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
Write-Host "PASS: d-mode3/binary-with-library built via standard provider; greeting matched; libdlib.a produced"
exit 0
