#requires -Version 5
# End-to-end verification: build the mixed/ada-uses-cpp-lib fixture
# (M58 forward cross-language direction: Ada binary calling a C
# library) via the Tier 2b dispatch path and run the produced
# executable.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\mixed\ada-uses-cpp-lib'
$scratchInsideFixture = Join-Path $fixture '.repro'
$memberName     = 'adacalc'
$libArchive     = Join-Path $fixture '.repro\build\mathlib\libmathlib.a'
$expectedGreeting = 'ada says: mathlib added 2+3 = 5'

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

# --- toolchain probe (Ada + C) ---
$gnatmake = Get-Command gnatmake -ErrorAction SilentlyContinue
if (-not $gnatmake) {
  Write-Host "SKIP: 'gnatmake' not on PATH (install via 'pacman -S mingw-w64-x86_64-gcc-ada' under MSYS2; M58 forward fixture needs Ada)"
  exit 0
}
$cc = Get-Command gcc -ErrorAction SilentlyContinue
if (-not $cc) { $cc = Get-Command clang -ErrorAction SilentlyContinue }
if (-not $cc) {
  Write-Host "SKIP: neither 'gcc' nor 'clang' on PATH (M58 forward fixture needs a C compiler)"
  exit 0
}
$ar = Get-Command ar -ErrorAction SilentlyContinue
if (-not $ar) {
  Write-Host "SKIP: 'ar' not on PATH (M58 forward fixture needs an archiver)"
  exit 0
}
Write-Host "==> using gnatmake=$($gnatmake.Source); cc=$($cc.Source); ar=$($ar.Source)"

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
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-mixed-ada-uses-cpp-lib.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-mixed-ada-uses-cpp-lib.stderr.txt'
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

# --- step 4: verify upstream C archive exists ---
if (-not (Test-Path -LiteralPath $libArchive)) {
  Write-Host "FAIL: expected upstream C archive not found at $libArchive"
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
Write-Host "PASS: mixed/ada-uses-cpp-lib built; greeting matched; libmathlib.a produced; cross-lang Ada -> C round-trip"
exit 0
