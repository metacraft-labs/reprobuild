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

import ./expand_archive_boundary_support

type
  ProcessResult = object
    exitCode: int
    output: string

  ObservedRun = object
    ## ``exitCode`` is the OBSERVER's. ``childExit`` is the process under test's,
    ## and ``childExitReported`` says whether the observer got far enough to read
    ## it at all. Keeping them apart is the whole point: an observer that dies
    ## before launching the child also exits non-zero, and reading that as the
    ## child's verdict is how this gate previously reported a state it never
    ## reached. See Verification-Harness-Traps.md section 2.
    exitCode: int
    output: string
    scratchPath: string
    scratchReported: bool
    childExit: int
    childExitReported: bool

const ObserverCommand = """
$ErrorActionPreference = 'Stop'
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $env:TEMP
$watcher.Filter = 'repro-expand-archive-*.zip'
$watcher.IncludeSubdirectories = $false
$watcher.EnableRaisingEvents = $true
$subscription = Register-ObjectEvent -InputObject $watcher -EventName Created -SourceIdentifier 'repro-expand-archive-created'
try {
  # The child is EXPECTED to fail in two of the four cases below, so its
  # failure must not become the OBSERVER's failure before the observer has
  # read the watcher. Two independent mechanisms do exactly that under
  # $ErrorActionPreference = 'Stop':
  #
  #   * Windows PowerShell turns a native command's stderr into
  #     NativeCommandError records whenever the host's own stderr is
  #     redirected -- which it always is here, because the Nim harness pipes
  #     it (poStdErrToStdOut).
  #   * pwsh 7.4+ additionally applies $ErrorActionPreference to a native
  #     command's non-zero EXIT CODE
  #     ($PSNativeCommandUseErrorActionPreference, on by default).
  #
  # Either one aborts this scriptblock at the '&' below. The observer then
  # exits non-zero having never called Wait-Event -- so it reports "no
  # scratch archive was created" about a child that created one, while its
  # own non-zero exit is read as the child's. That is precisely the failure
  # this gate showed: `exitCode != 0` green, `scratchPath.len > 0` red.
  #
  # 'Continue' for the duration of the call, and the exit code read
  # explicitly afterwards, is the only combination that lets a failing child
  # be observed rather than propagated.
  $observerPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $childExit = $null
  & $env:REPRO_TEST_POWERSHELL -NoProfile -Command $env:REPRO_TEST_COMMAND
  $childExit = $LASTEXITCODE
  $ErrorActionPreference = $observerPreference
  if ($null -eq $childExit) {
    # `&` never launched the child (command not found, access denied). Print
    # a non-numeric placeholder rather than a plausible integer: the reader
    # parses CHILD_EXIT= strictly, so this reports "not observed" instead of
    # impersonating an exit code.
    $childExit = 'unlaunched'
  }
  $created = Wait-Event -SourceIdentifier 'repro-expand-archive-created' -Timeout 10
  if ($null -ne $created) {
    [Console]::Out.WriteLine('SCRATCH=' + $created.SourceEventArgs.FullPath)
  }
  # Printed BEFORE the require-creation throw below, and unconditionally:
  # once the child has been waited on, its exit code is a fact the reader is
  # entitled to even when the watcher assertion then fails.
  [Console]::Out.WriteLine('CHILD_EXIT=' + $childExit)
  if ($null -eq $created -and $env:REPRO_TEST_REQUIRE_CREATION -eq '1') {
    throw 'scratch .zip creation was not observed'
  }
  if ($childExit -ne 0) {
    exit 1
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

proc inheritedModulePath(): string =
  getEnv("PSModulePath")

proc fixtureShellEnvironment(): StringTableRef =
  ## Environment for the FIXTURE PowerShell calls -- the ones that build
  ## archives and manipulate ACLs. It differs from the inherited environment in
  ## exactly one variable, and that variable is the bug.
  ##
  ## ``Get-Acl`` / ``Set-Acl`` live in ``Microsoft.PowerShell.Security``, which
  ## Windows PowerShell autoloads by walking ``$env:PSModulePath``. The CI step
  ## shell on this runner class is PowerShell 7 (``C:\pwsh\pwsh.EXE``), and it
  ## exports a ``PSModulePath`` whose ``$PSHOME\Modules`` entry holds
  ## PowerShell 7's OWN ``Microsoft.PowerShell.Security``, whose manifest
  ## declares ``CompatiblePSEditions = @("Core")``. Desktop edition finds that
  ## copy first, refuses it, and reports
  ##
  ##   Get-Acl : The 'Get-Acl' command was found in the module
  ##   'Microsoft.PowerShell.Security', but the module could not be loaded.
  ##
  ## ``Microsoft.PowerShell.Archive`` (``Expand-Archive`` / ``Compress-Archive``)
  ## carries no ``CompatiblePSEditions`` key at all, so Desktop edition loads
  ## PowerShell 7's copy of THAT one happily -- which is why the archive
  ## fixtures kept working and only the ACL arm went red, and why the symptom
  ## looked like an ACL bug rather than an environment one.
  ##
  ## Rebuilding the variable from Windows PowerShell's own three directories is
  ## composed and unit-tested host-side in
  ## ``tests/windows/t_expand_archive_boundary_support.nim``.
  result = processEnvironment()
  result["PSModulePath"] = windowsPowerShellModulePath(
    getEnv("SystemRoot"), getEnv("ProgramFiles"), getEnv("USERPROFILE"))

proc fixtureShellExe(): string =
  ## The fixture interpreter, named absolutely and required to exist.
  ##
  ## No silent fallback to a PATH lookup: ``powershell`` on PATH is what the
  ## PRODUCTION argv resolves (deliberately -- that resolution is part of what
  ## this gate checks), and letting the fixture share that ambiguity is how an
  ## ACL check ends up unable to say which interpreter refused its module.
  result = windowsPowerShellExe(getEnv("SystemRoot"))
  if not fileExists(result):
    raise newException(IOError,
      "Windows PowerShell (Desktop edition) not found at " & result &
      " - the ACL fixtures need it. Inherited PSModulePath was: " &
      inheritedModulePath())

proc runPowerShell(command: string): ProcessResult =
  ## Fixture-side PowerShell. See ``fixtureShellExe`` and
  ## ``fixtureShellEnvironment`` above for why neither the interpreter nor the
  ## module path is inherited.
  runProcess(fixtureShellExe(), @["-NoProfile", "-Command", command],
             fixtureShellEnvironment())

proc requireProcessSuccess(processResult: ProcessResult; context: string) =
  if processResult.exitCode != 0:
    raise newException(IOError,
      context & " exited " & $processResult.exitCode & ": " &
        processResult.output)

proc requireSecurityModuleLoaded() =
  ## Preflight for the ACL arm: prove ``Get-Acl`` is live BEFORE any assertion
  ## depends on it.
  ##
  ## An ACL check whose module silently failed to load is a check that does not
  ## check (Verification-Harness-Traps.md section 2). The probe therefore
  ## asserts on what it PRODUCED -- a marker line naming the module that
  ## actually backs ``Get-Acl`` -- rather than on a zero exit code, and on
  ## failure it names the interpreter, the module path it was given, and the
  ## foreign entries in the path it was NOT given, so the next reader does not
  ## have to re-derive the diagnosis from "the module could not be loaded".
  let probe = runPowerShell(
    "$ErrorActionPreference = 'Stop'; " &
    "Import-Module Microsoft.PowerShell.Security -ErrorAction Stop; " &
    "$command = Get-Command Get-Acl -ErrorAction Stop; " &
    "if ($command.ModuleName -ne 'Microsoft.PowerShell.Security') { " &
      "throw ('Get-Acl resolved to module ' + $command.ModuleName) }; " &
    "[Console]::Out.WriteLine('" & SecurityModuleTag &
      "' + $command.ModuleName)")
  let foreign = foreignModulePathEntries(
    inheritedModulePath(), getEnv("SystemRoot"), getEnv("ProgramFiles"),
    getEnv("USERPROFILE"))
  let diagnosis =
    "\n  interpreter: " & fixtureShellExe() &
    "\n  PSModulePath given: " & windowsPowerShellModulePath(
      getEnv("SystemRoot"), getEnv("ProgramFiles"), getEnv("USERPROFILE")) &
    "\n  PSModulePath inherited: " & inheritedModulePath() &
    "\n  foreign entries in the inherited path: " & foreign.join(", ")
  if probe.exitCode != 0:
    raise newException(IOError,
      "Microsoft.PowerShell.Security failed to load; the ACL arm would have " &
      "asserted over a check that does not check. Probe exited " &
      $probe.exitCode & ": " & probe.output & diagnosis)
  let reported = taggedValue(probe.output, SecurityModuleTag)
  if not reported.found or reported.value != "Microsoft.PowerShell.Security":
    raise newException(IOError,
      "Microsoft.PowerShell.Security probe exited 0 without reporting the " &
      "module behind Get-Acl. Output: " & probe.output & diagnosis)

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
    # icacls is a NATIVE command, and this runs on the teardown path. Under
    # $ErrorActionPreference = 'Stop' with the host's stderr redirected (it
    # always is here), anything icacls writes to stderr becomes a terminating
    # NativeCommandError before the explicit $LASTEXITCODE check below can
    # run -- and a spurious throw here abandons the fixture with a delete-deny
    # ACE still installed on a directory the next test must remove. The exit
    # code is the signal that matters, so it is the one that is read.
    "$restorePreference = $ErrorActionPreference; " &
    "$ErrorActionPreference = 'Continue'; " &
    "Get-ChildItem -LiteralPath $path -Force | ForEach-Object { " &
      "& icacls.exe $_.FullName /reset /T /C /Q | Out-Null; " &
      "if ($LASTEXITCODE -ne 0) { " &
        "throw ('icacls reset failed for ' + $_.FullName + " &
          "' with exit code ' + $LASTEXITCODE) } }; " &
    "$ErrorActionPreference = $restorePreference")

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
  # The OBSERVER host is deliberately the bare PATH name too, and its
  # environment is deliberately inherited unchanged: the child inherits from
  # the observer, so sanitising anything here would run the production argv
  # under conditions production does not have. The fixture helpers above are
  # the only calls that get a rebuilt PSModulePath.
  let observed = runProcess(
    "powershell", @["-NoProfile", "-Command", ObserverCommand], env)
  result.exitCode = observed.exitCode
  result.output = observed.output
  let report = parseObserverReport(observed.output)
  result.scratchPath = report.scratchPath
  result.scratchReported = report.scratchReported
  result.childExit = report.childExit
  result.childExitReported = report.childExitReported

proc requireObserverReachedChild(run: ObservedRun; context: string) =
  ## Refuse to read the observer's exit code as the child's.
  ##
  ## ``CHILD_EXIT=`` can only be printed by the code path that read the child's
  ## ``$LASTEXITCODE``. Its absence means the observer died first -- and every
  ## assertion downstream would then be describing the harness, not the
  ## boundary. Raising here rather than checking makes that state impossible to
  ## mistake for a verdict.
  if not run.childExitReported:
    raise newException(IOError,
      context & ": the observer exited " & $run.exitCode &
      " without ever reporting CHILD_EXIT, so it never read the child's exit " &
      "code. Its own exit code is not the child's. Observer output:\n" &
      run.output)

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

    # The observer's exit code is the weakest thing it produces; assert the
    # child's, which only the path that actually read $LASTEXITCODE can report.
    requireObserverReachedChild(first, "first success run")
    requireObserverReachedChild(second, "second success run")
    check first.childExit == 0
    check second.childExit == 0
    check first.scratchReported
    check second.scratchReported
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

    # `Copy-Item` refuses a missing source before it creates the destination,
    # so this arm's identity is that the failure happened BEFORE any scratch
    # existed. Asserting the absence of a creation event, and not merely the
    # absence of a leftover file, is what distinguishes it from the extraction
    # arm below -- which fails after creating one and then cleans it up.
    requireObserverReachedChild(failed, "copy-failure run")
    check failed.childExit != 0
    check not failed.scratchReported
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

    # `Copy-Item` succeeds here -- the invalid file is copied to scratch
    # perfectly well -- and `Expand-Archive` is what fails, so a scratch
    # archive HAS been created and the implementation owes us its path. That
    # expectation was always right; what was wrong was the observer, which
    # took the child's failure as a terminating error and exited before it
    # could call Wait-Event. `exitCode != 0` was then green because the
    # OBSERVER had failed, while `scratchPath.len > 0` was red because it
    # never looked. requireObserverReachedChild makes that state impossible.
    requireObserverReachedChild(failed, "extraction-failure run")
    check failed.childExit != 0
    check failed.scratchReported
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

      # Before anything asserts through Get-Acl / Set-Acl, prove they are
      # actually live. Get-Acl failing to autoload is not a runner fault and
      # not an ACL result -- it is a check that does not check, and it is what
      # made this case die at readAccessSddl on every Windows run.
      requireSecurityModuleLoaded()
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
