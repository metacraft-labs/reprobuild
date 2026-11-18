## repro's usage errors are clispec's error block, and its help pages and
## errors are styled for the stream they are written to.
##
## A command line repro's description rejects is reported as clispec renders
## a usage error: an `error:` line naming the command, a `tip:` with the
## similar spellings the command accepts when there are any, the usage line
## of the command the error is about and the command that prints its help,
## exit 2. The daemon worker sends the same block for a `repro build` line
## the thin client routed (`renderReproUsageError`, the plain rendering),
## and `t_thin_daemon_client` checks the routed bytes against the direct
## path's.
##
## Help and errors are printed by clispec's printers, which style a page on
## a terminal and leave it plain through a pipe, under `NO_COLOR` or with
## `TERM=dumb`; styling never changes the text, so the styled page with its
## escape sequences removed is the piped page. A completion reply and the
## JSON help are printed as they are, on a terminal too.
##
## The arms, and what makes each one evidence:
##
##   1. Errors through a pipe: `repro biuld` and `repro help biuld` suggest
##      `build`; `repro sync --jbos 3` suggests `--jobs`; `repro build
##      --dry-urn` suggests `--dry-run`; `repro build --jbos 3` is the same
##      block without a tip (`repro build` has no `--jobs`). Before, these
##      printed `repro: <message>` and a hint at `repro --help`, with no
##      suggestion and no usage line, so the arm can fail.
##   2. The text the daemon worker sends for a refused line
##      (`renderReproUsageError`) is byte for byte what the direct path
##      writes through a pipe.
##   3. A pseudo-terminal: `repro build --help` and `repro help build` on
##      a terminal carry SGR escapes around `Usage:` and equal the piped page
##      once they are removed; `NO_COLOR` and `TERM=dumb` suppress them; a
##      usage error on a terminal stderr is styled the same way. Before,
##      help was written as its plain text whatever the stream.
##   4. `repro --help=json` and a completion reply on a terminal carry no
##      escapes and equal their piped bytes.
##
## No mocks: the real `build/bin/repro` runs as a subprocess with a fresh
## HOME and XDG directories and a daemon endpoint nothing listens on; no
## command line here reaches a build. The terminal is a real pty
## (`repro_test_support/terminal_fixtures`); the child exits on its own and
## nothing here signals any process. `COLORFGBG` names a dark background so
## clispec does not query the terminal's background (it would query the
## controlling terminal of whoever runs the test).

import std/[os, osproc, posix, strtabs, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/terminal_fixtures

import repro_cli_support
import repro_cli_support/cli_program

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type
  Scratch = object
    cwd, home: string

  Run = object
    code: int
    stdout, stderr: string
    terminal: string
      ## What the program wrote to the pty, with the terminal's `\r\n`
      ## written back as `\n`.

proc newScratch(): Scratch =
  result.cwd = createTempDir("repro-cs-m6-errors-cwd-", "")
  result.home = createTempDir("repro-cs-m6-errors-home-", "")

proc dispose(s: Scratch) =
  removeDir(s.cwd)
  removeDir(s.home)

proc environment(s: Scratch; extra: openArray[(string, string)]):
    StringTableRef =
  ## A fixed environment: none of the caller's colour or width settings
  ## reach the run.
  result = newStringTable(modeCaseSensitive)
  result["PATH"] = getEnv("PATH")
  result["HOME"] = s.home
  result["XDG_STATE_HOME"] = s.home / "state"
  result["XDG_CONFIG_HOME"] = s.home / "config"
  result["XDG_CACHE_HOME"] = s.home / "cache"
  result["XDG_DATA_HOME"] = s.home / "data"
  result["XDG_RUNTIME_DIR"] = s.home / "run"
  result["REPRO_STORE_ROOT"] = s.home / "store"
  result["REPRO_DAEMON_ENDPOINT"] = s.home / "daemon" / "repro-daemon.sock"
  result["REPRO_DAEMON_STATE_DIR"] = s.home / "daemon-state"
  result["TERM"] = "xterm-256color"
  result["COLORFGBG"] = "15;0"
  for (name, value) in extra:
    result[name] = value

type Stream = enum
  onPipe, stdoutOnTerminal, stderrOnTerminal

proc run(s: Scratch; argv: openArray[string]; stream = onPipe;
         extra: openArray[(string, string)] = []): Run =
  ## Runs repro with stdout and stderr in files, or one of them on a fresh
  ## pty's slave side. The master is drained while the program runs (a pty
  ## is a small kernel buffer).
  let (master, slave) = openPtySlavePath()
  defer: discard close(master)
  let outPath = s.home / "run-stdout"
  let errPath = s.home / "run-stderr"
  let outTarget = if stream == stdoutOnTerminal: slave else: outPath
  let errTarget = if stream == stderrOnTerminal: slave else: errPath
  var shArgs = @["-c", "exec \"$0\" \"$@\" </dev/null >" &
    quoteShell(outTarget) & " 2>" & quoteShell(errTarget), reproBinary()]
  for arg in argv:
    shArgs.add(arg)
  let process = startProcess("/bin/sh", workingDir = s.cwd, args = shArgs,
    env = s.environment(extra), options = {})
  defer: process.close()
  let flags = fcntl(master, F_GETFL, 0)
  discard fcntl(master, F_SETFL, flags or O_NONBLOCK)
  var chunk = newString(8192)
  var drained = ""
  template pumpNow() =
    while true:
      let got = read(master, addr chunk[0], chunk.len)
      if got <= 0:
        break
      drained.add(chunk[0 ..< got])
  let deadline = 120_000
  var waited = 0
  while process.running and waited < deadline:
    pumpNow()
    sleep(2)
    waited += 2
  check waited < deadline
  pumpNow()
  result.code = process.peekExitCode()
  result.terminal = drained.replace("\r\n", "\n")
  result.stdout = if fileExists(outPath): readFile(outPath) else: ""
  result.stderr = if fileExists(errPath): readFile(errPath) else: ""
  removeFile(outPath)
  removeFile(errPath)
  checkpoint("repro " & argv.join(" ") & " (" & $stream & ") -> exit " &
    $result.code & "\nstdout:\n" & result.stdout & "\nstderr:\n" &
    result.stderr & "\nterminal:\n" & result.terminal.escape)

func withoutEscapes(text: string): string =
  ## ``text`` without its SGR sequences (``ESC [ <digits and ;> m``).
  var i = 0
  while i < text.len:
    if text[i] == '\e' and i + 1 < text.len and text[i + 1] == '[':
      var j = i + 2
      while j < text.len and text[j] in {'0' .. '9', ';'}:
        inc j
      if j < text.len and text[j] == 'm':
        i = j + 1
        continue
    result.add(text[i])
    inc i

func styledBefore(text, word: string): bool =
  ## Whether an SGR sequence directly precedes ``word`` in ``text``.
  let at = text.find(word)
  if at < 1 or text[at - 1] != 'm':
    return false
  var j = at - 2
  while j >= 0 and text[j] in {'0' .. '9', ';'}:
    dec j
  j >= 1 and text[j] == '[' and text[j - 1] == '\e'

suite "repro's usage errors and coloured help":

  test "usage errors are clispec's error block, with suggestions":
    let s = newScratch()
    defer: s.dispose()
    let cases: seq[(seq[string], string, string, string, string)] = @[
      (@["biuld"], "error: unknown subcommand 'biuld' for 'repro'",
        "  tip: a similar subcommand exists: 'build'", "Usage: repro ",
        "For more information, try 'repro --help'."),
      (@["help", "biuld"], "error: unknown subcommand 'biuld' for 'repro'",
        "  tip: a similar subcommand exists: 'build'", "Usage: repro ",
        "For more information, try 'repro --help'."),
      (@["sync", "--jbos", "3"], "error: unknown flag '--jbos' for 'repro sync'",
        "  tip: a similar flag exists: '--jobs'", "Usage: repro sync ",
        "For more information, try 'repro sync --help'."),
      (@["build", "--dry-urn"],
        "error: unknown flag '--dry-urn' for 'repro build'",
        "  tip: a similar flag exists: '--dry-run'", "Usage: repro build ",
        "For more information, try 'repro build --help'."),
      # `repro build` has no `--jobs`: the block, with no tip.
      (@["build", "--jbos", "3"],
        "error: unknown flag '--jbos' for 'repro build'", "",
        "Usage: repro build ",
        "For more information, try 'repro build --help'.")]
    for (argv, first, tip, usage, last) in cases:
      let res = s.run(argv)
      check res.code == 2
      check res.stdout == ""
      # The `error:` line (clispec's wording, which lists an unknown
      # subcommand's alternatives after the word), then a blank line.
      check res.stderr.startsWith(first)
      check res.stderr.find("\n") == res.stderr.find("\n\n")
      if tip.len > 0:
        check ("\n\n" & tip & "\n\n") in res.stderr
      else:
        check "tip:" notin res.stderr
      check ("\n\n" & usage) in res.stderr
      check res.stderr.endsWith("\n\n" & last & "\n")
      # Not repro's old text, and plain through a pipe.
      check "Run `repro --help`" notin res.stderr
      check not res.stderr.startsWith("repro: ")
      check '\e' notin res.stderr
    check not dirExists(s.home / "daemon")

  test "the daemon worker's text is the direct path's":
    let s = newScratch()
    defer: s.dispose()
    for argv in [@["--dry-urn"], @["--jbos", "3"], @["--daemon=maybe"]]:
      var rendered = ""
      try:
        discard loadBuildCommandLine(argv)
      except CliUsageError as e:
        rendered = renderReproUsageError(e)
      check rendered.len > 0
      let res = s.run(@["build"] & argv,
        extra = [("REPRO_DAEMON", ""), ("REPROBUILD_LOG", "")])
      check res.code == 2
      check res.stderr == rendered

  test "help is styled on a terminal and plain through a pipe":
    let s = newScratch()
    defer: s.dispose()
    for argv in [@["build", "--help"], @["build", "-h"], @["help", "build"],
        @["--help"], @["sync", "--help"]]:
      let piped = s.run(argv)
      check piped.code == 0
      check "Usage: repro" in piped.stdout
      check '\e' notin piped.stdout
      let styled = s.run(argv, stdoutOnTerminal)
      check styled.code == 0
      check '\e' in styled.terminal
      check styledBefore(styled.terminal, "Usage:")
      check withoutEscapes(styled.terminal) == piped.stdout
      for off in [@[("NO_COLOR", "1")], @[("TERM", "dumb")]]:
        let plain = s.run(argv, stdoutOnTerminal, off)
        check plain.code == 0
        check '\e' notin plain.terminal
        check plain.terminal == piped.stdout

  test "a usage error is styled on a terminal stderr":
    let s = newScratch()
    defer: s.dispose()
    for argv in [@["biuld"], @["build", "--dry-urn"]]:
      let piped = s.run(argv)
      let styled = s.run(argv, stderrOnTerminal)
      check styled.code == 2
      check styledBefore(styled.terminal, "error:")
      check styledBefore(styled.terminal, "Usage:")
      check withoutEscapes(styled.terminal) == piped.stderr
      let plain = s.run(argv, stderrOnTerminal, [("NO_COLOR", "1")])
      check plain.code == 2
      check plain.terminal == piped.stderr

  test "JSON help and completion replies are printed as they are":
    let s = newScratch()
    defer: s.dispose()
    for argv in [@["--help=json"], @["build", "--help=json"],
        @["__complete", "fish", "bu"]]:
      let piped = s.run(argv)
      check piped.code == 0
      check piped.stdout.len > 0
      let terminal = s.run(argv, stdoutOnTerminal)
      check terminal.code == 0
      check '\e' notin terminal.terminal
      check terminal.terminal == piped.stdout
