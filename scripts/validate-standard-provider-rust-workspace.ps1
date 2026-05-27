#requires -Version 5
# End-to-end M13 verification: build the Rust workspace example via the
# Tier 2b dispatch path, then run the produced binary and assert it
# prints the greeting that comes from the workspace's library member.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 + fall back to the rustup stable
#      toolchain if rustc/cargo aren't on PATH.
#   2. Wipe any prior .repro/build/ scratch under the fixture so the
#      build runs cold.
#   3. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   4. Assert exit code 0.
#   5. Assert both ``crate_a``'s rlib AND ``crate_b``'s binary exist
#      under the per-crate scratch dirs.
#   6. Run ``crate_b`` and assert stdout contains the expected greeting
#      (the greeting comes from ``crate_a::greet``, so this verifies
#      the inter-crate ``--extern`` edge is wired correctly).
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org
# §M13 verification "e2e_rust_workspace_builds_via_standard_provider".

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\rust\workspace'
$scratchInsideFixture = Join-Path $fixture '.repro'
$crateALibDir   = Join-Path $fixture (Join-Path '.repro\build' (Join-Path 'crate_a' 'bin'))
$crateBBinary   = Join-Path $fixture (Join-Path '.repro\build' (Join-Path 'crate_b' (Join-Path 'bin' 'crate_b.exe')))
$expectedGreeting = "hello, rust-workspace-example"

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
  Write-Host "SKIP: rustc/cargo not available -- the M13 e2e gate needs both on PATH."
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

# --- step 1: clean prior scratch ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}
$leftoverTarget = Join-Path $fixture 'target'
if (Test-Path -LiteralPath $leftoverTarget) {
  Write-Host "wiping leftover target dir $leftoverTarget"
  Remove-Item -LiteralPath $leftoverTarget -Recurse -Force
}

# --- step 2: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-rust-workspace.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-rust-workspace.stderr.txt'
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

# --- step 3: assert crate_a's rlib AND crate_b's binary exist ---
if (-not (Test-Path -LiteralPath $crateALibDir)) {
  Write-Host "FAIL: expected crate_a bin dir not found at $crateALibDir"
  exit 1
}
$rlibs = @(Get-ChildItem -LiteralPath $crateALibDir -Filter "libcrate_a-*.rlib" -ErrorAction SilentlyContinue)
if ($rlibs.Count -eq 0) {
  Write-Host "FAIL: no rlib matching 'libcrate_a-*.rlib' under $crateALibDir"
  Get-ChildItem -LiteralPath $crateALibDir -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "  $($_.Name)  $($_.Length) bytes" }
  exit 1
}
Write-Host "produced crate_a rlib: $($rlibs[0].FullName)"

if (-not (Test-Path -LiteralPath $crateBBinary)) {
  Write-Host "FAIL: expected crate_b binary not found at $crateBBinary"
  $crateBBinDir = Join-Path $fixture (Join-Path '.repro\build' (Join-Path 'crate_b' 'bin'))
  if (Test-Path $crateBBinDir) {
    Get-ChildItem -LiteralPath $crateBBinDir -ErrorAction SilentlyContinue |
      ForEach-Object { Write-Host "  $($_.Name)  $($_.Length) bytes" }
  }
  exit 1
}
Write-Host "produced crate_b binary: $crateBBinary"
Write-Host "  size: $((Get-Item $crateBBinary).Length) bytes"

# --- step 4: run crate_b and assert greeting ---
Write-Host "==> running $crateBBinary"
$output = & $crateBBinary 2>&1 | Out-String
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
Write-Host "PASS: rust/workspace built via standard provider; crate_b greeted via crate_a::greet"
exit 0
