#requires -Version 5
# M2 integration test: when a reprobuild.nim package declares no
# `build:` block, the engine's executeBuildTarget must dispatch to the
# pre-built `repro-standard-provider` binary instead of compiling a
# per-project provider. We detect the dispatch by reading the REPRO_STATS_DIR
# record the engine drops on every invocation and asserting that
# `fastPath == "tier2b-standard-direct"`.
#
# We deliberately use a package whose `uses:` token does NOT match any
# registered convention. The standard provider's M1 dispatch path will
# return a "no convention matched" diagnostic and exit non-zero; the
# engine surfaces that as a non-zero process exit. The DISPATCH
# (fastPath value) is what proves the engine routing is wired — the
# build's eventual failure is incidental.

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\..\..\env.ps1"

$repoRoot    = (Resolve-Path "$PSScriptRoot\..").Path
$reproExe    = Join-Path $repoRoot 'build\bin\repro.exe'
$providerExe = Join-Path $repoRoot 'build\bin\repro-standard-provider.exe'
$workRoot    = Join-Path $repoRoot 'build\validate-engine-standard-dispatch'
$projectDir  = Join-Path $workRoot 'project'
$statsDir    = Join-Path $workRoot 'stats'

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
New-Item -ItemType Directory -Force -Path $statsDir   | Out-Null

# --- step 1: materialise a minimal reprobuild.nim with no `build:` block ---
$projectReprobuildNim = @'
import repro_project_dsl

# No `build:` block, no executable/library declarations. Pure
# metadata. `ProjectInterface.standardBuildEligible` should be true.
# The `uses:` token deliberately does NOT match any registered
# convention, so the standard provider's dispatch will fail loudly --
# but the routing decision (fastPath) is what this test verifies.
package m2EligibleExample:
  uses:
    "dummy-language >=1.0"
'@
$projectReprobuildPath = Join-Path $projectDir 'reprobuild.nim'
$projectReprobuildNim | Out-File -FilePath $projectReprobuildPath -Encoding ascii
Write-Host "wrote $projectReprobuildPath"

# --- step 2: invoke `repro build` with stats collection ------------------
$env:REPRO_STATS_DIR = $statsDir
try {
  $stdoutCapture = Join-Path $workRoot 'repro.stdout.txt'
  $stderrCapture = Join-Path $workRoot 'repro.stderr.txt'
  $reproTarget   = "$projectDir#default"
  Write-Host "==> launching repro.exe build $reproTarget"
  # Run from the repo root so reprobuildLibraryWorkDir() resolves to it
  # via the cwd check and the runner script can find libs/ for --path.
  $proc = Start-Process -FilePath $reproExe -ArgumentList @(
      'build', $reproTarget,
      '--tool-provisioning=path',
      '--log=quiet'
    ) -NoNewWindow -PassThru -Wait `
    -WorkingDirectory $repoRoot `
    -RedirectStandardOutput $stdoutCapture `
    -RedirectStandardError  $stderrCapture
  $exitCode = $proc.ExitCode
}
finally {
  Remove-Item Env:REPRO_STATS_DIR -ErrorAction SilentlyContinue
}

Write-Host "--- repro exit code: $exitCode"
$stdoutTail = if (Test-Path $stdoutCapture) {
  (Get-Content -LiteralPath $stdoutCapture -Tail 10) -join "`n"
} else { "<no stdout>" }
$stderrTail = if (Test-Path $stderrCapture) {
  (Get-Content -LiteralPath $stderrCapture -Tail 10) -join "`n"
} else { "<no stderr>" }
Write-Host "--- repro stdout (last 10 lines):"
Write-Host $stdoutTail
Write-Host "--- repro stderr (last 10 lines):"
Write-Host $stderrTail

# --- step 3: assertions --------------------------------------------------
$statsFiles = @(Get-ChildItem -LiteralPath $statsDir -Filter '*.json' -ErrorAction SilentlyContinue)
if ($statsFiles.Count -eq 0) {
  Write-Host "FAIL: REPRO_STATS_DIR=$statsDir is empty after the build invocation"
  exit 1
}

$failures = @()
$dispatchRecord = $null
foreach ($file in $statsFiles) {
  $raw = Get-Content -LiteralPath $file.FullName -Raw
  try {
    $record = $raw | ConvertFrom-Json
  } catch {
    $failures += "stats record $($file.Name) is not valid JSON: $($_.Exception.Message)"
    continue
  }
  if ($record.fastPath -eq 'tier2b-standard-direct') {
    $dispatchRecord = $record
    break
  }
}

if ($null -eq $dispatchRecord) {
  $failures += "no stats record has fastPath=='tier2b-standard-direct'"
  Write-Host "--- stats files found:"
  foreach ($f in $statsFiles) {
    $raw = Get-Content -LiteralPath $f.FullName -Raw
    Write-Host "  $($f.Name): $raw"
  }
} else {
  # The dispatch record's target should mention the temp project root.
  # parseBuildTarget normalises path separators, so compare against both
  # raw and forward-slash forms (Windows hands the helper a backslash
  # path).
  $targetField = "$($dispatchRecord.target)"
  $projectDirFwd = $projectDir.Replace('\','/')
  if (-not ($targetField -like "*$projectDir*") -and
      -not ($targetField -like "*$projectDirFwd*")) {
    $failures += "dispatch stats record target='$targetField' does not mention project dir '$projectDir'"
  }
  Write-Host "--- matched stats record: target='$targetField' fastPath='$($dispatchRecord.fastPath)' exitCode=$($dispatchRecord.exitCode)"
}

if ($failures.Count -gt 0) {
  Write-Host ""
  foreach ($f in $failures) {
    Write-Host "FAIL: $f"
  }
  exit 1
}

Write-Host ""
Write-Host "PASS: engine dispatched the standard-provider binary (fastPath=tier2b-standard-direct)"
exit 0
