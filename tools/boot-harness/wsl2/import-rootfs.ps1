<#
  import-rootfs.ps1 -- wsl --import a tarball rootfs into a transient
  distro whose name MUST start with 'repro-test-boot-'.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $InstanceName,
  [Parameter(Mandatory)] [string] $TarPath,
  [Parameter(Mandatory)] [string] $InstallDir,
  [int] $WslVersion = 2
)

$ErrorActionPreference = 'Stop'

if (-not $InstanceName.StartsWith('repro-test-boot-')) {
  Write-Error "SAFETY: InstanceName must start with 'repro-test-boot-' (got '$InstanceName')."
  exit 2
}
if (-not (Test-Path $TarPath)) {
  Write-Error "Tarball not found: $TarPath"
  exit 3
}
if (-not (Test-Path $InstallDir)) {
  New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
}

& wsl.exe --import $InstanceName $InstallDir $TarPath --version $WslVersion
if ($LASTEXITCODE -ne 0) {
  Write-Error "wsl --import failed (rc=$LASTEXITCODE)."
  exit $LASTEXITCODE
}
Write-Host "[wsl2] imported $InstanceName"
