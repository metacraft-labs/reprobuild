# Windows-friendly test driver: runs all pre-built ``t_*.exe`` test
# binaries under ``build/test-bin/`` and tallies pass/fail.
#
# Assumes the binaries have already been compiled (run_tests.sh does
# the compile phase fine on Windows; the test-enumeration phase
# fails because Git Bash's ``find`` isn't on PATH).

param(
  [int]$TimeoutSeconds = 300,
  [string]$Filter = "*"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Resolve-Path (Join-Path $ScriptRoot "..")
$TestBinDir = Join-Path $RepoRoot "build\test-bin"

if (-not (Test-Path $TestBinDir)) {
  throw "test-bin dir not found: $TestBinDir"
}

# Ensure nim + gcc on PATH so subprocess-spawned ``nim c``s (the
# dev-env edge tests + fixture-provider compiles) can find them.
$env:PATH = "D:\metacraft-dev-deps\nim\2.2.8\prebuilt\nim-2.2.8\bin;" +
            "D:\metacraft-dev-deps\gcc\15.2.0\bin;" +
            "D:\metacraft-dev-deps\go\1.23.4\bin;" + $env:PATH

Set-Location $RepoRoot

$candidates = Get-ChildItem -Path $TestBinDir -Filter "t_$Filter.exe"
# Skip stale ``.exe`` artifacts whose source has been deleted (e.g.,
# ``t_catalog_profile_cli`` whose ``.nim`` was rolled back at some
# point but the binary stuck around in ``build/test-bin``). Without
# this filter the driver runs the stale exe and the user has to
# triage failures that aren't reproducible from the current tree.
$sources = @{}
foreach ($s in Get-ChildItem -Path $RepoRoot -Recurse -Filter "t_*.nim" -ErrorAction SilentlyContinue) {
  $sources[$s.BaseName] = $true
}
$tests = $candidates | Where-Object { $sources.ContainsKey($_.BaseName) }
$stale = ($candidates | Where-Object { -not $sources.ContainsKey($_.BaseName) }).Count
Write-Host "Found $($tests.Count) test binaries ($stale stale skipped)"

$passed = @()
$failed = @()
$timedOut = @()

foreach ($t in $tests) {
  $name = $t.BaseName
  Write-Host -NoNewline "  $name ... "
  $logFile = Join-Path $env:TEMP "reprobuild-test-$name.log"
  $job = Start-Job -ScriptBlock {
    param($exe, $log, $cwd, $extraPath)
    # Start-Job spawns a fresh pwsh whose default cwd is the user's
    # home (Documents), not the parent's cwd. Several reprobuild
    # tests use ``getCurrentDir()`` to locate ``build/bin/repro.exe``
    # — without re-applying the parent's cwd those tests blow up
    # with "Requested command not found".
    Set-Location -LiteralPath $cwd
    # Same caveat for PATH: the child pwsh inherits the parent's
    # session env, but only if the parent's env mutations were made
    # via [Environment]::SetEnvironmentVariable(..., 'Process').
    # Mutations via ``$env:PATH=...`` only affect the current pwsh
    # session, so re-apply.
    $env:PATH = $extraPath + ";" + $env:PATH
    & $exe *> $log
    return $LASTEXITCODE
  } -ArgumentList $t.FullName, $logFile, $RepoRoot, ("D:\metacraft-dev-deps\python\3.12.10;" +
    "D:\metacraft-dev-deps\python\3.12.10\Scripts;" +
    "D:\metacraft-dev-deps\nim\2.2.8\prebuilt\nim-2.2.8\bin;" +
    "D:\metacraft-dev-deps\gcc\15.2.0\bin;" +
    "D:\metacraft-dev-deps\go\1.23.4\bin")
  $finished = Wait-Job -Job $job -Timeout $TimeoutSeconds
  if ($null -eq $finished) {
    Write-Host "TIMEOUT" -ForegroundColor Yellow
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    $timedOut += $name
    Get-Process | Where-Object { $_.Name -eq $name } |
      Stop-Process -Force -ErrorAction SilentlyContinue
    continue
  }
  $rc = Receive-Job -Job $job
  Remove-Job -Job $job -ErrorAction SilentlyContinue
  if ($rc -eq 0) {
    Write-Host "OK" -ForegroundColor Green
    $passed += $name
  } else {
    Write-Host "FAIL (exit=$rc)" -ForegroundColor Red
    $failed += $name
    if (Test-Path $logFile) {
      $tail = Get-Content $logFile -Tail 6
      foreach ($l in $tail) { Write-Host "    $l" }
    }
  }
}

Write-Host ""
Write-Host "==== Summary ===="
Write-Host "Passed:   $($passed.Count)"
Write-Host "Failed:   $($failed.Count)"
Write-Host "TimedOut: $($timedOut.Count)"
if ($failed.Count -gt 0) {
  Write-Host ""
  Write-Host "Failed tests:"
  foreach ($f in $failed) { Write-Host "  $f" }
}
if ($timedOut.Count -gt 0) {
  Write-Host ""
  Write-Host "Timed-out tests:"
  foreach ($t in $timedOut) { Write-Host "  $t" }
}
exit ($failed.Count + $timedOut.Count)
