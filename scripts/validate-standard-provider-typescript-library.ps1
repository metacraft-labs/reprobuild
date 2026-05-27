#requires -Version 5
# End-to-end M16 verification: build the TypeScript pure-library example
# via the Tier 2b dispatch path and assert the produced ``.js`` + ``.d.ts``
# pair imports cleanly under ``node``.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so the managed nim/gcc/repro tools are
#      on PATH.
#   2. Probe for node / npx; SKIP cleanly if missing. The convention's
#      ``recognize`` short-circuits when ``node`` isn't on PATH and the
#      whole gate becomes a no-op.
#   3. Wipe any prior .repro/ scratch under the fixture so the build
#      runs cold.
#   4. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   5. Assert exit code 0.
#   6. Locate ``dist/index.js`` and ``dist/index.d.ts`` under the
#      convention's scratch dir.
#   7. ``node -e "import('<dist/index.js>').then(m => console.log(m.greet('test')))"``
#      and assert stdout is ``hello, test``.
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org §M16.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\javascript-typescript\typescript-library'
$scratchInsideFixture = Join-Path $fixture '.repro'
# The JS/TS convention's scratch dir is flat (per-project, not per-member).
$expectedDistDir = Join-Path $fixture '.repro\build\dist'

# --- ensure `node` (and `npx`) is available somewhere ---
# env.ps1 doesn't manage node today; the convention's recognize probe
# only requires node on PATH. Fall back to the managed install under
# D:\metacraft-dev-deps\node\ when the dev shell didn't preload it.
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
  Write-Host "SKIP: 'node' not available on PATH and not under D:/metacraft-dev-deps/node/. M16 e2e gate skipped."
  exit 0
}
$npxCmd = Get-Command npx -ErrorAction SilentlyContinue
if (-not $npxCmd) {
  Write-Host "SKIP: 'npx' not available on PATH (node install must ship npm/npx). M16 e2e gate skipped."
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
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-typescript-library.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-typescript-library.stderr.txt'
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

# --- step 3: assert dist/index.js + dist/index.d.ts exist ---
if (-not (Test-Path -LiteralPath $expectedDistDir)) {
  Write-Host "FAIL: expected dist dir not found at $expectedDistDir"
  exit 1
}
$expectedJs  = Join-Path $expectedDistDir 'index.js'
$expectedDts = Join-Path $expectedDistDir 'index.d.ts'
if (-not (Test-Path -LiteralPath $expectedJs)) {
  Write-Host "FAIL: missing $expectedJs"
  Write-Host "--- contents of ${expectedDistDir}:"
  Get-ChildItem -LiteralPath $expectedDistDir -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "  $($_.Name)  $($_.Length) bytes" }
  exit 1
}
if (-not (Test-Path -LiteralPath $expectedDts)) {
  Write-Host "FAIL: missing $expectedDts"
  exit 1
}
Write-Host "produced: $expectedJs"
Write-Host "produced: $expectedDts"

# --- step 4: import probe via node -e ---
# We use ``import()`` (dynamic) so node's ESM loader picks up the file
# regardless of whether the package.json under the dist dir declares
# ``"type": "module"``. The TS source declares ``export function greet``
# so the imported module exposes ``greet`` directly.
$jsForUrl = $expectedJs -replace '\\', '/'
$probe = "import('file:///$jsForUrl').then(m => { console.log(m.greet('test')); }).catch(e => { console.error(e.stack || String(e)); process.exit(2); });"
$probeOutput = & $nodeCmd.Source --input-type=module -e $probe 2>&1
$probeExit = $LASTEXITCODE
$probeText = ($probeOutput | Out-String).Trim()
Write-Host "--- node import probe output:"
Write-Host $probeText
if ($probeExit -ne 0) {
  Write-Host "FAIL: node import probe exited $probeExit"
  exit 1
}
if ($probeText -ne 'hello, test') {
  Write-Host "FAIL: imported module's greet('test') returned '$probeText' (expected 'hello, test')"
  exit 1
}

Write-Host ""
Write-Host "PASS: javascript-typescript/typescript-library built via standard provider; dist/index.js imports and greet('test') returns 'hello, test'"
exit 0
