# Reprobuild PowerShell installer — coming soon
#
# Served from https://get.reprobuild.com/pwsh
#
# A native PowerShell bootstrapper for Windows is on the way (tracked in the
# reprobuild-installer work, install.ps1). Until it lands here, install
# Reprobuild on Windows via WSL:
#
#   wsl -- bash -c "curl -fsSL https://get.reprobuild.com/sh | sh"
#
# or grab a release directly from:
#
#   https://github.com/metacraft-labs/reprobuild/releases
#
# This script intentionally exits non-zero so nothing is silently installed.

Write-Host "Reprobuild: a native PowerShell installer is not available yet." -ForegroundColor Yellow
Write-Host "On Windows, install via WSL:" -ForegroundColor Yellow
Write-Host '  wsl -- bash -c "curl -fsSL https://get.reprobuild.com/sh | sh"'
Write-Host "Or download a release: https://github.com/metacraft-labs/reprobuild/releases"
exit 1
