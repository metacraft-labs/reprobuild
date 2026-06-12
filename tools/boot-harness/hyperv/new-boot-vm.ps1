<#
  new-boot-vm.ps1 -- Create a transient Hyper-V VM for the boot-harness.

  Constraints (per ReproOS-MVP R0 spec + project memory):
    - VM name MUST start with 'repro-test-boot-' so the standing safety
      sweep covers it.
    - Gen-2 UEFI by default; pass -Generation 1 for legacy BIOS.
    - Serial console wired to named pipe \\.\pipe\<PipeName>.
    - Dynamic VHDX, 8 GB cap by default.
    - Secure Boot disabled (Hyper-V's UEFI MS Standard Secure Boot
      doesn't accept the test ISOs we'll be feeding it).
    - If -ImagePath is supplied, attach as cdrom (ISO) or as data drive
      (VHDX). If -DryRun, attach nothing (lifecycle smoke).

  Output:
    On success, writes the VM name to stdout. Non-zero exit on failure.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $VmName,
  [Parameter(Mandatory)] [string] $PipeName,
  [Parameter(Mandatory)] [string] $VhdxPath,
  [int]    $Generation = 2,
  [int]    $MemoryMB   = 1024,
  [int]    $VhdxSizeGB = 8,
  [string] $ImagePath  = '',
  [ValidateSet('iso','vhdx')] [string] $ImageKind = 'iso',
  [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

if (-not $VmName.StartsWith('repro-test-boot-')) {
  Write-Error "SAFETY: VmName must start with 'repro-test-boot-' (got '$VmName')."
  exit 2
}

# Verify Hyper-V module is loaded; this script is unusable without it.
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
  Write-Error "Hyper-V PowerShell module not available."
  exit 3
}

if (Get-VM -Name $VmName -ErrorAction SilentlyContinue) {
  Write-Error "VM '$VmName' already exists; refusing to clobber."
  exit 4
}

$vhdxDir = Split-Path -Parent $VhdxPath
if (-not (Test-Path $vhdxDir)) {
  New-Item -ItemType Directory -Force -Path $vhdxDir | Out-Null
}

try {
  Write-Host "[new-boot-vm] creating VHDX $VhdxPath (${VhdxSizeGB}GB dynamic)"
  $vhdxSizeBytes = [int64]$VhdxSizeGB * 1GB
  New-VHD -Path $VhdxPath -SizeBytes $vhdxSizeBytes -Dynamic | Out-Null

  Write-Host "[new-boot-vm] creating VM '$VmName' (Gen $Generation, ${MemoryMB} MB RAM)"
  $memBytes = [int64]$MemoryMB * 1MB
  $newVmArgs = @{
    Name               = $VmName
    Generation         = $Generation
    MemoryStartupBytes = $memBytes
    VHDPath            = $VhdxPath
  }
  New-VM @newVmArgs | Out-Null

  # Remove the default network adapter that New-VM auto-attached.
  # Boot-harness VMs don't need network; isolating them keeps the
  # transient state truly transient.
  try {
    Get-VMNetworkAdapter -VMName $VmName -ErrorAction SilentlyContinue |
      Remove-VMNetworkAdapter -ErrorAction SilentlyContinue
  } catch {}

  # Secure Boot off (Gen-2 only).
  if ($Generation -eq 2) {
    try {
      Set-VMFirmware -VMName $VmName -EnableSecureBoot Off
    } catch {
      Write-Warning "Set-VMFirmware -EnableSecureBoot Off failed: $($_.Exception.Message)"
    }
  }

  # Wire serial -> named pipe.
  $pipePath = "\\.\pipe\$PipeName"
  Write-Host "[new-boot-vm] wiring COM1 to $pipePath"
  Set-VMComPort -VMName $VmName -Number 1 -Path $pipePath

  # Attach image, if any (and not dry-run).
  if ($ImagePath -and -not $DryRun) {
    if (-not (Test-Path $ImagePath)) {
      throw "Image path not found: $ImagePath"
    }
    if ($ImageKind -eq 'iso') {
      Write-Host "[new-boot-vm] attaching ISO $ImagePath"
      Add-VMDvdDrive -VMName $VmName -Path $ImagePath
      if ($Generation -eq 2) {
        # Make the DVD the first boot device on Gen-2.
        $dvd = Get-VMDvdDrive -VMName $VmName | Select-Object -First 1
        if ($dvd) {
          Set-VMFirmware -VMName $VmName -FirstBootDevice $dvd
        }
      }
    } else {
      Write-Host "[new-boot-vm] attaching VHDX as data drive $ImagePath"
      Add-VMHardDiskDrive -VMName $VmName -Path $ImagePath
    }
  }

  Write-Output $VmName
} catch {
  Write-Error $_
  # Best-effort cleanup of the half-built VM and its VHDX.
  try { Remove-VM -Name $VmName -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
  try { if (Test-Path $VhdxPath) { Remove-Item -Force -LiteralPath $VhdxPath } } catch {}
  exit 1
}
