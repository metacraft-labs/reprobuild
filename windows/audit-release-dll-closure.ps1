<#
.SYNOPSIS
  Audit the DLL closure of an extracted Windows release archive.

.DESCRIPTION
  A Windows release archive must run on a machine that never built
  reprobuild, so every DLL its images load has to come either from the
  archive's own bin/ or from Windows itself, and every image it carries has to
  be of the archive's machine (ARM64 for windows-aarch64, x64 for
  windows-x86_64). A best-effort list of runtime DLLs cannot show that;
  walking the import tables can.

  With -ArchiveRoot (the extracted archive's top directory, holding bin/),
  this runs Assert-WindowsArchiveClosure (toolchain-utils.ps1): every PE image
  anywhere in the archive -- bin/, lib/, or any other directory -- must be of
  the -Arch machine, and each DLL it imports or delay-loads must be in bin/ or
  be an operating-system DLL (an API set, or a Windows DLL named in
  windows/release-os-dlls.txt and present in System32). With -BinDir it runs
  the same rule over that one directory (Assert-WindowsDllClosure).

  windows/stage-release-dlls.ps1 runs the same audit over build\bin before
  packaging. scripts/verify_release.sh runs this script with -ArchiveRoot over
  the packaged archive, with PATH reduced to the Windows system directories, so
  what is audited is what ships, and nothing on the build host's PATH can
  stand in for a DLL the archive lacks.

  Exit status: 0 when the closure is complete, 1 with every violation listed
  otherwise (including a bin/ that holds no image at all).

.PARAMETER ArchiveRoot
  The top directory of an extracted release archive (the one holding bin/).

.PARAMETER BinDir
  A single bin/ directory, audited on its own.

.PARAMETER Arch
  The leg's architecture: arm64 or x64.

.PARAMETER SystemDir
  The directory whose DLLs count as operating-system DLLs. Defaults to
  %SystemRoot%\System32. Tests pass a stand-in.

.EXAMPLE
  powershell -NoProfile -File windows\audit-release-dll-closure.ps1 -ArchiveRoot C:\x\reprobuild-0.2.36-windows-aarch64 -Arch arm64
#>
[CmdletBinding(DefaultParameterSetName = "Archive")]
param(
  [Parameter(Mandatory = $true, ParameterSetName = "Archive")][string]$ArchiveRoot,
  [Parameter(Mandatory = $true, ParameterSetName = "Bin")][string]$BinDir,
  [Parameter(Mandatory = $true)][ValidateSet("arm64", "x64")][string]$Arch,
  [string]$SystemDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "toolchain-utils.ps1")

try {
  if ($PSCmdlet.ParameterSetName -eq "Archive") {
    if (-not (Test-Path -LiteralPath $ArchiveRoot -PathType Container)) {
      throw "closure audit: $ArchiveRoot is not a directory"
    }
    Assert-WindowsArchiveClosure -Root $ArchiveRoot -Arch $Arch -SystemDir $SystemDir
  } else {
    if (-not (Test-Path -LiteralPath $BinDir -PathType Container)) {
      throw "closure audit: $BinDir is not a directory"
    }
    Assert-WindowsDllClosure -BinDir $BinDir -Arch $Arch -SystemDir $SystemDir
  }
} catch {
  [Console]::Error.WriteLine("ERROR: " + $_.Exception.Message)
  exit 1
}
exit 0
