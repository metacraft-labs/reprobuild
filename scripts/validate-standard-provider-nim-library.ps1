#requires -Version 5
# End-to-end M12 verification: build the Nim library example via the
# Tier 2b dispatch path and assert the static archive is produced.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so nim/gcc/repro/ar are on PATH.
#   2. Assume scripts/build_apps.sh has been run; rebuilding here would
#      double-pay every other gate.
#   3. Wipe any prior .repro/build/ scratch under the fixture so the
#      build runs cold.
#   4. Invoke repro.exe build <fixture>#default --tool-provisioning=path
#      --log=actions.
#   5. Assert exit code 0.
#   6. Assert libnim_library_example.a exists under
#      <fixture>/.repro/build/nim_library_example/.
#   7. Sanity-probe the action log: at least one phase-1 nim c
#      compileOnly + one phase-2 gcc-compile + one phase-3 ar-archive
#      line must appear.
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org
# §M12 verification "e2e_nim_library_builds_via_standard_provider".

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\nim\library'
$scratchInsideFixture = Join-Path $fixture '.repro'
$entryName      = 'nim_library_example'
$expectedArchive = Join-Path $fixture (Join-Path '.repro\build' (Join-Path $entryName ("lib" + $entryName + ".a")))

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
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-nim-library.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-nim-library.stderr.txt'
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

# --- step 3: assert the archive exists ---
if (-not (Test-Path -LiteralPath $expectedArchive)) {
  Write-Host "FAIL: expected archive not found at $expectedArchive"
  Write-Host "--- contents of $scratchInsideFixture\build:"
  if (Test-Path (Join-Path $scratchInsideFixture 'build')) {
    Get-ChildItem -LiteralPath (Join-Path $scratchInsideFixture 'build') -Recurse |
      ForEach-Object { Write-Host "  $($_.FullName)" }
  } else {
    Write-Host "  (no build dir)"
  }
  exit 1
}
$archiveSize = (Get-Item $expectedArchive).Length
Write-Host "produced archive: $expectedArchive"
Write-Host "  size: $archiveSize bytes"
if ($archiveSize -lt 64) {
  Write-Host "FAIL: archive looks empty ($archiveSize bytes)"
  exit 1
}

# --- step 4: probe the action log for the three-phase shape ---
$logText = if (Test-Path $stdoutCapture) { Get-Content -LiteralPath $stdoutCapture -Raw } else { '' }
$hasPhase1 = $logText -match 'nim-c-compileonly|nim\.c\.compileOnly'
$hasPhase2 = $logText -match 'gcc-compile|nim\.c\.gcc-compile'
$hasPhase3 = $logText -match 'ar-archive|nim\.c\.ar-archive'
Write-Host "--- fragment shape probe:"
Write-Host "    phase 1 (nim c --compileOnly): $hasPhase1"
Write-Host "    phase 2 (gcc -c)             : $hasPhase2"
Write-Host "    phase 3 (ar rcs)             : $hasPhase3"
if (-not ($hasPhase1 -and $hasPhase2 -and $hasPhase3)) {
  Write-Host "FAIL: expected all three phases in the action log; see $stdoutCapture"
  exit 1
}

Write-Host ""
Write-Host "PASS: nim/library built via standard provider; static archive produced"
exit 0
