#requires -Version 5
# End-to-end M21 verification: build the TypeScript CLI example via the
# Tier 2b dispatch path and assert the produced launcher shim runs.
#
# **Scope at M21**: the JS/TS convention now emits (in addition to the
# M16 tsc-compile action):
#
#   * A1 ``npm ci`` — installs ``typescript`` + ``tsx`` + ``esbuild``
#     into ``<fixture>/node_modules/`` from ``package-lock.json``.
#   * A5 ``esbuild --bundle src/bin/cli.ts --format=esm --platform=node
#     --outfile=<scratch>/dist/bin/cli.js --metafile=<...>.meta.json``.
#   * A6 launcher shim — ``<scratch>/bin/typescript-cli-example.cmd``
#     (Windows) that exec-spawns ``node <bundle> %*``.
#
# This script asserts:
#   1. The build's bundle ``dist/bin/cli.js`` exists.
#   2. The esbuild metafile ``dist/bin/cli.js.meta.json`` exists.
#   3. The Windows ``.cmd`` shim exists under ``<scratch>/bin/``.
#   4. Invoking the shim directly via ``& <path>.cmd`` prints the
#      expected greeting (load-bearing — proves the launcher works end
#      to end, not just that the file is on disk).
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1.
#   2. Probe for node / npx; SKIP cleanly if missing.
#   3. Wipe any prior .repro/ scratch.
#   4. Invoke repro.exe build <fixture>#default.
#   5. Assert exit code 0.
#   6. Confirm bundle + metafile + shim exist.
#   7. Run the shim and assert stdout contains the expected greeting.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\javascript-typescript\typescript-cli'
$scratchInsideFixture = Join-Path $fixture '.repro'
$expectedDistDir = Join-Path $fixture '.repro\build\dist'

# --- ensure `node` (and `npx`) is available somewhere ---
$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
  $nodeRoot = 'D:\metacraft-dev-deps\node'
  if (Test-Path -LiteralPath $nodeRoot) {
    $candidates = @()
    foreach ($verDir in Get-ChildItem -LiteralPath $nodeRoot -Directory -ErrorAction SilentlyContinue) {
      foreach ($inner in Get-ChildItem -LiteralPath $verDir.FullName -Directory -ErrorAction SilentlyContinue) {
        $candidate = Join-Path $inner.FullName 'node.exe'
        if (Test-Path -LiteralPath $candidate) {
          $candidates += $candidate
        }
      }
    }
    if ($candidates.Count -gt 0) {
      $picked = $candidates | Sort-Object | Select-Object -Last 1
      $binDir = Split-Path -Parent $picked
      $env:PATH = "$binDir;$env:PATH"
      $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    }
  }
}
if (-not $nodeCmd) {
  Write-Host "SKIP: 'node' not available. M16 e2e gate skipped."
  exit 0
}
$npxCmd = Get-Command npx -ErrorAction SilentlyContinue
if (-not $npxCmd) {
  Write-Host "SKIP: 'npx' not available. M16 e2e gate skipped."
  exit 0
}
Write-Host "node = $($nodeCmd.Source)"
Write-Host "npx  = $($npxCmd.Source)"
& $nodeCmd.Source --version

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
  Write-Host "FAIL: fixture missing at $fixture"
  exit 1
}

# --- step 1: clean prior scratch ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}

# --- step 2: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-typescript-cli.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-typescript-cli.stderr.txt'
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

# --- step 3: assert dist/bin/cli.js + metafile exist (M21 A5) ---
$expectedJs       = Join-Path $expectedDistDir 'bin\cli.js'
$expectedMetafile = Join-Path $expectedDistDir 'bin\cli.js.meta.json'
if (-not (Test-Path -LiteralPath $expectedJs)) {
  Write-Host "FAIL: missing $expectedJs"
  Write-Host "--- recursive contents of ${expectedDistDir}:"
  if (Test-Path -LiteralPath $expectedDistDir) {
    Get-ChildItem -LiteralPath $expectedDistDir -Recurse -ErrorAction SilentlyContinue |
      ForEach-Object { Write-Host "  $($_.FullName)  $($_.Length) bytes" }
  } else {
    Write-Host "  (dist dir does not exist)"
  }
  exit 1
}
if (-not (Test-Path -LiteralPath $expectedMetafile)) {
  Write-Host "FAIL: missing esbuild metafile $expectedMetafile"
  exit 1
}
Write-Host "produced bundle:   $expectedJs"
Write-Host "produced metafile: $expectedMetafile"

# --- step 4: assert .cmd shim exists (M21 A6) ---
$expectedShimDir = Join-Path $fixture '.repro\build\bin'
$expectedShim    = Join-Path $expectedShimDir 'typescript-cli-example.cmd'
if (-not (Test-Path -LiteralPath $expectedShim)) {
  Write-Host "FAIL: missing launcher shim $expectedShim"
  Write-Host "--- contents of ${expectedShimDir}:"
  if (Test-Path -LiteralPath $expectedShimDir) {
    Get-ChildItem -LiteralPath $expectedShimDir -ErrorAction SilentlyContinue |
      ForEach-Object { Write-Host "  $($_.FullName)  $($_.Length) bytes" }
  } else {
    Write-Host "  (shim dir does not exist)"
  }
  exit 1
}
Write-Host "produced shim:     $expectedShim"
Write-Host "--- shim contents:"
Get-Content -LiteralPath $expectedShim | ForEach-Object { Write-Host "  $_" }

# --- step 5: run the shim and assert greeting (M21 A6 load-bearing) ---
$cliOutput = & $expectedShim 2>&1
$cliExit = $LASTEXITCODE
$cliText = ($cliOutput | Out-String).Trim()
Write-Host "--- shim invocation output:"
Write-Host $cliText
if ($cliExit -ne 0) {
  Write-Host "FAIL: shim '$expectedShim' exited $cliExit"
  exit 1
}
if ($cliText -notmatch 'hello from typescript-cli-example') {
  Write-Host "FAIL: shim stdout missing 'hello from typescript-cli-example'; got: $cliText"
  exit 1
}

Write-Host ""
Write-Host "PASS: javascript-typescript/typescript-cli built via standard provider; .cmd shim runs and prints the expected greeting"
exit 0
