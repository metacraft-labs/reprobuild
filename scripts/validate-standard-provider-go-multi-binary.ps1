#requires -Version 5
# End-to-end M14 verification: build the Go multi-binary example via the
# Tier 2b dispatch path and run BOTH produced executables.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so the managed nim/gcc/repro tools are
#      on PATH. The dev shell does NOT (yet) provision Go; fall back to
#      the Windows install under D:/metacraft-dev-deps/go/<ver>/go/bin.
#      If that's also missing the script exits with SKIP=0 so the gate is
#      honest about toolchain absence.
#   2. Wipe any prior .repro/build/ scratch under the fixture so the
#      build runs cold.
#   3. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   4. Assert exit code 0.
#   5. Locate BOTH produced binaries under
#      <fixture>/.repro/build/<entry>/bin/ and run each; assert each
#      stdout contains the expected greeting.
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org
# §M14 verification "e2e_go_multi_binary_builds_via_standard_provider".

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\go\multi-binary'
$scratchInsideFixture = Join-Path $fixture '.repro'
# The Go convention's projectEntry is derived from the module's last
# path segment, snake-cased: ``example.com/go-multi-binary-example`` →
# ``go_multi_binary_example``. Both alpha + beta land under that scratch
# dir's bin/.
$entryName      = 'go_multi_binary_example'
$expectedBinDir = Join-Path $fixture (Join-Path '.repro\build' (Join-Path $entryName 'bin'))
$expectedAlpha  = Join-Path $expectedBinDir 'alpha.exe'
$expectedBeta   = Join-Path $expectedBinDir 'beta.exe'

# --- ensure `go` is available somewhere ---
$goCmd = Get-Command go -ErrorAction SilentlyContinue
if (-not $goCmd) {
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
  foreach ($sys in @('D:\Program Files\Go\bin\go.exe',
                     'C:\Program Files\Go\bin\go.exe',
                     'D:\Go\bin\go.exe',
                     'C:\Go\bin\go.exe')) {
    if (Test-Path -LiteralPath $sys) {
      $candidates += $sys
    }
  }
  if ($candidates.Count -gt 0) {
    $picked = $candidates | Sort-Object | Select-Object -Last 1
    $binDir = Split-Path -Parent $picked
    Write-Host "go not on PATH; falling back to $picked"
    $env:PATH = "$binDir;$env:PATH"
    $goCmd = Get-Command go -ErrorAction SilentlyContinue
  }
}
if (-not $goCmd) {
  Write-Host "SKIP: 'go' not available on PATH and not found under D:/metacraft-dev-deps/go/. M14 e2e gate skipped."
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
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-go-multi-binary.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-go-multi-binary.stderr.txt'
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

# --- step 3: assert both binaries exist ---
foreach ($pair in @(
  @{ Path = $expectedAlpha; Greeting = 'hello from alpha' },
  @{ Path = $expectedBeta;  Greeting = 'hello from beta'  }
)) {
  if (-not (Test-Path -LiteralPath $pair.Path)) {
    Write-Host "FAIL: expected binary not found at $($pair.Path)"
    Write-Host "--- contents of ${expectedBinDir}:"
    if (Test-Path -LiteralPath $expectedBinDir) {
      Get-ChildItem -LiteralPath $expectedBinDir -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host "  $($_.Name)  $($_.Length) bytes" }
    } else {
      Write-Host "  (no bin dir at $expectedBinDir)"
    }
    exit 1
  }
  Write-Host "produced binary: $($pair.Path) ($((Get-Item $pair.Path).Length) bytes)"
}

# --- step 4: run each binary and assert greeting ---
foreach ($pair in @(
  @{ Path = $expectedAlpha; Greeting = 'hello from alpha' },
  @{ Path = $expectedBeta;  Greeting = 'hello from beta'  }
)) {
  Write-Host "==> running $($pair.Path)"
  $output = & $pair.Path 2>&1 | Out-String
  $runExit = $LASTEXITCODE
  Write-Host "--- binary exit code: $runExit"
  Write-Host "--- binary stdout: $($output.Trim())"
  if ($runExit -ne 0) {
    Write-Host "FAIL: $($pair.Path) exited with code $runExit"
    exit 1
  }
  if ($output -notmatch [regex]::Escape($pair.Greeting)) {
    Write-Host "FAIL: $($pair.Path) stdout missing greeting '$($pair.Greeting)'"
    exit 1
  }
}

Write-Host ""
Write-Host "PASS: go/multi-binary built via standard provider; both alpha + beta produced and greetings matched"
exit 0
