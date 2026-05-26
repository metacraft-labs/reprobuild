<#
  Get-VmPassword.ps1 - retrieve the 4-word EFF-Short passphrase that
  provision-base-vm.ps1 auto-generated for the M69 Hyper-V test VM
  (repro-m69-hyperv).

  The passphrase is stored DPAPI-sealed (current user only) at
    $env:LOCALAPPDATA\Repro\hyperv-m69\vm-cred.xml
  via Export-Clixml. This script imports it and prints the plaintext
  to stdout so the operator can sign into the VM console if needed.

  Exit codes:
    0  - printed the passphrase to stdout
    2  - cred cache missing; provision the VM first

  Usage:
    pwsh -File tools\hyperv-m69-system\Get-VmPassword.ps1
#>
#requires -Version 7
[CmdletBinding()]
param()
$credPath = Join-Path $env:LOCALAPPDATA 'Repro\hyperv-m69\vm-cred.xml'
if (-not (Test-Path $credPath)) {
  Write-Error "VM passphrase cache not found at $credPath. Provision the VM first."
  exit 2
}
$cred = Import-Clixml $credPath
$cred.GetNetworkCredential().Password
