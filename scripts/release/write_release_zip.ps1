# write_release_zip.ps1 -- zip a directory tree with portable entry names.
#
# Usage:
#
#   ./scripts/release/write_release_zip.ps1 -SourceDir <dir> -DestinationPath <zip>
#
# Writes <zip> whose one top-level entry is <dir>'s own name: an entry
# `<name>/` for the directory itself, `<name>/<sub>/` for every directory
# below it (empty ones included) and `<name>/<sub>/<file>` for every file,
# hidden ones included. <zip> must not exist yet.
#
# WHY NOT Compress-Archive. Windows PowerShell 5.1's Compress-Archive (the
# Microsoft.PowerShell.Archive 1.0.x module it ships) builds each entry name
# from the Windows path, so a release zip made under 5.1 held entries such as
# `reprobuild-<v>-windows-x86_64\bin\repro.exe`. The ZIP format requires
# forward slashes: APPNOTE.TXT 4.4.17.1, "All slashes MUST be forward slashes
# '/' as opposed to backwards slashes '\' for compatibility with Amiga and
# UNIX file systems etc." (https://pkware.cachefly.net/webdocs/casestudies/APPNOTE.TXT).
# Info-ZIP's unzip then warns that the archive "appears to use backslashes as
# path separators", and a consumer that does not translate them writes files
# whose names contain backslashes instead of a tree. So every entry name here
# is built explicitly with '/', through System.IO.Compression's ZipArchive,
# and the result does not depend on the PowerShell edition, the .NET runtime
# or the module version that happens to be installed.
#
# Windows PowerShell 5.1 and PowerShell 7 compatible (also on Linux and macOS).

param(
  [Parameter(Mandatory = $true)][string]$SourceDir,
  [Parameter(Mandatory = $true)][string]$DestinationPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
  throw "write_release_zip: $SourceDir is not a directory"
}
$source = (Resolve-Path -LiteralPath $SourceDir).ProviderPath
$separators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$source = $source.TrimEnd($separators)
$top = Split-Path -Leaf $source
if ([string]::IsNullOrEmpty($top)) {
  throw "write_release_zip: $SourceDir has no name to use as the top-level entry"
}

# The .NET APIs resolve relative paths against the process's working
# directory, which PowerShell does not keep in step with its own location.
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationPath)
if (Test-Path -LiteralPath $destination) {
  throw "write_release_zip: $destination already exists; remove it first"
}

function ConvertTo-EntryName {
  # The '/'-separated name of $FullName below $source, prefixed with the
  # top-level directory. A path component that itself contains a backslash
  # (possible on Linux and macOS) has no portable spelling: an extractor on
  # Windows would read it as a separator. Refused rather than rewritten.
  param([string]$FullName)
  if (-not $FullName.StartsWith($source, [StringComparison]::OrdinalIgnoreCase)) {
    throw "write_release_zip: $FullName is not below $source"
  }
  $relative = $FullName.Substring($source.Length).TrimStart($separators)
  $parts = @($relative.Split($separators, [StringSplitOptions]::RemoveEmptyEntries))
  foreach ($part in $parts) {
    if ($part.Contains('\') -or $part -eq '.' -or $part -eq '..') {
      throw "write_release_zip: '$FullName' has a path component ('$part') with no portable zip spelling"
    }
  }
  return (@($top) + $parts) -join '/'
}

$items = @(Get-ChildItem -LiteralPath $source -Recurse -Force |
  Sort-Object -Property FullName)

$stream = [IO.File]::Open($destination, [IO.FileMode]::CreateNew)
$complete = $false
try {
  $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
  try {
    [void]$zip.CreateEntry("$top/")
    foreach ($item in $items) {
      $name = ConvertTo-EntryName -FullName $item.FullName
      if ($item.PSIsContainer) {
        # A directory entry is a name ending in '/' with no data
        # (APPNOTE.TXT 4.3.8 and 4.4.17.1's directory convention).
        [void]$zip.CreateEntry("$name/")
      } else {
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
          $zip, $item.FullName, $name, [IO.Compression.CompressionLevel]::Optimal)
      }
    }
  } finally {
    $zip.Dispose()
  }
  $complete = $true
} finally {
  $stream.Dispose()
  # A half-written archive must not be mistaken for a release asset.
  if (-not $complete) { Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue }
}
