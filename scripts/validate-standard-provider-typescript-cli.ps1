#requires -Version 5
# End-to-end M16 verification: build the TypeScript CLI example via the
# Tier 2b dispatch path and assert the produced ``dist/bin/cli.js`` runs.
#
# **Scope at M16**: the JS/TS convention emits a single whole-project
# ``npx tsc`` compile that transpiles every ``src/**/*.ts`` (including
# ``src/bin/cli.ts``) to a matching ``.js``. The hashbang on line 1 of
# ``cli.ts`` is preserved into ``dist/bin/cli.js`` (tsc copies it
# verbatim). The Mode A spec's A5 ``esbuild --bundle`` step that would
# emit a single self-contained bundle per ``bin`` entry is **deferred**;
# the fixture has no runtime ``node_modules`` deps so the plain
# transpile is enough to produce a runnable file.
#
# A6 launcher-shim emission (``.cmd`` on Windows / chmod +x on POSIX) is
# also deferred — this script invokes the produced JS via ``node
# dist/bin/cli.js`` directly. The package.json's ``"bin"`` map points at
# ``./dist/bin/cli.js`` so once A6 lands the shim will resolve to that
# exact file.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1.
#   2. Probe for node / npx; SKIP cleanly if missing.
#   3. Wipe any prior .repro/ scratch.
#   4. Invoke repro.exe build <fixture>#default.
#   5. Assert exit code 0.
#   6. Confirm dist/bin/cli.js exists.
#   7. Run ``node dist/bin/cli.js`` and assert stdout contains the
#      expected greeting.

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

# --- step 3: assert dist/bin/cli.js exists ---
$expectedJs = Join-Path $expectedDistDir 'bin\cli.js'
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
Write-Host "produced: $expectedJs"

# --- step 4: run the CLI and assert greeting ---
$cliOutput = & $nodeCmd.Source $expectedJs 2>&1
$cliExit = $LASTEXITCODE
$cliText = ($cliOutput | Out-String).Trim()
Write-Host "--- node $expectedJs output:"
Write-Host $cliText
if ($cliExit -ne 0) {
  Write-Host "FAIL: 'node $expectedJs' exited $cliExit"
  exit 1
}
if ($cliText -notmatch 'hello from typescript-cli-example') {
  Write-Host "FAIL: CLI stdout missing 'hello from typescript-cli-example'; got: $cliText"
  exit 1
}

Write-Host ""
Write-Host "PASS: javascript-typescript/typescript-cli built via standard provider; node dist/bin/cli.js prints the expected greeting"
exit 0
