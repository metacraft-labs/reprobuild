## `repro --help` is a short, grouped page of the daily commands, and
## `repro --help-all` lists every command under the same headings.
##
## The root has dozens of commands. `repro --help`, `repro -h` and `repro
## help` list only the daily ones (the `primary` tier), under four domain
## headings, and end with the line that names `repro --help-all` and how
## many commands it lists. `repro --help-all` and `repro help --all` list
## every shown command (both tiers) under the same headings. The
## machine-readable help (`--help=json`) carries each command's group and
## tier, and shell completion offers both tiers alike.
##
## What is checked, against the real built `repro`:
##
## * the short page, by all three spellings: at most 45 lines; the four
##   headings, in order, each listing exactly its daily commands in order;
##   no `Commands:` section (every shown command has a group); and the
##   closing line, whose count is the number of shown commands;
## * the long page, by both spellings, which print the same bytes: the same
##   four headings listing every shown command, and no hidden or internal
##   one;
## * `--help=json`: a `group` and a `tier` on every shown command, agreeing
##   with the pages;
## * `__complete`: a daily command, a command only `--help-all` lists, and
##   every shown command for an empty word.
##
## The set of shown commands the pages are compared with comes from
## `--help=json`, not from the pages, and is cross-checked with the
## description's own table (`ReproCommandGroups`). The daily commands per
## heading are written out below, as the requirement states them, so a
## change to the table that drops or moves one fails here.
##
## No mocks: every page and answer comes from `build/bin/repro` run as a
## subprocess in an empty directory with a fresh `HOME`.

import std/[json, os, sequtils, sets, strutils, tempfiles, unittest]

import repro_test_support

import repro_cli_support/cli_description

const
  DailyCommands = [
    ("Build & Test", @["build", "test", "watch", "clean"]),
    ("Environments & Services",
      @["shell", "exec", "up", "down", "run", "tasks"]),
    ("Dependencies & Workspaces",
      @["develop", "add", "why", "lock", "workspace"]),
    ("Machines & Diagnostics", @["home", "system", "infra", "health"])]
    ## The headings of `repro --help`, in order, and the commands each
    ## lists, in order.
  MaxShortPageLines = 45

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type Scratch = object
  cwd, home: string
  env: seq[(string, string)]

proc newScratch(): Scratch =
  result.cwd = createTempDir("repro-root-help-cwd-", "")
  result.home = createTempDir("repro-root-help-home-", "")
  let home = result.home
  result.env = @[("HOME", home), ("XDG_STATE_HOME", home / "state"),
    ("XDG_CONFIG_HOME", home / "config"), ("XDG_CACHE_HOME", home / "cache"),
    ("XDG_DATA_HOME", home / "data"), ("XDG_RUNTIME_DIR", home / "run"),
    # The page width is clispec's default, not the calling terminal's.
    ("COLUMNS", "")]

proc dispose(s: Scratch) =
  removeDir(s.cwd)
  removeDir(s.home)

proc runStdout(s: Scratch; argv: openArray[string]): string =
  ## `repro <argv>`'s stdout (`sh` discards its stderr); it must exit 0.
  let res = runShell(shellCommand(@["sh", "-c", "\"$@\" 2>/dev/null", "sh",
    reproBinary()] & @argv, s.env), cwd = s.cwd, timeoutMs = 120_000)
  checkpoint("repro " & argv.join(" ") & " -> exit " & $res.code &
    "; stdout:\n" & res.output)
  check res.code == 0
  res.output

type Section = tuple[heading: string, commands: seq[string]]

proc sectionsOf(page: string): seq[Section] =
  ## The page's sections: each unindented line ending in `:` opens one, and
  ## each line indented by exactly two spaces is a row whose first word
  ## (without the comma before an alias) is the command. A heading's own
  ## help and a wrapped row's continuation are indented further.
  for line in page.splitLines():
    if line.len > 0 and line[0] != ' ' and line.endsWith(":"):
      result.add((line[0 ..< ^1], newSeq[string]()))
    elif result.len > 0 and line.startsWith("  ") and line.len > 2 and
        line[2] != ' ':
      result[^1].commands.add(line.strip().splitWhitespace()[0].strip(
        leading = false, chars = {','}))

proc commandSections(page: string): seq[Section] =
  ## The sections that list commands: every section but `Options:` (the
  ## root's `--version` and `--help`).
  sectionsOf(page).filterIt(it.heading != "Options")

proc lastSentence(page: string): string =
  ## The page's closing paragraph, its wrapped lines joined.
  let paragraphs = page.strip().split("\n\n")
  paragraphs[^1].splitWhitespace().join(" ")

proc shownCommandsOf(helpJson: JsonNode): seq[JsonNode] =
  for cmd in helpJson["command"]["commands"]:
    if cmd["visibility"].getStr() == "shown":
      result.add(cmd)

suite "repro --help is grouped and tiered; --help-all lists every command":

  test "t_root_help_tiered_and_help_all_complete":
    let s = newScratch()
    defer: s.dispose()

    # The shown commands, from the machine-readable help.
    let helpJson = parseJson(s.runStdout(["--help=json"]))
    let shown = shownCommandsOf(helpJson)
    let shownNames = shown.mapIt(it["name"].getStr())
    check shownNames.len > 40
    check shownNames.toHashSet().len == shownNames.len

    # The description's table accounts for exactly those commands, and its
    # daily commands are the required ones.
    var tableNames: seq[string] = @[]
    check ReproCommandGroups.len == DailyCommands.len
    for i, group in ReproCommandGroups:
      check group.title == DailyCommands[i][0]
      check group.primary == DailyCommands[i][1]
      tableNames.add(group.primary & group.secondary)
    check tableNames.toHashSet() == shownNames.toHashSet()
    check tableNames.len == shownNames.len

    # Every shown command carries its group and tier; the primary ones are
    # exactly the daily commands.
    var dailyNames: seq[string] = @[]
    for daily in DailyCommands:
      dailyNames.add(daily[1])
    for cmd in shown:
      let name = cmd["name"].getStr()
      checkpoint("--help=json: " & name)
      check cmd.hasKey("group") and cmd["group"].kind == JString
      check cmd.hasKey("tier")
      let tier = cmd["tier"].getStr()
      check tier == (if name in dailyNames: "primary" else: "secondary")
      for group in ReproCommandGroups:
        if name in group.primary or name in group.secondary:
          check cmd["group"].getStr() == group.title

    # The short page, by each of its spellings.
    let footer = "Run 'repro --help-all' to list all " & $shownNames.len &
      " commands, or 'repro <command> --help' for details."
    for argv in [@["--help"], @["-h"], @["help"]]:
      let page = s.runStdout(argv)
      checkpoint("repro " & argv.join(" ") & ":\n" & page)
      check page.strip().splitLines().len <= MaxShortPageLines
      let sections = commandSections(page)
      check sections.len == DailyCommands.len
      for i, daily in DailyCommands:
        if i < sections.len:
          check sections[i].heading == daily[0]
          check sections[i].commands == daily[1]
      check lastSentence(page) == footer

    # The long page, by both of its spellings: every shown command, under
    # the same headings, and nothing that is not shown.
    let all = s.runStdout(["--help-all"])
    check s.runStdout(["help", "--all"]) == all
    # The JSON form of the long page is the same document as `--help=json`
    # (both list both tiers), and `help --all <command>` asks for that
    # command's long page.
    check s.runStdout(["--help-all=json"]) == s.runStdout(["--help=json"])
    check s.runStdout(["help", "--all", "workspace", "sync"]) ==
      s.runStdout(["workspace", "sync", "--help-all"])
    let allSections = commandSections(all)
    check allSections.mapIt(it.heading) == DailyCommands.mapIt(it[0])
    var listed: seq[string] = @[]
    for i, section in allSections:
      if i < DailyCommands.len:
        # The daily commands first, in their order.
        check section.commands[0 ..< DailyCommands[i][1].len] ==
          DailyCommands[i][1]
      listed.add(section.commands)
    check listed.len == shownNames.len
    check listed.toHashSet() == shownNames.toHashSet()
    for word in ["internal", "__repro-runquota-helper", "__remote-activate"]:
      check word notin listed
    check lastSentence(all) ==
      "Run 'repro <command> --help' for more on a command."

    # Completion offers both tiers alike.
    proc candidates(word: string): seq[string] =
      for line in s.runStdout(["__complete", "fish", word]).splitLines():
        if line.len > 0:
          result.add(line.split('\t')[0])
    check "build" in candidates("bu")
    check "bench" in candidates("ben")
    check "bench" notin dailyNames
    let everything = candidates("").toHashSet()
    for name in shownNames:
      checkpoint("__complete offers " & name)
      check name in everything

    check toSeq(walkDirRec(s.cwd)).len == 0
