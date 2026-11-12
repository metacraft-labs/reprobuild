## The Windows PowerShell script that extracts a zip archive.
##
## Two producers extract zips on Windows with the OS's own Windows PowerShell
## 5.1 and the .NET Framework zip reader: the tool store
## (``repro_tool_profiles.powershellZipExtractScript``), which unpacks a
## provisioned archive into a fresh staging directory, and the stdlib
## ``expandArchive`` package (``expand_archive.buildZipArgvWindows``), whose
## destination may already hold an earlier extraction. They differ only in
## whether an existing file may be overwritten, so they share this script.
##
## LONG PATHS
## ==========
##
## Win32 path APIs cap a path at ``MAX_PATH`` (260 UTF-16 units) unless the
## process is long-path aware in its manifest AND the
## ``HKLM\SYSTEM\CurrentControlSet\Control\FileSystem\LongPathsEnabled``
## policy is on. The policy is off by default and is not set on every host
## this runs on: the ephemeral Windows ARM64 CI runners do not set it. The
## Nim 2.2.10 Windows zip carries
## ``dist/nimble/tests/conflictingdepres/nimbledeps/pkgs2/b-0.1.4-<sha1>/``,
## and under a tool-store staging directory of a CI checkout that member
## reaches 288 units, so ``ZipFile.ExtractToDirectory`` failed with
## ``DirectoryNotFoundException`` on those runners and nowhere else.
##
## Every file-system call below therefore goes through the ``\\?\``
## extended-length form, which bypasses ``MAX_PATH`` whatever the policy says
## (https://learn.microsoft.com/windows/win32/fileio/maximum-file-path-limitation).
## ``ExtractToDirectory`` cannot be handed such a destination: it appends each
## entry's ``/``-separated name to it, and the extended namespace performs no
## separator normalization, so .NET Framework rejects the result as a syntax
## error. The script therefore runs the per-entry loop itself, which is the
## loop ``ExtractToDirectory`` runs internally.
##
## The destination check stays on the ORDINARY spelling. ``GetFullPath``
## resolves ``..`` segments in an ordinary path but leaves them literal in an
## extended one, so a check made on the extended form would accept
## ``evil/../../x`` and the write would then fail, or worse, land. The ordinary
## spelling is only ever a string here: ``GetFullPath`` does not touch the disk,
## and .NET Framework 4.6.2 and later no longer refuse a long path in it.
## Only the checked path is then prefixed for the write.
##
## The extended namespace also skips the Win32 rule that drops a trailing
## ``.`` or space from a path segment. Through an ordinary path, an entry such
## as ``a/.../b`` or ``trail ./x`` could not be written, and every extractor
## here failed on it. Through ``\\?\`` it would be written verbatim, as a
## directory that ordinary paths, ``Remove-Item`` and ``Get-ChildItem``
## included, cannot address. So the script refuses such an entry, as it was
## refused before. ``.`` and ``..`` are path syntax, not names, and stay
## subject to the destination check alone.
##
## Measured 2026-11-11 on a Windows 11 x64 host with ``LongPathsEnabled = 0``
## (Windows PowerShell 5.1.26100, .NET Framework 4.8.1): a 288-unit member
## extracts under this script; ``ExtractToDirectory`` fails on it with the CI
## runners' exception; and ``ExtractToDirectory`` with a ``\\?\`` destination
## fails with "The filename, directory name, or volume label syntax is
## incorrect".

import std/strutils

proc powershellSingleQuotedLiteral*(value: string): string =
  ## A PowerShell single-quoted string literal. Nothing inside it is
  ## interpolated, and the only escape is a doubled quote.
  "'" & value.replace("'", "''") & "'"

proc powershellZipExtractScript*(archivePath, destination: string;
                                 overwrite: bool): string =
  ## A Windows PowerShell 5.1 ``-Command`` script that extracts the zip at
  ## ``archivePath`` into ``destination``, creating it if needed.
  ##
  ## With ``overwrite`` an existing file is replaced, and every other file in
  ## the destination is left alone (``Expand-Archive -Force``). Without it the
  ## first existing file fails the script, as ``ExtractToDirectory`` does.
  ##
  ## Unflagged entry names are decoded as CP437, the zip specification's
  ## default; names carrying the UTF-8 flag stay UTF-8
  ## (https://learn.microsoft.com/dotnet/api/system.io.compression.zipfile.open).
  ## An entry whose resolved path lies outside the destination (``../x``, an
  ## absolute name), or one with a path segment ending in ``.`` or a space,
  ## throws before anything is written for it.
  ##
  ## ``$ErrorActionPreference = 'Stop'`` turns every .NET exception (a missing
  ## or corrupt archive, an escaping entry, an existing file without
  ## ``overwrite``) into a terminating error, and ``-Command`` then exits
  ## non-zero. Progress is silenced: a progress record per entry made
  ## ``Expand-Archive`` take about 90 ms an entry when output was captured.
  ##
  ## ``ZipFile``/``ZipFileExtensions`` live in
  ## System.IO.Compression.FileSystem, but ``ZipArchiveMode`` lives in
  ## System.IO.Compression, so both assemblies are loaded.
  "$ProgressPreference = 'SilentlyContinue'; " &
    "$ErrorActionPreference = 'Stop'; " &
    "Add-Type -AssemblyName System.IO.Compression.FileSystem; " &
    "Add-Type -AssemblyName System.IO.Compression; " &
    # The extended-length spelling of an absolute ordinary path: a UNC path
    # `\\server\share\…` becomes `\\?\UNC\server\share\…`, a drive path
    # `C:\…` becomes `\\?\C:\…`. Only Windows has that namespace: PowerShell
    # 7 on Linux or macOS reads the prefix as a relative directory literally
    # named `\\?\`, so there the path is returned as it is.
    "function ConvertTo-ExtendedPath([string]$p) { " &
      "if ([System.IO.Path]::DirectorySeparatorChar -ne '\\') { return $p } " &
      "if ($p.StartsWith('\\\\?\\')) { return $p } " &
      "if ($p.StartsWith('\\\\')) { return '\\\\?\\UNC\\' + $p.Substring(2) } " &
      "return '\\\\?\\' + $p " &
    "}; " &
    "$root = [System.IO.Path]::GetFullPath(" &
      powershellSingleQuotedLiteral(destination) & ").TrimEnd([char[]]'\\/') + " &
      "[System.IO.Path]::DirectorySeparatorChar; " &
    "[void][System.IO.Directory]::CreateDirectory(" &
      "(ConvertTo-ExtendedPath $root)); " &
    "$zip = [System.IO.Compression.ZipFile]::Open(" &
      powershellSingleQuotedLiteral(archivePath) &
      ", [System.IO.Compression.ZipArchiveMode]::Read, " &
      "[System.Text.Encoding]::GetEncoding(437)); " &
    "try { " &
      "foreach ($entry in $zip.Entries) { " &
        "$target = [System.IO.Path]::GetFullPath(" &
          "[System.IO.Path]::Combine($root, $entry.FullName)); " &
        "if (-not $target.StartsWith($root, " &
          "[System.StringComparison]::OrdinalIgnoreCase)) { " &
          "throw ('zip entry escapes the destination: ' + " &
            "$entry.FullName) " &
        "} " &
        "foreach ($segment in $entry.FullName.Split([char[]]'/\\')) { " &
          "if ($segment -ne '.' -and $segment -ne '..' -and " &
            "($segment.EndsWith('.') -or $segment.EndsWith(' '))) { " &
            "throw ('zip entry names a path segment Windows cannot " &
              "address: ' + $entry.FullName) " &
          "} " &
        "} " &
        "$io = ConvertTo-ExtendedPath $target; " &
        "if ($entry.Name.Length -eq 0) { " &
          "[void][System.IO.Directory]::CreateDirectory($io) " &
        "} else { " &
          "[void][System.IO.Directory]::CreateDirectory(" &
            "[System.IO.Path]::GetDirectoryName($io)); " &
          "[System.IO.Compression.ZipFileExtensions]::ExtractToFile(" &
            "$entry, $io, " & (if overwrite: "$true" else: "$false") & ") " &
        "} " &
      "} " &
    "} finally { " &
      "$zip.Dispose() " &
    "}"
