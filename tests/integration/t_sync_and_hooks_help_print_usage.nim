## ``repro sync --help`` and ``repro hooks ensure --help`` print usage.
##
## Both used to be refused by their flag parsers ("unsupported `repro
## workspace sync` flag: --help", "unsupported hooks flag: --help") and exit
## non-zero. The CLI's convention is that an explicit help
## request prints to stdout and exits 0, so a script or an operator can ask
## any verb how to call it.
##
## ``repro help <command>`` answers every command ``repro --help`` lists,
## with help on stdout and exit 0, including the commands whose own parser
## does not know ``--help``. ``repro help`` must not hand such a parser a
## ``--help`` it would reject or, worse, take as an operand: ``repro allow
## --help`` trusts a directory named ``--help``, so a ``repro help allow``
## that forwarded the flag changed the trust store.
##
## No mocks: the real ``build/bin/repro`` is run as a subprocess, in an empty
## directory, so the help path is proven not to need a workspace. The check
## that help did NOT fall through to the verb itself is that nothing was
## written to that directory (and, for ``repro help``, to a fresh ``HOME``
## and XDG state directories).

import std/[macros, os, strutils, tempfiles, unittest]

import clispec/model
import repro_test_support

import repro_cli_support/cli_description

macro shownCommands(): untyped =
  ## The top-level commands ``repro --help`` lists, from the description.
  var words: seq[string] = @[]
  for cmd in reproCommandLineModel().commands:
    if not cmd.anonymous and cmd.path.len == 1 and
        cmd.visibility == cvShown:
      words.add(cmd.name)
  newLit(words)

const ShownCommands = shownCommands()

proc entriesUnder(dir: string): seq[string] =
  for entry in walkDirRec(dir, yieldFilter = {pcFile, pcDir, pcLinkToFile,
      pcLinkToDir}):
    result.add(entry)

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

suite "sync and hooks help":

  test "t_sync_and_hooks_help_print_usage":
    let repro = reproBinary()
    let empty = createTempDir("repro-help-", "")
    defer: removeDir(empty)
    for (argv, expected) in [
        (@["sync", "--help"], "usage: repro sync"),
        (@["sync", "-h"], "usage: repro sync"),
        (@["workspace", "sync", "--help"], "usage: repro sync"),
        (@["ws", "sync", "--help"], "usage: repro sync"),
        (@["hooks", "ensure", "--help"], "usage: repro hooks"),
        (@["hooks", "--help"], "usage: repro hooks")]:
      var cmd = @[repro]
      cmd.add(argv)
      cmd.add("--workspace-root=" & empty)
      let res = runShell(shellCommand(cmd))
      checkpoint(argv.join(" ") & " -> exit " & $res.code & "\n" & res.output)
      check res.code == 0
      check expected in res.output
      check "unsupported" notin res.output
    var leftovers: seq[string]
    for entry in walkDir(empty):
      leftovers.add(entry.path)
    check leftovers.len == 0

  test "t_help_command_answers_every_shown_command":
    let repro = reproBinary()
    check ShownCommands.len > 50
    check "allow" in ShownCommands
    let empty = createTempDir("repro-help-cwd-", "")
    let home = createTempDir("repro-help-home-", "")
    defer:
      removeDir(empty)
      removeDir(home)
    let env = @[("HOME", home), ("XDG_STATE_HOME", home / "state"),
      ("XDG_CONFIG_HOME", home / "config"), ("XDG_CACHE_HOME", home / "cache"),
      ("XDG_DATA_HOME", home / "data"), ("XDG_RUNTIME_DIR", home / "run")]
    var topics: seq[seq[string]] = @[]
    for word in ShownCommands:
      topics.add(@[word])
    # A deeper word of a command whose parser does not know `--help`.
    topics.add(@["allow", "somewhere"])
    for topic in topics:
      let res = runShell(shellCommand(@[repro, "help"] & topic, env),
        cwd = empty, timeoutMs = 60_000)
      checkpoint("repro help " & topic.join(" ") & " -> exit " & $res.code &
        "\n" & res.output)
      check res.code == 0
      check res.output.strip().len > 0
      # What `repro allow --help` and `repro deny --help` print: the
      # command ran, with `--help` as its directory.
      check "Allowed repro dev-env" notin res.output
      check "was not trusted" notin res.output
    check entriesUnder(empty).len == 0
    check entriesUnder(home).len == 0
