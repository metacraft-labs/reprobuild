<#
  run-iso.ps1 -- manual-debug shim around qemu-system-x86_64.exe.

  The Python QEMU backend (`lib/backends/qemu.py`) talks to QEMU
  directly; this script exists for operators who want to repro a run
  outside the harness, with the same flag set.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $IsoPath,
  [int]    $MemoryMB  = 1024,
  [string] $BiosPath  = '',
  [int]    $TimeoutSec = 0   # 0 = no harness-side timeout (use Ctrl-C)
)

$ErrorActionPreference = 'Stop'

$qemu = Get-Command 'qemu-system-x86_64.exe' -ErrorAction SilentlyContinue
if (-not $qemu) {
  $qemu = Get-Command 'qemu-system-x86_64' -ErrorAction SilentlyContinue
}
if (-not $qemu) {
  Write-Error "qemu-system-x86_64 not found on PATH. Install: 'winget install QEMU.QEMU' or 'scoop install qemu'."
  exit 3
}
if (-not (Test-Path $IsoPath)) {
  Write-Error "ISO not found: $IsoPath"
  exit 4
}

$qemuArgs = @(
  '-m', $MemoryMB.ToString(),
  '-nographic',
  '-serial', 'stdio',
  '-display', 'none',
  '-no-reboot',
  '-cdrom', $IsoPath
)
if ($BiosPath -and (Test-Path $BiosPath)) {
  $qemuArgs += @('-bios', $BiosPath)
}

Write-Host "[qemu] $($qemu.Source) $($qemuArgs -join ' ')"
& $qemu.Source @qemuArgs
exit $LASTEXITCODE
