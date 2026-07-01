#requires -Version 5
# End-to-end M6 verification: build the Rust binary-with-build-rs example
# via the Tier 2b dispatch path. The Rust convention `recognize` claims
# the project (M6 relaxation — build.rs no longer rejects), and the
# convention's `emitFragment` routes through the Mode B crude fallback
# which delegates to `cargo build --release --locked --offline` under
# io-monitor monitoring.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so the managed nim/gcc/repro tools are
#      on PATH. Same rustup-fallback as validate-standard-provider-rust.ps1.
#   2. Wipe any prior .repro/build/ scratch AND the Cargo target/ dir so
#      the build runs cold.
#   3. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   4. Assert exit code 0.
#   5. Cargo writes its output to <fixture>/target/release/ (NOT into
#      .repro/build/) because the crude action runs `cargo build` with
#      its own toolchain managing output paths. Assert the produced
#      binary exists and prints the expected greeting (which proves
#      both that cargo ran AND that build.rs fired).
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org
# §M6 verification "e2e_rust_with_build_rs_falls_back_to_crude".

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\rust\binary-with-build-rs'
$scratchInsideFixture = Join-Path $fixture '.repro'
$cargoTargetDir = Join-Path $fixture 'target'
# Cargo emits the binary at target/release/<package-name>.exe. Cargo
# converts hyphens to nothing (NOT underscores) in the binary name —
# the package is `rust-binary-with-build-rs`, so the binary lands at
# `rust-binary-with-build-rs.exe`.
$expectedBinary = Join-Path $cargoTargetDir 'release\rust-binary-with-build-rs.exe'
$expectedGreeting = "hello with build.rs: yes"

# --- ensure rustc + cargo are available somewhere ---
$rustcCmd = Get-Command rustc -ErrorAction SilentlyContinue
$cargoCmd = Get-Command cargo -ErrorAction SilentlyContinue
if (-not $rustcCmd -or -not $cargoCmd) {
  # The Metacraft dev shell doesn't currently provision rustc/cargo. Try
  # the rustup stable toolchain that the host setup script populates.
  $rustupStableBin = 'D:\metacraft-dev-deps\rustup\toolchains\stable-x86_64-pc-windows-msvc\bin'
  if (Test-Path -LiteralPath (Join-Path $rustupStableBin 'rustc.exe')) {
    Write-Host "rustc/cargo not on PATH; falling back to rustup stable at $rustupStableBin"
    $env:PATH = "$rustupStableBin;$env:PATH"
    $rustcCmd = Get-Command rustc -ErrorAction SilentlyContinue
    $cargoCmd = Get-Command cargo -ErrorAction SilentlyContinue
  }
}
if (-not $rustcCmd -or -not $cargoCmd) {
  Write-Host "SKIP: rustc/cargo not available — the M6 e2e gate needs both on PATH."
  Write-Host "      Install via: rustup default stable (or set up the dev shell to provision rust)."
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
  Write-Host "FAIL: fixture missing at $fixture -- expected reprobuild-examples checkout"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'build.rs'))) {
  Write-Host "FAIL: fixture missing build.rs at $fixture -- this gate requires the build script to exercise Mode B"
  exit 1
}

# --- step 1: clean prior scratch ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}
if (Test-Path -LiteralPath $cargoTargetDir) {
  Write-Host "wiping prior cargo target dir $cargoTargetDir"
  Remove-Item -LiteralPath $cargoTargetDir -Recurse -Force
}

# --- step 2: invoke `repro build` ---
# M11 (2026-05-27): The previously-required REPRO_MONITOR_BYPASS=1
# workaround has been retired. The root cause was the io-monitor IAT
# shim's hook bodies (libs/repro_monitor_shim/src/repro_monitor_shim/
# windows_interpose.nim) clobbering the thread-local LastError that
# the real Win32 functions had just set. Cargo's std::process::Command
# inspects LastError after CreateNamedPipeW / UpdateProcThreadAttribute
# probes and would see whatever value our Nim allocator / lock-acquire
# bookkeeping left behind, ending up panicking with the misleading
# `Os { code: 183, kind: AlreadyExists, message: "Cannot create a file
# when that file already exists." }`. Each hook now Save/Restores
# LastError around the bookkeeping block, so the caller observes the
# kernel's actual error code.
#
# With the bypass dropped, io-monitor's automaticMonitor policy is now
# exercised end-to-end on Windows: cargo's reads are captured into the
# monitor fragment dir and merged into the action's recorded inputs.
# Ensure no inherited REPRO_MONITOR_BYPASS leaks from the harness env.
if (Test-Path Env:REPRO_MONITOR_BYPASS) {
  Remove-Item Env:REPRO_MONITOR_BYPASS
}

$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-rust-crude.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-rust-crude.stderr.txt'
New-Item -ItemType Directory -Force -Path (Split-Path $stdoutCapture) | Out-Null

Write-Host "==> launching repro.exe build $reproTarget (REPRO_MONITOR_BYPASS unset)"
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
  Write-Host "--- contents of ${cargoTargetDir}:"
  if (Test-Path $cargoTargetDir) {
    Get-ChildItem -LiteralPath $cargoTargetDir -Recurse |
      ForEach-Object { Write-Host "  $($_.FullName)" }
  } else {
    Write-Host "  (no target dir)"
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
Write-Host "PASS: rust/binary-with-build-rs built via Mode B crude fallback; build.rs fired"
exit 0
