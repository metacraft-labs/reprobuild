## The build family takes its command lines from repro's description:
## `repro build`, `repro bench`, `repro lint`, `repro clean`, `repro test`,
## `repro certify`, `repro certificates`, `repro ci` and `repro watch`. Each
## answers `--help` (and `repro help <command>`) from its declarations, a
## command line the description does not accept is a usage error (exit 2)
## naming the command, the commands' own refusals keep their exit codes, and
## a command line the description accepts reaches the command with the
## values it gave, from the flag or from the environment variable the flag
## declares, the flag winning.
##
## `bench` and `lint` take `build`'s command line unchanged (one shared
## declaration): each is `repro build` of its conventional collection.
## `repro test` (and `repro certify`, which takes its command line) adds its
## own flags to `build`'s and hands the build exactly the build flags it was
## given (confutils' generated `argvOf`, which writes them back from their
## origins). `repro watch` declares the build flags a watch
## cycle takes with the same declarations as `build`.
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
##   5. The rest of the group (arms 1, 2 and 4 again): `test`, `certify`,
##      `certificates` with `list`, `plan`, `policy`, `ci plan` and `watch`
##      print generated help; their refusals are usage errors (exit 2,
##      `repro ci`'s and `repro certificates`' included, which were 1 and
##      stderr-only before); `watch`'s `--daemon`/`REPRO_DAEMON`,
##      `--tool-provisioning`/`REPRO_TOOL_PROVISIONING`, `--measure`,
##      `--show` and `--[no-]restore-cached-outputs` over their variables,
##      `ci plan --branch` over `GITHUB_BASE_REF` then `GITHUB_REF_NAME`, and
##      `certificates list|plan --no-runquota` over `REPROBUILD_NO_RUNQUOTA`,
##      each in both orders; `repro test` hands its build exactly the build
##      flags given on its command line, which the build parses back to the
##      same values, and the words after `--`; what the run evaluates itself
##      sees its variant assignments in `$REPRO_VARIANTS` after the caller's,
##      and each build it runs starts from the caller's value, so a second
##      build in one run does not add them twice. `--release` and `-v` reach
##      the build as themselves and build exactly what their values
##      (`--variant=buildType=release`, `--log=summary`) build, sharded or
##      not.
##   6. `--work-root` over `REPROBUILD_WORK_ROOT` and `--action-cache-root`
##      over `REPROBUILD_ACTION_CACHE_ROOT`, in both orders, on every command
##      that declares them (`build`, `bench`, `lint`, `test`, `certify`,
##      `watch`, `clean`, `graph`, `why`, `stats`, `store
##      closure|export|import`, `bundle create|restore`); a variable set to
##      the empty string counts as unset, and what a variable gave is not
##      handed to `repro test`'s build.
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
    ("REPRO_TOOL_PROVISIONING", ""), ("REPRO_RESTORE_CACHED_OUTPUTS", ""),
    ("REPROBUILD_WORK_ROOT", ""), ("REPROBUILD_ACTION_CACHE_ROOT", ""),
    ("GITHUB_BASE_REF", ""), ("GITHUB_REF_NAME", ""),
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
  "REPROBUILD_NO_RUNQUOTA", "REPRO_TOOL_PROVISIONING",
  "REPRO_RESTORE_CACHED_OUTPUTS", "GITHUB_BASE_REF", "GITHUB_REF_NAME",
  "REPROBUILD_WORK_ROOT", "REPROBUILD_ACTION_CACHE_ROOT"]

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

  test "test, certify, certificates, ci and watch answer help from their declarations":
    let s = newScratch()
    defer: s.dispose()
    for path in [@["test"], @["certify"], @["certificates"],
        @["certificates", "list"], @["certificates", "plan"],
        @["certificates", "policy"], @["ci"], @["ci", "plan"], @["watch"]]:
      let usage = "Usage: repro " & path.join(" ")
      for argv in [path & @["--help"], path & @["-h"], @["help"] & path]:
        let res = s.runStdout(argv)
        check res.code == 0
        check usage in res.stdout
    # `repro certificates help` is the namespace's help, on stdout.
    let namespaceHelp = s.runStdout(["certificates", "help"])
    check namespaceHelp.code == 0
    check "Usage: repro certificates" in namespaceHelp.stdout
    # `repro test` and `repro certify` take `repro build`'s flags with their
    # own.
    for verb in ["test", "certify"]:
      let help = s.runStdout([verb, "--help"]).stdout
      for flag in @SharedFlags & @["--shard", "--partition-strategy",
          "--emit-partition-plan", "--plan-from", "--fixture-from",
          "--bin-dir", "--[no-]certify", "--certificate-out",
          "--workspace-root", "--current-repo", "--ct-incremental-trace-dir",
          "--allow-pin-regression"]:
        checkpoint(verb & " help lists " & flag)
        check flag in help
    let certifyHelp = s.runStdout(["certify", "--help"]).stdout
    for flag in ["--verify", "--content", "--registered-keys",
        "--workspace", "--check-set", "--check-set-command"]:
      check flag in certifyHelp
    let watchHelp = s.runStdout(["watch", "--help"]).stdout
    for flag in ["--daemon", "--tool-provisioning", "--work-root",
        "--max-cycles", "--debounce-ms", "--detach", "--attach", "--stop",
        "--measure", "--show", "--write-report", "--no-write-report",
        "--write-stats", "--stats-groups", "--[no-]restore-cached-outputs",
        "--hcr", "--hcr-mode", "--hcr-debug", "--hcr-agent-socket",
        "--hcr-artifacts", "--hcr-metadata", "--hcr-target",
        "--ct-incremental", "--ct-incremental-trace-dir", "REPRO_DAEMON"]:
      checkpoint("watch help lists " & flag)
      check flag in watchHelp
    check "GITHUB_BASE_REF" in s.runStdout(["ci", "plan", "--help"]).stdout
    check not dirExists(s.home / "daemon")

  test "their refusals are usage errors, before anything runs":
    let s = newScratch()
    defer: s.dispose()
    let certificate = s.cwd / "cert.toml"
    let cases: seq[(seq[string], seq[(string, string)], string)] = @[
      (@["test", "--bogus"], @[], "--bogus"),
      (@["test", "--daemon=maybe"], @[], "--daemon"),
      (@["test", "."], @[("REPRO_DAEMON", "maybe")], "REPRO_DAEMON"),
      (@["test", "--partition-strategy=zigzag"], @[], "--partition-strategy"),
      (@["test", "--shard=half"], @[], "invalid --shard value"),
      (@["test", "--variant=novalue"], @[], "--variant expects name=value"),
      (@["test", "--allow-pin-regression=*"], @[], "--allow-pin-regression"),
      (@["certify", "--bogus"], @[], "--bogus"),
      (@["certify", "--content=git-tree-sha1:00"], @[],
        "--content applies to --verify only"),
      (@["certify", "--check-set-command=true"], @[],
        "--check-set-command applies to --check-set only"),
      (@["certify", "--verify", certificate, "--content=x", "--json"], @[],
        "unknown option --json"),
      (@["certify", "--verify", certificate, "other.toml", "--content=x"],
        @[], "one certificate at a time"),
      (@["certify", "--verify", certificate], @[], "--content is required"),
      (@["certify", "--check-set", "--content=x"], @[],
        "--content applies to --verify only"),
      (@["certificates"], @[], "certificates"),
      (@["certificates", "bogus"], @[], "bogus"),
      (@["certificates", "list", "stray"], @[], "stray"),
      (@["certificates", "list", "--tool-provisioning", "path"], @[],
        "--tool-provisioning"),
      (@["certificates", "plan", "--no-runquota=perhaps"], @[],
        "--no-runquota"),
      (@["certificates", "policy", "--branch="], @[], "--branch needs a name"),
      (@["ci"], @[], "ci"),
      (@["ci", "plan", "--bogus"], @[], "--bogus"),
      (@["ci", "plan", "--platform", "x86_64-linux"], @[], "--platform"),
      (@["watch", "--bogus"], @[], "--bogus"),
      (@["watch", "--daemon=maybe"], @[], "--daemon"),
      (@["watch", "."], @[("REPRO_DAEMON", "maybe")], "REPRO_DAEMON"),
      (@["watch", "--max-cycles=0"], @[], "--max-cycles"),
      (@["watch", "--max-cycles=many"], @[], "--max-cycles"),
      (@["watch", "--debounce-ms=-5"], @[], "--debounce-ms"),
      (@["watch", "--hcr-mode=fast"], @[], "--hcr-mode"),
      (@["watch", "--hcr-target=only-a-name"], @[], "--hcr-target"),
      (@["watch", "--attach"], @[], "--attach"),
      (@["watch", "--ct-incremental-trace-dir", "d"], @[],
        "--ct-incremental-trace-dir")]
    for (argv, env, needle) in cases:
      let res = s.run(argv, env)
      check res.code == 2
      check needle in res.output
      check ("repro " & argv[0]) in res.output or "'" & argv[0] & "'" in
        res.output
    check not dirExists(s.home / "daemon")

  test "watch's flags over their variables, in both orders":
    withBuildEnv(NoEnv):
      let (c, o) = loadWatchCommandLine(NoArgs)
      check c.daemon == ""
      check o.daemon.winner.kind notin {cokCli, cokEnv}
      check c.debounceMs == 250
      check c.maxCycles == 0
      check not c.restoreCachedOutputs
    withBuildEnv([("REPRO_DAEMON", "off"),
        ("REPRO_TOOL_PROVISIONING", "nix"),
        ("REPRO_RESTORE_CACHED_OUTPUTS", "1"),
        ("REPROBUILD_MEASURE", "timing"), ("REPROBUILD_SHOW", "trace")]):
      let (c, o) = loadWatchCommandLine(["."])
      check c.daemon == "off"
      check o.daemon.winner.kind == cokEnv
      check c.toolProvisioning == "nix"
      check o.toolProvisioning.winner.kind == cokEnv
      check c.restoreCachedOutputs
      check o.restoreCachedOutputs.winner.kind == cokEnv
      check c.measure == @["timing"]
      check o.measure.winner.kind == cokEnv
      check c.show == @["trace"]
      check o.show.winner.kind == cokEnv
      let (f, fo) = loadWatchCommandLine(["--daemon=require",
        "--tool-provisioning=path", "--no-restore-cached-outputs",
        "--measure=none", "--show=timing", "."])
      check f.daemon == "require"
      check fo.daemon.winner.kind == cokCli
      check f.toolProvisioning == "path"
      check fo.toolProvisioning.winner.kind == cokCli
      check not f.restoreCachedOutputs
      check fo.restoreCachedOutputs.winner.kind == cokCli
      check f.measure == @["none"]
      check fo.measure.winner.kind == cokCli
      check f.show == @["timing"]
      check fo.show.winner.kind == cokCli
    withBuildEnv([("REPRO_DAEMON", "require")]):
      check loadWatchCommandLine(["--daemon", "off"]).conf.daemon == "off"
      check loadWatchCommandLine(NoArgs).conf.daemon == "require"
    withBuildEnv([("REPRO_DAEMON", "")]):
      check loadWatchCommandLine(NoArgs).conf.daemon == ""
    withBuildEnv(NoEnv):
      let (w, _) = loadWatchCommandLine(["--max-cycles=3", "--debounce-ms=40",
        "--hcr", "--hcr-mode=shlib", "--hcr-target=a:/s:/art",
        "--hcr-target=name=p:q,socket=/t,artifacts=/u", "--detach",
        "--write-stats", "one", "two"])
      check w.maxCycles == 3
      check w.debounceMs == 40
      check w.hcr
      check w.hcrMode == "shlib"
      check w.hcrTarget == @["a:/s:/art", "name=p:q,socket=/t,artifacts=/u"]
      check w.detach
      check w.writeStats == some("")
      check w.selectors == @["one", "two"]

  test "ci plan --branch over GITHUB_BASE_REF, then GITHUB_REF_NAME":
    withBuildEnv([("GITHUB_REF_NAME", "dev")]):
      check parsed(["ci", "plan"]) == 0
      check parsedCommand.ci.plan.branch == "dev"
      check parsed(["ci", "plan", "--branch=main"]) == 0
      check parsedCommand.ci.plan.branch == "main"
    withBuildEnv([("GITHUB_BASE_REF", "stable"), ("GITHUB_REF_NAME", "dev")]):
      check parsed(["ci", "plan"]) == 0
      check parsedCommand.ci.plan.branch == "stable"
      check parsed(["ci", "plan", "--branch=main", "--platform=a",
        "--platform=b", "--json"]) == 0
      check parsedCommand.ci.plan.branch == "main"
      check parsedCommand.ci.plan.platform == @["a", "b"]
      check parsedCommand.ci.plan.json
    # A pull request's empty `GITHUB_BASE_REF` on a push event counts as
    # unset, so `GITHUB_REF_NAME` applies.
    withBuildEnv([("GITHUB_BASE_REF", ""), ("GITHUB_REF_NAME", "dev")]):
      check parsed(["ci", "plan"]) == 0
      check parsedCommand.ci.plan.branch == "dev"

  test "certificates list and plan: --no-runquota over REPROBUILD_NO_RUNQUOTA":
    withBuildEnv([("REPROBUILD_NO_RUNQUOTA", "1")]):
      check parsed(["certificates", "list"]) == 0
      check parsedCommand.certificates.list.noRunquota
      check parsed(["certificates", "plan", "--json", "a", "b"]) == 0
      check parsedCommand.certificates.plan.noRunquota
      check parsedCommand.certificates.plan.selectors == @["a", "b"]
    withBuildEnv(NoEnv):
      check parsed(["certificates", "list"]) == 0
      check not parsedCommand.certificates.list.noRunquota
      check parsed(["certificates", "plan", "--no-runquota", "--no-certify",
        "--tool-provisioning=nix"]) == 0
      check parsedCommand.certificates.plan.noRunquota
      check parsedCommand.certificates.plan.noCertify
      check parsedCommand.certificates.plan.toolProvisioning == "nix"
      check parsed(["certificates", "policy", "--branch", "main"]) == 0
      check parsedCommand.certificates.policy.branch == some("main")

  test "repro test hands its build exactly the build flags it was given":
    withBuildEnv([("REPRO_DAEMON", "off"), ("REPROBUILD_LOG", "actions")]):
      let argv = @["--shard=1/2", "--daemon", "require", "-v", "--release",
        "--variant=a=1", "--no-certify", "--workspace-root=w",
        "--runquota", "--write-report", "--write-stats=s.db",
        "--no-unicode", "--lock", "L", "--only=x", "--hard-rebuild",
        "--dry-run", "sel", "--", "-x", "a b"]
      let (c, o) = loadTestCommandLine(argv)
      check c.shard == "1/2"
      check not c.certify
      check c.selectors == @["sel"]
      check c.actionArgs == @["-x", "a b"]
      let words = reproTestBuildWords(argv).buildFlags
      checkpoint(words.join(" "))
      # Only what the command line gave, in the order given and in the
      # flags' long spellings; none of `repro test`'s own flags, the
      # positionals or what a variable gave. A switch that stands for
      # another flag's value is written as itself.
      check words == @["--daemon=require", "--verbose", "--release",
        "--variant=a=1", "--runquota", "--write-report", "--write-stats=s.db",
        "--no-unicode", "--lock=L", "--only=x", "--hard-rebuild",
        "--dry-run"]
      # The build reads them back to the same values; the variables the
      # flags declare it reads itself.
      let (b, bo) = loadBuildCommandLine(words & @["sel", "--", "-x", "a b"])
      check b.daemon == "require"
      check bo.daemon.winner.kind == cokCli
      check b.log == "summary"
      check b.variant == @["buildType=release", "a=1"]
      check b.release and b.verbose
      check b.lock == @["L"]
      check b.writeReport == some("")
      check b.writeStats == some("s.db")
      check not b.unicode
      check bo.unicode.winner.kind == cokCli
      check b.dryRun and b.hardRebuild
      check b.only == @["x"]
      check not b.noRunquota
      check bo.noRunquota.winner.kind == cokCli
      check b.selectors == @["sel"]
      check b.actionArgs == @["-x", "a b"]
      # Without the flags, the build reads the variables, as before.
      let (e, eo) = loadTestCommandLine(NoArgs)
      check reproTestBuildWords(NoArgs).buildFlags.len == 0
      check e.daemon == "off"
      check eo.daemon.winner.kind == cokEnv
      check e.certify
      check e.partitionStrategy == "joint-duration"
      check e.binDir == "build/test-bin"
    # `repro certify` takes the same command line.
    withBuildEnv(NoEnv):
      let (c, o) = loadCertifyCommandLine(["--verify", "cert.toml",
        "--content=x", "--registered-keys", "k"])
      check c.verify
      check c.selectors == @["cert.toml"]
      check c.content == "x"
      check c.registeredKeys == "k"
      check argvOf(o, only = reproBuildFlagNames(),
        commandWords = false).len == 0
      let (t, to) = loadCertifyCommandLine(["--check-set",
        "--check-set-command=true", "--tool-provisioning=nix"])
      check t.checkSet
      check t.checkSetCommand == "true"
      check argvOf(to, only = reproBuildFlagNames(),
        commandWords = false) == @["--tool-provisioning=nix"]

  test "repro test's variants: the run's own reads see them, its builds add them once":
    # The certificate plan, the lock refresh and the sharded path evaluate
    # the recipe in this process, under `$REPRO_VARIANTS`; the builds the run
    # starts get the assignments on their command line (`argvOf`) and
    # must start from the caller's value, or a second build in one run
    # (`repro certify`'s re-execution) would see them twice.
    let saved = (existsEnv("REPRO_VARIANTS"), getEnv("REPRO_VARIANTS"))
    try:
      withBuildEnv(NoEnv):
        putEnv("REPRO_VARIANTS", "x=0")
        let r = reproTestRunVariants(["--release", "--variant=a=1",
          "--target=native"])
        check r.duringRun == some("x=0,buildType=release,a=1")
        check r.duringBuild == some("x=0")
        check r.afterBuild == some("x=0,buildType=release,a=1")
        check getEnv("REPRO_VARIANTS") == "x=0"
        delEnv("REPRO_VARIANTS")
        let t = reproTestRunVariants(["--debug", "--target=armv7-linux"])
        check t.duringRun.isSome
        check t.duringRun.get.startsWith("buildType=debug,targetTriple=")
        check "armv7" in t.duringRun.get
        check t.duringBuild.isNone
        check not existsEnv("REPRO_VARIANTS")
        # Nothing given: the caller's value throughout.
        let n = reproTestRunVariants(NoArgs)
        check n.duringRun.isNone and n.duringBuild.isNone
    finally:
      if saved[0]: putEnv("REPRO_VARIANTS", saved[1])
      else: delEnv("REPRO_VARIANTS")

  test "repro test --release and -v build as before, sharded and not":
    # Before confutils wrote the build's words back, `--release` reached the
    # build as `--variant=buildType=release` and `-v` as `--log=summary`.
    # Now they reach it as themselves, which also sets the build's `release`
    # and `verbose` switches; nothing reads those, so the build must see the
    # same variants and the same log level, from the command line.
    withBuildEnv([("REPROBUILD_LOG", "actions")]):
      for shard in [NoArgs, @["--shard=1/2"]]:
        for (given, before) in [
            (@["--release"], @["--variant=buildType=release"]),
            (@["-v"], @["--log=summary"]),
            (@["--variant=a=1", "--release", "-v", "--debug"],
              @["--variant=a=1", "--variant=buildType=release",
                "--log=summary", "--variant=buildType=debug"]),
            (@["-vv", "--release", "--verbose"], @["--log=actions",
              "--variant=buildType=release", "--log=summary"])]:
          checkpoint((shard & given).join(" "))
          let opts = reproTestBuildWords(shard & given)
          # The sharded path evaluates with the run's own variants, which
          # `--release` gives in its place among the `--variant`s.
          let (old, oldOrigin) = loadBuildCommandLine(before)
          check opts.variants == old.variant
          let (b, bo) = loadBuildCommandLine(opts.buildFlags)
          check b.variant == old.variant
          check b.log == old.log
          check bo.log.winner.kind == oldOrigin.log.winner.kind
          check bo.variant.winner.kind == oldOrigin.variant.winner.kind

  test "--work-root and --action-cache-root over their variables, in both orders":
    const
      WorkRoot = "REPROBUILD_WORK_ROOT"
      CacheRoot = "REPROBUILD_ACTION_CACHE_ROOT"
    # Each command that takes the flags reads the variables they declare,
    # the flag winning; an empty variable counts as unset.
    template both(argv: openArray[string]; field: untyped) =
      block:
        let flagged = @argv & @["--work-root=/flag/w"]
        withBuildEnv([(WorkRoot, "/env/w")]):
          check parsed(argv) == 0
          check field.workRoot == "/env/w"
          check parsed(flagged) == 0
          check field.workRoot == "/flag/w"
        withBuildEnv([(WorkRoot, "")]):
          check parsed(argv) == 0
          check field.workRoot == ""
    template bothCache(argv: openArray[string]; field: untyped) =
      block:
        let flagged = @argv & @["--action-cache-root=/flag/c"]
        withBuildEnv([(CacheRoot, "/env/c")]):
          check parsed(argv) == 0
          check field.actionCacheRoot == "/env/c"
          check parsed(flagged) == 0
          check field.actionCacheRoot == "/flag/c"
        withBuildEnv([(CacheRoot, "")]):
          check parsed(argv) == 0
          check field.actionCacheRoot == ""
    both(["build"], parsedCommand.build)
    bothCache(["build"], parsedCommand.build)
    both(["bench"], parsedCommand.bench)
    bothCache(["bench"], parsedCommand.bench)
    both(["lint"], parsedCommand.lint)
    bothCache(["lint"], parsedCommand.lint)
    both(["test"], parsedCommand.test)
    bothCache(["test"], parsedCommand.test)
    both(["certify"], parsedCommand.certify)
    bothCache(["certify"], parsedCommand.certify)
    both(["watch"], parsedCommand.watch)
    both(["clean"], parsedCommand.clean)
    both(["graph"], parsedCommand.graph)
    bothCache(["graph"], parsedCommand.graph)
    both(["why", "x"], parsedCommand.why)
    bothCache(["why", "x"], parsedCommand.why)
    both(["stats"], parsedCommand.stats)
    bothCache(["stats"], parsedCommand.stats)
    bothCache(["store", "closure", "--root=r"], parsedCommand.store.closure)
    bothCache(["store", "export", "--root=r", "--out=o"],
      parsedCommand.store.`export`)
    bothCache(["store", "import", "d"], parsedCommand.store.`import`)
    bothCache(["bundle", "create", "--out=o", "x"], parsedCommand.bundle.create)
    bothCache(["bundle", "restore", "b"], parsedCommand.bundle.restore)
    # The origin says which one gave it.
    withBuildEnv([(WorkRoot, "/env/w"), (CacheRoot, "/env/c")]):
      let (c, o) = loadBuildCommandLine(NoArgs)
      check o.workRoot.winner.kind == cokEnv
      check o.actionCacheRoot.winner.kind == cokEnv
      let (f, fo) = loadBuildCommandLine(["--work-root", "/flag/w",
        "--action-cache-root=/flag/c"])
      check f.workRoot == "/flag/w" and f.actionCacheRoot == "/flag/c"
      check fo.workRoot.winner.kind == cokCli
      check fo.actionCacheRoot.winner.kind == cokCli
      # `repro test` hands its build only what its command line gave; the
      # build reads the variables itself.
      check c.workRoot == "/env/w"
      check loadTestCommandLine(NoArgs).conf.workRoot == "/env/w"
      check reproTestBuildWords(NoArgs).buildFlags.len == 0
      check reproTestBuildWords(["--work-root=/flag/w"]).buildFlags ==
        @["--work-root=/flag/w"]
