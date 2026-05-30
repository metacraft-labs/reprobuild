#requires -Version 5
# End-to-end M55 verification: build the haskell-cabal/hello-binary
# example via the Tier 2b dispatch path and run the produced binary.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so repro.exe is on PATH.
#   2. Probe for ghc AND cabal. SKIP exit 0 if either is missing. On
#      Windows, attempt to lift them from a managed install under
#      ``D:/metacraft-dev-deps/ghcup/`` or
#      ``%LOCALAPPDATA%\Programs\ghcup\`` when ``Get-Command`` doesn't
#      resolve via PATH alone — this is the documented provisioning
#      path (GHCup-windows from https://www.haskell.org/ghcup/).
#   3. Warm step: ``cabal v2-update`` (non-fatal — mirrors M40 Maven +
#      M41 Gradle warm pattern; the M55 fixture only depends on ``base``
#      so the warm step is a no-op for this fixture but kept as
#      documentation of the canonical warm sequence).
#   4. Wipe any prior .repro/ scratch AND ``dist-newstyle/`` dir under
#      the fixture so the build runs cold.
#   5. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   6. Assert exit code 0.
#   7. Locate the produced ``hello.exe`` under ``dist-newstyle/`` (the
#      exact path varies by GHC version + platform tuple, so we walk)
#      and run it; assert stdout contains
#      ``hello from haskell-cabal-hello-binary``.
#
# Per reprobuild-specs/Provisioning-And-Languages-Expansion.milestones.org §M55.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\haskell-cabal\hello-binary'
$scratchInsideFixture = Join-Path $fixture '.repro'
$distInsideFixture    = Join-Path $fixture 'dist-newstyle'
$expectedGreeting = 'hello from haskell-cabal-hello-binary'

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
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'hello.cabal'))) {
  Write-Host "FAIL: fixture missing hello.cabal at $fixture"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'app\Main.hs'))) {
  Write-Host "FAIL: fixture missing app\Main.hs at $fixture"
  exit 1
}

# --- toolchain probe ---
# Try to lift a managed GHCup install into PATH when ghc/cabal don't
# resolve directly. The dev-deps tree may carry a GHCup install under
# ``D:\metacraft-dev-deps\ghcup\``; per-user GHCup installs land under
# ``%LOCALAPPDATA%\Programs\ghcup\``. Both ``ghc`` and ``cabal`` are
# required for the convention.
function Try-LiftGhcup {
  $candidates = @()
  foreach ($ghcupRoot in @(
    'D:\metacraft-dev-deps\ghcup',
    (Join-Path $env:LOCALAPPDATA 'Programs\ghcup'))) {
    if (-not $ghcupRoot) { continue }
    if (-not (Test-Path -LiteralPath $ghcupRoot)) { continue }
    foreach ($candidate in @(
      (Join-Path $ghcupRoot 'bin\ghc.exe'),
      (Join-Path $ghcupRoot 'bin\cabal.exe'))) {
      if (Test-Path -LiteralPath $candidate) { $candidates += $candidate }
    }
  }
  if ($candidates.Count -gt 0) {
    $binDir = Split-Path -Parent ($candidates | Select-Object -First 1)
    if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $binDir })) {
      $env:PATH = "$binDir;$env:PATH"
    }
  }
}

$ghcCmd = Get-Command ghc -ErrorAction SilentlyContinue
$cabalCmd = Get-Command cabal -ErrorAction SilentlyContinue
if (-not $ghcCmd -or -not $cabalCmd) {
  Try-LiftGhcup
  $ghcCmd = Get-Command ghc -ErrorAction SilentlyContinue
  $cabalCmd = Get-Command cabal -ErrorAction SilentlyContinue
}
if (-not $ghcCmd) {
  Write-Host "SKIP: 'ghc' not on PATH (M55 haskell-cabal convention needs the Haskell toolchain; install GHC + cabal via GHCup from https://www.haskell.org/ghcup/ — M55 pins GHC 9.10.1)"
  exit 0
}
if (-not $cabalCmd) {
  Write-Host "SKIP: 'cabal' not on PATH (M55 haskell-cabal convention needs cabal-install; install via GHCup from https://www.haskell.org/ghcup/ — M55 pins cabal-install 3.12.1.0)"
  exit 0
}

Write-Host "==> using ghc=$($ghcCmd.Source)"
Write-Host "==> using cabal=$($cabalCmd.Source)"

# --- warm step: cabal v2-update (non-fatal) ---
# Refresh the local Hackage index so subsequent ``v2-build --offline``
# can resolve any external deps. The M55 fixture only depends on
# ``base`` so this is a no-op for the fixture but kept as the canonical
# warm sequence (mirrors M40 Maven + M41 Gradle warm patterns).
Write-Host "==> warm: cabal v2-update (non-fatal)"
try {
  $warmOut = & $cabalCmd.Source v2-update 2>&1 | Out-String
  Write-Host "  cabal v2-update exit: $LASTEXITCODE"
  if ($LASTEXITCODE -ne 0) {
    Write-Host "  cabal v2-update failed (non-fatal — fixture depends only on base)"
  }
} catch {
  Write-Host "  cabal v2-update threw (non-fatal): $_"
}

# --- step 1: clean prior scratch + dist-newstyle dir ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}
if (Test-Path -LiteralPath $distInsideFixture) {
  Write-Host "wiping prior Cabal dist-newstyle dir $distInsideFixture"
  Remove-Item -LiteralPath $distInsideFixture -Recurse -Force
}

# --- step 2: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-haskell-cabal-hello-binary.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-haskell-cabal-hello-binary.stderr.txt'
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
# Cabal v2-build writes the executable to a complex platform-tuple-
# and GHC-version-keyed path under ``dist-newstyle/``. Walk for
# ``hello.exe`` (Windows) or ``hello`` (POSIX). The convention's
# predicted path is the deepest match (under ``x/<exe>/build/<exe>/``).
$exeName = 'hello.exe'
$producedExe = $null
$cands = Get-ChildItem -LiteralPath $distInsideFixture -Filter $exeName -Recurse -ErrorAction SilentlyContinue
if ($cands -and $cands.Count -gt 0) {
  # Prefer the deepest path — that's the final emitted binary, not
  # the intermediate object files (which don't have a ``.exe`` suffix
  # anyway but the filter is defensive).
  $producedExe = ($cands | Sort-Object { $_.FullName.Length } -Descending | Select-Object -First 1).FullName
}
if (-not $producedExe -or -not (Test-Path -LiteralPath $producedExe)) {
  Write-Host "FAIL: expected exe not found under $distInsideFixture"
  if (Test-Path $distInsideFixture) {
    Write-Host "--- contents of ${distInsideFixture}:"
    Get-ChildItem -LiteralPath $distInsideFixture -Recurse |
      ForEach-Object { Write-Host "  $($_.FullName)" }
  } else {
    Write-Host "  (no Cabal dist-newstyle dir)"
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
Write-Host "PASS: haskell-cabal/hello-binary built via standard provider; greeting matched"
exit 0
