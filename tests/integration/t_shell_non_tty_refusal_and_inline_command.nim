## `repro shell` without a terminal, and `repro shell -c` / `repro shell --`.
##
## Spawn mode (no `--print-env`, `-c` or `-- <command>`) starts an
## interactive shell. With a standard input that is not a terminal it must
## refuse at once: exit 2, nothing on stdout, nothing spawned, and an
## `error:` + `tip:` diagnostic naming `repro exec -- <command>` and
## `repro shell --print-env=<format>`. The refusal is taken before the
## development environment is resolved, so it must also be fast.
##
## `-c <command>` (through the selected shell) and `-- <command>` (directly)
## run one command in the activated environment and exit with its status,
## with or without a terminal. Naming two modes at once is a usage error.
##
## Spawn mode with a terminal on standard input must still start the shell;
## that arm runs under a real pseudo-terminal (`terminal_fixtures`), because
## nothing else makes `isatty` answer true.
##
## No mocks: every case runs the real built `repro` against a real fixture
## project, whose development environment is really computed. The "shells"
## passed with `--shell` are real executable scripts that record that they
## ran (a marker file) instead of reading commands; that is what lets a case
## prove a shell was, or was not, started.

import std/[os, osproc, strtabs, strutils, tempfiles, times, unittest]

import repro_test_support
import repro_cli_support/shell_invocation
when defined(posix):
  import repro_test_support/terminal_fixtures

proc q(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc reproBinary(): string =
  requireBinary(getCurrentDir() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc writeFixture(dir: string) =
  createDir(dir)
  writeFile(dir / "reprobuild.nim",
    "import repro_project_dsl\n\n" &
    "package fixture:\n" &
    "  defaultToolProvisioning \"path\"\n" &
    "  devEnv:\n" &
    "    activity \"default\"\n" &
    "    setEnv \"FIXTURE_MODE\", \"dev\"\n")

proc makeExecutable(path: string) =
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec,
    fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

type
  ShellCase = object
    tempRoot: string
    projectRoot: string
    repoRoot: string
    reproBin: string
    shim: string

proc prepareCase(prefix: string): ShellCase =
  result.repoRoot = getCurrentDir()
  result.tempRoot = expandFilename(createTempDir(prefix, ""))
  result.projectRoot = result.tempRoot / "project"
  writeFixture(result.projectRoot)
  result.reproBin = reproBinary()
  when isIoMonitorSupported:
    let monitor = prepareMonitorTools(result.repoRoot, result.tempRoot,
      "shell-non-tty")
    result.shim = monitor.shim

proc envFor(c: ShellCase): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result["REPROBUILD_SOURCE_ROOT"] = c.repoRoot
  if c.shim.len > 0:
    result["REPRO_MONITOR_SHIM_LIB"] = c.shim
  # The default shell `-c` runs through, when `--shell` is not given.
  result["SHELL"] = "/bin/sh"

proc markerShell(c: ShellCase; name: string): tuple[script, marker: string] =
  ## A "shell" that records its arguments and the activated environment in
  ## a marker file, then exits 0.
  result.marker = c.tempRoot / (name & ".marker")
  result.script = c.tempRoot / name
  writeFile(result.script,
    "#!/bin/sh\n" &
    "printf 'ran:%s:%s:%s\\n' \"$FIXTURE_MODE\" \"$1\" \"$2\" > " &
      q(result.marker) & "\n")
  makeExecutable(result.script)

type Run = tuple[code: int; stdout, stderr: string; seconds: float]

proc runWithNullStdin(c: ShellCase; args: openArray[string]): Run =
  ## `repro <args> < /dev/null`. The redirection is made by an `exec`-ing
  ## `/bin/sh`, so the status is repro's own.
  var shArgs = @["-c", "exec \"$0\" \"$@\" </dev/null", c.reproBin]
  for arg in args:
    shArgs.add(arg)
  let started = epochTime()
  let res = runProgramSplit("/bin/sh", shArgs, c.repoRoot, c.envFor(),
    timeoutMs = 600_000)
  (code: res.code, stdout: res.stdout, stderr: res.stderr,
    seconds: epochTime() - started)

suite "repro shell decides its mode before resolving anything":
  test "the flags name exactly one mode, or a usage error":
    check shellInvocationOf(false, false, false, false).mode == simSpawn
    check shellInvocationOf(false, false, false, true).mode == simSpawn
    check shellInvocationOf(true, false, false, false).mode == simPrintEnv
    check shellInvocationOf(false, true, false, true).mode == simInlineCommand
    check shellInvocationOf(false, false, true, false).mode == simDirectCommand
    for flags in [(false, true, true, false), (true, true, false, false),
                  (true, false, true, false), (false, false, true, true)]:
      let inv = shellInvocationOf(flags[0], flags[1], flags[2], flags[3])
      check inv.usageError.len > 0
    check shellInvocationOf(false, true, false, false).usageError.len == 0

  test "only spawn mode without a terminal is refused":
    let refusal = shellSpawnRefusal(simSpawn, stdinIsTerminal = false)
    check refusal.len == 2
    check refusal[0].startsWith("error: ")
    check refusal[1].startsWith("tip: ")
    check refusal[1].contains("repro exec -- <command>")
    check refusal[1].contains("repro shell --print-env=<format>")
    check shellSpawnRefusal(simSpawn, stdinIsTerminal = true).len == 0
    for mode in [simPrintEnv, simInlineCommand, simDirectCommand]:
      check shellSpawnRefusal(mode, stdinIsTerminal = false).len == 0

  test "-c is spelt for the shell that runs it":
    check inlineCommandArgv("/bin/sh", "true") == @["/bin/sh", "-c", "true"]
    check inlineCommandArgv("C:\\Windows\\System32\\cmd.exe", "ver") ==
      @["C:\\Windows\\System32\\cmd.exe", "/c", "ver"]
    check inlineCommandArgv("pwsh", "1") == @["pwsh", "-Command", "1"]

when defined(posix):
  suite "repro shell without a terminal, and with one":
    test "spawn mode on /dev/null is refused at once, with no output":
      let c = prepareCase("repro-shell-non-tty")
      defer: removeDir(c.tempRoot)
      let res = c.runWithNullStdin(@["shell", c.projectRoot])
      checkpoint(res.stderr)
      check res.code == 2
      check res.seconds < 2.0
      check res.stdout.len == 0
      check res.stderr.contains("error:")
      check res.stderr.contains("tip:")
      check res.stderr.contains("repro exec -- ")
      check res.stderr.contains("repro shell --print-env=")

    test "spawn mode on /dev/null starts no shell":
      let c = prepareCase("repro-shell-non-tty-nospawn")
      defer: removeDir(c.tempRoot)
      let shell = c.markerShell("marker-shell")
      let res = c.runWithNullStdin(@["shell", c.projectRoot,
        "--shell=" & shell.script])
      checkpoint(res.stderr)
      check res.code == 2
      check res.seconds < 2.0
      check res.stdout.len == 0
      check not fileExists(shell.marker)

    test "-c runs the command through the shell and exits with its status":
      let c = prepareCase("repro-shell-inline")
      defer: removeDir(c.tempRoot)
      let ok = c.runWithNullStdin(@["shell", c.projectRoot, "-c", "printf ok"])
      checkpoint(ok.stderr)
      check ok.code == 0
      check ok.stdout == "ok"
      let failed = c.runWithNullStdin(@["shell", c.projectRoot, "-c",
        "exit 5"])
      check failed.code == 5
      # In the activated environment, and through the shell `--shell`
      # names (`<shell> -c <command>`).
      let activated = c.runWithNullStdin(@["shell", c.projectRoot,
        "--command=printf %s \"$FIXTURE_MODE\""])
      check activated.code == 0
      check activated.stdout == "dev"
      let shell = c.markerShell("inline-shell")
      let through = c.runWithNullStdin(@["shell", c.projectRoot,
        "--shell=" & shell.script, "-c", "the command"])
      check through.code == 0
      check fileExists(shell.marker)
      if fileExists(shell.marker):
        check readFile(shell.marker).strip() == "ran:dev:-c:the command"

    test "-- runs the command directly and exits with its status":
      let c = prepareCase("repro-shell-direct")
      defer: removeDir(c.tempRoot)
      let res = c.runWithNullStdin(@["shell", c.projectRoot, "--", "sh", "-c",
        "printf '%s' \"$FIXTURE_MODE\"; exit 7"])
      checkpoint(res.stderr)
      check res.code == 7
      check res.stdout == "dev"

    test "a bare -- names no command, so it is spawn mode, refused here":
      # The parser keeps no trace of a `--` with nothing after it, so
      # `repro shell --` cannot be told from `repro shell` (as `repro exec --`
      # cannot be told from `repro exec`). It is spawn mode, which this
      # standard input refuses, and no shell starts.
      let c = prepareCase("repro-shell-bare-separator")
      defer: removeDir(c.tempRoot)
      let shell = c.markerShell("bare-separator-shell")
      let res = c.runWithNullStdin(@["shell", c.projectRoot,
        "--shell=" & shell.script, "--"])
      checkpoint(res.stderr)
      check res.code == 2
      check res.seconds < 2.0
      check res.stdout.len == 0
      check res.stderr.contains("standard input is not a terminal")
      check not fileExists(shell.marker)

    test "two modes at once are a usage error":
      let c = prepareCase("repro-shell-conflicts")
      defer: removeDir(c.tempRoot)
      let shell = c.markerShell("conflict-shell")
      for args in [
          @["-c", "true", "--", "true"],
          @["--print-env=posix", "-c", "true"],
          @["--print-env=posix", "--", "true"],
          @["--shell=" & shell.script, "--", "true"]]:
        let res = c.runWithNullStdin(@["shell", c.projectRoot] & args)
        checkpoint(args.join(" ") & "\n" & res.stderr)
        check res.code == 2
        check res.seconds < 2.0
        check res.stdout.len == 0
        check res.stderr.contains("repro shell: error: ")
      check not fileExists(shell.marker)

    test "spawn mode with a terminal on stdin starts the shell":
      let c = prepareCase("repro-shell-tty")
      defer: removeDir(c.tempRoot)
      let shell = c.markerShell("tty-shell")
      let res = runWithTerminalStdin(c.reproBin,
        @["shell", c.projectRoot, "--shell=" & shell.script], c.repoRoot,
        c.tempRoot, c.envFor())
      checkpoint(res.stderr)
      check res.code == 0
      check fileExists(shell.marker)
      if fileExists(shell.marker):
        check readFile(shell.marker).strip() == "ran:dev::"
