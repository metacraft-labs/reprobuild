#requires -Version 5
# End-to-end M46 verification: build the ocaml-dune/hello-binary
# example via the Tier 2b dispatch path and run the produced binary.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so repro.exe is on PATH.
#   2. Probe for ocaml AND dune. SKIP exit 0 if either is missing. On
#      Windows, attempt to lift them from a managed install under
#      ``D:/metacraft-dev-deps/opam/`` when ``Get-Command`` doesn't
#      resolve via PATH alone — this is the documented provisioning
#      path (download OPAM Windows from ocaml.org into
#      ``D:/metacraft-dev-deps/opam/`` and then ``opam install dune``).
#   3. Wipe any prior .repro/ scratch AND ``_build/`` dir under the
#      fixture so the build runs cold.
#   4. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   5. Assert exit code 0.
#   6. Locate the produced ``_build/default/hello.exe`` and run it;
#      assert stdout contains ``hello from ocaml-dune-hello-binary``.
#
# Per reprobuild-specs/Mode3-Language-Expansion.milestones.org §M46.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\ocaml-dune\hello-binary'
$scratchInsideFixture = Join-Path $fixture '.repro'
$buildInsideFixture   = Join-Path $fixture '_build'
$expectedGreeting = 'hello from ocaml-dune-hello-binary'

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
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'dune-project'))) {
  Write-Host "FAIL: fixture missing dune-project at $fixture"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'dune'))) {
  Write-Host "FAIL: fixture missing root dune file at $fixture"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'hello.ml'))) {
  Write-Host "FAIL: fixture missing hello.ml at $fixture"
  exit 1
}

# --- toolchain probe ---
# Try to lift a managed opam switch into PATH when ocaml/dune don't
# resolve directly. The dev-deps tree may carry one or more opam
# installs as subdirs (e.g. ``D:\metacraft-dev-deps\opam\<switch>\``);
# look under ``<switch>\bin\ocaml.exe`` (the standard opam switch
# layout). Both ``ocaml`` and ``dune`` are required for the convention.
function Try-LiftOpamSwitch {
  $opamRoot = 'D:\metacraft-dev-deps\opam'
  if (-not (Test-Path -LiteralPath $opamRoot)) { return }
  $candidates = @()
  foreach ($entry in Get-ChildItem -LiteralPath $opamRoot -Directory -ErrorAction SilentlyContinue) {
    foreach ($candidate in @(
      (Join-Path $entry.FullName 'bin\ocaml.exe'),
      (Join-Path $entry.FullName 'usr\bin\ocaml.exe'))) {
      if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
    }
  }
  if ($candidates.Count -gt 0) {
    $picked = $candidates | Sort-Object | Select-Object -Last 1
    $binDir = Split-Path -Parent $picked
    if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
      $env:PATH = "$binDir;$env:PATH"
    }
  }
}

$ocamlCmd = Get-Command ocaml -ErrorAction SilentlyContinue
$duneCmd = Get-Command dune -ErrorAction SilentlyContinue
if (-not $ocamlCmd -or -not $duneCmd) {
  Try-LiftOpamSwitch
  $ocamlCmd = Get-Command ocaml -ErrorAction SilentlyContinue
  $duneCmd = Get-Command dune -ErrorAction SilentlyContinue
}
if (-not $ocamlCmd) {
  Write-Host "SKIP: 'ocaml' not on PATH (M46 ocaml-dune convention needs the OCaml toolchain; install OPAM Windows from ocaml.org into D:/metacraft-dev-deps/opam/ and then 'opam install dune')"
  exit 0
}
if (-not $duneCmd) {
  Write-Host "SKIP: 'dune' not on PATH (M46 ocaml-dune convention needs the Dune build system; install via 'opam install dune' after OPAM init)"
  exit 0
}

Write-Host "==> using ocaml=$($ocamlCmd.Source)"
Write-Host "==> using dune=$($duneCmd.Source)"

# --- step 1: clean prior scratch + _build dir ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}
if (Test-Path -LiteralPath $buildInsideFixture) {
  Write-Host "wiping prior Dune _build dir $buildInsideFixture"
  Remove-Item -LiteralPath $buildInsideFixture -Recurse -Force
}

# --- step 2: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-ocaml-dune-hello-binary.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-ocaml-dune-hello-binary.stderr.txt'
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
# Try ``_build/default/hello.exe`` first (the M46-predicted path); fall
# back to walking ``_build/`` for the ``hello.exe`` binary as a defensive
# secondary lookup (Dune may stage the binary under a triple-specific
# subdir on some host shapes).
$exeName = 'hello.exe'
$producedExe = Join-Path $fixture ('_build\default\' + $exeName)
if (-not (Test-Path -LiteralPath $producedExe)) {
  # Walk _build for the produced binary as a fallback.
  $candidates = Get-ChildItem -LiteralPath $buildInsideFixture -Filter $exeName -Recurse -ErrorAction SilentlyContinue
  if ($candidates -and $candidates.Count -gt 0) {
    $producedExe = $candidates[0].FullName
  }
}
if (-not (Test-Path -LiteralPath $producedExe)) {
  Write-Host "FAIL: expected exe not found at $producedExe"
  if (Test-Path $buildInsideFixture) {
    Write-Host "--- contents of ${buildInsideFixture}:"
    Get-ChildItem -LiteralPath $buildInsideFixture -Recurse |
      ForEach-Object { Write-Host "  $($_.FullName)" }
  } else {
    Write-Host "  (no Dune _build dir)"
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
Write-Host "PASS: ocaml-dune/hello-binary built via standard provider; greeting matched"
exit 0
