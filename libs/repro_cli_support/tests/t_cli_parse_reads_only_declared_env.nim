## The engine's command-line parse reads the environment BY NAME, never as a
## whole block.
##
## Every monitored edge whose tree runs the `reprobuild` engine image -- the
## profile compile (`__repro-compile-profile`), the profile platform probe,
## the provider compile, interface extraction -- parses its argv through
## `loadReproCommandLine` before doing anything else. That parse used to take
## its environment from confutils' `cliProcessEnv()`, which enumerates the
## whole environment (`envPairs`; on Windows `GetEnvironmentStringsW` called
## from the program's own image). io-mon's Windows shim records such a block
## read as a read of EVERY variable in it (`snoopEnvBlock`), so each of those
## edges was keyed on the value of every variable of the caller's environment:
## `repro home export` after `repro home plan` recompiled the profile because
## only `$REPRO_HOST` differed between the two (reprobuild-pm issue
## 2026-11-15-windows-gm2-export-gate-recompiles-the-profile-after-the-plan).
##
## The gate runs the real images under the real monitor (`internal io
## monitor`) on a helper argv that exits after the parse (a usage error: the
## helper's required flags are missing), with a sentinel variable in its
## environment that nothing reads, twice: the engine (`build/bin/reprobuild`)
## directly, and the public CLI (`build/bin/repro`, the thin client the
## helper edges actually invoke, `publicCliPath`), so the client's hand-off
## to the engine is inside the observed tree too. It asserts on the depfile
## the shim wrote:
##
## * the sentinel is NOT among the recorded environment reads (the defect:
##   on Windows it was, through the block read);
## * no environment read came from a whole-block enumeration
##   (`scope=block`), on hosts whose shim reports the scope;
## * positive control, so the first check cannot pass because environment
##   reads are not captured at all: a variable the engine's startup reads by
##   name (`REPRO_PUBLIC_CLI_PATH`, `stablePublicCliPath`) IS recorded.
##
## Falsifying mutation (performed when this gate was written): restore
## `CliSources(env: cliProcessEnv())` in `loadReproCommandLine`. On Windows the
## sentinel is recorded and the gate goes red.
##
## The second suite checks that the by-name lookup is the same input to the
## parse as the whole environment was, on every host: a small description
## with parameters that declare variables (repro's own grammar declares only
## `repro build`'s, `bench`'s and `lint`'s, which a self-contained probe
## exercises better) is loaded
## from `cliProcessEnv()` and from `declaredEnvOf` under several
## environments, and must yield the same values, or the same refusal. It
## also checks `reproDeclaredEnv()` against the whole environment filtered to
## repro's declared names (a variable set to the empty string counts as
## unset, as reprobuild has always read these), and that the parse of one
## command looks up only the variables that command's parameters declare
## (`reproDeclaredEnvFor`). This half has teeth on Linux too: a lookup that
## leaked an undeclared variable, dropped a declared one, or changed which of
## a parameter's variables wins, fails it.
##
## No mocks: the real engine, the real monitor shim, the real depfile; the
## real generated parser for the equivalence suite.
##
## Platforms: every host. On Linux and macOS `environ` is read without an
## observable call, so there the first two checks hold before and after the
## fix; the positive control still has to pass.

import std/[os, strtabs, strutils, tables, tempfiles, unittest]

import confutils/clispec_config

import io_mon
from repro_test_support import requireBinary, monitorShimPath,
  runProgramSplit
import repro_cli_support/cli_program

const RepoRoot = currentSourcePath().parentDir().parentDir().parentDir().
  parentDir()

const SentinelName = "REPRO_TEST_UNREAD_ENV_SENTINEL"
  ## Set in the monitored engine's environment; no code reads it.
const ByNameControl = "REPRO_PUBLIC_CLI_PATH"
  ## Read by name at the engine's entry (`stablePublicCliPath`), before the
  ## argv parse.

proc engineBinary(): string =
  requireBinary(RepoRoot / "build" / "bin" / addFileExt("reprobuild",
    ExeExt), "reprobuild.apps.repro")

proc publicCliBinary(): string =
  requireBinary(RepoRoot / "build" / "bin" / addFileExt("repro", ExeExt),
    "reprobuild.apps.repro")

proc monitoredEnv(): StringTableRef =
  ## This process's environment plus the sentinel. Case-insensitive on
  ## Windows, where variable names are: a case-sensitive table would carry
  ## both `Path` and `PATH` into the child's block.
  result = newStringTable(
    when defined(windows): modeCaseInsensitive else: modeCaseSensitive)
  for k, v in envPairs():
    result[k] = v
  result[SentinelName] = "present"
  result.del(ByNameControl)
  let shim = monitorShimPath(RepoRoot)
  if fileExists(shim):
    result["REPRO_MONITOR_SHIM_LIB"] = shim

proc envReads(dep: MonitorDepFile): seq[MonitorRecord] =
  for record in dep.records:
    if record.kind == mrEnvRead:
      result.add record

proc readsName(reads: seq[MonitorRecord]; name: string): bool =
  for record in reads:
    if cmpIgnoreCase(record.path, name) == 0:
      return true
  false

suite "repro command-line parse: environment reads":

  test "the helper argv parse reads the environment by name, directly " &
      "and through the public CLI":
    let engine = engineBinary()
    # The engine image itself, and the public CLI the helper edges actually
    # invoke (`publicCliPath`), whose hand-off to the engine is then inside
    # the observed tree as well.
    for helperImage in [engine, publicCliBinary()]:
      let root = createTempDir("repro-cli-env-", "")
      defer:
        try: removeDir(root) except CatchableError: discard
      let depfile = root / "helper.iomon"
      # Both pipes drained until the child exits (`runProgramSplit`): a
      # single `readAll` of a Windows pipe returns after the first burst.
      let run = runProgramSplit(engine, ["internal", "io", "monitor",
        "--depfile", depfile, "--", helperImage, "__repro-compile-profile"],
        cwd = root, env = monitoredEnv(), timeoutMs = 120_000)
      let output = run.stdout & run.stderr
      checkpoint(helperImage & ": monitored helper exit " & $run.code &
        ":\n" & output)
      # The helper refuses its empty argv AFTER the parse.
      check run.code == 2
      check "missing --profile" in output
      require fileExists(depfile)

      let reads = envReads(readMonitorDepFile(depfile))
      var listed: seq[string]
      for record in reads:
        listed.add record.path & " (" & record.detail & ")"
      checkpoint(helperImage & ": recorded environment reads:\n  " &
        listed.join("\n  "))
      # Positive control: environment reads are captured at all.
      check reads.readsName(ByNameControl)
      # The defect: a block read makes every variable an input.
      check not reads.readsName(SentinelName)
      for record in reads:
        check "scope=block" notin record.detail

# A description whose parameters declare variables, for the equivalence
# suite: one parameter with two variables (the first one set wins), one
# with a single variable, and one that declares none.
cliConfiguration(EnvProbeCli, "envprobe"):
  flag jobs is int, default = 4,
    env = ["REPRO_TEST_ENVPROBE_JOBS", "REPRO_TEST_ENVPROBE_JOBS_ALT"]
  flag label is string, default = "none",
    env = ["REPRO_TEST_ENVPROBE_LABEL"]
  flag depth is int, default = 1

const ProbeVars = ["REPRO_TEST_ENVPROBE_JOBS", "REPRO_TEST_ENVPROBE_JOBS_ALT",
  "REPRO_TEST_ENVPROBE_LABEL", "REPRO_TEST_ENVPROBE_DEPTH", SentinelName]
  ## `..._DEPTH` names the undeclared parameter's would-be variable: the
  ## lookup must not pick it up.

proc loadOutcome(env: Table[string, string]): string =
  ## The parsed values, or the refusal, as one comparable string.
  try:
    let conf = EnvProbeCli.load(newSeq[string](),
      CliSources(env: env))
    "jobs=" & $conf.jobs & " label=" & conf.label & " depth=" & $conf.depth
  except CliUsageError as e:
    "usage error: " & e.msg
  except CliConfigError as e:
    "config error: " & e.msg

suite "repro command-line parse: the by-name environment is the same input":

  test "a description's declared variables load identically either way":
    let saved = block:
      var t: seq[(string, bool, string)]
      for name in ProbeVars:
        t.add((name, existsEnv(name), getEnv(name)))
      t
    defer:
      for (name, present, value) in saved:
        if present: putEnv(name, value) else: delEnv(name)

    let scenarios: seq[seq[(string, string)]] = @[
      @[],
      @[("REPRO_TEST_ENVPROBE_JOBS", "7")],
      @[("REPRO_TEST_ENVPROBE_JOBS_ALT", "9")],
      @[("REPRO_TEST_ENVPROBE_JOBS", "7"),
        ("REPRO_TEST_ENVPROBE_JOBS_ALT", "9")],
      @[("REPRO_TEST_ENVPROBE_LABEL", "from-env"),
        ("REPRO_TEST_ENVPROBE_DEPTH", "5"), (SentinelName, "present")],
      @[("REPRO_TEST_ENVPROBE_JOBS", "not-a-number")],
    ]
    let g = EnvProbeCli.cliGrammar()
    var outcomes: seq[string]
    for scenario in scenarios:
      for name in ProbeVars:
        delEnv(name)
      for (name, value) in scenario:
        putEnv(name, value)
      let byName = declaredEnvOf(g)
      let whole = loadOutcome(cliProcessEnv())
      checkpoint("scenario " & $scenario & ": " & whole)
      check loadOutcome(byName) == whole
      # Only declared, set variables are in the table.
      check SentinelName notin byName
      check "REPRO_TEST_ENVPROBE_DEPTH" notin byName
      for (name, value) in scenario:
        if name.startsWith("REPRO_TEST_ENVPROBE_") and
            name != "REPRO_TEST_ENVPROBE_DEPTH":
          check byName.getOrDefault(name, "<absent>") == value
      if whole notin outcomes:
        outcomes.add whole
    # The scenarios exercised the environment at all: defaults, each
    # variable winning, and a refusal produce different outcomes.
    check outcomes.len >= 5

  test "repro's own lookup equals the whole environment on its declared names":
    putEnv(SentinelName, "present")
    defer: delEnv(SentinelName)
    let g = ReproCommandLine.cliGrammar()
    var declared: seq[string]
    for p in g.params:
      if csEnv in p.sources:
        for name in p.env:
          declared.add name
    var expected = initTable[string, string]()
    for name, value in cliProcessEnv():
      if name in declared and value.len > 0:
        expected[name] = value
    let actual = reproDeclaredEnv()
    check SentinelName notin actual
    check actual == expected

  test "a command's parse looks up only the variables its parameters declare":
    # `REPRO_DAEMON` is `repro build`'s (and `bench`'s and `lint`'s); a
    # helper edge's parse must not be keyed on it.
    let saved = (existsEnv("REPRO_DAEMON"), getEnv("REPRO_DAEMON"))
    defer:
      if saved[0]: putEnv("REPRO_DAEMON", saved[1])
      else: delEnv("REPRO_DAEMON")
    putEnv("REPRO_DAEMON", "off")
    check reproDeclaredEnvFor(["build", "--work-root", "x", "."]).
      getOrDefault("REPRO_DAEMON") == "off"
    check reproDeclaredEnvFor(["lint"]).getOrDefault("REPRO_DAEMON") == "off"
    check "REPRO_DAEMON" notin reproDeclaredEnvFor(
      ["__repro-compile-profile", "--out", "x"])
    check "REPRO_DAEMON" notin reproDeclaredEnvFor(["sync"])
    # The root alone may reach any command, so it sees them all.
    check reproDeclaredEnvFor(newSeq[string]()).
      getOrDefault("REPRO_DAEMON") == "off"
    # Set to the empty string, it counts as unset.
    putEnv("REPRO_DAEMON", "")
    check "REPRO_DAEMON" notin reproDeclaredEnvFor(["build"])
