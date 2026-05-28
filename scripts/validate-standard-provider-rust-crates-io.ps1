#requires -Version 5
# End-to-end M23 verification: build the Rust binary-with-crates-io
# example via the Tier 2b dispatch path. The M23 Rust convention
# detects external (crates.io / git) deps in cargo metadata and routes
# the project through the Mode B crude fallback (``cargo build
# --release --offline``). This is the scoped-down M23 surface; the
# full Mode A path with per-rustc-action ``--extern`` threading
# against the CARGO_HOME registry is deferred to a future milestone.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 + fall back to rustup stable.
#   2. Probe the host CARGO_HOME registry for ``libc`` (the dep this
#      fixture uses). If absent, attempt ``cargo fetch`` in the
#      fixture's working dir. If that ALSO fails (offline), SKIP
#      cleanly — the Mode B fallback's ``--offline`` flag would error
#      without the registry cache populated.
#   3. Wipe prior scratch under the fixture so the build runs cold.
#   4. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   5. Assert exit code 0.
#   6. Assert ``target/release/rust-binary-with-crates-io.exe`` (the
#      crude path's cargo-managed output dir) exists.
#   7. Run the binary and assert stdout contains the expected greeting
#      (proves the libc dep was resolved + linked).
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org
# §M23 — "crates.io / git deps" (Mode B fallback scope).

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\rust\binary-with-crates-io'
$scratchInsideFixture = Join-Path $fixture '.repro'
# Mode B's cargo invocation writes to <fixture>/target/release/.
$binaryPath     = Join-Path $fixture 'target\release\rust-binary-with-crates-io.exe'
$expectedGreeting = 'hello from rust-binary-with-crates-io'

# --- ensure rustc + cargo are available somewhere ---
$rustcCmd = Get-Command rustc -ErrorAction SilentlyContinue
$cargoCmd = Get-Command cargo -ErrorAction SilentlyContinue
if (-not $rustcCmd -or -not $cargoCmd) {
  $rustupStableBin = 'D:\metacraft-dev-deps\rustup\toolchains\stable-x86_64-pc-windows-msvc\bin'
  if (Test-Path -LiteralPath (Join-Path $rustupStableBin 'rustc.exe')) {
    Write-Host "rustc/cargo not on PATH; falling back to rustup stable at $rustupStableBin"
    $env:PATH = "$rustupStableBin;$env:PATH"
    $rustcCmd = Get-Command rustc -ErrorAction SilentlyContinue
    $cargoCmd = Get-Command cargo -ErrorAction SilentlyContinue
  }
}
if (-not $rustcCmd -or -not $cargoCmd) {
  Write-Host "SKIP: rustc/cargo not available -- the M23 e2e gate needs both on PATH."
  exit 0
}
Write-Host "rustc = $((Get-Command rustc).Source)"
Write-Host "cargo = $((Get-Command cargo).Source)"

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

# --- step 1: warm CARGO_HOME registry if needed ---
# Determine CARGO_HOME (cargo's default is %USERPROFILE%\.cargo on Windows).
$cargoHome = $env:CARGO_HOME
if (-not $cargoHome) { $cargoHome = Join-Path $env:USERPROFILE '.cargo' }
$cratesCacheDir = Join-Path $cargoHome 'registry\cache'
$libcCached = $false
if (Test-Path -LiteralPath $cratesCacheDir) {
  $libcMatches = @(Get-ChildItem -Recurse -LiteralPath $cratesCacheDir -Filter 'libc-*.crate' -ErrorAction SilentlyContinue)
  if ($libcMatches.Count -gt 0) {
    $libcCached = $true
  }
}
if (-not $libcCached) {
  Write-Host "libc not in CARGO_HOME registry; attempting 'cargo fetch' (needs network)"
  Push-Location -LiteralPath $fixture
  try {
    & cargo fetch 2>&1 | ForEach-Object { Write-Host "  $_" }
    $fetchExit = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  if ($fetchExit -ne 0) {
    Write-Host "SKIP: 'cargo fetch' failed (exit $fetchExit) -- M23 Mode B fallback needs registry cache populated."
    exit 0
  }
}

# --- step 2: clean prior scratch ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}
$leftoverTarget = Join-Path $fixture 'target'
if (Test-Path -LiteralPath $leftoverTarget) {
  Write-Host "wiping leftover target dir $leftoverTarget"
  Remove-Item -LiteralPath $leftoverTarget -Recurse -Force
}

# --- step 3: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-rust-crates-io.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-rust-crates-io.stderr.txt'
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

# --- step 4: assert the binary exists + runs ---
if (-not (Test-Path -LiteralPath $binaryPath)) {
  Write-Host "FAIL: expected binary not found at $binaryPath"
  Write-Host "--- contents of target\release:"
  $targetRelease = Join-Path $fixture 'target\release'
  if (Test-Path $targetRelease) {
    Get-ChildItem -LiteralPath $targetRelease -ErrorAction SilentlyContinue |
      ForEach-Object { Write-Host "  $($_.Name)  $($_.Length) bytes" }
  }
  exit 1
}
Write-Host "produced binary: $binaryPath"
Write-Host "  size: $((Get-Item $binaryPath).Length) bytes"

Write-Host "==> running $binaryPath"
$output = & $binaryPath 2>&1 | Out-String
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
Write-Host "PASS: rust/binary-with-crates-io built via Mode B fallback; libc dep resolved + linked"
exit 0
