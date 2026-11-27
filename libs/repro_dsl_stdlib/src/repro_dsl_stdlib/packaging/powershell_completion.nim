## The PowerShell profile block a Windows package writes so that PowerShell
## loads the completion script the package installed.
##
## PowerShell loads no completion file on its own: a block in a profile has
## to evaluate the script (about_Profiles,
## https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_profiles).
## A program installed by reprobuild's own installers writes that block
## itself (``repro hooks ensure --shell-autocomplete``), but a program the DSL
## packages has no such command, so the MSI's custom actions and the Scoop
## manifest's hooks run the PowerShell code this module generates instead:
##
## * ``profileBlockUpdater`` defines ``Update-ClispecCompletionBlock``, which
##   puts the block in one profile file, or takes it out, and reports what it
##   did. Its body is clispec's (``cliProfileBlockBody``, the text
##   ``repro hooks ensure`` writes for PowerShell): it evaluates the script
##   with ``Invoke-Expression`` when the file exists, so no execution policy
##   applies to it. It sits between the lines ``completionBlockOpen`` and
##   ``completionBlockClose``, which name the program, so it never touches
##   another program's block or reprobuild's own, and a second run replaces
##   it instead of adding one.
## * ``allUsersProfilesScript`` updates the all-users profile,
##   ``$PSHOME\Profile.ps1``, of Windows PowerShell 5.1 and of each
##   PowerShell 7 under ``%ProgramFiles%\PowerShell``: what an MSI, which is
##   per machine, runs.
## * ``currentUserProfilesScript`` updates each edition's
##   ``CurrentUserAllHosts`` profile (``<Documents>\PowerShell\Profile.ps1``
##   and ``<Documents>\WindowsPowerShell\Profile.ps1``, clispec's per-user
##   Windows targets): what a Scoop manifest, which is per user, runs.
## * ``msiQuietExecCommand`` and ``msiCompletionRunValue`` are an all-users
##   script as the command line a quiet-exec custom action runs, in MSI's
##   formatted-text syntax, and the property that carries the script.
##
## The code runs in Windows PowerShell 5.1 and in PowerShell 7, and refers
## to the system only through environment variables and .NET calls, which
## is what lets a test run it with pwsh on any host against scratch
## directories.

import std/[base64, strutils, unicode]

import clispec/completion
import clispec/completion_install

const ScriptPathPlaceholder = "@@CLISPEC_COMPLETION_SCRIPT@@"
  ## Where the installed script's path goes in the block body; replaced at
  ## install time, when the path is known.

proc completionBlockOpen*(program: string): string =
  ## The line that opens ``program``'s block.
  "# >>> clispec-completion:" & program & " >>>"

proc completionBlockClose*(program: string): string =
  ## The line that closes ``program``'s block.
  "# <<< clispec-completion:" & program & " <<<"

proc completionBlockBody*(program, script: string): string =
  ## The block's body for the script at ``script``: clispec's text.
  cliProfileBlockBody(cshPowerShell, program, script)

proc powerShellLiteral*(s: string): string =
  ## ``s`` as a single-quoted PowerShell string literal.
  cliPowerShellSingleQuote(s)

proc q(s: string): string = powerShellLiteral(s)

proc profileBlockUpdater*(program: string): string =
  ## PowerShell source defining
  ## ``Update-ClispecCompletionBlock [string]$Path [string]$Script``: with a
  ## ``$Script``, the block loading it is put in the profile file at
  ## ``$Path`` (created when absent), replacing one already there; with ""
  ## the block is taken out. Everything else in the file is kept as it is.
  ## It returns ``written``, ``unchanged``, ``deleted`` (the block was all
  ## the file held, so removing it removes the file, which is what an
  ## install that created it added) or ``absent`` (nothing to remove from a
  ## file that does not exist), and throws, leaving the file alone, when the
  ## file holds a block with no closing line, text its encoding cannot
  ## decode, UTF-32, or non-ASCII text without a byte-order mark: Windows
  ## PowerShell 5.1 reads such a file in the system's ANSI code page, which
  ## this code cannot know, so rewriting it could change its text.
  ##
  ## The file keeps its encoding: UTF-8 or UTF-16 (either byte order) with
  ## their byte-order marks (Windows PowerShell 5.1 writes UTF-16LE with
  ## ``>``), and plain ASCII stays without one while the text stays ASCII.
  ## A new file, or an ASCII one that a non-ASCII path makes non-ASCII, is
  ## written as UTF-8 with a byte-order mark, which both editions read as
  ## UTF-8. So taking the block out restores the bytes of the file it was
  ## added to, with two exceptions: a last line that had no line ending
  ## keeps the one adding the block gave it, and an ASCII file that a
  ## non-ASCII path gave a byte-order mark keeps the mark (the text is the
  ## same; whether the mark was there before cannot be told).
  ##
  ## The path is put in the block's single-quoted strings with every quote
  ## PowerShell reads as one doubled, the typographic ones included
  ## (``cliPowerShellSingleQuote``; about_Quoting_Rules,
  ## https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_quoting_rules).
  let bodyTemplate = completionBlockBody(program, ScriptPathPlaceholder)
  result = "function Update-ClispecCompletionBlock([string]$Path, " &
    "[string]$Script) {\n"
  result.add("  $open = " & q(completionBlockOpen(program)) & "\n")
  result.add("  $close = " & q(completionBlockClose(program)) & "\n")
  result.add("  $template = " & q(bodyTemplate) & "\n")
  result.add("  $placeholder = " & q(ScriptPathPlaceholder) & "\n")
  result.add("""
  $exists = [IO.File]::Exists($Path)
  $bytes = [byte[]]@()
  if ($exists) { $bytes = [IO.File]::ReadAllBytes($Path) }
  if ($bytes.Length -ge 4 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0 -and $bytes[3] -eq 0) -or ($bytes[0] -eq 0 -and $bytes[1] -eq 0 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF))) {
    throw ('{0} is UTF-32; left as it is' -f $Path)
  }
  # The encoding the file is read and written back in; $null for ASCII
  # without a byte-order mark (and for a new file). The decoders throw on
  # bytes they cannot decode, rather than replacing them.
  $encoding = $null
  $start = 0
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $start = 3
    $encoding = New-Object System.Text.UTF8Encoding $true, $true
  } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    $start = 2
    $encoding = New-Object System.Text.UnicodeEncoding $false, $true, $true
  } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
    $start = 2
    $encoding = New-Object System.Text.UnicodeEncoding $true, $true, $true
  } else {
    foreach ($b in $bytes) {
      if ($b -ge 0x80) { throw ('{0} holds non-ASCII text without a byte-order mark; left as it is' -f $Path) }
    }
  }
  if ($encoding) {
    $text = $encoding.GetString($bytes, $start, $bytes.Length - $start)
  } else {
    $text = [Text.Encoding]::ASCII.GetString($bytes)
  }
  $nl = "`r`n"
  if ($text.Contains("`n") -and -not $text.Contains("`r`n")) { $nl = "`n" }
  $kept = New-Object 'System.Collections.Generic.List[string]'
  $inside = $false
  foreach ($line in [regex]::Split($text, '\r?\n')) {
    if ($inside) {
      if ($line -ceq $close) { $inside = $false }
      continue
    }
    if ($line -ceq $open) { $inside = $true; continue }
    $kept.Add($line)
  }
  if ($inside) { throw ('{0}: the line {1} has no closing line; left as it is' -f $Path, $open) }
  $out = [string]::Join($nl, $kept.ToArray())
  if ($Script.Length -gt 0) {
    if ($out.Length -gt 0 -and -not $out.EndsWith($nl)) { $out += $nl }
    $body = $template.Replace($placeholder, [regex]::Replace($Script, '[''\u2018-\u201B]', '$0$0'))
    $out += $open + $nl + [regex]::Replace($body, '\r?\n', $nl) + $close + $nl
  }
  if ($out -ceq $text) {
    if ($exists) { return 'unchanged' }
    return 'absent'
  }
  if ($out.Length -eq 0) {
    [IO.File]::Delete($Path)
    return 'deleted'
  }
  if (-not $encoding -and ($out -cmatch '[^\x00-\x7F]' -or -not $exists)) {
    $encoding = New-Object System.Text.UTF8Encoding $true
  }
  $parent = [IO.Path]::GetDirectoryName($Path)
  if (-not [IO.Directory]::Exists($parent)) { [void][IO.Directory]::CreateDirectory($parent) }
  if ($encoding) {
    [IO.File]::WriteAllText($Path, $out, $encoding)
  } else {
    [IO.File]::WriteAllText($Path, $out, [Text.Encoding]::ASCII)
  }
  return 'written'
}
""")

proc reportLoop(program, files: string; failures: bool): string =
  ## The loop that updates each path of the PowerShell array expression
  ## ``files`` with ``$completionScript`` and prints one line per file; with
  ## ``failures``, it counts failures in ``$failed``.
  result = "foreach ($file in " & files & ") {\n"
  result.add("  try {\n")
  result.add("    $outcome = Update-ClispecCompletionBlock $file $completionScript\n")
  result.add("    Write-Output (" & q(program & " completion: ") &
    " + $file + ': ' + $outcome)\n")
  result.add("  } catch {\n")
  if failures:
    result.add("    $failed++\n")
  result.add("    Write-Output (" & q(program & " completion: ") &
    " + $file + ': not changed: ' + $_.Exception.Message)\n")
  result.add("  }\n")
  result.add("}\n")

const MsiScriptPathMarker* = "#clispec-completion-script:"
  ## What precedes the installed script's path at the end of an MSI
  ## action's command line (``msiQuietExecCommand``).

proc allUsersProfilesScript*(program: string): string =
  ## PowerShell that puts the block loading the installed script (the path
  ## after ``MsiScriptPathMarker`` in this process's command line; none
  ## there removes the block) in the all-users profile, ``$PSHOME\Profile.ps1``, of each PowerShell on the
  ## machine whose ``$PSHOME`` it can write: Windows PowerShell 5.1's
  ## (``%SystemRoot%\System32\WindowsPowerShell\v1.0``) and each PowerShell
  ## 7's, a directory under ``%ProgramFiles%\PowerShell`` that holds
  ## ``pwsh.exe`` (its MSI's layout). An MSIX PowerShell is not there, and
  ## its ``$PSHOME`` is not writable anyway. A file it cannot change is
  ## reported and the rest are still done; it exits 1 when any failed.
  result = "& {\n"
  # The path is read from the command line rather than written into the
  # code the command line runs: Windows Installer inserts it as it is, so
  # spliced into a PowerShell string a path holding a quote would end the
  # string and run the rest as code, as LocalSystem. After the marker it is
  # in a comment, which ends only at a line break, and no Windows path
  # holds one. The marker's first occurrence is the one: what precedes it
  # (the PowerShell executable's path and the base64 script) cannot hold
  # it, and the path itself may.
  result.add("$completionScript = ''\n")
  result.add("$marker = " & q(MsiScriptPathMarker) & "\n")
  result.add("$commandLine = [Environment]::CommandLine\n")
  result.add("$at = $commandLine.IndexOf($marker, " &
    "[StringComparison]::Ordinal)\n")
  result.add("if ($at -ge 0) {\n")
  result.add("  $completionScript = $commandLine.Substring($at + " &
    "$marker.Length).TrimEnd().TrimEnd([char]34).TrimEnd()\n")
  result.add("}\n")
  result.add(profileBlockUpdater(program))
  result.add("""
$homes = New-Object 'System.Collections.Generic.List[string]'
if ($env:SystemRoot) {
  $homes.Add([IO.Path]::Combine($env:SystemRoot, 'System32', 'WindowsPowerShell', 'v1.0'))
}
if ($env:ProgramFiles) {
  $pwshRoot = [IO.Path]::Combine($env:ProgramFiles, 'PowerShell')
  if ([IO.Directory]::Exists($pwshRoot)) {
    foreach ($d in [IO.Directory]::GetDirectories($pwshRoot)) {
      if ([IO.File]::Exists([IO.Path]::Combine($d, 'pwsh.exe'))) { $homes.Add($d) }
    }
  }
}
$files = New-Object 'System.Collections.Generic.List[string]'
foreach ($h in $homes) {
  if ([IO.Directory]::Exists($h)) { $files.Add([IO.Path]::Combine($h, 'Profile.ps1')) }
}
$failed = 0
""")
  result.add(reportLoop(program, "$files", failures = true))
  result.add("if ($failed -gt 0) { exit 1 }\n")
  result.add("}\n")

proc currentUserProfilesScript*(program, scriptExpr: string): string =
  ## PowerShell that puts the block loading the script at the PowerShell
  ## expression ``scriptExpr`` ("" removes the block) in the current user's
  ## ``CurrentUserAllHosts`` profile of both editions, under the folder
  ## ``[Environment]::GetFolderPath('MyDocuments')`` names (which may be
  ## redirected away from ``%USERPROFILE%\Documents``). A file it cannot
  ## change is reported and the other is still done; it never exits, since
  ## a package manager runs it in its own session.
  result = "& {\n"
  result.add("$completionScript = " &
    (if scriptExpr.len > 0: scriptExpr else: "''") & "\n")
  result.add(profileBlockUpdater(program))
  result.add("""
$docs = [Environment]::GetFolderPath('MyDocuments')
$files = @()
if ($docs) {
  $files = @([IO.Path]::Combine($docs, 'PowerShell', 'Profile.ps1'),
             [IO.Path]::Combine($docs, 'WindowsPowerShell', 'Profile.ps1'))
}
""")
  result.add(reportLoop(program, "$files", failures = false))
  result.add("}\n")

proc utf16LeBase64(text: string): string =
  ## ``text`` as PowerShell's ``-EncodedCommand`` spells a script: the
  ## base64 of its UTF-16LE bytes
  ## (https://learn.microsoft.com/powershell/module/microsoft.powershell.core/about/about_powershell_exe).
  var bytes = newStringOfCap(text.len * 2)
  for r in text.runes:
    var c = int(r)
    if c >= 0x10000:
      c -= 0x10000
      let hi = 0xD800 + (c shr 10)
      let lo = 0xDC00 + (c and 0x3FF)
      for unit in [hi, lo]:
        bytes.add(char(unit and 0xFF))
        bytes.add(char(unit shr 8))
    else:
      bytes.add(char(c and 0xFF))
      bytes.add(char(c shr 8))
  encode(bytes)

proc msiCompletionRunValue*(program: string): string =
  ## The value of the MSI property that carries
  ## ``allUsersProfilesScript(program)``: the tail of a PowerShell
  ## ``-Command`` that decodes the script and runs it. The script travels
  ## base64-encoded, so nothing in it can be read as command-line quoting or
  ## formatted-text syntax, and it lives in a property, whose value Windows
  ## Installer inserts into a formatted string as it is, never formatting
  ## it again (Formatted, https://learn.microsoft.com/windows/win32/msi/formatted).
  " iex ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('" &
    utf16LeBase64(allUsersProfilesScript(program)) & "')))"

proc msiQuietExecCommand*(scriptRef, runProperty: string): string =
  ## The command line, as an MSI formatted string, of a quiet-exec custom
  ## action that runs the machine's 64-bit Windows PowerShell with the
  ## property ``runProperty`` (whose value is ``msiCompletionRunValue``) as
  ## its command, followed, when ``scriptRef`` (a formatted reference to
  ## the installed script, ``[#<file id>]``) is not "", by a comment holding
  ## ``MsiScriptPathMarker`` and the path, which the script reads back from
  ## its command line (``allUsersProfilesScript``); with "" it removes the
  ## block. The path is never PowerShell code, whatever it holds: a comment
  ## ends only at a line break, which no Windows path can hold, and the
  ## path cannot hold the ``"`` that would end the argument either
  ## (Naming Files, https://learn.microsoft.com/windows/win32/fileio/naming-a-file).
  ## ``-NoProfile`` keeps the profiles being edited from running. The
  ## script, several kilobytes, is in the property, so the action's own
  ## ``Target`` (https://learn.microsoft.com/windows/win32/msi/customaction-table)
  ## stays this short line whatever the script's length.
  result = "\"[System64Folder]WindowsPowerShell\\v1.0\\powershell.exe\" -NoLogo " &
    "-NoProfile -NonInteractive -Command \"[" & runProperty & "]"
  if scriptRef.len > 0:
    result.add(" " & MsiScriptPathMarker & scriptRef)
  result.add("\"")
