#requires -Version 5
# End-to-end verification: M36 cross-language Mode 3 workspace where a
# C++ binary calls into a Go static library declared in the same
# repro.nim (REVERSE direction, c-archive). The go-direct convention
# takes ownership of dispatch because c-cpp-direct's recognize defers
# when the workspace's ``uses:`` block names ``go`` (and no ``go.mod``
# / ``go.work`` is present). It then emits the Go library via
# ``go build -buildmode=c-archive`` (producing both ``libgoaddlib.a``
# AND ``libgoaddlib.h``) and wires the archive onto the C++ binary's
# link line as a trailing positional + the platform-specific Go
# runtime libs.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1 so nim/gcc/repro are on PATH;
#      prepend the bundled Go toolchain so ``go`` resolves.
#   2. Probe for go AND g++ (with fallback to clang++); SKIP exit 0 if
#      either toolchain is missing.
#   3. Wipe any prior .repro/ scratch under the fixture so the build
#      runs cold.
#   4. Verify ``repro deps refresh --check`` exits 0.
#   5. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   6. Assert exit code 0.
#   7. Verify both artefacts exist:
#       * the Go c-archive : ``<fixture>/.repro/build/goaddlib/libgoaddlib.a``
#       * the C++ binary   : ``<fixture>/.repro/build/cppapp/cppapp[.exe]``
#   8. Run the C++ binary and assert stdout contains:
#         "cpp says: GoAdd 2+3 = 5"
#         "hello from cpp-uses-go-lib"
#      The first line proves the Go c-archive's GoAdd symbol is linked
#      AND callable from C++ via the cgo c-archive runtime (the
#      cross-language round-trip succeeded).

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\mixed\cpp-uses-go-lib'
$scratchInsideFixture = Join-Path $fixture '.repro'
$libArchive     = Join-Path $fixture '.repro\build\goaddlib\libgoaddlib.a'
$libHeader      = Join-Path $fixture '.repro\build\goaddlib\libgoaddlib.h'
$gomodSyntheticFile = Join-Path $fixture 'goaddlib\go.mod'
$expectedAddition = 'cpp says: GoAdd 2+3 = 5'
$expectedGreeting = 'hello from cpp-uses-go-lib'

# --- preflight ---
if (-not (Test-Path -LiteralPath $reproExe)) {
  Write-Host "FAIL: missing $reproExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath $providerExe)) {
  Write-Host "FAIL: missing $providerExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath (Join-Path $fixture 'repro.nim'))) {
  Write-Host "FAIL: fixture missing at $fixture -- expected reprobuild-examples checkout"
  exit 1
}

# --- toolchain probe ---
$goCmd = Get-Command go -ErrorAction SilentlyContinue
if (-not $goCmd) {
  $goRoot = 'D:/metacraft-dev-deps/go'
  if (Test-Path -LiteralPath $goRoot) {
    foreach ($verDir in Get-ChildItem -LiteralPath $goRoot -Directory -ErrorAction SilentlyContinue) {
      $candidate = Join-Path $verDir.FullName 'go\bin\go.exe'
      if (Test-Path -LiteralPath $candidate) {
        $binDir = Split-Path -Parent $candidate
        $env:PATH = "$binDir;$env:PATH"
        $goCmd = Get-Command go -ErrorAction SilentlyContinue
        break
      }
    }
  }
}
if (-not $goCmd) {
  Write-Host "SKIP: 'go' not on PATH and no bundled Go under D:/metacraft-dev-deps/go"
  exit 0
}
$cxx = Get-Command g++ -ErrorAction SilentlyContinue
if (-not $cxx) { $cxx = Get-Command clang++ -ErrorAction SilentlyContinue }
if (-not $cxx) {
  Write-Host "SKIP: neither g++ nor clang++ on PATH; cannot build mixed cpp-uses-go-lib (C++ link driver)"
  exit 0
}
# The Go c-archive build itself also needs a C compiler at build time
# (cgo's external linker bridge); gcc/clang must also be available.
$cc = Get-Command gcc -ErrorAction SilentlyContinue
if (-not $cc) { $cc = Get-Command clang -ErrorAction SilentlyContinue }
if (-not $cc) {
  Write-Host "SKIP: neither gcc nor clang on PATH; Go's c-archive build mode needs a C compiler"
  exit 0
}
Write-Host "==> using go=$($goCmd.Source)"
Write-Host "==> using cc=$($cc.Source); cxx=$($cxx.Source)"

# --- step 1: deps refresh --check ---
Write-Host "==> repro deps refresh --check $fixture"
& $reproExe deps refresh --check $fixture
if ($LASTEXITCODE -ne 0) {
  Write-Host "FAIL: deps refresh --check failed; repro.scanned-deps.nim is out of date"
  exit 1
}

# --- step 2: clean prior scratch + synthesised go.mod ---
if (Test-Path -LiteralPath $scratchInsideFixture) {
  Write-Host "wiping prior scratch dir $scratchInsideFixture"
  Remove-Item -LiteralPath $scratchInsideFixture -Recurse -Force
}
if (Test-Path -LiteralPath $gomodSyntheticFile) {
  Write-Host "wiping prior synthesised go.mod at $gomodSyntheticFile"
  Remove-Item -LiteralPath $gomodSyntheticFile -Force
}

# --- step 3: invoke `repro build` ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-mixed-cpp-uses-go-lib.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-mixed-cpp-uses-go-lib.stderr.txt'
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

# --- step 4: verify archive + header exist ---
if (-not (Test-Path -LiteralPath $libArchive)) {
  Write-Host "FAIL: expected Go c-archive not found at $libArchive"
  exit 1
}
Write-Host "produced archive: $libArchive ($((Get-Item $libArchive).Length) bytes)"
if (-not (Test-Path -LiteralPath $libHeader)) {
  Write-Host "FAIL: expected auto-generated C header not found at $libHeader"
  exit 1
}
Write-Host "produced header: $libHeader ($((Get-Item $libHeader).Length) bytes)"

# --- step 5: locate produced binary ---
$candidates = @(
  (Join-Path $fixture '.repro\build\cppapp\cppapp.exe'),
  (Join-Path $fixture '.repro\build\cppapp\cppapp')
)
$producedBinary = $null
foreach ($candidate in $candidates) {
  if (Test-Path -LiteralPath $candidate) {
    $producedBinary = $candidate
    break
  }
}
if (-not $producedBinary) {
  Write-Host "FAIL: expected C++ binary not found at any of:"
  foreach ($c in $candidates) { Write-Host "    $c" }
  exit 1
}
Write-Host "produced binary: $producedBinary ($((Get-Item $producedBinary).Length) bytes)"

# --- step 6: run and assert greeting + Go call result ---
Write-Host "==> running $producedBinary"
$output = & $producedBinary 2>&1 | Out-String
$runExit = $LASTEXITCODE
Write-Host "--- binary exit code: $runExit"
Write-Host "--- binary stdout:"
Write-Host $output

if ($runExit -ne 0) {
  Write-Host "FAIL: produced binary exited with code $runExit"
  exit 1
}
if ($output -notmatch [regex]::Escape($expectedAddition)) {
  Write-Host "FAIL: produced binary stdout does not contain expected addition output '$expectedAddition' (this proves the Go c-archive's GoAdd() symbol is linked AND callable from C++)"
  exit 1
}
if ($output -notmatch [regex]::Escape($expectedGreeting)) {
  Write-Host "FAIL: produced binary stdout does not contain expected greeting '$expectedGreeting'"
  exit 1
}

Write-Host ""
Write-Host "PASS: mixed/cpp-uses-go-lib built via standard provider; cross-language call to Go GoAdd() produced cpp says: GoAdd 2+3 = 5; libgoaddlib.a archive + libgoaddlib.h header produced"
exit 0
