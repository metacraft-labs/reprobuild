<#
  tear-down.ps1 -- terminate + unregister a transient WSL2 distro.

  Safety: hard-fails unless the name starts with 'repro-test-boot-'.
  Idempotent: missing distro is not an error.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string] $InstanceName,
  [string] $InstallDir = ''
)

$ErrorActionPreference = 'Stop'

if (-not $InstanceName.StartsWith('repro-test-boot-')) {
  Write-Error "SAFETY: refusing to operate on WSL distro '$InstanceName' (must start with 'repro-test-boot-')."
  exit 2
}

try { & wsl.exe --terminate $InstanceName | Out-Null } catch {}
try { & wsl.exe --unregister $InstanceName | Out-Null } catch {}

if ($InstallDir -and (Test-Path $InstallDir)) {
  try { Remove-Item -Force -Recurse -LiteralPath $InstallDir } catch {
    Write-Warning "Failed to remove $InstallDir : $($_.Exception.Message)"
  }
}

exit 0
