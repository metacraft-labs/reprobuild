<#
  stop-boot-vm.ps1 -- Force-stop and remove a boot-harness VM.

  Idempotent: missing VM/VHDX are not errors. Always tries to remove
  both so that an orphan from an earlier crashed run can be cleaned
  up by passing the same name + path.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $VmName,
  [string] $VhdxPath = ''
)

$ErrorActionPreference = 'Stop'

if (-not $VmName.StartsWith('repro-test-boot-')) {
  Write-Error "SAFETY: refusing to operate on VM '$VmName' (must start with 'repro-test-boot-')."
  exit 2
}

$vm = Get-VM -Name $VmName -ErrorAction SilentlyContinue
if ($vm) {
  try {
    if ($vm.State -ne 'Off') {
      Write-Host "[stop-boot-vm] Stop-VM -TurnOff '$VmName'"
      Stop-VM -Name $VmName -TurnOff -Force -ErrorAction SilentlyContinue | Out-Null
    }
  } catch {
    Write-Warning "Stop-VM failed: $($_.Exception.Message)"
  }
  try {
    Write-Host "[stop-boot-vm] Remove-VM '$VmName'"
    Remove-VM -Name $VmName -Force -ErrorAction SilentlyContinue | Out-Null
  } catch {
    Write-Warning "Remove-VM failed: $($_.Exception.Message)"
  }
}

if ($VhdxPath -and (Test-Path -LiteralPath $VhdxPath)) {
  try {
    Write-Host "[stop-boot-vm] Remove-Item $VhdxPath"
    Remove-Item -Force -LiteralPath $VhdxPath
  } catch {
    Write-Warning "Failed to remove VHDX '$VhdxPath': $($_.Exception.Message)"
  }
}

# Best effort: also try to remove the per-VM scratch dir if it's empty.
if ($VhdxPath) {
  $parent = Split-Path -Parent $VhdxPath
  if ($parent -and (Test-Path $parent)) {
    $children = Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue
    if (-not $children) {
      try { Remove-Item -Force -Recurse -LiteralPath $parent } catch {}
    }
  }
}

exit 0
