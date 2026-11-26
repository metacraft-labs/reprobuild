<#
.SYNOPSIS
  Audit the DLL closure of a release archive's bin/ directory.

.DESCRIPTION
  The windows-aarch64 release archive must run on a machine that never built
  reprobuild, so every DLL its images load has to come either from the
  archive's own bin/ or from Windows itself, and every image it carries has to
  be ARM64. A best-effort list of runtime DLLs cannot show that; walking the
  import tables can. This runs Assert-WindowsDllClosure (toolchain-utils.ps1)
  over an extracted archive: every image in -BinDir must be of the -Arch
  machine, and each DLL it imports or delay-loads must be in -BinDir or be an
  operating-system DLL.

  windows/stage-release-dlls.ps1 runs the same audit over build\bin before
  packaging. scripts/verify_release.sh runs this script over the bin/ of the
  packaged archive, with PATH reduced to the Windows system directories, so
  what is audited is what ships, and nothing on the build host's PATH can
  stand in for a DLL the archive lacks.

  Exit status: 0 when the closure is complete, 1 with every violation listed
  otherwise (including a bin/ that holds no image at all).

.PARAMETER BinDir
  The bin/ directory of an extracted release archive.

.PARAMETER Arch
  The leg's architecture: arm64 or x64.

.PARAMETER SystemDir
  The directory whose DLLs count as operating-system DLLs. Defaults to
  %SystemRoot%\System32. Tests pass a stand-in.

.EXAMPLE
  powershell -NoProfile -File windows\audit-release-dll-closure.ps1 -BinDir C:\x\reprobuild-0.2.36\bin -Arch arm64
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$BinDir,
  [Parameter(Mandatory = $true)][ValidateSet("arm64", "x64")][string]$Arch,
  [string]$SystemDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "toolchain-utils.ps1")

try {
  if (-not (Test-Path -LiteralPath $BinDir -PathType Container)) {
    throw "closure audit: $BinDir is not a directory"
  }
  Assert-WindowsDllClosure -BinDir $BinDir -Arch $Arch -SystemDir $SystemDir
} catch {
  [Console]::Error.WriteLine("ERROR: " + $_.Exception.Message)
  exit 1
}
exit 0
