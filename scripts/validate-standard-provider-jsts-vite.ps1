#requires -Version 5
# End-to-end M24 verification: build the javascript-typescript/vite-app
# fixture via the Tier 2b dispatch path. The M24 JS/TS convention
# detects a ``vite.config.*`` at the project root (and/or a
# ``scripts.build`` invoking vite) and routes the project through the
# Mode B crude fallback. The fallback invokes either
# ``npm ci && npm run build`` (when a lockfile is present) or
# ``npm install && npm run build`` (otherwise) through cmd.exe/sh.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1; fall back to bundled Node under
#      D:/metacraft-dev-deps/node/<ver>/<dist>/ if node isn't on PATH.
#   2. Probe for npm. SKIP if missing.
#   3. Wipe prior scratch (dist/, node_modules/, package-lock.json,
#      .repro/) so the build runs cold.
#   4. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   5. Assert exit code 0.
#   6. Assert ``<fixture>/dist/index.js`` exists.
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org §M24.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\javascript-typescript\vite-app'
$bundlePath     = Join-Path $fixture 'dist\index.js'

# --- ensure node + npm are available ---
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
      Write-Host "node not on PATH; falling back to bundled install at $binDir"
      $env:PATH = "$binDir;$env:PATH"
      $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    }
  }
}
if (-not $nodeCmd) {
  Write-Host "SKIP: 'node' not on PATH and not under D:/metacraft-dev-deps/node/ -- vite Mode B needs node + npm."
  exit 0
}
$npmCmd = Get-Command npm -ErrorAction SilentlyContinue
if (-not $npmCmd) {
  Write-Host "SKIP: 'npm' not on PATH -- vite Mode B drives the install + bundler through npm."
  exit 0
}
Write-Host "node = $($nodeCmd.Source)"
Write-Host "npm  = $($npmCmd.Source)"

# --- preflight ---
if (-not (Test-Path -LiteralPath $reproExe)) {
  Write-Host "FAIL: missing $reproExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'reprobuild.nim'))) {
  Write-Host "FAIL: fixture missing at $fixture"
  exit 1
}

# --- wipe prior scratch ---
foreach ($leftover in @('.repro', 'dist', 'node_modules', 'package-lock.json')) {
  $leftoverPath = Join-Path $fixture $leftover
  if (Test-Path -LiteralPath $leftoverPath) {
    Write-Host "wiping prior $leftoverPath"
    Remove-Item -LiteralPath $leftoverPath -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# --- invoke repro build ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-jsts-vite.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-jsts-vite.stderr.txt'
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

# --- assert the bundle exists ---
if (-not (Test-Path -LiteralPath $bundlePath)) {
  Write-Host "FAIL: expected bundle missing at $bundlePath"
  $distDir = Split-Path $bundlePath -Parent
  if (Test-Path -LiteralPath $distDir) {
    Write-Host "--- contents of dist:"
    Get-ChildItem -LiteralPath $distDir -ErrorAction SilentlyContinue |
      ForEach-Object { Write-Host "  $($_.Name)  $($_.Length) bytes" }
  }
  exit 1
}
Write-Host "produced bundle: $bundlePath"
Write-Host "  size: $((Get-Item $bundlePath).Length) bytes"

Write-Host ""
Write-Host "PASS: javascript-typescript/vite-app built via M24 Mode B fallback; dist/index.js produced"
exit 0
