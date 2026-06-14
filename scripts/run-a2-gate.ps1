<#
.SYNOPSIS
    A2 integration-test gate harness.

.DESCRIPTION
    Builds the daemon + the two helper binaries, then runs the 5
    A2 integration tests under `tests/integration/binary_cache/`
    sequentially. Reports per-test pass/fail and summary.

    Tests:
      * t_a2_cache_info.sh
      * t_a2_persistence.sh
      * t_a2_signature_verification.sh
      * t_a2_closure_compat.sh
      * t_a2_backup_restore.sh

    Each test starts/stops its own in-process daemon under a
    random ephemeral port; tests don't interfere.

    Per the campaign spec, the same tests can run against a real
    `repro-cache` distro by setting `$env:REPRO_BINARY_CACHE_HOST`
    to a URL like `http://localhost:7878` before invoking the
    harness. The test bodies are identical; only the daemon
    bring-up path changes.

.PARAMETER Tests
    Optional list of specific test names to run. Default: all.

.PARAMETER SkipBuild
    Skip the helper-binary build step (assumes everything's
    already up to date under build/test-bin/).
#>
[CmdletBinding()]
param(
  [string[]] $Tests = @(
    "t_a2_cache_info",
    "t_a2_persistence",
    "t_a2_signature_verification",
    "t_a2_closure_compat",
    "t_a2_backup_restore"
  ),
  [switch] $SkipBuild
)

$ErrorActionPreference = 'Stop'

# Locate repo root by walking up from this script.
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

if (-not $SkipBuild) {
  Write-Host "[run-a2-gate] building daemon + helpers ..."
  $env:PATH = "D:\metacraft-dev-deps\nim\2.2.8\prebuilt\nim-2.2.8\bin;" + $env:PATH

  $buildTargets = @(
    @{ Src = "apps/repro-binary-cache/repro_binary_cache.nim";
       Out = "build/test-bin/repro_binary_cache.exe" }
    @{ Src = "tests/integration/binary_cache/lib/a2_publish_helper.nim";
       Out = "build/test-bin/a2_publish_helper.exe" }
    @{ Src = "tests/integration/binary_cache/lib/a2_verify_helper.nim";
       Out = "build/test-bin/a2_verify_helper.exe" }
  )
  foreach ($t in $buildTargets) {
    Write-Host "[run-a2-gate]   nim c $($t.Src) ..."
    & nim c --hints:off --warnings:off -d:ssl `
        ("-o:" + $t.Out) $t.Src
    if ($LASTEXITCODE -ne 0) {
      throw "build of $($t.Src) failed"
    }
  }
}

# Make sure bash + curl are available.
foreach ($tool in @('bash', 'curl', 'python3')) {
  $cmd = Get-Command $tool -ErrorAction SilentlyContinue
  if (-not $cmd) {
    throw "$tool not on PATH"
  }
}

$results = @()
foreach ($t in $Tests) {
  $path = Join-Path $repoRoot "tests/integration/binary_cache/$t.sh"
  if (-not (Test-Path $path)) {
    Write-Host "[run-a2-gate] SKIP $t (script not found at $path)"
    continue
  }
  Write-Host ""
  Write-Host "[run-a2-gate] ==> $t"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $out = & bash $path 2>&1
  $sw.Stop()
  $exit = $LASTEXITCODE
  $out | ForEach-Object { Write-Host "    $_" }
  $status = if ($exit -eq 0) { 'PASS' } else { 'FAIL' }
  $results += [pscustomobject]@{
    Name = $t
    Status = $status
    Wall = ('{0:N1}s' -f $sw.Elapsed.TotalSeconds)
    ExitCode = $exit
  }
}

Write-Host ""
Write-Host "[run-a2-gate] summary"
$results | Format-Table -AutoSize

$failed = @($results | Where-Object { $_.Status -ne 'PASS' }).Count
if ($failed -gt 0) {
  Write-Host "[run-a2-gate] $failed failure(s)" -ForegroundColor Red
  exit 1
}
Write-Host "[run-a2-gate] ALL PASS" -ForegroundColor Green
exit 0
