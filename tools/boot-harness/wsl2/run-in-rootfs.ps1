<#
  run-in-rootfs.ps1 -- run a shell command inside a 'repro-test-boot-*'
  WSL2 distro. Exit code is forwarded.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $InstanceName,
  [Parameter(Mandatory)] [string] $Command,
  [string] $Shell = '/bin/sh'
)

$ErrorActionPreference = 'Stop'

if (-not $InstanceName.StartsWith('repro-test-boot-')) {
  Write-Error "SAFETY: InstanceName must start with 'repro-test-boot-' (got '$InstanceName')."
  exit 2
}

& wsl.exe -d $InstanceName -- $Shell -c $Command
exit $LASTEXITCODE
