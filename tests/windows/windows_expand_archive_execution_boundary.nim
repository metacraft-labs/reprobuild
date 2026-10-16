## Windows-System-Resources M3f — real Windows execution-boundary gate.
##
## Test-double policy: this test uses no mocks or test doubles. It launches
## the exact argv emitted by ``buildZipArgvWindows`` in real, distinct Windows
## PowerShell processes. A real ``System.IO.FileSystemWatcher`` observes the
## isolated temporary directory, so a scratch archive would be seen even if
## the command removed it before exiting.
##
## What it pins: the lowered command extracts with the .NET zip reader
## directly, never through the ``Expand-Archive`` cmdlet and never through a
## scratch ``.zip`` copy under ``$env:TEMP``. The cmdlet's per-entry progress
## records made a 12,000-entry archive take about 40 minutes, and the scratch
## copy it needed carried its own cleanup-failure mode, which this gate used
## to exercise with a delete-deny ACL. With no scratch file there is no
## cleanup to fail, so what remains is: success in distinct processes,
## no ``.zip`` created in the temporary directory on any path, non-zero exit
## for a missing or corrupt archive, and overwrite-in-place over an existing
## destination under Windows PowerShell 5.1's .NET Framework, whose
## ``ExtractToDirectory`` cannot overwrite.
##
## This source intentionally is not named ``t_*.nim``: the cross-platform test
## graph must not turn a Windows-only gate into a Linux skip. Required PR CI
## compiles and runs this file directly on the Windows runner class. Compiling
## it anywhere else is a hard error, never a passing skip.
##
## Host-environment contract: the required lane invokes this binary from a
## ``shell: pwsh`` step (PowerShell 7 at ``C:\pwsh``) while every process the
## test spawns is ``powershell.exe`` — Windows PowerShell 5.1. Two properties
## of that pairing are load-bearing and are handled explicitly below rather
## than inherited by accident: PowerShell 7's PSModulePath must not reach 5.1
## (see ``processEnvironment``), and 5.1's 'Stop' preference must not be in
## force across the native child call (see ``ObserverCommand``). Each was a
## silent, permanent failure of this gate.

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

# The boundary child is invoked through a function whose preference
# variables are deliberately RELAXED. The observer itself wants 'Stop', but
# under Windows PowerShell 5.1 'Stop' also turns a native command's STDERR
# into a TERMINATING NativeCommandError. Every failure path this gate exists
# to observe makes the child write to stderr, so with 'Stop' in force the
# observer aborted at the call itself: Wait-Event never ran, no SCRATCH=
# line was ever emitted, and the extraction-failure case could only ever
# report "no scratch observed". Preference variables resolve dynamically, so
# the function-local relaxation covers exactly this call and is discarded on
# return; $PSNativeCommandUseErrorActionPreference keeps a pwsh 7 host from
# making the non-zero EXIT CODE terminating instead. This is the same
# containment pattern infra's Invoke-CacheCli uses for the same hazard.
# The child's merged output is echoed under a CHILD: prefix so it cannot be
# confused with the SCRATCH=/CHILD_EXIT= protocol lines and so a future
# failure arrives with the child's own diagnosis attached.
function Invoke-BoundaryChild {
  $ErrorActionPreference = 'Continue'
  $PSNativeCommandUseErrorActionPreference = $false
  & $env:REPRO_TEST_POWERSHELL -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $env:REPRO_TEST_COMMAND 2>&1 |
    ForEach-Object { [Console]::Out.WriteLine('CHILD: ' + [string]$_) }
  return $LASTEXITCODE
}

$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $env:TEMP
$watcher.Filter = '*.zip'
$watcher.IncludeSubdirectories = $false
$watcher.EnableRaisingEvents = $true
$subscription = Register-ObjectEvent -InputObject $watcher -EventName Created -SourceIdentifier 'repro-expand-archive-created'
try {
  $childExit = Invoke-BoundaryChild
  if ($null -eq $childExit) { $childExit = 1 }
  $created = Wait-Event -SourceIdentifier 'repro-expand-archive-created' -Timeout 10
  if ($null -ne $created) {
    [Console]::Out.WriteLine('SCRATCH=' + $created.SourceEventArgs.FullPath)
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
  ## The environment handed to every child this test starts — the ambient one
  ## minus ``PSModulePath``, so each ``powershell.exe`` resolves modules the
  ## way Windows PowerShell 5.1 would on its own.
  ##
  ## The required lane runs this gate from a ``shell: pwsh`` step, i.e. from
  ## PowerShell 7 installed at ``C:\pwsh``. pwsh exports a PSModulePath whose
  ## leading entry is its OWN module directory, this process inherits it, and
  ## the ``powershell`` children inherit it in turn. Windows PowerShell 5.1
  ## then searches PowerShell 7's directory FIRST when auto-loading a module,
  ## and PowerShell 7's ``Microsoft.PowerShell.Security`` is a Core-only
  ## binary module that 5.1 cannot load — which is why ``Get-Acl`` failed with
  ## "The 'Get-Acl' command was found in the module
  ## 'Microsoft.PowerShell.Security', but the module could not be loaded"
  ## while ``Compress-Archive`` in the very same process succeeded: modules
  ## already present in 5.1's default session (Utility, Management) are loaded
  ## by path at startup, and ``Microsoft.PowerShell.Archive`` is an
  ## edition-agnostic script module that 5.1 can load from either copy.
  ##
  ## ``docs/windows-dev-environment.md`` pins the same remedy for interactive
  ## use ("not optional if you launched from pwsh 7"). Dropping the variable
  ## is the version-agnostic spelling of it: with PSModulePath absent,
  ## PowerShell rebuilds its own default, so 5.1 gets 5.1's directories.
  ##
  ## The scrub is applied to the explicitly built child environment rather
  ## than to this process's own variables: the child block is then what
  ## ``startProcess`` writes, with no dependency on whether a CRT ``delEnv``
  ## also reaches the Win32 environment block that a nil-env spawn inherits.
  ##
  ## This also puts the lowered production command on a stock Windows
  ## PowerShell module path, which is the environment a reprobuild engine
  ## action actually spawns it in — the engine is not a pwsh 7 child.
  result = newStringTable(modeCaseInsensitive)
  for key, value in envPairs():
    result[key] = value
  if result.hasKey("PSModulePath"):
    result.del("PSModulePath")

proc runProcess(executable: string; args: seq[string];
                env: StringTableRef = nil): ProcessResult =
  # A nil `env` would make the child inherit this process's environment
  # verbatim, PSModulePath included — the one variable this test must not
  # pass down (see `processEnvironment`). Defaulting to the scrubbed table
  # keeps the fixture helpers and the boundary spawns on the same footing.
  let childEnv = if env.isNil: processEnvironment() else: env
  let process = startProcess(
    executable,
    args = args,
    env = childEnv,
    options = {poUsePath, poStdErrToStdOut})
  defer: process.close()
  # Nim 2.2 readAll stops at a short pipe read, not necessarily EOF. These
  # finite children must be drained completely, including late protocol lines
  # and the full SDDL needed to restore the fixture's original permissions.
  let output = process.outputStream
  while not output.atEnd():
    result.output.add(output.readAll())
  result.exitCode = process.waitForExit()

proc runPowerShell(command: string): ProcessResult =
  runProcess("powershell", @["-NoProfile", "-Command", command])

proc requireProcessSuccess(processResult: ProcessResult; context: string) =
  if processResult.exitCode != 0:
    raise newException(IOError,
      context & " exited " & $processResult.exitCode & ": " &
        processResult.output)

const LoweredFlags = @["-NoProfile", "-NonInteractive", "-ExecutionPolicy",
  "Bypass", "-Command"]

proc runObserved(argv: seq[string]; tempRoot: string): ObservedRun =
  ## Runs the lowered command under the observer with ``TEMP``/``TMP``
  ## pointed at ``tempRoot``. ``scratchPath`` is the first ``.zip`` the
  ## watcher saw created there, if any.
  if argv.len != LoweredFlags.len + 2 or argv[0] != "powershell" or
      argv[1 .. ^2] != LoweredFlags:
    raise newException(ValueError,
      "observer requires the exact lowered PowerShell argv, got " & $argv)
  var env = processEnvironment()
  env["TEMP"] = tempRoot
  env["TMP"] = tempRoot
  env["REPRO_TEST_POWERSHELL"] = argv[0]
  env["REPRO_TEST_COMMAND"] = argv[^1]
  let observed = runProcess(
    "powershell", @["-NoProfile", "-Command", ObserverCommand], env)
  result.exitCode = observed.exitCode
  result.output = observed.output
  for line in observed.output.splitLines():
    if line.startsWith("SCRATCH="):
      result.scratchPath = line["SCRATCH=".len .. ^1]
  if result.scratchPath.len > 0 or not observed.output.contains("CHILD_EXIT="):
    # `check` prints the expression, not the evidence.
    echo "observer exit code ", observed.exitCode, "; full observer output:"
    echo observed.output

proc remainingScratchFiles(tempRoot: string): seq[string] =
  for path in walkFiles(tempRoot / "*.zip"):
    result.add(path)

proc makeArchive(root, archive: string; files: openArray[(string, string)]) =
  ## Builds ``archive`` from ``files`` with Windows PowerShell's own
  ## ``Compress-Archive``, which writes backslash-separated entry names. The
  ## payload is staged in a directory of its own so the archive holds only
  ## these files.
  let stage = root / "payload"
  removeDir(stage)
  for (rel, text) in files:
    createDir(parentDir(stage / rel))
    writeFile(stage / rel, text)
  let compress = runPowerShell(
    "$ErrorActionPreference = 'Stop'; " &
    "Compress-Archive -Path " &
      powershellSingleQuotedLiteral(stage / "*") &
    " -DestinationPath " & powershellSingleQuotedLiteral(archive) &
    " -Force")
  requireProcessSuccess(compress, "create fixture archive")

suite "M3f Windows expandArchive runtime boundary":

  test "process capture retains delayed stdout and stderr after a short read":
    let captured = runPowerShell(
      "[Console]::Out.Write('first'); [Console]::Out.Flush(); " &
      "Start-Sleep -Milliseconds 200; " &
      "[Console]::Out.Write(('x' * 1024)); " &
      "[Console]::Error.Write('last'); exit 7")
    check captured.exitCode == 7
    check captured.output == "first" & repeat('x', 1024) & "last"

  test "distinct PowerShell processes extract with no scratch .zip":
    let root = createTempDir("repro-expand-archive-boundary-", "")
    defer:
      if dirExists(root):
        removeDir(root)

    let archive = root / "source archive's.zip"
    let destinationA = root / "destination one's"
    let destinationB = root / "destination two's"
    makeArchive(root, archive, [
      ("payload.txt", "M3f real Windows boundary\n"),
      ("nested\\deeper.txt", "backslash-separated entry\n")])

    let first = runObserved(
      buildZipArgvWindows(archive, destinationA), root)
    let second = runObserved(
      buildZipArgvWindows(archive, destinationB), root)

    check first.exitCode == 0
    check second.exitCode == 0
    check first.scratchPath.len == 0
    check second.scratchPath.len == 0
    for destination in [destinationA, destinationB]:
      check readFile(destination / "payload.txt") ==
        "M3f real Windows boundary\n"
      check readFile(destination / "nested" / "deeper.txt") ==
        "backslash-separated entry\n"
    check remainingScratchFiles(root) == @[archive]

  test "an existing destination is overwritten in place, like -Force":
    let root = createTempDir("repro-expand-archive-overwrite-", "")
    defer:
      if dirExists(root):
        removeDir(root)

    let archive = root / "runner.zip"
    let destination = root / "destination"
    makeArchive(root, archive, [("config.cmd", "new config\n")])
    createDir(destination)
    writeFile(destination / "config.cmd", "old config\n")
    writeFile(destination / "keep.txt", "not in the archive\n")

    let run = runObserved(buildZipArgvWindows(archive, destination), root)
    check run.exitCode == 0
    check run.scratchPath.len == 0
    check readFile(destination / "config.cmd") == "new config\n"
    check readFile(destination / "keep.txt") == "not in the archive\n"

  test "a missing archive is nonzero and creates no scratch":
    let root = createTempDir("repro-expand-archive-missing-", "")
    defer:
      if dirExists(root):
        removeDir(root)

    let failed = runObserved(
      buildZipArgvWindows(root / "missing archive's.zip",
        root / "destination"), root)
    check failed.exitCode != 0
    check failed.scratchPath.len == 0
    check remainingScratchFiles(root).len == 0

  test "a corrupt archive is nonzero and creates no scratch":
    let root = createTempDir("repro-expand-archive-corrupt-", "")
    defer:
      if dirExists(root):
        removeDir(root)

    let invalidArchive = root / "invalid archive's.zip"
    writeFile(invalidArchive, "this is not a zip archive")
    let failed = runObserved(
      buildZipArgvWindows(invalidArchive, root / "destination"), root)
    check failed.exitCode != 0
    check failed.scratchPath.len == 0
    check remainingScratchFiles(root) == @[invalidArchive]
