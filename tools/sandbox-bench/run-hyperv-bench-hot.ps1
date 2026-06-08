<#
  run-hyperv-bench-hot.ps1 - measure Hyper-V revert-from-RUNNING-state
  paths to see whether they eliminate the 26-second cold-boot cost.

  Two mechanisms tested:

    1. Standard Checkpoint of a RUNNING VM. The snapshot captures
       memory + CPU + device state; Restore-VMCheckpoint to it returns
       the VM to its exact running state instantly. The existing
       `base-clean` snapshot was taken with the VM Off, so it has no
       memory state - this script creates `base-hot` for the test.

    2. Save-VM / Start-VM (hibernate). Save-VM writes RAM to disk like
       OS hibernate; Start-VM after that resumes from the saved state.
       No checkpoint involved.

  Procedure (each cycle reuses the same VM, no host-side reboot):

    Phase A - one-time HOT snapshot creation:
      A0  start
      A1  Start-VM + PSDirect ready (full boot ~26 s)
      A2  Checkpoint-VM (while running, type Standard)
          -> snapshot 'base-hot' captures memory+CPU+devices

    Phase B - measure revert-from-hot (3 iterations):
      B0  start of iteration
      B1  Restore-VMCheckpoint -Name base-hot returned
      B2  first successful Invoke-Command -VMName (proves VM is fully usable)

    Phase C - measure Save-VM / Start-VM:
      C0  start
      C1  Save-VM returned
      C2  Start-VM returned
      C3  first successful Invoke-Command -VMName

    Phase D - cleanup:
      D1  Remove the base-hot snapshot (host stays clean for next run)
      D2  Stop-VM -TurnOff
#>

[CmdletBinding()]
param(
  [int]$TimeoutMinutes = 10,
  [int]$RevertIterations = 3
)

$ErrorActionPreference = 'Stop'
$VmName    = 'repro-m69-hyperv'
$ColdSnap  = 'base-clean'
$HotSnap   = 'base-hot'
$OutDir    = 'D:\metacraft\sandbox-bench-out'
$Timings   = Join-Path $OutDir 'TIMINGS-hyperv-hot.txt'
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
if (Test-Path $Timings) { Remove-Item $Timings -Force }

function Stamp($name, $ms = $null) {
  $line = "$name=$((Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))"
  if ($null -ne $ms) { $line += " ms=$ms" }
  Add-Content -LiteralPath $Timings -Value $line
  Write-Host "[hothbench] $line"
}

function Info($m) { Write-Host "[hothbench] $m" }

$CredPath = Join-Path $env:LOCALAPPDATA 'Repro\hyperv-m69\vm-cred.xml'
$cred = Import-Clixml -LiteralPath $CredPath

function Wait-PSDirect {
  param([int]$timeoutSec = 600)
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    try {
      $h = Invoke-Command -VMName $VmName -Credential $cred `
        -ScriptBlock { hostname } -ErrorAction Stop
      if ($h) { return $true }
    } catch { Start-Sleep -Milliseconds 500 }
  }
  return $false
}

try {
  # Make sure we start from a known-cold state.
  $vm = Get-VM -Name $VmName
  if ($vm.State -ne 'Off') { Stop-VM -Name $VmName -TurnOff -Force }
  Restore-VMCheckpoint -VMName $VmName -Name $ColdSnap -Confirm:$false

  # Drop any prior base-hot from a previous run of this script.
  $prior = Get-VMSnapshot -VMName $VmName -Name $HotSnap -ErrorAction SilentlyContinue
  if ($prior) { Remove-VMSnapshot -VMSnapshot $prior -Confirm:$false }

  Stamp 'A0_start'

  # --- Phase A: cold boot + create hot snapshot --------------------------
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  Start-VM -Name $VmName
  if (-not (Wait-PSDirect -timeoutSec ($TimeoutMinutes * 60))) {
    throw 'PSDirect never became ready'
  }
  $sw.Stop()
  Stamp 'A1_first_boot_done' $sw.ElapsedMilliseconds

  $sw.Restart()
  Checkpoint-VM -Name $VmName -SnapshotName $HotSnap
  $sw.Stop()
  Stamp 'A2_hot_snapshot_taken' $sw.ElapsedMilliseconds

  # --- Phase B: measure revert-from-hot ---------------------------------
  for ($i = 1; $i -le $RevertIterations; $i++) {
    Stamp "B0_iter${i}_start"
    $sw.Restart()
    Restore-VMCheckpoint -VMName $VmName -Name $HotSnap -Confirm:$false
    $sw.Stop()
    Stamp "B1_iter${i}_restore_returned" $sw.ElapsedMilliseconds

    $sw.Restart()
    if (-not (Wait-PSDirect -timeoutSec 60)) {
      Stamp "B2_iter${i}_psdirect_FAILED"
      continue
    }
    $sw.Stop()
    Stamp "B2_iter${i}_psdirect_ready" $sw.ElapsedMilliseconds
  }

  # --- Phase C: Save-VM / Start-VM hibernate path -----------------------
  Stamp 'C0_start'
  $sw.Restart()
  Save-VM -Name $VmName
  $sw.Stop()
  Stamp 'C1_save_returned' $sw.ElapsedMilliseconds

  $sw.Restart()
  Start-VM -Name $VmName
  $sw.Stop()
  Stamp 'C2_start_returned' $sw.ElapsedMilliseconds

  $sw.Restart()
  if (Wait-PSDirect -timeoutSec 60) {
    $sw.Stop()
    Stamp 'C3_psdirect_ready' $sw.ElapsedMilliseconds
  } else {
    Stamp 'C3_psdirect_FAILED'
  }

} finally {
  Stamp 'D1_cleanup_begin'
  # Remove the hot snapshot so we leave the host as we found it (and so
  # the next run of this script always measures fresh).
  $hs = Get-VMSnapshot -VMName $VmName -Name $HotSnap -ErrorAction SilentlyContinue
  if ($hs) { Remove-VMSnapshot -VMSnapshot $hs -Confirm:$false }
  try {
    Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue
  } catch {}
  # Revert to base-clean to leave the harness VM in its expected state.
  Restore-VMCheckpoint -VMName $VmName -Name $ColdSnap -Confirm:$false
  Stamp 'D2_cleanup_done'

  Write-Host ""
  Info "==== TIMINGS-hyperv-hot.txt ===="
  Get-Content $Timings | ForEach-Object { Write-Host "  $_" }
}
