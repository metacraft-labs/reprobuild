#requires -Version 5
# End-to-end M60 verification: build the crystal-shards/hello-binary
# example via the Tier 2b dispatch path and run the produced binary.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so repro.exe is on PATH.
#   2. Probe for both ``crystal`` AND ``shards``. SKIP exit 0 if
#      either is missing. The canonical Windows install is via scoop
#      (``scoop install crystal``) or manual download from
#      https://github.com/crystal-lang/crystal/releases. ``shards`` is
#      bundled with the Crystal distribution.
#   3. Wipe any prior .repro/ scratch under the fixture so the build
#      runs cold.
#   4. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   5. Assert exit code 0.
#   6. Run the produced ``hello[.exe]`` and assert stdout contains
#      ``hello from crystal-shards-hello-binary``.
#
# Per reprobuild-specs/Provisioning-And-Languages-Expansion.milestones.org §M60.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\crystal-shards\hello-binary'
$scratchInsideFixture = Join-Path $fixture '.repro'
$expectedGreeting = 'hello from crystal-shards-hello-binary'

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
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'shard.yml'))) {
  Write-Host "FAIL: fixture missing shard.yml at $fixture"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'shard.lock'))) {
  Write-Host "FAIL: fixture missing shard.lock at $fixture"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'src\hello.cr'))) {
  Write-Host "FAIL: fixture missing src\hello.cr at $fixture"
  exit 1
}

# --- toolchain probe ---
$crystalCmd = Get-Command crystal -ErrorAction SilentlyContinue
if (-not $crystalCmd) {
  Write-Host "SKIP: 'crystal' not on PATH (M60 crystal convention needs Crystal; install via 'scoop install crystal' on Windows or download from https://github.com/crystal-lang/crystal/releases)"
  exit 0
}
$shardsCmd = Get-Command shards -ErrorAction SilentlyContinue
if (-not $shardsCmd) {
  Write-Host "SKIP: 'shards' not on PATH (shards is bundled with the Crystal distribution; reinstall Crystal to populate shards alongside crystal)"
  exit 0
}

Write-Host "==> using crystal=$($crystalCmd.Source)"
Write-Host "==> using shards=$($shardsCmd.Source)"

# --- step 1: clean prior scratch dir ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}

# --- step 2: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-crystal-shards-hello-binary.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-crystal-shards-hello-binary.stderr.txt'
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

# --- step 3: locate produced exe ---
$exeName = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'hello.exe' } else { 'hello' }
$producedExe = Join-Path $fixture (Join-Path '.repro\build' (Join-Path 'hello' $exeName))
if (-not (Test-Path -LiteralPath $producedExe)) {
  Write-Host "FAIL: expected exe not found at $producedExe"
  $scratchDir = Join-Path $fixture '.repro\build'
  if (Test-Path $scratchDir) {
    Write-Host "--- contents of ${scratchDir}:"
    Get-ChildItem -LiteralPath $scratchDir -Recurse |
      ForEach-Object { Write-Host "  $($_.FullName)" }
  }
  exit 1
}
Write-Host "produced exe: $producedExe"
Write-Host "  size: $((Get-Item $producedExe).Length) bytes"

# --- step 4: run exe and assert greeting ---
Write-Host "==> running $producedExe"
$output = & $producedExe 2>&1 | Out-String
$runExit = $LASTEXITCODE
Write-Host "--- exe exit code: $runExit"
Write-Host "--- exe stdout:"
Write-Host $output

if ($runExit -ne 0) {
  Write-Host "FAIL: produced exe exited with code $runExit"
  exit 1
}
if ($output -notmatch [regex]::Escape($expectedGreeting)) {
  Write-Host "FAIL: produced exe stdout does not contain expected greeting '$expectedGreeting'"
  exit 1
}

Write-Host ""
Write-Host "PASS: crystal-shards/hello-binary built via standard provider; greeting matched"
exit 0
