<#
  run-hyperv-bench-portable.ps1 - measure whether a Hyper-V hot
  checkpoint (memory + CPU + device state) is portable across host
  boundaries via Export-VM / Import-VM.

  If yes, the warm "VM is booted, ready for tests" state can be cached
  as a CI artifact: one CI runner pays the 46 s cold-boot cost ONCE
  to produce the export, subsequent runners just download it, Import-VM,
  and Restore-VMCheckpoint to the hot snapshot in ~5 s.

  Procedure (preserves the original VM throughout - the export is
  imported as a new VM with a fresh ID, then removed in cleanup):

    Phase A - prepare a portable hot checkpoint:
      A1 Restore original VM to base-clean (cold), start, wait PSDirect
      A2 Checkpoint-VM creates 'exp-hot' (memory + CPU + device state)
      A3 Stop the original VM (export requires it Off in some configs)

    Phase B - export:
      B1 Export-VM to a fresh folder
      B2 Inspect folder size + files; look for .vmrs (memory state),
         .vmgs (guest state), .vmcx (config), .vhdx/.avhdx (disks)

    Phase C - import + resume:
      C1 Import-VM with -GenerateNewId -Copy from the export
      C2 The imported VM gets a new name; capture it
      C3 Restore-VMCheckpoint to 'exp-hot' on the imported VM
      C4 Time how long until PSDirect on the IMPORTED VM is ready

    Phase D - cleanup:
      D1 Stop imported VM, Remove-VM (and all its files)
      D2 Remove the export folder
      D3 Remove 'exp-hot' from the original VM
      D4 Restore original VM to base-clean (its baseline)
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$VmName    = 'repro-m69-hyperv'
$ColdSnap  = 'base-clean'
$ExpHot    = 'exp-hot'
$OutDir    = 'D:\metacraft\sandbox-bench-out'
$Timings   = Join-Path $OutDir 'TIMINGS-hyperv-portable.txt'
$ExportDir = 'D:\metacraft\hyperv-bench-export'

if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
if (Test-Path $Timings) { Remove-Item $Timings -Force }
if (Test-Path $ExportDir) { Remove-Item $ExportDir -Recurse -Force }

function Stamp($name, $ms = $null) {
  $line = "$name=$((Get-Date).ToString('yyyy-MM-ddTHH:mm:ss.fffZ'))"
  if ($null -ne $ms) { $line += " ms=$ms" }
  Add-Content -LiteralPath $Timings -Value $line
  Write-Host "[port] $line"
}
function Info($m) { Write-Host "[port] $m" }
function Note($key, $value) {
  Add-Content -LiteralPath $Timings -Value "$key=$value"
  Write-Host "[port] $key=$value"
}

$CredPath = Join-Path $env:LOCALAPPDATA 'Repro\hyperv-m69\vm-cred.xml'
$cred = Import-Clixml -LiteralPath $CredPath

function Wait-PSDirectFor {
  param([string]$Name, [int]$timeoutSec = 600)
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    try {
      $h = Invoke-Command -VMName $Name -Credential $cred `
        -ScriptBlock { hostname } -ErrorAction Stop
      if ($h) { return $true }
    } catch { Start-Sleep -Milliseconds 500 }
  }
  return $false
}

$importedVmName = $null
$importedExpHotName = $null

try {
  # --- Phase A: prepare hot checkpoint ----------------------------------
  Stamp 'A0_start'
  $vm = Get-VM -Name $VmName
  if ($vm.State -ne 'Off') { Stop-VM -Name $VmName -TurnOff -Force }
  Restore-VMCheckpoint -VMName $VmName -Name $ColdSnap -Confirm:$false
  $prior = Get-VMSnapshot -VMName $VmName -Name $ExpHot -ErrorAction SilentlyContinue
  if ($prior) { Remove-VMSnapshot -VMSnapshot $prior -Confirm:$false }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  Start-VM -Name $VmName
  if (-not (Wait-PSDirectFor -Name $VmName)) { throw 'PSDirect ready failed' }
  $sw.Stop()
  Stamp 'A1_first_boot' $sw.ElapsedMilliseconds

  $sw.Restart()
  Checkpoint-VM -Name $VmName -SnapshotName $ExpHot
  $sw.Stop()
  Stamp 'A2_hot_checkpoint' $sw.ElapsedMilliseconds

  $sw.Restart()
  Stop-VM -Name $VmName -TurnOff -Force
  $sw.Stop()
  Stamp 'A3_stopped' $sw.ElapsedMilliseconds

  # --- Phase B: Export-VM ------------------------------------------------
  Stamp 'B0_export_start'
  $sw.Restart()
  Export-VM -Name $VmName -Path $ExportDir
  $sw.Stop()
  Stamp 'B1_export_done' $sw.ElapsedMilliseconds

  # The export creates a sub-folder named after the VM. Inspect it.
  $exportRoot = Join-Path $ExportDir $VmName
  if (-not (Test-Path $exportRoot)) { throw "export root not found: $exportRoot" }
  $totalSize = (Get-ChildItem -Path $exportRoot -Recurse -File | Measure-Object Length -Sum).Sum
  Note 'export_total_bytes' $totalSize
  Note 'export_total_gb' ([math]::Round($totalSize / 1GB, 2))
  $byExt = Get-ChildItem -Path $exportRoot -Recurse -File |
    Group-Object Extension |
    Sort-Object @{Expression={($_.Group | Measure-Object Length -Sum).Sum}; Descending=$true}
  foreach ($g in $byExt) {
    $sumBytes = ($g.Group | Measure-Object Length -Sum).Sum
    Note ("export_ext" + $g.Name) ("count=" + $g.Count + " bytes=" + $sumBytes + " mb=" + [math]::Round($sumBytes / 1MB, 1))
  }
  # Specifically check for memory-state files (.vmrs/.vsv/.bin)
  $memFiles = Get-ChildItem -Path $exportRoot -Recurse -Include '*.vmrs','*.vsv','*.bin'
  Note 'memory_state_files_count' $memFiles.Count
  foreach ($f in $memFiles) {
    Note ("memstate_" + $f.Name) ("bytes=" + $f.Length + " mb=" + [math]::Round($f.Length / 1MB, 1))
  }

  # --- Phase C: Import as a NEW VM, restore hot, time resume -----------
  Stamp 'C0_import_start'
  # Find the VM's CURRENT-state .vmcx config (Hyper-V exports put it
  # under "Virtual Machines/", and snapshot configs under "Snapshots/").
  # Picking a snapshot's vmcx would import that snapshot as the VM root,
  # losing the snapshot tree.
  $vmcx = Get-ChildItem -Path (Join-Path $exportRoot 'Virtual Machines') `
    -Filter '*.vmcx' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $vmcx) { throw 'no .vmcx file in <export>/Virtual Machines/' }
  Note 'imported_from_vmcx' $vmcx.FullName
  $sw.Restart()
  $imported = Import-VM -Path $vmcx.FullName -Copy -GenerateNewId `
    -VirtualMachinePath (Join-Path $ExportDir 'imported-vm') `
    -VhdDestinationPath (Join-Path $ExportDir 'imported-vhds') `
    -SnapshotFilePath (Join-Path $ExportDir 'imported-snapshots')
  $sw.Stop()
  Stamp 'C1_import_done' $sw.ElapsedMilliseconds
  $importedVmName = $imported.Name
  Note 'imported_vm_name' $importedVmName
  Note 'imported_vm_id' $imported.Id

  # Rename so we don't get confused with the original.
  Rename-VM -VM $imported -NewName "$VmName-imported-portable-test"
  $importedVmName = "$VmName-imported-portable-test"

  # The imported VM has a copy of the exp-hot snapshot. Find it.
  $importedSnaps = Get-VMSnapshot -VMName $importedVmName
  Note 'imported_snapshot_names' ($importedSnaps.Name -join ',')
  $importedHot = $importedSnaps | Where-Object Name -eq $ExpHot
  if (-not $importedHot) { throw "exp-hot snapshot missing in imported VM" }
  $importedExpHotName = $importedHot.Name

  $sw.Restart()
  Restore-VMCheckpoint -VMName $importedVmName -Name $importedExpHotName -Confirm:$false
  $sw.Stop()
  Stamp 'C2_revert_done' $sw.ElapsedMilliseconds

  # Hot checkpoint: VM should resume in Running state; if not, Start-VM.
  $iState = (Get-VM -Name $importedVmName).State
  Note 'imported_state_post_revert' $iState
  if ($iState -ne 'Running') {
    $sw.Restart()
    Start-VM -Name $importedVmName
    $sw.Stop()
    Stamp 'C3_started_warm' $sw.ElapsedMilliseconds
  }

  $sw.Restart()
  $ready = Wait-PSDirectFor -Name $importedVmName -timeoutSec 120
  $sw.Stop()
  if ($ready) {
    Stamp 'C4_imported_psdirect_ready' $sw.ElapsedMilliseconds
  } else {
    Stamp 'C4_imported_psdirect_FAILED'
  }

} finally {
  Info '--- cleanup begin ---'
  Stamp 'D0_cleanup_start'
  if ($importedVmName) {
    try { Stop-VM -Name $importedVmName -TurnOff -Force -ErrorAction SilentlyContinue } catch {}
    try { Remove-VM -Name $importedVmName -Force -ErrorAction SilentlyContinue } catch {}
  }
  if (Test-Path $ExportDir) {
    try { Remove-Item -LiteralPath $ExportDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }
  # Restore the original VM to base-clean for safety.
  try {
    $expHotOrig = Get-VMSnapshot -VMName $VmName -Name $ExpHot -ErrorAction SilentlyContinue
    if ($expHotOrig) { Remove-VMSnapshot -VMSnapshot $expHotOrig -Confirm:$false -ErrorAction SilentlyContinue }
  } catch {}
  try {
    $st = (Get-VM -Name $VmName).State
    if ($st -ne 'Off') { Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue }
    Restore-VMCheckpoint -VMName $VmName -Name $ColdSnap -Confirm:$false -ErrorAction SilentlyContinue
  } catch {}
  Stamp 'D1_cleanup_done'
  Write-Host ''
  Info '==== TIMINGS-hyperv-portable.txt ===='
  Get-Content $Timings | ForEach-Object { Write-Host "  $_" }
}
