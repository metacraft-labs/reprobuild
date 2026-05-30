#requires -Version 5
# End-to-end M61 verification: build the erlang-rebar3/hello-binary
# example via the Tier 2b dispatch path and run the produced launcher.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so repro.exe is on PATH.
#   2. Probe for ``erl`` AND ``rebar3``. SKIP exit 0 if either missing.
#   3. Wipe any prior .repro/ + _build/ scratch under the fixture so
#      the build runs cold.
#   4. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   5. Assert exit code 0.
#   6. Run the produced ``hello.cmd`` and assert stdout contains
#      ``hello from erlang-rebar3-hello-binary``.
#
# Per reprobuild-specs/Provisioning-And-Languages-Expansion.milestones.org §M61.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\erlang-rebar3\hello-binary'
$scratchInsideFixture = Join-Path $fixture '.repro'
$rebarBuildDir  = Join-Path $fixture '_build'
$expectedGreeting = 'hello from erlang-rebar3-hello-binary'

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
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'rebar.config'))) {
  Write-Host "FAIL: fixture missing rebar.config at $fixture"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'rebar.lock'))) {
  Write-Host "FAIL: fixture missing rebar.lock at $fixture"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'src\hello.erl'))) {
  Write-Host "FAIL: fixture missing src\hello.erl at $fixture"
  exit 1
}

# --- toolchain probe ---
$erlCmd = Get-Command erl -ErrorAction SilentlyContinue
if (-not $erlCmd) {
  Write-Host "SKIP: 'erl' not on PATH (M61 erlang-rebar3 convention needs Erlang; install via 'scoop install erlang' on Windows or download from https://www.erlang.org/downloads)"
  exit 0
}
$rebar3Cmd = Get-Command rebar3 -ErrorAction SilentlyContinue
if (-not $rebar3Cmd) {
  Write-Host "SKIP: 'rebar3' not on PATH (M61 erlang-rebar3 convention needs rebar3; install via 'scoop install rebar3' on Windows; rebar3 is independent of Erlang/OTP)"
  exit 0
}

Write-Host "==> using erl=$($erlCmd.Source)"
Write-Host "==> using rebar3=$($rebar3Cmd.Source)"

# --- step 1: clean prior scratch dirs ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}
if (Test-Path -LiteralPath $rebarBuildDir) {
  Write-Host "wiping prior rebar build dir $rebarBuildDir"
  Remove-Item -LiteralPath $rebarBuildDir -Recurse -Force
}

# --- step 2: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-erlang-rebar3-hello-binary.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-erlang-rebar3-hello-binary.stderr.txt'
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

# --- step 3: locate produced wrapper ---
$wrapperName = if ($IsWindows -or $env:OS -eq 'Windows_NT') { 'hello.cmd' } else { 'hello' }
$producedWrapper = Join-Path $fixture (Join-Path '.repro\build' (Join-Path 'hello' $wrapperName))
if (-not (Test-Path -LiteralPath $producedWrapper)) {
  Write-Host "FAIL: expected launcher not found at $producedWrapper"
  $scratchDir = Join-Path $fixture '.repro\build'
  if (Test-Path $scratchDir) {
    Write-Host "--- contents of ${scratchDir}:"
    Get-ChildItem -LiteralPath $scratchDir -Recurse |
      ForEach-Object { Write-Host "  $($_.FullName)" }
  }
  if (Test-Path $rebarBuildDir) {
    Write-Host "--- contents of ${rebarBuildDir}\default\bin:"
    $binDir = Join-Path $rebarBuildDir 'default\bin'
    if (Test-Path $binDir) {
      Get-ChildItem -LiteralPath $binDir -Recurse |
        ForEach-Object { Write-Host "  $($_.FullName)" }
    }
  }
  exit 1
}
Write-Host "produced wrapper: $producedWrapper"
Write-Host "  size: $((Get-Item $producedWrapper).Length) bytes"

# --- step 4: run wrapper and assert greeting ---
Write-Host "==> running $producedWrapper"
$output = & $producedWrapper 2>&1 | Out-String
$runExit = $LASTEXITCODE
Write-Host "--- wrapper exit code: $runExit"
Write-Host "--- wrapper stdout:"
Write-Host $output

if ($runExit -ne 0) {
  Write-Host "FAIL: produced wrapper exited with code $runExit"
  exit 1
}
if ($output -notmatch [regex]::Escape($expectedGreeting)) {
  Write-Host "FAIL: produced wrapper stdout does not contain expected greeting '$expectedGreeting'"
  exit 1
}

Write-Host ""
Write-Host "PASS: erlang-rebar3/hello-binary built via standard provider; greeting matched"
exit 0
