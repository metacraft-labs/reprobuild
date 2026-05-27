#requires -Version 5
# End-to-end M5 verification: build the Go binary example via the
# Tier 2b dispatch path and run the produced executable.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so the managed nim/gcc/repro tools are
#      on PATH. The dev shell does NOT (yet) provision Go; if `go` is not
#      on PATH after sourcing, fall back to the Windows install under
#      D:/metacraft-dev-deps/go/<ver>/go/bin. If that's also missing the
#      script exits with SKIP=0 (informational success) so the milestone
#      gate is honest about toolchain absence.
#   2. Wipe any prior .repro/build/ scratch under the fixture so the
#      build runs cold.
#   3. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   4. Assert exit code 0.
#   5. Locate the produced binary under
#      <fixture>/.repro/build/<entry>/bin/ and run it; assert stdout
#      contains the expected greeting.
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org
# §M5 verification "e2e_go_binary_builds_via_standard_provider".

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\go\binary'
$scratchInsideFixture = Join-Path $fixture '.repro'
$entryName      = 'go_binary_example'
# The Go convention puts the executable under
# <scratch>/<entry>/bin/<entry>.exe.
$expectedBinary = Join-Path $fixture (Join-Path '.repro\build' (Join-Path $entryName (Join-Path 'bin' ($entryName + '.exe'))))
$expectedGreeting = "hello from go-binary-example"

# --- ensure `go` is available somewhere ---
$goCmd = Get-Command go -ErrorAction SilentlyContinue
if (-not $goCmd) {
  # Walk the metacraft-dev-deps Go install — the layout is
  # D:/metacraft-dev-deps/go/<version>/go/bin/go.exe.
  $goRoot = 'D:/metacraft-dev-deps/go'
  $candidates = @()
  if (Test-Path -LiteralPath $goRoot) {
    foreach ($verDir in Get-ChildItem -LiteralPath $goRoot -Directory -ErrorAction SilentlyContinue) {
      $candidate = Join-Path $verDir.FullName 'go\bin\go.exe'
      if (Test-Path -LiteralPath $candidate) {
        $candidates += $candidate
      }
    }
  }
  # Fall back to common system paths as well.
  foreach ($sys in @('D:\Program Files\Go\bin\go.exe',
                     'C:\Program Files\Go\bin\go.exe',
                     'D:\Go\bin\go.exe',
                     'C:\Go\bin\go.exe')) {
    if (Test-Path -LiteralPath $sys) {
      $candidates += $sys
    }
  }
  if ($candidates.Count -gt 0) {
    # Use the highest-versioned (last after sort) candidate; metacraft-dev-deps
    # version directories sort lexicographically — for the 1.x line that
    # matches numeric order well enough for the milestone.
    $picked = $candidates | Sort-Object | Select-Object -Last 1
    $binDir = Split-Path -Parent $picked
    Write-Host "go not on PATH; falling back to $picked"
    $env:PATH = "$binDir;$env:PATH"
    $goCmd = Get-Command go -ErrorAction SilentlyContinue
  }
}
if (-not $goCmd) {
  Write-Host "SKIP: 'go' not available on PATH and not found under D:/metacraft-dev-deps/go/. M5 e2e gate skipped."
  Write-Host "      Install Go via your distro/scoop/winget, or drop a Go install under D:/metacraft-dev-deps/go/<ver>/go/."
  exit 0
}
Write-Host "go = $((Get-Command go).Source)"
& go version

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
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-go.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-go.stderr.txt'
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

# --- step 3: assert the binary exists ---
if (-not (Test-Path -LiteralPath $expectedBinary)) {
  Write-Host "FAIL: expected binary not found at $expectedBinary"
  Write-Host "--- contents of $scratchInsideFixture\build:"
  if (Test-Path (Join-Path $scratchInsideFixture 'build')) {
    Get-ChildItem -LiteralPath (Join-Path $scratchInsideFixture 'build') -Recurse |
      ForEach-Object { Write-Host "  $($_.FullName)" }
  } else {
    Write-Host "  (no build dir)"
  }
  exit 1
}
Write-Host "produced binary: $expectedBinary"
Write-Host "  size: $((Get-Item $expectedBinary).Length) bytes"

# --- step 4: run it and assert greeting ---
Write-Host "==> running $expectedBinary"
$output = & $expectedBinary 2>&1 | Out-String
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
Write-Host "PASS: go/binary built via standard provider; greeting matched"
exit 0
