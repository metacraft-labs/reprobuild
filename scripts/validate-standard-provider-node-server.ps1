#requires -Version 5
# End-to-end M16 verification: build the pure-JS node-server example via
# the Tier 2b dispatch path and assert the produced ``dist/index.js`` is
# importable.
#
# The JS-only path (no TypeScript) emits one ``fs.copyFile`` action per
# source file. The convention's predicted output is
# ``<fixture>/.repro/build/dist/index.js``.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1.
#   2. Probe for node; SKIP cleanly if missing.
#   3. Wipe any prior .repro/ scratch.
#   4. Invoke repro.exe build <fixture>#default.
#   5. Assert exit code 0.
#   6. Confirm dist/index.js exists.
#   7. Smoke-test the import via ``node --input-type=module -e
#      "import('file:///<dist>/index.js')"``. The server file itself
#      calls ``server.listen(port, ...)`` at module top-level — by the
#      time the import settles the server is listening. We immediately
#      tear it down (``process.exit(0)`` after a tiny tick) to avoid
#      leaving the gate hanging on a live socket.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\javascript-typescript\node-server'
$scratchInsideFixture = Join-Path $fixture '.repro'
$expectedDistDir = Join-Path $fixture '.repro\build\dist'

# --- ensure `node` is available somewhere ---
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
Write-Host "node = $($nodeCmd.Source)"
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
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-node-server.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-node-server.stderr.txt'
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

# --- step 3: assert dist/index.js exists ---
if (-not (Test-Path -LiteralPath $expectedDistDir)) {
  Write-Host "FAIL: expected dist dir not found at $expectedDistDir"
  exit 1
}
$expectedJs = Join-Path $expectedDistDir 'index.js'
if (-not (Test-Path -LiteralPath $expectedJs)) {
  Write-Host "FAIL: missing $expectedJs"
  Write-Host "--- contents of ${expectedDistDir}:"
  Get-ChildItem -LiteralPath $expectedDistDir -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "  $($_.Name)  $($_.Length) bytes" }
  exit 1
}
Write-Host "produced: $expectedJs"

# --- step 4: import smoke test ---
# The server module starts listening as a side-effect of import. To avoid
# leaving an open port behind we route PORT to 0 (auto-assign), then
# exit immediately once the import settles. We use a sub-process with
# ``--input-type=module`` to evaluate the ESM dynamic import.
$jsForUrl = $expectedJs -replace '\\', '/'
$probe = @"
process.env.PORT = '0';
import('file:///$jsForUrl').then(() => {
  setImmediate(() => process.exit(0));
}).catch(e => {
  console.error(e.stack || String(e));
  process.exit(2);
});
"@
$probeOutput = & $nodeCmd.Source --input-type=module -e $probe 2>&1
$probeExit = $LASTEXITCODE
$probeText = ($probeOutput | Out-String).Trim()
Write-Host "--- node import probe output:"
Write-Host $probeText
if ($probeExit -ne 0) {
  Write-Host "FAIL: node import probe exited $probeExit"
  exit 1
}

Write-Host ""
Write-Host "PASS: javascript-typescript/node-server built via standard provider; dist/index.js imports cleanly under node"
exit 0
