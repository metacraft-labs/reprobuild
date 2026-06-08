<#
  run-sandbox-bench.ps1 - HOST-SIDE launcher for the sandbox-bench harness.

  Trimmed copy of tools/sandbox-migration/run-sandbox-migration.ps1
  with these differences:
    - shorter timeout (10 min vs 40 min)
    - dedicated output dir (D:\metacraft\sandbox-bench-out)
    - reports decomposed timing on completion
#>

[CmdletBinding()]
param(
  [int]$TimeoutMinutes = 10
)

$ErrorActionPreference = 'Stop'

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$WsbFile     = Join-Path $ScriptDir 'bench.wsb'
$OutDir      = 'D:\metacraft\sandbox-bench-out'
$SandboxExe  = 'C:\Windows\System32\WindowsSandbox.exe'

function Info($m)  { Write-Host "[bench] $m" }
function Warn($m)  { Write-Host "[bench] WARNING: $m" -ForegroundColor Yellow }
function Fail($m)  { Write-Host "[bench] ERROR: $m" -ForegroundColor Red }

if (-not (Test-Path $SandboxExe)) {
  Fail "Windows Sandbox not found at $SandboxExe."; exit 1
}
if (-not (Test-Path $WsbFile)) {
  Fail "bench.wsb not found at $WsbFile"; exit 1
}

# VC++ DLL prep - shared with the migration harness.
$vcDstDir = Join-Path (Split-Path $ScriptDir -Parent) 'sandbox-migration\vcruntime'
if (-not (Test-Path $vcDstDir)) { New-Item -ItemType Directory -Path $vcDstDir -Force | Out-Null }
$vcDlls = @('vcruntime140.dll','vcruntime140_1.dll','msvcp140.dll',
            'msvcp140_1.dll','msvcp140_2.dll','concrt140.dll','vccorlib140.dll')
$vcSys32 = Join-Path $env:WINDIR 'System32'
foreach ($dll in $vcDlls) {
  $src = Join-Path $vcSys32 $dll
  if (Test-Path $src) {
    try { Copy-Item -LiteralPath $src -Destination (Join-Path $vcDstDir $dll) -Force } catch {}
  }
}

# Pre-flight: prebuilt binaries we depend on.
foreach ($need in @('repro.exe','sqlite3_64.dll')) {
  $p = Join-Path 'D:\metacraft\reprobuild\build\bin' $need
  if (-not (Test-Path $p)) {
    Fail "expected $p (the host-side launcher requires the production repro binary directory to be built)."; exit 1
  }
}
$testExe = 'D:\metacraft\reprobuild\build\test-bin\t_integration_plan_classifier_bucket_drift_is_cache_hit.exe'
if (-not (Test-Path $testExe)) {
  Fail "expected $testExe."; exit 1
}

# Clear OUTPUT.
if (Test-Path $OutDir) {
  Get-ChildItem -LiteralPath $OutDir -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
} else {
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

# Kill stale sandbox processes (mapped folders pinned by a stale session
# cause the next launch's mounts to fail silently).
$SandboxProcs = @('WindowsSandbox','WindowsSandboxClient','WindowsSandboxServer','WindowsSandboxRemoteSession')
foreach ($pn in $SandboxProcs) {
  Get-Process -Name $pn -ErrorAction SilentlyContinue | ForEach-Object {
    Warn "stopping pre-existing $pn (pid $($_.Id))"
    try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
  }
}
Start-Sleep -Seconds 2

# Record T0_wsb_launch BEFORE spawning the sandbox.
Add-Content -LiteralPath (Join-Path $OutDir 'TIMINGS.txt') `
  -Value ("T0_wsb_launch=" + (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))

Info "launching Windows Sandbox: $WsbFile"
$wallSw = [System.Diagnostics.Stopwatch]::StartNew()
try {
  Start-Process -FilePath $SandboxExe -ArgumentList "`"$WsbFile`"" | Out-Null
} catch {
  Fail "failed to launch WindowsSandbox.exe: $_"; exit 1
}

# Capture T1_logon_fired as soon as the heartbeat file shows up.
$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$DoneFile = Join-Path $OutDir 'DONE'
$HeartbeatFile = Join-Path $OutDir '_logon-heartbeat.txt'
$sawLogon = $false
$done = $false
while ((Get-Date) -lt $deadline) {
  if (-not $sawLogon -and (Test-Path $HeartbeatFile)) {
    $sawLogon = $true
    Add-Content -LiteralPath (Join-Path $OutDir 'TIMINGS.txt') `
      -Value ("T1_logon_fired_host_observed=" + (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))
    Info "  checkpoint: LogonCommand fired."
  }
  if (Test-Path $DoneFile) { $done = $true; break }
  Start-Sleep -Seconds 3
}
$wallSw.Stop()

Add-Content -LiteralPath (Join-Path $OutDir 'TIMINGS.txt') `
  -Value ("T_total_wall_ms=" + $wallSw.ElapsedMilliseconds)

if ($done) {
  Info "DONE after $([int]($wallSw.ElapsedMilliseconds/1000)) sec wall time."
} else {
  Warn "timeout - DONE never appeared after $TimeoutMinutes min."
}

Start-Sleep -Seconds 3
foreach ($pn in $SandboxProcs) {
  Get-Process -Name $pn -ErrorAction SilentlyContinue | ForEach-Object {
    try { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } catch {}
  }
}

Write-Host ""
Info "=================================================================="
$timings = Join-Path $OutDir 'TIMINGS.txt'
if (Test-Path $timings) { Get-Content $timings | ForEach-Object { Write-Host "  $_" } }
Info "=================================================================="

if ($done) { exit 0 } else { exit 2 }
