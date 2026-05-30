#requires -Version 5
# End-to-end M62 verification: build the elixir-mix/hello-binary
# example via the Tier 2b dispatch path and run the produced launcher.
#
# **Campaign-closing milestone** (M49-M62 Provisioning & Languages
# Expansion). Mirrors the M61 erlang-rebar3 validate script structure.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so repro.exe is on PATH.
#   2. Probe for ``elixir`` AND ``mix`` AND ``escript``. SKIP exit 0
#      if any missing.
#   3. Wipe any prior .repro/ + _build/ + ./hello scratch under the
#      fixture so the build runs cold.
#   4. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   5. Assert exit code 0.
#   6. Run the produced ``hello.cmd`` wrapper and assert stdout
#      contains ``hello from elixir-mix-hello-binary``.
#
# Per reprobuild-specs/Provisioning-And-Languages-Expansion.milestones.org §M62.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\elixir-mix\hello-binary'
$scratchInsideFixture = Join-Path $fixture '.repro'
$mixBuildDir    = Join-Path $fixture '_build'
$producedEscript = Join-Path $fixture 'hello'
$expectedGreeting = 'hello from elixir-mix-hello-binary'

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
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'mix.exs'))) {
  Write-Host "FAIL: fixture missing mix.exs at $fixture"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'mix.lock'))) {
  Write-Host "FAIL: fixture missing mix.lock at $fixture"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'lib\hello.ex'))) {
  Write-Host "FAIL: fixture missing lib\hello.ex at $fixture"
  exit 1
}

# --- toolchain probe ---
$elixirCmd = Get-Command elixir -ErrorAction SilentlyContinue
if (-not $elixirCmd) {
  Write-Host "SKIP: 'elixir' not on PATH (M62 elixir-mix convention needs Elixir; install via 'scoop install elixir' on Windows or download from https://github.com/elixir-lang/elixir/releases)"
  exit 0
}
$mixCmd = Get-Command mix -ErrorAction SilentlyContinue
if (-not $mixCmd) {
  Write-Host "SKIP: 'mix' not on PATH (M62 elixir-mix convention needs mix; mix is bundled with Elixir)"
  exit 0
}
$escriptCmd = Get-Command escript -ErrorAction SilentlyContinue
if (-not $escriptCmd) {
  Write-Host "SKIP: 'escript' not on PATH (M62 elixir-mix wrapper runs 'escript <bin>'; escript ships with Erlang/OTP)"
  exit 0
}

Write-Host "==> using elixir=$($elixirCmd.Source)"
Write-Host "==> using mix=$($mixCmd.Source)"
Write-Host "==> using escript=$($escriptCmd.Source)"

# --- step 1: clean prior scratch dirs ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}
if (Test-Path -LiteralPath $mixBuildDir) {
  Write-Host "wiping prior mix build dir $mixBuildDir"
  Remove-Item -LiteralPath $mixBuildDir -Recurse -Force
}
if (Test-Path -LiteralPath $producedEscript) {
  Write-Host "wiping prior escript $producedEscript"
  Remove-Item -LiteralPath $producedEscript -Force
}

# --- step 2: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-elixir-mix-hello-binary.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-elixir-mix-hello-binary.stderr.txt'
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
  if (Test-Path -LiteralPath $producedEscript) {
    Write-Host "--- escript exists at $producedEscript ($(Get-Item $producedEscript).Length bytes)"
  } else {
    Write-Host "--- escript NOT produced at $producedEscript"
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
Write-Host "PASS: elixir-mix/hello-binary built via standard provider; greeting matched (M62 — campaign-closing milestone)"
exit 0
