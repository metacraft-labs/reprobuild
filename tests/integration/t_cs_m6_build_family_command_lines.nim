## `repro build`, `repro bench`, `repro lint` and `repro clean` take their
## command lines from repro's description: each answers `--help` (and `repro
## help <command>`) from its declarations, a command line the description
## does not accept is a usage error (exit 2) naming the command, the build's
## own refusals keep their exit codes, and a command line the description
## accepts reaches the build with the values it gave, from the flag or from
## the environment variable the flag declares, the flag winning.
##
## `bench` and `lint` take `build`'s command line unchanged (one shared
## declaration): each is `repro build` of its conventional collection.
##
## The arms, and what makes each one evidence:
##
##   1. Help. Each command prints its generated usage on stdout and exits 0
##      through `--help`, `-h` and `help <command>`; `build`'s, `bench`'s and
##      `lint`'s list the shared flags, and `--evidence`'s help carries its
##      hazard (`t_da1i_evidence_help_names_the_hazard` checks the rows).
##      Before the four moved, their arguments were handed to their own
##      parsers unparsed, so the arm can fail.
##   2. Usage errors (exit 2, naming the command), each refused before the
##      build starts: an unknown flag, a `--daemon` value outside its set
##      (on the command line and in `$REPRO_DAEMON`), `--json` without
##      `--list-targets`, two rebuild verbs, `--stats-groups` without `=`, a
##      `--variant` without `=`, an invalid boolean in `--no-runquota=` and
##      `$REPROBUILD_NO_RUNQUOTA`, `--runquota=off` and `--release=false`
##      (switches that stand for another flag's value refuse `=false`);
##      `clean`'s unknown flag and stray word.
##   3. The build's own refusals, which keep their exit codes: `--only`
##      without a rebuild verb, an empty `--publish=`, two `--trust-profile`s,
##      an unknown `--strategy`; `clean` of a project root that does not
##      exist.
##   4. Values reach the build (in process, through the same generated
##      parser the engine, the internal callers and the daemon worker use),
##      with their origin: every flag-over-environment precedence of the
##      build in both orders (`--daemon`/`REPRO_DAEMON`, `--log` and `-v`,
##      `-vv`/`REPROBUILD_LOG`, `--progress`/`REPROBUILD_PROGRESS`/
##      `REPRO_PROGRESS`, `--measure`/`REPROBUILD_MEASURE`,
##      `--show`/`REPROBUILD_SHOW`, `--unicode`/`REPRO_UNICODE`,
##      `--no-runquota`, `--runquota`/`REPROBUILD_NO_RUNQUOTA`); a variable
##      set to the empty string counts as unset; the words after `--` reach
##      the action byte for byte; `--release`/`--debug` keep their place
##      among the `--variant`s; `bench`, `lint` and `clean` fill their own
##      configurations; the daemon parent's request readers find the target
##      and the work root the worker builds.
##
## No mocks: the real `build/bin/repro` runs as a subprocess, in an empty
## directory with a fresh HOME and XDG directories and a daemon endpoint
## nothing listens on, and arm 4 runs the generated parser in process. Every
## subprocess command line here is refused before a build starts or only
## prints help: no daemon is started and nothing is built or written.

import std/[options, os, strutils, tempfiles, unittest]

import repro_test_support

import repro_cli_support
import repro_cli_support/cli_program

proc repoRoot(): string =
  currentSourcePath().parentDir.parentDir.parentDir

proc reproBinary(): string =
  requireBinary(repoRoot() / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

type Scratch = object
  cwd, home: string
  env: seq[(string, string)]

proc newScratch(): Scratch =
  result.cwd = createTempDir("repro-build-cli-cwd-", "")
  result.home = createTempDir("repro-build-cli-home-", "")
  let home = result.home
  result.env = @[("HOME", home), ("XDG_STATE_HOME", home / "state"),
    ("XDG_CONFIG_HOME", home / "config"), ("XDG_CACHE_HOME", home / "cache"),
    ("XDG_DATA_HOME", home / "data"), ("XDG_RUNTIME_DIR", home / "run"),
    ("REPRO_STORE_ROOT", home / "store"),
    # Nothing listens here, and no command line below gets far enough to
    # look: a build that did would show up as this directory.
    ("REPRO_DAEMON_ENDPOINT", home / "daemon" / "repro-daemon.sock"),
    ("REPRO_DAEMON_STATE_DIR", home / "daemon-state"),
    # The calling shell's build defaults must not reach these lines.
    ("REPRO_DAEMON", ""), ("REPROBUILD_PROGRESS", ""), ("REPRO_PROGRESS", ""),
    ("REPROBUILD_LOG", ""), ("REPROBUILD_MEASURE", ""),
    ("REPROBUILD_SHOW", ""), ("REPRO_UNICODE", ""),
    ("REPROBUILD_NO_RUNQUOTA", ""), ("REPRO_VARIANTS", ""),
    ("REPRO_WORKSPACE_CONFIG", ""), ("REPRO_DEFAULT_PROJECTS", "")]

proc dispose(s: Scratch) =
  removeDir(s.cwd)
  removeDir(s.home)

proc run(s: Scratch; argv: openArray[string];
         extraEnv: openArray[(string, string)] = []): tuple[code: int,
         output: string] =
  let res = runShell(shellCommand(@[reproBinary()] & @argv,
    s.env & @extraEnv), cwd = s.cwd, timeoutMs = 120_000)
  checkpoint("repro " & argv.join(" ") & " -> exit " & $res.code & "\n" &
    res.output)
  (res.code, res.output)

proc runStdout(s: Scratch; argv: openArray[string]): tuple[code: int,
               stdout: string] =
  ## Like ``run``, with stdout alone: `sh` discards the command's stderr.
  let res = runShell(shellCommand(@["sh", "-c", "\"$@\" 2>/dev/null", "sh",
    reproBinary()] & @argv, s.env), cwd = s.cwd, timeoutMs = 120_000)
  checkpoint("repro " & argv.join(" ") & " -> exit " & $res.code &
    "; stdout:\n" & res.output)
  (res.code, res.output)

const
  NoEnv: seq[(string, string)] = @[]
  NoArgs: seq[string] = @[]

const BuildEnv = ["REPRO_DAEMON", "REPROBUILD_PROGRESS", "REPRO_PROGRESS",
  "REPROBUILD_LOG", "REPROBUILD_MEASURE", "REPROBUILD_SHOW", "REPRO_UNICODE",
  "REPROBUILD_NO_RUNQUOTA"]

template withBuildEnv(assignments: openArray[(string, string)];
                      body: untyped) =
  ## ``body`` with exactly ``assignments`` among the build's variables, the
  ## process environment restored afterwards.
  block:
    var saved: seq[(string, bool, string)]
    for name in BuildEnv:
      saved.add((name, existsEnv(name), getEnv(name)))
      delEnv(name)
    try:
      for (name, value) in assignments:
        putEnv(name, value)
      body
    finally:
      for (name, present, value) in saved:
        if present: putEnv(name, value) else: delEnv(name)

var parsedCommand: ReproCommandLine

proc parsed(argv: openArray[string]): int =
  ## ``argv`` through the generated parser, in process; the configuration
  ## it selects is left in ``parsedCommand``.
  parsedCommand = ReproCommandLine()
  runReproArgs(argv, proc (conf: ReproCommandLine): int =
    parsedCommand = conf
    0)

const SharedFlags = ["--daemon", "--tool-provisioning", "--target",
  "--variant", "--release", "--debug", "--work-root", "--action-cache-root",
  "--lock", "--strategy", "--print-solved-graph", "--list-targets",
  "--list-targets-json", "--json", "--package", "--progress",
  "--progress-bars", "--[no-]unicode", "--log", "--verbose",
  "-vv", "--very-verbose", "--action-output", "--measure", "--show",
  "--write-report", "--no-write-report", "--write-diagnostics",
  "--write-benchmark", "--write-stats", "--stats-groups", "--prepare-only",
  "--dry-run", "--force-rebuild", "--rebuild", "--soft-rebuild",
  "--rebuild-host-bound", "--hard-rebuild", "--only",
  "--unsafe-preserve-outputs", "--no-output-cleanup", "--publish-cache-hits",
  "--publish-materialized", "--skip-cmake-regeneration",
  "--[no-]restore-cached-outputs",
  "--no-runquota", "--runquota", "--monitor-hosting", "--evidence",
  "--peer-cache", "--trust-profile", "--publish"]

suite "the build family's command lines":

  test "each command answers help from its declarations":
    let s = newScratch()
    defer: s.dispose()
    for verb in ["build", "bench", "lint", "clean"]:
      let usage = "Usage: repro " & verb
      for argv in [@[verb, "--help"], @[verb, "-h"], @["help", verb]]:
        let res = s.runStdout(argv)
        check res.code == 0
        check usage in res.stdout
    for verb in ["build", "bench", "lint"]:
      let help = s.runStdout([verb, "--help"]).stdout
      for flag in SharedFlags:
        checkpoint(verb & " help lists " & flag)
        check flag in help
      check "REPRO_DAEMON" in help
    let cleanHelp = s.runStdout(["clean", "--help"]).stdout
    for flag in ["--project-root", "--work-root", "--dry-run"]:
      check flag in cleanHelp
    # `--help` wins over the words around it, and asks no daemon.
    check s.run(["build", ".", "--dry-run", "--help"]).code == 0
    check not dirExists(s.home / "daemon")

  test "a command line the description does not accept is a usage error":
    let s = newScratch()
    defer: s.dispose()
    let cases: seq[(seq[string], seq[(string, string)], string)] = @[
      (@["build", "--bogus"], @[], "--bogus"),
      (@["build", "--daemon=maybe"], @[], "--daemon"),
      (@["build", "."], @[("REPRO_DAEMON", "maybe")], "REPRO_DAEMON"),
      (@["build", "--json"], @[], "--json"),
      (@["build", "--soft-rebuild", "--hard-rebuild"], @[],
        "mutually exclusive"),
      (@["build", "--stats-groups", "timing"], @[], "--stats-groups"),
      (@["build", "--variant", "novalue"], @[], "--variant"),
      (@["build", "--no-runquota=perhaps"], @[], "--no-runquota"),
      # A switch that stands for another flag's value sets nothing as
      # `=false`, so it is refused rather than ignored.
      (@["build", "--runquota=off"], @[], "--runquota"),
      (@["build", "--release=false"], @[], "--release"),
      (@["build", "."], @[("REPROBUILD_NO_RUNQUOTA", "perhaps")],
        "REPROBUILD_NO_RUNQUOTA"),
      (@["bench", "--bogus"], @[], "--bogus"),
      (@["lint", "--daemon=maybe"], @[], "--daemon"),
      (@["clean", "--bogus"], @[], "--bogus"),
      (@["clean", "stray"], @[], "stray")]
    for (argv, env, needle) in cases:
      let res = s.run(argv, env)
      check res.code == 2
      check needle in res.output
      check ("repro " & argv[0]) in res.output or "'" & argv[0] & "'" in
        res.output
    check not dirExists(s.home / "daemon")

  test "the build's own refusals keep their exit codes":
    let s = newScratch()
    defer: s.dispose()
    let cases: seq[(seq[string], int, string)] = @[
      (@["build", "--only=x"], 2, "--only scopes a rebuild verb"),
      (@["build", "--publish="], 2, "--publish= names no edge"),
      (@["build", "--trust-profile=trusted", "--trust-profile=hardened"], 2,
        "--trust-profile given more than once"),
      (@["build", "--strategy=sideways"], 2, "unknown --strategy"),
      (@["clean", "--project-root=" & s.cwd / "absent"], 2,
        "project root does not exist")]
    for (argv, code, needle) in cases:
      let res = s.run(argv)
      check res.code == code
      check needle in res.output
    check not dirExists(s.home / "daemon")
    # `clean` of a project with no build state removes nothing, exit 0.
    let clean = s.run(["clean", "--project-root=" & s.cwd, "--dry-run"])
    check clean.code == 0
    check "would remove 0 output(s)" in clean.output

  test "--daemon over REPRO_DAEMON, in both orders":
    withBuildEnv(NoEnv):
      let (c, o) = loadBuildCommandLine(["."])
      check c.daemon == ""
      check o.daemon.winner.kind notin {cokCli, cokEnv}
    withBuildEnv([("REPRO_DAEMON", "off")]):
      let (c, o) = loadBuildCommandLine(["."])
      check c.daemon == "off"
      check o.daemon.winner.kind == cokEnv
      let (f, fo) = loadBuildCommandLine(["--daemon=require", "."])
      check f.daemon == "require"
      check fo.daemon.winner.kind == cokCli
    withBuildEnv([("REPRO_DAEMON", "require")]):
      check loadBuildCommandLine(["--daemon", "off"]).conf.daemon == "off"
      check loadBuildCommandLine(["."]).conf.daemon == "require"
    # Set to the empty string, the variable counts as unset (it is not an
    # invalid value).
    withBuildEnv([("REPRO_DAEMON", "")]):
      check loadBuildCommandLine(["."]).conf.daemon == ""

  test "--log, -v and -vv over REPROBUILD_LOG, in both orders":
    withBuildEnv([("REPROBUILD_LOG", "summary")]):
      let (c, o) = loadBuildCommandLine(NoArgs)
      check c.log == "summary"
      check o.log.winner.kind == cokEnv
      check loadBuildCommandLine(["--log=quiet"]).conf.log == "quiet"
      # `-vv` is `--log=actions`; the last of them on the command line wins.
      let (v, vo) = loadBuildCommandLine(["-vv"])
      check v.log == "actions"
      check vo.log.winner.kind == cokCli
    withBuildEnv([("REPROBUILD_LOG", "actions")]):
      check loadBuildCommandLine(["-v"]).conf.log == "summary"
      check loadBuildCommandLine(["--log=quiet", "-v"]).conf.log == "summary"
      check loadBuildCommandLine(["-v", "--log=quiet"]).conf.log == "quiet"
      check loadBuildCommandLine(["--very-verbose", "--verbose"]).conf.log ==
        "summary"

  test "--progress over REPROBUILD_PROGRESS, then REPRO_PROGRESS":
    withBuildEnv([("REPRO_PROGRESS", "dots")]):
      check loadBuildCommandLine(NoArgs).conf.progress == "dots"
      check loadBuildCommandLine(["--progress=quiet"]).conf.progress ==
        "quiet"
    withBuildEnv([("REPROBUILD_PROGRESS", "lines"),
        ("REPRO_PROGRESS", "dots")]):
      check loadBuildCommandLine(NoArgs).conf.progress == "lines"
      check loadBuildCommandLine(["--progress", "quiet"]).conf.progress ==
        "quiet"
    # The empty first variable counts as unset, so the second one applies.
    withBuildEnv([("REPROBUILD_PROGRESS", ""), ("REPRO_PROGRESS", "dots")]):
      check loadBuildCommandLine(NoArgs).conf.progress == "dots"

  test "--measure and --show over their variables, with their origin":
    withBuildEnv([("REPROBUILD_MEASURE", "timing"),
        ("REPROBUILD_SHOW", "trace")]):
      let (c, o) = loadBuildCommandLine(NoArgs)
      check c.measure == @["timing"]
      check o.measure.winner.kind == cokEnv
      check c.show == @["trace"]
      check o.show.winner.kind == cokEnv
      # The flag replaces the variable; its occurrences add up.
      let (f, fo) = loadBuildCommandLine(["--measure=none",
        "--measure=cache-evidence", "--show=timing"])
      check f.measure == @["none", "cache-evidence"]
      check fo.measure.winner.kind == cokCli
      check f.show == @["timing"]
      check fo.show.winner.kind == cokCli

  test "--unicode and --runquota over their variables, in both orders":
    withBuildEnv([("REPRO_UNICODE", "1"), ("REPROBUILD_NO_RUNQUOTA", "yes")]):
      let (c, o) = loadBuildCommandLine(NoArgs)
      check c.unicode
      check o.unicode.winner.kind == cokEnv
      check c.noRunquota
      check o.noRunquota.winner.kind == cokEnv
      let (f, fo) = loadBuildCommandLine(["--no-unicode", "--runquota"])
      check not f.unicode
      check fo.unicode.winner.kind == cokCli
      # `--runquota` is a request on the command line, which the build reads
      # as one (a dry run's implied bypass does not override it).
      check not f.noRunquota
      check fo.noRunquota.winner.kind == cokCli
    withBuildEnv([("REPRO_UNICODE", "off")]):
      check loadBuildCommandLine(["--unicode"]).conf.unicode
      check not loadBuildCommandLine(NoArgs).conf.unicode
      # The last of `--runquota` and `--no-runquota` wins.
      check loadBuildCommandLine(["--runquota", "--no-runquota"]).conf.
        noRunquota
      check not loadBuildCommandLine(["--no-runquota", "--runquota"]).conf.
        noRunquota

  test "the words after -- reach the action byte for byte":
    withBuildEnv(NoEnv):
      let words = @["--weird", "--", "-v", "a b", "", "--daemon=off", "\t"]
      let (c, _) = loadBuildCommandLine(@[".#run", "--dry-run", "--"] & words)
      check c.selectors == @[".#run"]
      check c.dryRun
      check c.actionArgs == words
      check c.daemon == ""
      # A bare trailing `--` forwards nothing.
      check loadBuildCommandLine([".", "--"]).conf.actionArgs.len == 0

  test "--release and --debug keep their place among the --variants":
    withBuildEnv(NoEnv):
      let (c, _) = loadBuildCommandLine(["--variant", "a=1", "--release",
        "--variant=b=2", "--debug"])
      check c.variant == @["a=1", "buildType=release", "b=2",
        "buildType=debug"]
      check loadBuildCommandLine(["--rebuild"]).conf.forceRebuild
      let (w, _) = loadBuildCommandLine(["--write-stats", "--write-report"])
      check w.writeStats == some("")
      check w.writeReport == some("")
      check loadBuildCommandLine(["--write-stats=s.db"]).conf.writeStats ==
        some("s.db")
      check loadBuildCommandLine(["--stats-groups=timing"]).conf.statsGroups ==
        some("timing")

  test "bench, lint and clean fill their own configurations":
    withBuildEnv([("REPRO_DAEMON", "off")]):
      check parsed(["bench", "--dry-run", "suite", "--", "--quick"]) == 0
      check parsedCommand.command == ReproCommandLineCommand.bench
      check parsedCommand.bench.dryRun
      check parsedCommand.bench.selectors == @["suite"]
      check parsedCommand.bench.actionArgs == @["--quick"]
      check parsedCommand.bench.daemon == "off"
      check parsed(["lint", "-vv", "--only=x", "--soft-rebuild"]) == 0
      check parsedCommand.command == ReproCommandLineCommand.lint
      check parsedCommand.lint.veryVerbose
      check parsedCommand.lint.only == @["x"]
      check parsed(["clean", "--project-root", "p", "--work-root=w",
        "--dry-run"]) == 0
      check parsedCommand.command == ReproCommandLineCommand.clean
      check parsedCommand.clean.projectRoot == "p"
      check parsedCommand.clean.workRoot == "w"
      check parsedCommand.clean.dryRun
    # What the dispatcher hands a build verb: the words after the verb.
    check reproWordsAfterCommand(["build", "--daemon", "off", "x"]) ==
      @["--daemon", "off", "x"]
    check reproWordsAfterCommand(["lint", "--", "build"]) == @["--", "build"]

  test "the daemon parent reads the request the worker builds":
    # The daemon's own environment belongs to no request, so the readers
    # ignore it: an invalid `$REPRO_DAEMON` there changes nothing.
    withBuildEnv([("REPRO_DAEMON", "maybe")]):
      let project = createTempDir("repro-build-cli-request-", "")
      defer: removeDir(project)
      writeFile(project / "repro.nim", "")
      let other = createTempDir("repro-build-cli-other-", "")
      defer: removeDir(other)
      # The first positional is the target, whatever flag values precede it
      # (`--work-root`'s and `--daemon`'s are not targets).
      check daemonRequestProjectRoot(["--work-root", other, "--daemon",
        "off", project], other) == project
      check daemonRequestProjectRoot(["."], project) == project
      # A word after `--` is the action's, not a target.
      check daemonRequestProjectRoot(["--", project], other) == ""
      # A command line `repro build` does not accept names no project.
      check daemonRequestProjectRoot(["--bogus", project], other) == ""
      # A forced rebuild, in either spelling, and a dry run warm nothing.
      for flag in ["--force-rebuild", "--rebuild", "--dry-run"]:
        check daemonPrewarmTargetOutputDir([flag, project], other, NoArgs) == ""
      let warmed = daemonPrewarmTargetOutputDir([project], other, NoArgs)
      check warmed.len > 0
      check daemonPrewarmTargetOutputDir(["--work-root=" & other / "w",
        project], other, NoArgs) != warmed
