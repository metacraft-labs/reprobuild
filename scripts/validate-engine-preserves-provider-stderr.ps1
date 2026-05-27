#requires -Version 5
# Integration test for the M8 stderr-truncation fix: when `repro build`
# invokes a provider that exits non-zero, the engine MUST preserve the
# provider's full diagnostic in the error message, not truncate it to a
# single byte.
#
# Pre-fix behaviour (the bug this script guards against):
#
#   repro build .#default --tool-provisioning=path
#   repro build: error: provider exited with code 3: r
#                                                    ^^^
#                                                    only one byte
#
# Post-fix behaviour (what this script asserts):
#
#   repro build: error: provider exited with code 3:
#     repro-standard-provider: no convention matched for project root
#     'D:\...\fake-project' (uses: nonexistent_language)
#
# Root cause: ``runProviderProtocol`` /
# ``runStableProviderProtocol`` used ``startProcess`` +
# ``outputStream.readAll`` + ``waitForExit`` to drive the provider
# binary. On Windows the ``readAll`` path returned only the first byte
# of the merged stdout/stderr pipe (the standard provider writes its
# diagnostic to stderr with ``poStdErrToStdOut`` merging it into the
# captured stream). Switched to ``execCmdEx`` which uses ``readLine`` +
# ``peekExitCode`` to drain incrementally, matching the M6.5 cargo /
# Go-list pipe-buffer fixes in
# ``libs/repro_standard_provider/src/repro_standard_provider/conventions/``.
#
# Note: the existing ``validate-standard-provider-no-match.ps1``
# exercises the same provider diagnostic but invokes the provider
# *directly* via PowerShell ``Start-Process -RedirectStandardError`` —
# it bypasses the engine's pipe-drain code entirely. This script
# *requires* the engine's call path to exercise the bug.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot    = (Resolve-Path "$PSScriptRoot\..").Path
$reproExe    = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$workRoot    = Join-Path $repoRoot 'build\validate-engine-preserves-provider-stderr'
$projectDir  = Join-Path $workRoot 'fake-project'

if (-not (Test-Path -LiteralPath $reproExe)) {
  Write-Host "FAIL: missing $reproExe -- run scripts\build_apps.sh first"
  exit 1
}
if (-not (Test-Path -LiteralPath $providerExe)) {
  Write-Host "FAIL: missing $providerExe -- run scripts\build_apps.sh first"
  exit 1
}

if (Test-Path -LiteralPath $workRoot) {
  Remove-Item -LiteralPath $workRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $projectDir | Out-Null

# --- step 1: write a reprobuild.nim whose uses: hint matches NO -----------
# --- registered convention. The standard provider's M1 dispatch ---------
# --- will exit non-zero with the "no convention matched" diagnostic. ----
$projectReprobuildNim = @'
# Project fixture for the M8 stderr-preservation regression. The
# `nonexistent_language` token does NOT correspond to any registered
# convention, so the standard provider exits non-zero with a
# "no convention matched" diagnostic. The engine MUST surface the
# full diagnostic in its error message.

import repro_project_dsl

package engine_preserves_provider_stderr:
  uses:
    "nonexistent_language"
'@
$projectReprobuildPath = Join-Path $projectDir 'reprobuild.nim'
$projectReprobuildNim | Out-File -FilePath $projectReprobuildPath -Encoding ascii
Write-Host "wrote $projectReprobuildPath"

# --- step 2: invoke `repro build` and capture combined stdout/stderr ------
# Mirror validate-engine-standard-dispatch.ps1's process model: launch
# repro.exe via Start-Process with -WorkingDirectory set to the repo
# root (so ``reprobuildLibraryWorkDir()`` resolves to it via the cwd
# check and the runner script can find libs/ for --path) and target the
# project by absolute path. Doing this with ``Push-Location`` into the
# project dir trips direnv loaded by an outer ``.envrc`` and clobbers
# PATH for the engine's child processes. Combined stdout+stderr is
# captured into a single log file by redirecting both streams to two
# files and concatenating; the assertions below run against the union.
$stdoutCapture = Join-Path $workRoot 'repro.stdout.txt'
$stderrCapture = Join-Path $workRoot 'repro.stderr.txt'
$reproTarget   = "$projectDir#default"
Write-Host "==> running: $reproExe build $reproTarget --tool-provisioning=path"
$proc = Start-Process -FilePath $reproExe -ArgumentList @(
    'build', $reproTarget,
    '--tool-provisioning=path'
  ) -NoNewWindow -PassThru -Wait `
  -WorkingDirectory $repoRoot `
  -RedirectStandardOutput $stdoutCapture `
  -RedirectStandardError  $stderrCapture
$reproExit = $proc.ExitCode

$logText = ""
if (Test-Path -LiteralPath $stdoutCapture) {
  $raw = Get-Content -LiteralPath $stdoutCapture -Raw
  if ($raw) { $logText += $raw }
}
if (Test-Path -LiteralPath $stderrCapture) {
  $raw = Get-Content -LiteralPath $stderrCapture -Raw
  if ($raw) { $logText += $raw }
}

Write-Host ""
Write-Host "--- repro build exit code: $reproExit"
Write-Host "--- captured output ---"
Write-Host $logText
Write-Host "---"

# --- step 3: assertions ---------------------------------------------------
$failures = @()

# The engine should propagate the provider's non-zero exit.
if ($reproExit -eq 0) {
  $failures += "expected `repro build` to fail (the provider rejects the project) but it succeeded"
}

# The error must mention that the provider exited with a non-zero code.
if ($logText -notmatch 'provider exited with code') {
  $failures += "captured output is missing the 'provider exited with code' framing -- did the engine surface the provider failure?"
}

# This is the load-bearing assertion: the provider's diagnostic body
# must appear verbatim. The pre-fix bug truncated this to a single
# byte ('r').
if ($logText -notmatch 'no convention matched for project root') {
  $failures += "captured output is missing the FULL provider diagnostic 'no convention matched for project root' -- stderr was truncated"
}

# The diagnostic must name the offending `uses:` entry.
if ($logText -notmatch 'nonexistent_language') {
  $failures += "captured output is missing the offending uses: token 'nonexistent_language' -- diagnostic body was lost"
}

if ($failures.Count -gt 0) {
  Write-Host ""
  foreach ($f in $failures) {
    Write-Host "FAIL: $f"
  }
  exit 1
}

Write-Host ""
Write-Host "PASS: repro build preserves the full provider diagnostic when the provider exits non-zero"
exit 0
