## Windows-System-Resources M3f — real Windows execution-boundary gate.
##
## Test-double policy: this test uses no mocks or test doubles. It launches
## the exact argv emitted by ``buildZipArgvWindows`` in real, distinct Windows
## PowerShell processes. A real ``System.IO.FileSystemWatcher`` observes the
## isolated temporary directory so scratch creation remains observable even
## though the production command removes the file before exiting.
## Cleanup-failure coverage is deterministic rather than watcher-timed: an
## NTFS deny ACE for the current SID prevents deletion of both children and
## their parent entry while still allowing create/read/extract. The original
## directory DACL is restored unconditionally and fixture-child ACLs are reset
## from that restored parent before teardown.
##
## This source intentionally is not named ``t_*.nim``: the cross-platform test
## graph must not turn a Windows-only gate into a Linux skip. Required PR CI
## compiles and runs this file directly on the Windows runner class. Compiling
## it anywhere else is a hard error, never a passing skip.

when not defined(windows):
  {.fatal: "windows_expand_archive_execution_boundary must run on Windows".}

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import repro_dsl_stdlib/packages/expand_archive

type
  ProcessResult = object
    exitCode: int
    output: string

  ObservedRun = object
    exitCode: int
    output: string
    scratchPath: string

const ObserverCommand = """
$ErrorActionPreference = 'Stop'
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $env:TEMP
$watcher.Filter = 'repro-expand-archive-*.zip'
$watcher.IncludeSubdirectories = $false
$watcher.EnableRaisingEvents = $true
$subscription = Register-ObjectEvent -InputObject $watcher -EventName Created -SourceIdentifier 'repro-expand-archive-created'
try {
  & $env:REPRO_TEST_POWERSHELL -NoProfile -Command $env:REPRO_TEST_COMMAND
  $childExit = $LASTEXITCODE
  $created = Wait-Event -SourceIdentifier 'repro-expand-archive-created' -Timeout 10
  if ($null -ne $created) {
    [Console]::Out.WriteLine('SCRATCH=' + $created.SourceEventArgs.FullPath)
  } elseif ($env:REPRO_TEST_REQUIRE_CREATION -eq '1') {
    throw 'scratch .zip creation was not observed'
  }
  [Console]::Out.WriteLine('CHILD_EXIT=' + $childExit)
  if ($childExit -ne 0) {
    exit $childExit
  }
} finally {
  Unregister-Event -SourceIdentifier 'repro-expand-archive-created' -ErrorAction SilentlyContinue
  Get-Event -SourceIdentifier 'repro-expand-archive-created' -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
  if ($null -ne $subscription) {
    Remove-Job -Job $subscription -Force -ErrorAction SilentlyContinue
  }
  $watcher.Dispose()
}
"""

proc processEnvironment(): StringTableRef =
  result = newStringTable(modeCaseInsensitive)
  for key, value in envPairs():
    result[key] = value

proc runProcess(executable: string; args: seq[string];
                env: StringTableRef = nil): ProcessResult =
  let process = startProcess(
    executable,
    args = args,
    env = env,
    options = {poUsePath, poStdErrToStdOut})
  result.output = process.outputStream.readAll()
  result.exitCode = process.waitForExit()
  process.close()

proc runPowerShell(command: string): ProcessResult =
  runProcess("powershell", @["-NoProfile", "-Command", command])

proc requireProcessSuccess(processResult: ProcessResult; context: string) =
  if processResult.exitCode != 0:
    raise newException(IOError,
      context & " exited " & $processResult.exitCode & ": " &
        processResult.output)

proc readAccessSddl(path: string): string =
  let readResult = runPowerShell(
    "$ErrorActionPreference = 'Stop'; " &
    "$acl = Get-Acl -LiteralPath " & powershellSingleQuotedLiteral(path) &
      "; " &
    "[Console]::Out.Write($acl.GetSecurityDescriptorSddlForm(" &
      "[System.Security.AccessControl.AccessControlSections]::Access))")
  requireProcessSuccess(readResult, "read original fixture DACL")
  result = readResult.output.strip()
  if result.len == 0:
    raise newException(IOError, "read original fixture DACL returned no SDDL")

proc installDeleteDenyAcl(path: string): ProcessResult =
  let pathLiteral = powershellSingleQuotedLiteral(path)
  runPowerShell(
    "$ErrorActionPreference = 'Stop'; " &
    "$path = " & pathLiteral & "; " &
    "$sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User; " &
    "$rights = [System.Security.AccessControl.FileSystemRights](" &
      "[System.Security.AccessControl.FileSystemRights]::Delete -bor " &
      "[System.Security.AccessControl.FileSystemRights]::" &
        "DeleteSubdirectoriesAndFiles); " &
    "$inheritance = [System.Security.AccessControl.InheritanceFlags](" &
      "[System.Security.AccessControl.InheritanceFlags]::ContainerInherit " &
        "-bor " &
      "[System.Security.AccessControl.InheritanceFlags]::ObjectInherit); " &
    "$rule = [System.Security.AccessControl.FileSystemAccessRule]::new(" &
      "$sid, $rights, $inheritance, " &
      "[System.Security.AccessControl.PropagationFlags]::None, " &
      "[System.Security.AccessControl.AccessControlType]::Deny); " &
    "$acl = Get-Acl -LiteralPath $path; " &
    "$acl.AddAccessRule($rule); " &
    "Set-Acl -LiteralPath $path -AclObject $acl; " &
    "$verified = Get-Acl -LiteralPath $path; " &
    "$matching = @($verified.Access | Where-Object { " &
      "-not $_.IsInherited -and " &
      "$_.AccessControlType -eq " &
        "[System.Security.AccessControl.AccessControlType]::Deny -and " &
      "$_.IdentityReference.Translate(" &
        "[System.Security.Principal.SecurityIdentifier]).Value -eq " &
        "$sid.Value -and " &
      "($_.FileSystemRights -band $rights) -eq $rights -and " &
      "($_.InheritanceFlags -band $inheritance) -eq $inheritance }); " &
    "if ($matching.Count -ne 1) { " &
      "throw ('delete-deny ACE verification found ' + $matching.Count + " &
        "' matches') }")

proc restoreAccessAndResetChildren(path, accessSddl: string): ProcessResult =
  runPowerShell(
    "$ErrorActionPreference = 'Stop'; " &
    "$path = " & powershellSingleQuotedLiteral(path) & "; " &
    "$acl = Get-Acl -LiteralPath $path; " &
    "$acl.SetSecurityDescriptorSddlForm(" &
      powershellSingleQuotedLiteral(accessSddl) & ", " &
      "[System.Security.AccessControl.AccessControlSections]::Access); " &
    "Set-Acl -LiteralPath $path -AclObject $acl; " &
    "Get-ChildItem -LiteralPath $path -Force | ForEach-Object { " &
      "& icacls.exe $_.FullName /reset /T /C /Q | Out-Null; " &
      "if ($LASTEXITCODE -ne 0) { " &
        "throw ('icacls reset failed for ' + $_.FullName + " &
          "' with exit code ' + $LASTEXITCODE) } }")

proc runObserved(argv: seq[string]; tempRoot: string;
                 requireCreation: bool): ObservedRun =
  if argv.len != 4 or argv[0] != "powershell" or
      argv[1] != "-NoProfile" or argv[2] != "-Command":
    raise newException(ValueError,
      "observer requires the exact four-element PowerShell argv")
  var env = processEnvironment()
  env["TEMP"] = tempRoot
  env["TMP"] = tempRoot
  env["REPRO_TEST_POWERSHELL"] = argv[0]
  env["REPRO_TEST_COMMAND"] = argv[3]
  env["REPRO_TEST_REQUIRE_CREATION"] =
    if requireCreation: "1" else: "0"
  let observed = runProcess(
    "powershell", @["-NoProfile", "-Command", ObserverCommand], env)
  result.exitCode = observed.exitCode
  result.output = observed.output
  for line in observed.output.splitLines():
    if line.startsWith("SCRATCH="):
      result.scratchPath = line["SCRATCH=".len .. ^1]

proc remainingScratchFiles(tempRoot: string): seq[string] =
  for path in walkFiles(tempRoot / "repro-expand-archive-*.zip"):
    result.add(path)

suite "M3f Windows expandArchive runtime boundary":

  test "distinct PowerShell processes use distinct .zip scratch and clean success":
    let root = createTempDir("repro-expand-archive-boundary-", "")
    defer:
      if dirExists(root):
        removeDir(root)

    let payload = root / "payload.txt"
    let archive = root / "source archive's.zip"
    let destinationA = root / "destination one's"
    let destinationB = root / "destination two's"
    writeFile(payload, "M3f real Windows boundary\n")
    let compress = runPowerShell(
      "$ErrorActionPreference = 'Stop'; " &
      "Compress-Archive -LiteralPath " & powershellSingleQuotedLiteral(payload) &
      " -DestinationPath " & powershellSingleQuotedLiteral(archive) &
      " -Force")
    check compress.exitCode == 0

    let first = runObserved(
      buildZipArgvWindows(archive, destinationA), root,
      requireCreation = true)
    let second = runObserved(
      buildZipArgvWindows(archive, destinationB), root,
      requireCreation = true)

    check first.exitCode == 0
    check second.exitCode == 0
    check first.scratchPath.len > 0
    check second.scratchPath.len > 0
    check first.scratchPath.extractFilename().startsWith(
      "repro-expand-archive-")
    check second.scratchPath.extractFilename().startsWith(
      "repro-expand-archive-")
    check first.scratchPath.toLowerAscii().endsWith(".zip")
    check second.scratchPath.toLowerAscii().endsWith(".zip")
    check first.scratchPath.extractFilename() !=
      second.scratchPath.extractFilename()
    check readFile(destinationA / "payload.txt") ==
      "M3f real Windows boundary\n"
    check readFile(destinationB / "payload.txt") ==
      "M3f real Windows boundary\n"
    check remainingScratchFiles(root).len == 0

  test "copy failure is nonzero and leaves no scratch":
    let root = createTempDir("repro-expand-archive-copy-failure-", "")
    defer:
      if dirExists(root):
        removeDir(root)

    let missingArchive = root / "missing archive's.zip"
    let destination = root / "destination"
    let failed = runObserved(
      buildZipArgvWindows(missingArchive, destination), root,
      requireCreation = false)

    check failed.exitCode != 0
    check remainingScratchFiles(root).len == 0

  test "extraction failure is nonzero and cleans the observed scratch":
    let root = createTempDir("repro-expand-archive-extract-failure-", "")
    defer:
      if dirExists(root):
        removeDir(root)

    let invalidArchive = root / "invalid archive's.zip"
    let destination = root / "destination"
    writeFile(invalidArchive, "this is not a zip archive")
    let failed = runObserved(
      buildZipArgvWindows(invalidArchive, destination), root,
      requireCreation = true)

    check failed.exitCode != 0
    check failed.scratchPath.len > 0
    check failed.scratchPath.extractFilename().startsWith(
      "repro-expand-archive-")
    check failed.scratchPath.toLowerAscii().endsWith(".zip")
    check remainingScratchFiles(root).len == 0

  test "cleanup failure is nonzero and retains scratch until ACL restoration":
    let root = createTempDir("repro-expand-archive-cleanup-failure-", "")
    var originalAccessSddl = ""
    var restoreRequired = false
    try:
      let payload = root / "payload.txt"
      let archive = root / "source archive's.zip"
      let destination = root / "destination"
      writeFile(payload, "M3f cleanup-failure boundary\n")
      let compress = runPowerShell(
        "$ErrorActionPreference = 'Stop'; " &
        "Compress-Archive -LiteralPath " &
          powershellSingleQuotedLiteral(payload) &
        " -DestinationPath " & powershellSingleQuotedLiteral(archive) &
        " -Force")
      requireProcessSuccess(compress, "create cleanup-failure archive")

      originalAccessSddl = readAccessSddl(root)
      # Restoration is required even when installation reports a failure:
      # Set-Acl may have completed before the verification step failed.
      restoreRequired = true
      let denyInstall = installDeleteDenyAcl(root)
      requireProcessSuccess(denyInstall, "install fixture delete-deny ACL")

      var env = processEnvironment()
      env["TEMP"] = root
      env["TMP"] = root
      let argv = buildZipArgvWindows(archive, destination)
      check argv.len == 4
      let failed = runProcess(argv[0], argv[1 .. ^1], env)

      check failed.exitCode != 0
      # Extraction completed before the finally block attempted cleanup, so
      # the non-zero result is specifically the fail-closed Remove-Item path.
      check readFile(destination / "payload.txt") ==
        "M3f cleanup-failure boundary\n"
      let retained = remainingScratchFiles(root)
      check retained.len == 1
      if retained.len == 1:
        check retained[0].extractFilename().startsWith(
          "repro-expand-archive-")
        check retained[0].toLowerAscii().endsWith(".zip")
        check fileExists(retained[0])
    finally:
      if restoreRequired:
        let restored = restoreAccessAndResetChildren(
          root, originalAccessSddl)
        requireProcessSuccess(restored,
          "restore fixture DACL and reset child ACLs")
      for scratch in remainingScratchFiles(root):
        removeFile(scratch)
      check remainingScratchFiles(root).len == 0
      if dirExists(root):
        removeDir(root)
    check not dirExists(root)
