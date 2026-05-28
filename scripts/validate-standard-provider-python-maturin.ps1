#requires -Version 5
# End-to-end M24 verification: build the python/pep517-maturin fixture
# via the Tier 2b dispatch path. The M24 Python convention detects the
# maturin backend in pyproject.toml and routes the project through the
# Mode B crude fallback (``python -m build --wheel --no-isolation``).
# Maturin in turn invokes ``cargo`` to compile the Rust crate into a
# PyO3 extension wheel.
#
# Mechanics:
#
#   1. Source D:/metacraft/env.ps1.
#   2. Probe for rustc + cargo (fall back to rustup stable under
#      D:/metacraft-dev-deps/rustup). SKIP if Rust toolchain absent.
#   3. Probe for python3/python + the importability of ``maturin`` and
#      ``build``. SKIP if either module isn't installed.
#   4. Wipe prior scratch (``dist`` / ``target`` / ``.repro`` under
#      the fixture) so the build runs cold.
#   5. Invoke repro.exe build <fixture>#default --tool-provisioning=path.
#   6. Assert exit code 0.
#   7. Assert at least one ``*.whl`` under ``<fixture>/dist/``.
#
# Per reprobuild-specs/Standard-Provider-Implementation.milestones.org §M24.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot       = (Resolve-Path "$PSScriptRoot\..").Path
$metacraftRoot  = (Resolve-Path "$PSScriptRoot\..\..").Path
$reproExe       = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe    = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$fixture        = Join-Path $metacraftRoot 'reprobuild-examples\python\pep517-maturin'
$distDir        = Join-Path $fixture 'dist'

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
  Write-Host "SKIP: rustc/cargo not available -- maturin needs a Rust toolchain."
  exit 0
}
Write-Host "rustc = $((Get-Command rustc).Source)"
Write-Host "cargo = $((Get-Command cargo).Source)"

# --- probe for python + maturin + build modules ---
$pythonCmd = $null
foreach ($n in @('python3', 'python')) {
  $cand = Get-Command $n -ErrorAction SilentlyContinue
  if ($cand) { $pythonCmd = $cand; break }
}
if (-not $pythonCmd) {
  Write-Host "SKIP: python3/python not on PATH -- M24 Mode B uses 'python -m build'."
  exit 0
}
Write-Host "python = $($pythonCmd.Source)"

foreach ($mod in @('maturin', 'build')) {
  & $pythonCmd.Source -c "import $mod" 2>$null
  if ($LASTEXITCODE -ne 0) {
    Write-Host "SKIP: python module '$mod' not importable. Install via: $($pythonCmd.Source) -m pip install $mod"
    exit 0
  }
}
Write-Host "python modules: maturin + build importable"

# maturin's PEP 517 hook calls ``subprocess.run('maturin', ...)`` so
# the ``maturin.exe`` bundled in ``<python>/Scripts/`` must be on
# PATH. The convention's crude action inherits the parent process's
# env, so prepending here is enough.
$pythonScripts = Join-Path (Split-Path $pythonCmd.Source -Parent) 'Scripts'
if (Test-Path -LiteralPath (Join-Path $pythonScripts 'maturin.exe')) {
  if (-not ($env:PATH -split ';' | Where-Object { $_ -ieq $pythonScripts })) {
    $env:PATH = "$pythonScripts;$env:PATH"
    Write-Host "PATH prepended with $pythonScripts (maturin.exe lives there)"
  }
}

# pyo3 / maturin require the Python development headers + import
# library to link against. On Windows the import library lives at
# ``<python_prefix>/libs/python<MAJ><MIN>.lib``; on POSIX it's
# ``<python_prefix>/lib/libpython<MAJ>.<MIN>.{so,a}``. The embeddable
# Windows Python distribution OMITS ``libs/`` deliberately — projects
# wanting to build C/Rust extensions must use a "full" install (e.g.
# from python.org or via uv). SKIP cleanly when the import library is
# missing rather than failing with a cryptic LNK1181.
$pythonPrefix = Split-Path $pythonCmd.Source -Parent
$pythonLibsDir = Join-Path $pythonPrefix 'libs'
$hasPythonImportLib = $false
if (Test-Path -LiteralPath $pythonLibsDir) {
  $importLibs = @(Get-ChildItem -LiteralPath $pythonLibsDir -Filter 'python*.lib' -ErrorAction SilentlyContinue)
  if ($importLibs.Count -gt 0) { $hasPythonImportLib = $true }
}
# POSIX: the lib name pattern is different; we trust the python.org
# build to have the dev headers + lib alongside the interpreter.
if (-not ($IsWindows -or $env:OS -eq 'Windows_NT')) {
  $hasPythonImportLib = $true
}
if (-not $hasPythonImportLib) {
  Write-Host "SKIP: Python install lacks the import library (looked for python*.lib under $pythonLibsDir). The embeddable Windows Python distribution omits libs/; PyO3 extensions need a full install (python.org or via uv)."
  exit 0
}
Write-Host "python import library present under $pythonLibsDir"

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

# --- wipe prior scratch ---
foreach ($leftover in @('.repro', 'dist', 'target', 'build')) {
  $leftoverPath = Join-Path $fixture $leftover
  if (Test-Path -LiteralPath $leftoverPath) {
    Write-Host "wiping prior $leftoverPath"
    Remove-Item -LiteralPath $leftoverPath -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# --- invoke repro build ---
$reproTarget = "$fixture#default"
$stdoutCapture = Join-Path $repoRoot 'build\validate-standard-provider-python-maturin.stdout.txt'
$stderrCapture = Join-Path $repoRoot 'build\validate-standard-provider-python-maturin.stderr.txt'
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

# --- assert the wheel exists ---
if (-not (Test-Path -LiteralPath $distDir)) {
  Write-Host "FAIL: expected dist directory missing at $distDir"
  exit 1
}
$wheels = @(Get-ChildItem -LiteralPath $distDir -Filter '*.whl' -ErrorAction SilentlyContinue)
if ($wheels.Count -eq 0) {
  Write-Host "FAIL: no .whl found under $distDir"
  Write-Host "--- contents of dist:"
  Get-ChildItem -LiteralPath $distDir -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "  $($_.Name)  $($_.Length) bytes" }
  exit 1
}
foreach ($wheel in $wheels) {
  Write-Host "produced wheel: $($wheel.FullName)"
  Write-Host "  size: $($wheel.Length) bytes"
}

Write-Host ""
Write-Host "PASS: python/pep517-maturin built via M24 Mode B fallback; wheel produced"
exit 0
