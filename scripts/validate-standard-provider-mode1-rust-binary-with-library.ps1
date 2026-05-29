#requires -Version 5
# End-to-end verification: build the mode1/rust-binary-with-library
# fixture via the M48 Mode 1 (layout-as-manifest) dispatch path.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so nim/gcc/repro are on PATH.
#   2. Probe for rustc (falling back to bundled rustup stable); SKIP
#      exit 0 if rustc is unavailable.
#   3. Wipe the fixture's `.repro/` scratch so the run is cold.
#   4. ASSERT the fixture has NO repro.nim / reprobuild.nim and NO
#      Cargo.toml / repro.scanned-deps.nim at the workspace root
#      (this is the defining property of a Mode 1 fixture).
#   5. Invoke `repro show-conventions` and confirm the
#      ``[Mode 1 — inferred from layout]`` prefix is present.
#   6. Invoke `repro build <fixture>#default --tool-provisioning=path`.
#   7. Assert exit 0.
#   8. Locate the produced `calc[.exe]` under
#      <fixture>/.repro/mode1-synth/.repro/build/calc/ and run it;
#      assert the stdout contains
#      ``hello from mode1-rust-binary-with-library, mathlib added 2+3 = 5``.
#   9. RE-ASSERT the workspace root contains NO repro.nim /
#      reprobuild.nim / repro.scanned-deps.nim after the build
#      (Mode 1 persistence policy: nothing materialized at the root).

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\mode1\rust-binary-with-library'
$scratchInsideFixture = Join-Path $fixture '.repro'
$synthDir       = Join-Path $fixture '.repro\mode1-synth'
$memberName     = 'calc'
$libArchive     = Join-Path $synthDir '.repro\build\mathlib\libmathlib.rlib'
$expectedGreeting = 'hello from mode1-rust-binary-with-library, mathlib added 2+3 = 5'

# --- preflight ---
if (-not (Test-Path -LiteralPath $reproExe)) {
  Write-Host "FAIL: missing $reproExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath $providerExe)) {
  Write-Host "FAIL: missing $providerExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath $fixture)) {
  Write-Host "FAIL: fixture missing at $fixture"
  exit 1
}

# --- Mode 1 fixture shape: NO project file, NO ecosystem manifest ---
foreach ($forbidden in @('repro.nim','reprobuild.nim','Cargo.toml','repro.scanned-deps.nim')) {
  if (Test-Path -LiteralPath (Join-Path $fixture $forbidden)) {
    Write-Host "FAIL: Mode 1 fixture invariant broken: $forbidden present at workspace root"
    exit 1
  }
}

# --- toolchain probe ---
$rustc = Get-Command rustc -ErrorAction SilentlyContinue
if (-not $rustc) {
  $rustupStableBin = 'D:\metacraft-dev-deps\rustup\toolchains\stable-x86_64-pc-windows-msvc\bin'
  if (Test-Path -LiteralPath (Join-Path $rustupStableBin 'rustc.exe')) {
    $env:PATH = "$rustupStableBin;$env:PATH"
    $rustc = Get-Command rustc -ErrorAction SilentlyContinue
  }
}
if (-not $rustc) {
  Write-Host "SKIP: rustc not on PATH and no rustup stable toolchain under D:/metacraft-dev-deps/rustup"
  exit 0
}
Write-Host "==> using rustc=$($rustc.Source)"

# --- wipe scratch ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}

# --- step 1: repro show-conventions identifies Mode 1 ---
$showCapture = Join-Path $repoRoot 'build\validate-mode1-rust.show-conventions.txt'
New-Item -ItemType Directory -Force -Path (Split-Path $showCapture) | Out-Null
& $reproExe show-conventions $fixture > $showCapture 2>&1
$showExit = $LASTEXITCODE
if ($showExit -ne 0) {
  Write-Host "FAIL: repro show-conventions exited $showExit"
  Get-Content -LiteralPath $showCapture | ForEach-Object { Write-Host $_ }
  exit 1
}
$showText = Get-Content -LiteralPath $showCapture -Raw
if ($showText -notmatch [regex]::Escape('[Mode 1 — inferred from layout]')) {
  Write-Host "FAIL: show-conventions output missing Mode 1 prefix"
  Write-Host $showText
  exit 1
}
if ($showText -notmatch 'Inferred targets') {
  Write-Host "FAIL: show-conventions output missing inferred-targets block"
  Write-Host $showText
  exit 1
}
Write-Host "==> show-conventions Mode 1 banner verified"

# --- step 2: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-mode1-rust.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-mode1-rust.stderr.txt'

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

# --- step 3: verify rlib was produced under the synth tree ---
if (-not (Test-Path -LiteralPath $libArchive)) {
  Write-Host "FAIL: expected library rlib not found at $libArchive"
  exit 1
}
Write-Host "produced rlib: $libArchive ($((Get-Item $libArchive).Length) bytes)"

# --- step 4: locate produced binary ---
$candidates = @(
  Join-Path $synthDir (Join-Path '.repro\build' (Join-Path $memberName ($memberName + '.exe')))
  Join-Path $synthDir (Join-Path '.repro\build' (Join-Path $memberName $memberName))
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

# --- step 5: run and assert greeting ---
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

# --- step 6: re-assert the workspace root remains clean ---
foreach ($forbidden in @('repro.nim','reprobuild.nim','Cargo.toml','repro.scanned-deps.nim')) {
  if (Test-Path -LiteralPath (Join-Path $fixture $forbidden)) {
    Write-Host "FAIL: Mode 1 persistence-policy violation: $forbidden materialized at workspace root after build"
    exit 1
  }
}

Write-Host ""
Write-Host "PASS: mode1/rust-binary-with-library built via Mode 1; greeting matched; persistence policy honoured"
exit 0
