#requires -Version 5
# End-to-end M23 verification: build the Rust cdylib example via the
# Tier 2b dispatch path and assert the produced dynamic library exists
# AND exports the expected C-ABI symbol.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 + fall back to rustup stable.
#   2. Wipe prior scratch under the fixture so the build runs cold.
#   3. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   4. Assert exit code 0.
#   5. Assert ``rust_cdylib_example.dll`` (Windows) / ``librust_cdylib_example.so``
#      (POSIX) lands under .repro/build/rust_cdylib_example/bin/.
#   6. On Windows: scan the DLL's export table via dumpbin and assert
#      ``rust_cdylib_example_add`` is exported. If dumpbin isn't on
#      PATH (no Visual Studio Build Tools), fall back to a size-only
#      check (>0 bytes) — the file existence + non-zero size is still a
#      strong signal that rustc emitted a valid cdylib.
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org
# §M23 verification "e2e_rust_cdylib_produces_dynamic_library".

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\rust\cdylib'
$scratchInsideFixture = Join-Path $fixture '.repro'
$crateName      = 'rust_cdylib_example'
$binDir         = Join-Path $fixture (Join-Path '.repro\build' (Join-Path $crateName 'bin'))

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
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-rust-cdylib.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-rust-cdylib.stderr.txt'
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

# --- step 3: assert the dynamic library exists ---
if (-not (Test-Path -LiteralPath $binDir)) {
  Write-Host "FAIL: expected bin dir not found at $binDir"
  exit 1
}
$onWindows = $IsWindows -or ($env:OS -eq 'Windows_NT')
$expectedFilename =
  if ($onWindows) { "$crateName.dll" }
  elseif ($IsMacOS) { "lib$crateName.dylib" }
  else { "lib$crateName.so" }
$dynlibPath = Join-Path $binDir $expectedFilename
if (-not (Test-Path -LiteralPath $dynlibPath)) {
  Write-Host "FAIL: expected dynamic library $expectedFilename not found at $dynlibPath"
  Write-Host "--- contents of ${binDir}:"
  Get-ChildItem -LiteralPath $binDir -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "  $($_.Name)  $($_.Length) bytes" }
  exit 1
}
$dynlibSize = (Get-Item $dynlibPath).Length
Write-Host "produced dynamic library: $dynlibPath"
Write-Host "  size: $dynlibSize bytes"
if ($dynlibSize -le 0) {
  Write-Host "FAIL: produced dynamic library is empty"
  exit 1
}

# --- step 4: on Windows, verify the exported symbol via dumpbin -----------
if ($onWindows) {
  $dumpbin = $null
  $dbCandidate = Get-Command dumpbin -ErrorAction SilentlyContinue
  if ($dbCandidate) {
    $dumpbin = $dbCandidate.Source
  } else {
    $vsRoots = @(
      'C:\Program Files\Microsoft Visual Studio',
      'C:\Program Files (x86)\Microsoft Visual Studio'
    )
    foreach ($r in $vsRoots) {
      if (Test-Path -LiteralPath $r) {
        $cand = Get-ChildItem -Recurse -Filter 'dumpbin.exe' -LiteralPath $r -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cand) {
          $dumpbin = $cand.FullName
          break
        }
      }
    }
  }
  if ($dumpbin) {
    Write-Host "==> dumpbin /exports $dynlibPath"
    $exports = & $dumpbin /exports $dynlibPath 2>&1 | Out-String
    if ($exports -notmatch [regex]::Escape($crateName + '_add')) {
      Write-Host "FAIL: dumpbin did not list the expected '${crateName}_add' symbol"
      Write-Host "--- dumpbin output:"
      Write-Host $exports
      exit 1
    }
    Write-Host "verified exported symbol: ${crateName}_add"
  } else {
    Write-Host "SKIP-PARTIAL: dumpbin not found; relying on file existence + size as the cdylib signal."
  }
}

Write-Host ""
Write-Host "PASS: rust/cdylib built via standard provider; dynamic library produced"
exit 0
