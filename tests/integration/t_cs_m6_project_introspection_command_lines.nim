## The project-introspection commands (`configs`, `tasks`, `graph`, `why`,
## `deps`, `stats`) take their command lines from repro's description: each
## answers `--help` (and `repro help <command>`) from its declarations, a
## command line the description does not accept is a usage error (exit 2)
## naming the command, and a command line it accepts reaches the command with
## the values it gave.
##
## The arms, and what makes each one evidence:
##
##   1. Help. Every command and subcommand of the group prints its generated
##      usage on stdout and exits 0, through all three routes (`<command>
##      --help`, `help <command>`, and `deps help`, the spelling `repro deps`
##      kept). Before this group moved, `repro graph --help` was an
##      "unsupported graph flag" error, so the arm can fail.
##   2. Usage errors. A value outside a declared set, an unknown flag, a
##      missing subcommand and a stray argument each exit 2 and name the
##      command; none of them reaches the command (nothing is written to the
##      scratch directory or the scratch HOME).
##   3. Values reach the command. `repro configs` reports the `buildType` that
##      `REPRO_VARIANTS` selects; `repro deps refresh --dry-run <dir>` scans
##      the directory it names; the checks the commands make on the parsed
##      values still run (`--project` together with a positional, `--lock`,
##      a missing `why` subject, `--action` with two positionals) and exit 1
##      with the command's own `error:` line.
##   4. A mistyped command word is an unknown command, and the error lists
##      the commands, rather than an "unexpected argument" of the root.
##
## No mocks: the real `build/bin/repro` runs as a subprocess, in an empty
## directory with a fresh HOME and XDG directories.

import std/[os, strutils, tempfiles, unittest]

import repro_test_support

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc entriesUnder(dir: string): seq[string] =
  for entry in walkDirRec(dir, yieldFilter = {pcFile, pcDir, pcLinkToFile,
      pcLinkToDir}):
    result.add(entry)

type Scratch = object
  cwd, home: string
  env: seq[(string, string)]

proc newScratch(): Scratch =
  result.cwd = createTempDir("repro-cs-m6-g2-cwd-", "")
  result.home = createTempDir("repro-cs-m6-g2-home-", "")
  let home = result.home
  result.env = @[("HOME", home), ("XDG_STATE_HOME", home / "state"),
    ("XDG_CONFIG_HOME", home / "config"), ("XDG_CACHE_HOME", home / "cache"),
    ("XDG_DATA_HOME", home / "data"), ("XDG_RUNTIME_DIR", home / "run"),
    ("REPRO_VARIANTS", "")]

proc dispose(s: Scratch) =
  removeDir(s.cwd)
  removeDir(s.home)

proc run(s: Scratch; argv: openArray[string];
         extraEnv: openArray[(string, string)] = []): tuple[code: int,
         output: string] =
  var env = s.env
  for (name, value) in extraEnv:
    for item in env.mitems:
      if item[0] == name:
        item[1] = value
  let res = runShell(shellCommand(@[reproBinary()] & @argv, env),
    cwd = s.cwd, timeoutMs = 60_000)
  checkpoint("repro " & argv.join(" ") & " -> exit " & $res.code & "\n" &
    res.output)
  (res.code, res.output)

suite "CS-M6: the project-introspection command lines":

  test "every command of the group answers help from its declarations":
    let s = newScratch()
    defer: s.dispose()
    for (argv, usage) in [
        (@["configs", "--help"], "Usage: repro configs"),
        (@["tasks", "--help"], "Usage: repro tasks"),
        (@["graph", "--help"], "Usage: repro graph"),
        (@["why", "-h"], "Usage: repro why"),
        (@["deps", "--help"], "Usage: repro deps"),
        (@["deps", "refresh", "--help"], "Usage: repro deps refresh"),
        (@["stats", "--help"], "Usage: repro stats"),
        (@["help", "graph"], "Usage: repro graph"),
        (@["help", "deps", "refresh"], "Usage: repro deps refresh"),
        (@["deps", "help"], "Usage: repro deps"),
        (@["deps", "help", "refresh"], "Usage: repro deps refresh")]:
      let res = s.run(argv)
      check res.code == 0
      check usage in res.output
      check "unsupported" notin res.output
    # The declarations' own words reach the help: a flag of the shared
    # graph-inspection group, a view and an internal flag that must not.
    check "--tool-provisioning" in s.run(["graph", "--help"]).output
    check "blast-radius" in s.run(["graph", "--help"]).output
    check "--activity" in s.run(["tasks", "--help"]).output
    check "--lock-slice" notin s.run(["tasks", "--help"]).output
    check entriesUnder(s.cwd).len == 0
    check entriesUnder(s.home).len == 0

  test "a command line the description does not accept is a usage error":
    let s = newScratch()
    defer: s.dispose()
    for (argv, names) in [
        (@["configs", "extra"], "'repro configs'"),
        (@["configs", "--release"], "'repro configs'"),
        (@["deps"], "'repro deps' needs a subcommand"),
        (@["deps", "show"], "unknown subcommand 'show' for 'repro deps'"),
        (@["deps", "refresh", "--force"], "'repro deps refresh'"),
        (@["deps", "refresh", "a", "b"], "'repro deps refresh'"),
        (@["stats", "--scope=everything"], "'repro stats'"),
        (@["stats", "gc"], "'repro stats'"),
        (@["stats", "--top=many"], "'repro stats'"),
        (@["graph", "--view=lock"], "'repro graph'"),
        (@["graph", "--tool-provisioning=brew"], "'repro graph'"),
        (@["graph", "a", "b", "c"], "'repro graph'"),
        (@["why", "--format"], "'repro why'"),
        (@["tasks", "--activity"], "'repro tasks'")]:
      let res = s.run(argv)
      check res.code == 2
      check names in res.output
    check entriesUnder(s.cwd).len == 0
    check entriesUnder(s.home).len == 0

  test "the values the description accepts reach the command":
    let s = newScratch()
    defer: s.dispose()
    let configs = s.run(["configs"])
    check configs.code == 0
    check "current buildType: debug" in configs.output
    let release = s.run(["configs"],
      [("REPRO_VARIANTS", "opt=1,buildType=release")])
    check release.code == 0
    check "current buildType: release" in release.output

    let workspace = s.cwd / "ws"
    createDir(workspace)
    let dry = s.run(["deps", "refresh", "--dry-run", workspace])
    check dry.code == 0
    check ("# DRY RUN — would write to " &
      (workspace / "repro.scanned-deps.nim")) in dry.output
    check not fileExists(workspace / "repro.scanned-deps.nim")
    let dryFlag = s.run(["deps", "refresh", "--dry-run",
      "--project=" & workspace])
    check dryFlag.code == 0
    check (workspace / "repro.scanned-deps.nim") in dryFlag.output

    for (argv, message) in [
        (@["deps", "refresh", "--project=" & workspace, workspace],
          "repro deps: error: give the workspace root once"),
        (@["graph", "--lock"], "repro graph: error: --lock is not " &
          "implemented yet"),
        (@["graph", "--infra"], "repro graph: error: --infra is not " &
          "implemented yet"),
        (@["why"], "repro why: error: missing why subject"),
        (@["why", "--action=a", "dir", "extra"],
          "repro why: error: unexpected why argument: extra")]:
      let res = s.run(argv)
      check res.code == 1
      check message in res.output
    check entriesUnder(s.home).len == 0

  test "a mistyped command word is an unknown command":
    let s = newScratch()
    defer: s.dispose()
    let res = s.run(["biuld"])
    check res.code == 2
    check "unknown subcommand 'biuld' for 'repro'" in res.output
    # The tip names the close command; the full list is the help's (the
    # `--help` hint), not the error line's.
    check "tip: a similar subcommand exists: 'build'" in res.output
    check "unexpected argument" notin res.output
    # A flag after the mistyped word does not hide it.
    let withFlag = s.run(["biuld", "--once"])
    check withFlag.code == 2
    check "unknown subcommand 'biuld' for 'repro'" in withFlag.output
