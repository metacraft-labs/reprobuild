#requires -Version 5
# End-to-end M23 verification: build the Rust workspace-lib-chain
# example via the Tier 2b dispatch path and assert the produced binary
# prints the transitive greeting (crate_a::greet → crate_b::banner →
# crate_c).
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 + fall back to rustup stable.
#   2. Wipe prior scratch under the fixture so the build runs cold.
#   3. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   4. Assert exit code 0.
#   5. Assert each crate's expected output exists:
#        * crate_a    rlib  under .repro/build/crate_a/bin/
#        * crate_b    rlib  under .repro/build/crate_b/bin/
#        * crate_c.exe     under .repro/build/crate_c/bin/
#   6. Run crate_c.exe and assert stdout contains the chained greeting
#      ``[chain] hello, rust-workspace-lib-chain-example``. The
#      banner-prefix comes from crate_b; the embedded greeting comes
#      from crate_a — so successful execution proves the lib→lib edge
#      AND the bin's transitive resolution wire correctly.
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org
# §M23 verification "e2e_rust_workspace_lib_to_lib_deps".

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\rust\workspace-lib-chain'
$scratchInsideFixture = Join-Path $fixture '.repro'
$crateABinDir   = Join-Path $fixture (Join-Path '.repro\build' (Join-Path 'crate_a' 'bin'))
$crateBBinDir   = Join-Path $fixture (Join-Path '.repro\build' (Join-Path 'crate_b' 'bin'))
$crateCBinary   = Join-Path $fixture (Join-Path '.repro\build' (Join-Path 'crate_c' (Join-Path 'bin' 'crate_c.exe')))
$expectedGreeting = '[chain] hello, rust-workspace-lib-chain-example'

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
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-rust-workspace-lib-chain.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-rust-workspace-lib-chain.stderr.txt'
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

# --- step 3: assert each crate's lib + bin artefacts exist ---
foreach ($expected in @(
    @{ Dir = $crateABinDir; Filter = 'libcrate_a-*.rlib'; Label = 'crate_a rlib' },
    @{ Dir = $crateBBinDir; Filter = 'libcrate_b-*.rlib'; Label = 'crate_b rlib' }
  )) {
  if (-not (Test-Path -LiteralPath $expected.Dir)) {
    Write-Host "FAIL: $($expected.Label) dir not found at $($expected.Dir)"
    exit 1
  }
  $matches = @(Get-ChildItem -LiteralPath $expected.Dir -Filter $expected.Filter -ErrorAction SilentlyContinue)
  if ($matches.Count -eq 0) {
    Write-Host "FAIL: no $($expected.Label) matching $($expected.Filter) under $($expected.Dir)"
    Get-ChildItem -LiteralPath $expected.Dir -ErrorAction SilentlyContinue |
      ForEach-Object { Write-Host "  $($_.Name)  $($_.Length) bytes" }
    exit 1
  }
  Write-Host "produced $($expected.Label): $($matches[0].FullName)"
}

if (-not (Test-Path -LiteralPath $crateCBinary)) {
  Write-Host "FAIL: expected crate_c binary not found at $crateCBinary"
  $crateCBinDir = Join-Path $fixture (Join-Path '.repro\build' (Join-Path 'crate_c' 'bin'))
  if (Test-Path $crateCBinDir) {
    Get-ChildItem -LiteralPath $crateCBinDir -ErrorAction SilentlyContinue |
      ForEach-Object { Write-Host "  $($_.Name)  $($_.Length) bytes" }
  }
  exit 1
}
Write-Host "produced crate_c binary: $crateCBinary"
Write-Host "  size: $((Get-Item $crateCBinary).Length) bytes"

# --- step 4: run crate_c and assert chained greeting ---
Write-Host "==> running $crateCBinary"
$output = & $crateCBinary 2>&1 | Out-String
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
Write-Host "PASS: rust/workspace-lib-chain built via standard provider; lib→lib edge resolved transitively"
exit 0
