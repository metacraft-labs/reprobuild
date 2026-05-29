#requires -Version 5
# End-to-end verification: build the mixed/zig-uses-cpp-lib fixture
# (M44 cross-language FORWARD direction: Zig binary -> C archive) via
# the Tier 2b dispatch path and run the produced executable.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\mixed\zig-uses-cpp-lib'
$scratchInsideFixture = Join-Path $fixture '.repro'
$memberName     = 'zigcalc'
$libArchive     = Join-Path $fixture '.repro\build\mathlib\libmathlib.a'
$expectedGreeting = 'zig says: mathlib added 2+3 = 5'

if (-not (Test-Path -LiteralPath $reproExe)) {
  Write-Host "FAIL: missing $reproExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath $providerExe)) {
  Write-Host "FAIL: missing $providerExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'repro.nim'))) {
  Write-Host "FAIL: fixture missing at $fixture"
  exit 1
}

$zig = Get-Command zig -ErrorAction SilentlyContinue
if (-not $zig) {
  $zigRoot = 'D:\metacraft-dev-deps\zig'
  if (Test-Path -LiteralPath $zigRoot) {
    foreach ($verDir in Get-ChildItem -LiteralPath $zigRoot -Directory -ErrorAction SilentlyContinue) {
      $candidate = Join-Path $verDir.FullName 'zig.exe'
      if (Test-Path -LiteralPath $candidate) {
        $binDir = Split-Path -Parent $candidate
        $env:PATH = "$binDir;$env:PATH"
        $zig = Get-Command zig -ErrorAction SilentlyContinue
        break
      }
    }
  }
}
if (-not $zig) {
  Write-Host "SKIP: 'zig' not on PATH and not under D:/metacraft-dev-deps/zig/ (M44 forward fixture needs zig)"
  exit 0
}
$gcc = Get-Command gcc -ErrorAction SilentlyContinue
if (-not $gcc) {
  Write-Host "SKIP: 'gcc' not on PATH"
  exit 0
}
$ar = Get-Command ar -ErrorAction SilentlyContinue
if (-not $ar) {
  Write-Host "SKIP: 'ar' not on PATH"
  exit 0
}
Write-Host "==> using zig=$($zig.Source)"
Write-Host "==> using gcc=$($gcc.Source)"
Write-Host "==> using ar=$($ar.Source)"

Write-Host "==> repro deps refresh --check $fixture"
& $reproExe deps refresh --check $fixture
if ($LASTEXITCODE -ne 0) {
  Write-Host "FAIL: deps refresh --check failed; repro.scanned-deps.nim is out of date"
  exit 1
}

if (Test-Path -LiteralPath $scratchInsideFixture) {
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}

$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-mixed-zig-uses-cpp-lib.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-mixed-zig-uses-cpp-lib.stderr.txt'
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
  Get-Content -LiteralPath $stdoutCapture -Tail 20 | ForEach-Object { Write-Host $_ }
}
if (Test-Path $stderrCapture) {
  $stderrTail = Get-Content -LiteralPath $stderrCapture -Tail 20
  if ($stderrTail) {
    foreach ($line in $stderrTail) { Write-Host $line }
  }
}
if ($exitCode -ne 0) {
  Write-Host "FAIL: repro build exited with code $exitCode"
  exit 1
}

if (-not (Test-Path -LiteralPath $libArchive)) {
  Write-Host "FAIL: expected library archive not found at $libArchive"
  exit 1
}

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
  Write-Host "FAIL: expected binary not found"
  exit 1
}

Write-Host "==> running $producedBinary"
$output = & $producedBinary 2>&1 | Out-String
$runExit = $LASTEXITCODE
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
Write-Host "PASS: mixed/zig-uses-cpp-lib built via standard provider; greeting matched; libmathlib.a produced"
exit 0
