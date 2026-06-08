<#
  run-hyperv-bench.ps1 - HOST-SIDE Hyper-V per-test overhead measurement.

  Reuses the M69 harness VM (repro-m69-hyperv, base-clean snapshot)
  and times each step of the per-test cycle:

    T0 = script start
    T1 = Restore-VMCheckpoint returned
    T2 = Start-VM + Wait for PSDirect (Invoke-Command -VMName works)
    T3 = Copy-VMFile staged a payload
    T4 = Invoke-Command -VMName ran a trivial command (Get-Date)
    T5 = Stop-VM -TurnOff returned

  Wall-time decomposition the report shows:
    revert      = T1 - T0
    boot        = T2 - T1   (Start-VM + PSDirect ready)
    stage       = T3 - T2
    invoke      = T4 - T3   (this is what scales with test wall time)
    teardown    = T5 - T4

  NOTHING is mutated in the VM beyond what runs inside Invoke-Command,
  and the snapshot revert at the start guarantees a clean state.

  Safety: this script touches exactly the M69 harness VM.
#>

[CmdletBinding()]
param(
  [int]$TimeoutMinutes = 10
)

$ErrorActionPreference = 'Stop'
$VmName    = 'repro-m69-hyperv'
$Snapshot  = 'base-clean'
$OutDir    = 'D:\metacraft\sandbox-bench-out'
$Timings   = Join-Path $OutDir 'TIMINGS-hyperv.txt'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
if (Test-Path $Timings) { Remove-Item $Timings -Force }

function Stamp($name) {
  $ts = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
  Add-Content -LiteralPath $Timings -Value "$name=$ts"
  Write-Host "[hbench] $name @ $ts"
}

function Info($m) { Write-Host "[hbench] $m" }

# Pre-flight.
$vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if (-not $vm) { Write-Host "[hbench] VM '$VmName' not found."; exit 1 }
$snap = Get-VMSnapshot -VMName $VmName -Name $Snapshot -ErrorAction SilentlyContinue
if (-not $snap) { Write-Host "[hbench] snapshot '$Snapshot' not found."; exit 1 }

# Cred for PSDirect.
$CredPath = Join-Path $env:LOCALAPPDATA 'Repro\hyperv-m69\vm-cred.xml'
if (-not (Test-Path $CredPath)) { Write-Host "[hbench] cred cache missing at $CredPath."; exit 1 }
$cred = Import-Clixml -LiteralPath $CredPath

$wallSw = [System.Diagnostics.Stopwatch]::StartNew()
Stamp 'T0_start'

# Always Stop-VM in a finally so a failure doesn't leave the VM running.
try {
  # If the VM happens to be running, stop it first - revert requires Off.
  $vm = Get-VM -Name $VmName
  if ($vm.State -ne 'Off') {
    Info "VM is $($vm.State); stopping before revert"
    Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
  }
  Restore-VMCheckpoint -VMName $VmName -Name $Snapshot -Confirm:$false
  Stamp 'T1_revert_done'

  Start-VM -Name $VmName
  Info "polling PSDirect for $TimeoutMinutes min"
  $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
  $ready = $false
  while ((Get-Date) -lt $deadline) {
    try {
      $h = Invoke-Command -VMName $VmName -Credential $cred -ScriptBlock { hostname } -ErrorAction Stop
      if ($h) { $ready = $true; break }
    } catch {
      Start-Sleep -Seconds 2
    }
  }
  if (-not $ready) { throw "PSDirect never became ready within $TimeoutMinutes min" }
  Stamp 'T2_psdirect_ready'

  # Stage a tiny payload (mirrors what a per-test runner would do).
  $tmpHostPayload = Join-Path $env:TEMP "hbench-payload-$([guid]::NewGuid()).txt"
  Set-Content -LiteralPath $tmpHostPayload -Value "hbench payload"
  Copy-VMFile -Name $VmName -SourcePath $tmpHostPayload `
    -DestinationPath 'C:\hbench-payload.txt' -CreateFullPath -FileSource Host -Force
  Remove-Item -LiteralPath $tmpHostPayload -Force -ErrorAction SilentlyContinue
  Stamp 'T3_stage_done'

  # Run a trivial command inside the VM. This is the "test" wall time.
  $result = Invoke-Command -VMName $VmName -Credential $cred -ScriptBlock {
    Get-Date
    Get-Content -LiteralPath 'C:\hbench-payload.txt'
  }
  Add-Content -LiteralPath $Timings -Value ("invoke_result=" + ($result -join '|'))
  Stamp 'T4_invoke_done'

} finally {
  try {
    Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
  } catch {
    Info "Stop-VM warning: $_"
  }
  Stamp 'T5_stopped'
  $wallSw.Stop()
  Add-Content -LiteralPath $Timings -Value ("T_total_wall_ms=" + $wallSw.ElapsedMilliseconds)
  Write-Host ""
  Info "=================================================================="
  Get-Content $Timings | ForEach-Object { Write-Host "  $_" }
  Info "=================================================================="
}
