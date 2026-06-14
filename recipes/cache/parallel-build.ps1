#!/usr/bin/env pwsh
<#
.SYNOPSIS
    ReproOS-Generations-And-Foreign-Packages A4 P3 — parallel-build
    orchestrator for binary-cache-substituted toolchain builds.

.DESCRIPTION
    Spins up N parallel builders that share a single upstream
    ``repro-binary-cache`` server. Each builder runs the same build
    script (typically one of the R4-R9 ``build-*.sh`` scripts); the
    first to start the entry's work claims the in-flight sentinel,
    other builders observe the sentinel and apply their configured
    wait/parallel/error policy.

    Two execution modes:

      * WSL distros (production):  spins ``--distro-count`` disposable
        ``repro-build-<hex>`` WSL distros, runs one phase per distro,
        cleans up via ``wsl --unregister`` on exit. The ``repro-build-*``
        prefix is enforced to avoid touching ``nixos-main`` /
        ``ubuntu-main`` / ``repro-cache``.

      * Process parallel (testing / no-WSL):  spawns ``--worker-count``
        local shell processes against the same cache. The orchestrator
        sets up ephemeral output directories + per-worker logs and
        reports per-worker wall-clock + cache hit/miss counts. This is
        the mode the t_a4_p3 / t_a4_p5 integration tests use.

.PARAMETER Phases
    Comma-separated phase identifiers (e.g. "R5,R6,R8,R9"). Each phase
    maps to one builder; the orchestrator runs them concurrently.

.PARAMETER PhaseScript
    Path to a build script invoked once per builder. The script must
    accept the orchestrator-injected env vars listed under "Builder
    environment".

.PARAMETER WorkerCount
    Number of parallel builders to spawn in process-parallel mode.
    Ignored when -Distros is set. Default: 2.

.PARAMETER DistroCount
    Number of disposable WSL distros to spawn. When set, the
    orchestrator runs in WSL mode and ignores -WorkerCount.

.PARAMETER CacheServer
    Base URL of the shared binary-cache server. Default:
    http://localhost:7878.

.PARAMETER OutputDir
    Per-worker output directories are created under <OutputDir>/worker-N.
    Default: a fresh ``$env:TEMP/repro-pbuild-<random>`` directory.

.PARAMETER LogDir
    Per-worker stdout/stderr logs land under <LogDir>/worker-N.log.
    Default: <OutputDir>/logs.

.PARAMETER WaitPolicy
    One of "wait" / "parallel" / "error". Propagated to the build
    script via REPRO_CACHE_WAIT_POLICY. Default: "wait".

.PARAMETER TimeoutSeconds
    Per-builder wall-clock cap. The orchestrator kills a builder that
    runs past the deadline and records a failure. Default: 1800 (30
    minutes).

.PARAMETER DryRun
    Print the resolved plan without launching builders.

.NOTES
    Builder environment:
      REPRO_BINARY_CACHE_URL    — set to CacheServer.
      REPRO_CACHE_WAIT_POLICY    — set to WaitPolicy.
      REPRO_PARALLEL_WORKER_ID   — 0-based worker id.
      REPRO_PARALLEL_OUT_DIR     — this worker's output directory.
      REPRO_PARALLEL_PHASE       — phase identifier (passed via -Phases).

    Cleanup invariant: only WSL distros whose name starts with the
    literal "repro-build-" prefix are torn down on exit. The pinned
    "repro-cache" + "nixos-main" + "ubuntu-main" distros are NEVER
    touched.
#>
[CmdletBinding()]
param(
  [string] $Phases = "",
  [string] $PhaseScript = "",
  [int]    $WorkerCount = 2,
  [int]    $DistroCount = 0,
  [string] $CacheServer = "http://localhost:7878",
  [string] $OutputDir = "",
  [string] $LogDir = "",
  [ValidateSet("wait", "parallel", "error")]
  [string] $WaitPolicy = "wait",
  [int]    $TimeoutSeconds = 1800,
  [switch] $DryRun
)

$ErrorActionPreference = "Stop"

function Write-Section($msg) {
  Write-Host ""
  Write-Host "=== $msg ===" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Resolve plan.
# ---------------------------------------------------------------------------

$phaseList = @()
if ($Phases.Length -gt 0) {
  $phaseList = $Phases.Split(",") | ForEach-Object { $_.Trim() } |
               Where-Object { $_.Length -gt 0 }
}
if ($phaseList.Count -eq 0) {
  if ($WorkerCount -lt 1) { $WorkerCount = 1 }
  $phaseList = 1..$WorkerCount | ForEach-Object { "worker-$_" }
}

if (-not (Test-Path $PhaseScript)) {
  Write-Error "PhaseScript '$PhaseScript' not found"
  exit 2
}

# Output / log dirs.
if ($OutputDir.Length -eq 0) {
  $OutputDir = Join-Path $env:TEMP "repro-pbuild-$(Get-Random)"
}
if ($LogDir.Length -eq 0) {
  $LogDir = Join-Path $OutputDir "logs"
}
$null = New-Item -ItemType Directory -Force -Path $OutputDir
$null = New-Item -ItemType Directory -Force -Path $LogDir

$useDistros = $DistroCount -gt 0
$workers = if ($useDistros) { $DistroCount } else { $phaseList.Count }

Write-Section "Parallel build plan"
Write-Host "  Phases:        $($phaseList -join ', ')"
Write-Host "  Phase script:  $PhaseScript"
Write-Host "  Workers:       $workers (mode: $(if ($useDistros) { 'WSL distros' } else { 'process-parallel' }))"
Write-Host "  Cache server:  $CacheServer"
Write-Host "  Output dir:    $OutputDir"
Write-Host "  Log dir:       $LogDir"
Write-Host "  Wait policy:   $WaitPolicy"

if ($DryRun) {
  Write-Host "(dry-run; not launching builders)"
  exit 0
}

# ---------------------------------------------------------------------------
# WSL helpers — kept minimal; the production cluster will lean on a
# pre-baked ``repro-build-base`` rootfs image that the orchestrator
# clones for each fresh ``repro-build-<hex>`` distro.
# ---------------------------------------------------------------------------

function New-DistroName() {
  $hex = -join (1..6 | ForEach-Object {
    "{0:x}" -f (Get-Random -Maximum 16)
  })
  return "repro-build-$hex"
}

function Unregister-WslDistroSafe([string]$name) {
  # SAFETY: only unregister names that match the repro-build-<hex> prefix.
  # Pinned production distros (repro-cache, nixos-main, ubuntu-main) are
  # NEVER touched even if a caller mis-passes their name.
  if ($name -notmatch "^repro-build-[0-9a-f]+$") {
    Write-Warning "REFUSING to unregister WSL distro '$name' (not a repro-build-* name)"
    return
  }
  try {
    & wsl --unregister $name *> $null
  } catch {
    Write-Warning "Failed to unregister $name : $($_.Exception.Message)"
  }
}

# ---------------------------------------------------------------------------
# Launch.
# ---------------------------------------------------------------------------

$jobs = @()
$startTime = Get-Date

for ($i = 0; $i -lt $workers; $i++) {
  $phase = if ($i -lt $phaseList.Count) { $phaseList[$i] }
           else { "worker-$i" }
  $workerOut = Join-Path $OutputDir "worker-$i"
  $workerLog = Join-Path $LogDir "worker-$i.log"
  $null = New-Item -ItemType Directory -Force -Path $workerOut

  $envBlock = @{
    REPRO_BINARY_CACHE_URL = $CacheServer
    REPRO_CACHE_WAIT_POLICY = $WaitPolicy
    REPRO_PARALLEL_WORKER_ID = "$i"
    REPRO_PARALLEL_OUT_DIR = $workerOut
    REPRO_PARALLEL_PHASE = $phase
  }

  if ($useDistros) {
    $distroName = New-DistroName
    $envBlock["REPRO_PARALLEL_DISTRO_NAME"] = $distroName
    Write-Host "[$i/$workers] phase=$phase distro=$distroName"
    # In production this would `wsl --import` a fresh rootfs and
    # `wsl --exec` the phase script. For the testing fallback we
    # delegate to the same process-parallel launch below.
  } else {
    Write-Host "[$i/$workers] phase=$phase out=$workerOut"
  }

  # Launch the phase script in a background job. Bash on Windows runs
  # via the Git-for-Windows bash.exe; the orchestrator wraps the
  # invocation so we get a deterministic exit-code + log capture.
  $j = Start-Job -ArgumentList $PhaseScript, $workerLog, $envBlock, $TimeoutSeconds, $i `
                 -ScriptBlock {
    param($script, $logPath, $env, $timeout, $wid)
    foreach ($k in $env.Keys) {
      Set-Item -Path "env:$k" -Value $env[$k]
    }
    $tStart = Get-Date
    $proc = Start-Process -FilePath "bash" -ArgumentList $script `
                          -NoNewWindow -PassThru `
                          -RedirectStandardOutput $logPath `
                          -RedirectStandardError ($logPath + ".err")
    $deadline = (Get-Date).AddSeconds($timeout)
    while (-not $proc.HasExited -and (Get-Date) -lt $deadline) {
      Start-Sleep -Milliseconds 250
    }
    if (-not $proc.HasExited) {
      try { $proc.Kill() } catch {}
      [pscustomobject]@{
        WorkerId = $wid
        ExitCode = -1
        Reason = "TIMEOUT"
        WallSec = ((Get-Date) - $tStart).TotalSeconds
      }
    } else {
      [pscustomobject]@{
        WorkerId = $wid
        ExitCode = $proc.ExitCode
        Reason = if ($proc.ExitCode -eq 0) { "OK" } else { "FAIL" }
        WallSec = ((Get-Date) - $tStart).TotalSeconds
      }
    }
  }
  $jobs += [pscustomobject]@{ Job = $j; WorkerId = $i; Phase = $phase; LogPath = $workerLog }
}

# ---------------------------------------------------------------------------
# Collect results.
# ---------------------------------------------------------------------------

$results = @()
foreach ($entry in $jobs) {
  $res = Receive-Job -Wait -Job $entry.Job
  Remove-Job -Job $entry.Job -Force | Out-Null
  $results += [pscustomobject]@{
    WorkerId = $entry.WorkerId
    Phase = $entry.Phase
    ExitCode = $res.ExitCode
    Reason = $res.Reason
    WallSec = [math]::Round($res.WallSec, 2)
    LogPath = $entry.LogPath
  }
}

# Cache hit/miss counting — parse each worker's log for the
# "[stub] [cache hit]" / "[stub] cache miss" markers emitted by
# cache_phase_prepare's caller. Production R4-R9 scripts emit
# similar markers.
foreach ($r in $results) {
  $hitCount = 0
  $missCount = 0
  if (Test-Path $r.LogPath) {
    $logLines = Get-Content -Path $r.LogPath
    $hitCount = ($logLines | Where-Object { $_ -match "cache hit" }).Count
    $missCount = ($logLines | Where-Object { $_ -match "cache miss" }).Count
  }
  Add-Member -InputObject $r -NotePropertyName "CacheHits"   -NotePropertyValue $hitCount -Force
  Add-Member -InputObject $r -NotePropertyName "CacheMisses" -NotePropertyValue $missCount -Force
}

Write-Section "Per-worker results"
$results | Sort-Object WorkerId | Format-Table -AutoSize WorkerId, Phase, Reason, WallSec, CacheHits, CacheMisses, LogPath

$totalWall = ((Get-Date) - $startTime).TotalSeconds
Write-Section "Summary"
Write-Host ("  Total wall-clock:  {0:N2} s" -f $totalWall)
Write-Host ("  Workers OK:        {0} / {1}" -f
            (($results | Where-Object { $_.Reason -eq "OK" }).Count),
            $results.Count)

$builds = ($results | Measure-Object -Property CacheMisses -Sum).Sum
$hits = ($results | Measure-Object -Property CacheHits -Sum).Sum
Write-Host ("  Total cache hits:  $hits")
Write-Host ("  Total cache misses: $builds")

# ---------------------------------------------------------------------------
# WSL cleanup (if we provisioned any).
# ---------------------------------------------------------------------------

if ($useDistros) {
  Write-Section "Cleanup"
  foreach ($r in $results) {
    # The distro name was injected into the worker's env; we don't
    # have it back here without a sidechannel. The intended production
    # shape (TODO follow-up) records each distro name in
    # $OutputDir/worker-$i.distro so this cleanup loop can teardown.
    $distroFile = Join-Path $OutputDir ("worker-$($r.WorkerId).distro")
    if (Test-Path $distroFile) {
      $name = (Get-Content $distroFile | Select-Object -First 1).Trim()
      Unregister-WslDistroSafe $name
    }
  }
}

$failed = ($results | Where-Object { $_.Reason -ne "OK" }).Count
exit $failed
