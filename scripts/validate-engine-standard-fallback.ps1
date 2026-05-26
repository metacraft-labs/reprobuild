#requires -Version 5
# M2 integration test: when a reprobuild.nim package would be eligible
# for the Tier 2b fast path but `repro-standard-provider` is missing
# from the install, the engine logs a warning and falls back to the
# per-project provider-compile slow path. This script proves that
# fallback by temporarily renaming the provider binary out of the way.
#
# The slow path will eventually fail because the package has no
# `build:` body to compile a provider for, but that failure is
# incidental -- the FALLBACK BEHAVIOUR (warning + slow-path attempt)
# is what we verify.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot    = (Resolve-Path "$PSScriptRoot\..").Path
$reproExe    = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$workRoot    = Join-Path $repoRoot 'build\validate-engine-standard-fallback'
$projectDir  = Join-Path $workRoot 'project'

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

# --- step 1: materialise the same minimal reprobuild.nim as the dispatch test
$projectReprobuildNim = @'
import repro_project_dsl

# No `build:` block -- standardBuildEligible would be true. With the
# standard-provider binary moved aside we expect the engine to log a
# warning and fall back to the slow path.
package m2FallbackExample:
  uses:
    "dummy-language >=1.0"
'@
$projectReprobuildPath = Join-Path $projectDir 'reprobuild.nim'
$projectReprobuildNim | Out-File -FilePath $projectReprobuildPath -Encoding ascii
Write-Host "wrote $projectReprobuildPath"

# --- step 2: temporarily rename the provider binary aside -----------------
$providerBak = $providerExe + '.bak'
if (Test-Path -LiteralPath $providerBak) {
  Remove-Item -LiteralPath $providerBak -Force
}
Move-Item -LiteralPath $providerExe -Destination $providerBak

try {
  $stdoutCapture = Join-Path $workRoot 'repro.stdout.txt'
  $stderrCapture = Join-Path $workRoot 'repro.stderr.txt'
  $reproTarget   = "$projectDir#default"
  Write-Host "==> launching repro.exe build $reproTarget (provider moved aside)"
  # Run from the repo root so reprobuildLibraryWorkDir() resolves to it
  # via the cwd check and the runner script can find libs/ for --path.
  $proc = Start-Process -FilePath $reproExe -ArgumentList @(
      'build', $reproTarget,
      '--tool-provisioning=path',
      '--log=actions'
    ) -NoNewWindow -PassThru -Wait `
    -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $stdoutCapture `
    -RedirectStandardError  $stderrCapture
  $exitCode = $proc.ExitCode
}
finally {
  # Always restore the binary so subsequent tests don't see a broken
  # install. `Move-Item -Force` ensures we overwrite any partial copy
  # that may have been left around.
  if (Test-Path -LiteralPath $providerBak) {
    if (Test-Path -LiteralPath $providerExe) {
      Remove-Item -LiteralPath $providerExe -Force
    }
    Move-Item -LiteralPath $providerBak -Destination $providerExe -Force
  }
}

Write-Host "--- repro exit code: $exitCode"
$combined = @()
if (Test-Path $stdoutCapture) { $combined += Get-Content -LiteralPath $stdoutCapture }
if (Test-Path $stderrCapture) { $combined += Get-Content -LiteralPath $stderrCapture }
$combinedText = $combined -join "`n"
Write-Host "--- combined output (last 25 lines):"
$tail = $combined | Select-Object -Last 25
Write-Host (($tail -join "`n"))

# --- step 3: assertions --------------------------------------------------
$failures = @()
if ($combinedText -notmatch 'standardDirect: provider binary missing') {
  $failures += "expected 'standardDirect: provider binary missing' warning in output"
}
# Fallback should have continued into the slow path. The slow path
# enters the typed-tool-provisioning block, which emits any of:
#   - 'repro build: tool provisioning active' (summary line)
#   - 'providerCompile' (summary line, downstream of identity resolve)
#   - 'tool-resolution failed' (when the project uses an unknown tool,
#     as our `dummy-language` fixture intentionally does)
# Any of those proves the engine did NOT bail at the missing-binary
# check and made it past the Tier 2b dispatch point.
if ($combinedText -notmatch 'providerCompile' -and
    $combinedText -notmatch 'tool provisioning active' -and
    $combinedText -notmatch 'tool-resolution failed') {
  $failures += "no evidence the engine continued onto the slow path (expected one of: 'providerCompile', 'tool provisioning active', 'tool-resolution failed')"
}

if ($failures.Count -gt 0) {
  Write-Host ""
  foreach ($f in $failures) {
    Write-Host "FAIL: $f"
  }
  exit 1
}

# Verify the provider binary was restored.
if (-not (Test-Path -LiteralPath $providerExe)) {
  Write-Host "FAIL: provider binary was not restored after the test"
  exit 1
}

Write-Host ""
Write-Host "PASS: engine warned 'standardDirect: provider binary missing' and continued onto the slow path"
exit 0
