# Tear down ALL repro-* WSL instances and reclaim their VHDX storage.
#
# Safety:
# - This script only operates on WSL instances whose names start with "repro-".
# - It NEVER touches eli-wsl or any other distro the user may have.
# - It NEVER touches the rootfs cache under
#   $env:LOCALAPPDATA\repro-multi-distro-cache (re-use across runs).
#
# Usage:
#   pwsh tools/multi-distro-harness/teardown-all.ps1            # ask for confirmation
#   pwsh tools/multi-distro-harness/teardown-all.ps1 -Force     # skip confirmation

[CmdletBinding()] param([switch] $Force)
. "$PSScriptRoot\_common.ps1"

$raw = & wsl.exe --list --quiet 2>$null
if (-not $raw) {
  Write-Output 'No WSL instances found.'
  exit 0
}

$reproInstances = @()
foreach ($line in $raw) {
  $clean = ($line -replace "`0", '').Trim()
  if ($clean -match '^repro-') {
    $reproInstances += $clean
  }
}

if ($reproInstances.Count -eq 0) {
  Write-Output 'No repro-* WSL instances to tear down.'
  exit 0
}

Write-Output ('Will tear down: ' + ($reproInstances -join ', '))
if (-not $Force) {
  $confirm = Read-Host 'Proceed? (yes/no)'
  if ($confirm -ne 'yes') {
    Write-Output 'Aborted.'
    exit 1
  }
}

$instanceRoot = $script:ReproDistroInstanceRoot
foreach ($name in $reproInstances) {
  Assert-ReproInstanceName $name
  Write-Output "Unregistering $name ..."
  & wsl.exe --terminate $name 2>$null | Out-Null
  & wsl.exe --unregister $name | Out-Null
  $instDir = Join-Path $instanceRoot $name
  if (Test-Path $instDir) {
    Write-Output "  removing $instDir"
    Remove-Item -Recurse -Force $instDir -ErrorAction SilentlyContinue
  }
}

Write-Output "Done. Rootfs cache preserved at $($script:ReproDistroCacheDir)."
