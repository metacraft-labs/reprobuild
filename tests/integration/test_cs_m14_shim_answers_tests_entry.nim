## A binary whose tests are `ct_test_unittest_parallel`'s `suite` / `test`
## answers nim-entrypoints' `tests` entry, so `repro test` lists and runs its
## tests one by one through `runPerTest`, as it does a nim-entrypoints
## binary's.
##
## The fixture package (`tests/fixtures/cs_m14_shim_tests_entry`, copied to a
## scratch directory so it is a project outside this tree) builds three test
## binaries from the same tests (`math::add`, `math::mul`, `loose`) and puts
## each one's `runPerTest` collector into its `test` collection:
##
## * `shim_suite` links the shim alone, which answers the entry itself;
## * `shim_entry_suite` is built with nim-entrypoints, the shim's tests in a
##   `tests:` block beside a `testCase "alpha"` and a `main:`; nim-entrypoints
##   answers the entry, the shim runs the block's tests;
## * `plain_suite` links `std/unittest` alone and has no tests entry.
##
## Cases, each a real `repro test` read from its build report:
##
##   1. both shim binaries are listed and run per test: one created action
##      per test, argv `<binary> --entrypoint=tests --run-exact=<name>`, each
##      running only its test (its stdout carries its own marker and no
##      other); a second `repro test` serves every run from the cache. The
##      binaries themselves answer the entry on the right streams: the list
##      on stdout and nothing else there (a suite body's output goes to
##      stderr), the entry list as an `entrypoints/1` document, an unknown
##      `--run-exact` name and any `--run` under the shim's own entry refused
##      with 64 and nothing run;
##   2. with `math::mul` failing, its action fails in both shim binaries, the
##      other tests' actions succeed, and the command fails.
##
## Negative control (both cases): the plain `std/unittest` binary lists
## nothing and stays a whole-binary edge. Its collection is one run of the
## whole binary, `<collector>.whole-binary` with argv `[<binary>]`, not one
## per test: the check the shim binaries pass rejects it. That run runs every
## test (case 2: it fails with `math::mul`). The case also records why it is
## not listed: asked `--entrypoint=tests --run-exact=math::mul`, the plain
## binary runs no test and exits 0 with `math::mul` failing, so a per-test
## run of it would pass having run nothing.
##
## nim-entrypoints is found as `test_cs_m14_repro_collects_tests_per_entry`
## finds it (the `../nim-entrypoints` checkout, else `$ENTRYPOINTS_SRC`;
## `REPRO_SIBLING_POLICY=pin` takes `$ENTRYPOINTS_SRC` first), and must have
## `--run-exact`.
##
## MOCKS: none. The real `repro` of this build compiles the fixture's recipe
## and the three test binaries with the real Nim (the dev shell's, whose
## `std/unittest` is the protocol-carrying fork), runs the real
## `repro-tests-fragment` under the io monitor, and the engine creates,
## monitors and caches the runs. The direct probes run the binaries that
## build produced.

import std/[json, os, strtabs, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/process_fixtures

const
  FixtureDir = ReprobuildRepoRoot / "tests" / "fixtures" /
    "cs_m14_shim_tests_entry"
  ShimSrc = ReprobuildRepoRoot / "libs" / "ct_test_unittest_parallel" / "src"
  ShimCollector = "cs_m14_shim.tests.shim"
  EntryCollector = "cs_m14_shim.tests.entry"
  PlainCollector = "cs_m14_shim.tests.plain"
  ShimNames = ["math::add", "math::mul", "loose"]
  EntryNames = ["alpha", "math::add", "math::mul", "loose"]
  ShimBinary = "build/test-bin/shim_suite"
  EntryBinary = "build/test-bin/shim_entry_suite"
  PlainBinary = "build/test-bin/plain_suite"
  Marker = "CSM14SHIM "
  SuiteMarker = "CSM14SUITE "
  MulBody = "echo \"CSM14SHIM math::mul\" # mul's body"
  MulFails = "echo \"CSM14SHIM math::mul\"; check 1 == 2"
  Sources = ["shim_suite.nim", "shim_entry_suite.nim", "plain_suite.nim"]
  ReuseStatuses = ["asUpToDate", "asCacheHit"]
  ReuseDecisions = ["cdHit", "cdHybridCutoff"]

proc entrypointsSrc(): string =
  ## nim-entrypoints' `src/`, as this repository's `config.nims` finds it:
  ## the `../nim-entrypoints` checkout, else `$ENTRYPOINTS_SRC`, and
  ## `$ENTRYPOINTS_SRC` first under `REPRO_SIBLING_POLICY=pin`. (The same
  ## rule as `test_cs_m14_repro_collects_tests_per_entry`.)
  let pinned = getEnv("ENTRYPOINTS_SRC")
  if getEnv("REPRO_SIBLING_POLICY") == "pin" and pinned.len > 0:
    return pinned
  let sibling = ReprobuildRepoRoot.parentDir / "nim-entrypoints" / "src"
  if fileExists(sibling / "entrypoints.nim"):
    return sibling
  pinned

type Project = object
  scratch: string
  root: string
  reportDir: string

proc projectWith(mulBody = MulBody): Project =
  ## A scratch copy of the fixture with its placeholders filled in, and
  ## `math::mul`'s line replaced by `mulBody` in every source.
  let entrypoints = entrypointsSrc()
  doAssert fileExists(entrypoints / "entrypoints" / "tests.nim"),
    "nim-entrypoints not found: no ../nim-entrypoints beside this checkout " &
    "and no $ENTRYPOINTS_SRC"
  doAssert "--run-exact" in readFile(entrypoints / "entrypoints" /
    "tests.nim"), entrypoints & " predates --run-exact"
  result.scratch = expandFilename(createTempDir("cs-m14-shim-entry-", ""))
  releaseDirAtProcessExit(result.scratch)
  result.root = result.scratch / "project"
  result.reportDir = result.scratch / "reports"
  createDir(result.root / "src")
  createDir(result.reportDir)
  let backend = when defined(macosx): "clang" else: "gcc"
  writeFile(result.root / "repro.nim", readFile(FixtureDir / "repro.nim")
    .replace("__SHIM_SRC__", ShimSrc)
    .replace("__ENTRYPOINTS_SRC__", entrypoints)
    .replace("__NATIVE_BACKEND__", backend))
  for name in Sources:
    let source = readFile(FixtureDir / "src" / name)
    doAssert MulBody in source
    writeFile(result.root / "src" / name, source.replace(MulBody, mulBody))

proc childEnv(): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    result[key] = value
  result.del("LD_PRELOAD")

proc reproTest(p: Project; label: string):
    tuple[code: int; report: JsonNode; output: string] =
  ## `repro test` in the project, with this checkout's `repro` and DSL, the
  ## report it writes, and what it printed.
  let repoRoot = ReprobuildRepoRoot
  let reproBin = requireBinary(reproBinaryPath(repoRoot),
    "reprobuild.apps.repro")
  discard requireBinary(repoRoot / "build" / "bin" /
    addFileExt("repro-tests-fragment", ExeExt),
    "reprobuild.apps.repro-tests-fragment")
  let shim = requireBinary(monitorShimPath(repoRoot),
    "reprobuild.test_fixtures.monitor_shim")
  let env = childEnv()
  env["REPROBUILD_REPO_ROOT"] = repoRoot
  env["REPROBUILD_LIBS_DIR"] = repoRoot / "libs"
  env["REPRO_MONITOR_SHIM_LIB"] = shim
  let reportPath = p.reportDir / (label & ".json")
  let args = @["test", "--daemon=off", "--tool-provisioning=path",
    "--no-runquota", "--no-certify", "--progress=quiet",
    "--work-root=" & (p.scratch / "work"),
    "--action-cache-root=" & (p.scratch / "cache"),
    "--write-report=" & reportPath]
  let run = runProgramSplit(reproBin, args, p.root, env)
  checkpoint("repro " & args.join(" ") & " -> exit " & $run.code)
  if run.code != 0:
    checkpoint(run.stdout & run.stderr)
  result.code = run.code
  result.output = run.stdout & run.stderr
  result.report =
    if fileExists(reportPath): parseFile(reportPath) else: newJNull()

proc action(report: JsonNode; id: string): JsonNode =
  if report.kind == JObject:
    for entry in report{"actions"}:
      if entry{"id"}.getStr() == id:
        return entry
  newJNull()

type CreatedRun = object
  id: string
  argv: seq[string]
  status: string
  launched: bool
  decision: string
  stdout: string

proc createdRuns(report: JsonNode; collector: string): seq[CreatedRun] =
  ## Every action the collector's fragment created, with the argv the engine
  ## recorded for it and its outcome, in creation order.
  if report.kind != JObject:
    return
  var ids: seq[string] = @[]
  for event in report{"trace"}:
    if event{"event"}.getStr() == "action-create" and
        event{"detail"}.getStr() == "producer=" & collector:
      ids.add(event{"actionId"}.getStr())
  for id in ids:
    var run = CreatedRun(id: id)
    for event in report{"trace"}:
      if event{"actionId"}.getStr() == id and
          event{"event"}.getStr() == "action-create-argv":
        for item in parseJson(event{"detail"}.getStr()):
          run.argv.add(item.getStr())
    let entry = report.action(id)
    if entry.kind == JObject:
      run.status = entry{"status"}.getStr()
      run.launched = entry{"launched"}.getBool()
      run.decision = entry{"cacheDecision"}.getStr()
      run.stdout = entry{"stdout"}.getStr()
    result.add(run)

proc runFor(runs: seq[CreatedRun]; name: string): CreatedRun =
  ## The run whose argv selects exactly the test `name`.
  for run in runs:
    if run.argv.len == 3 and run.argv[1 .. 2] ==
        @["--entrypoint=tests", "--run-exact=" & name]:
      return run
  CreatedRun()

proc isPerTestCollection(runs: seq[CreatedRun]; names: openArray[string];
                         binary, collector: string): bool =
  ## One run per test, each running the binary's tests entry with exactly
  ## that test selected, under the collector's `.test.` ids, and nothing
  ## else.
  if runs.len != names.len:
    return false
  for name in names:
    let run = runs.runFor(name)
    if run.id.len == 0 or not run.id.startsWith(collector & ".test.") or
        not run.argv[0].endsWith(addFileExt(binary, ExeExt)):
      return false
  true

proc describe(runs: seq[CreatedRun]): string =
  for run in runs:
    result.add(run.id & " argv=" & $run.argv & " status=" & run.status &
      " launched=" & $run.launched & " decision=" & run.decision & "\n")

proc markers(output: string): seq[string] =
  for line in output.splitLines():
    let at = line.find(Marker)
    if at >= 0:
      result.add(line[at + Marker.len .. ^1].strip())

proc lines(output: string): seq[string] =
  for line in output.splitLines():
    if line.len > 0:
      result.add(line)

proc probe(p: Project; binary: string; args: openArray[string]):
    CmdSplitResult =
  ## Run a binary the build produced, its streams apart.
  let path = p.root / addFileExt(binary, ExeExt)
  result = runProgramSplit(path, args, p.root, childEnv(), timeoutMs = 60_000)
  checkpoint(binary & " " & args.join(" ") & " -> exit " & $result.code &
    "\nstdout:\n" & result.stdout & "\nstderr:\n" & result.stderr)

proc checkWholeBinary(report: JsonNode): CreatedRun =
  ## The negative control: the plain binary's collection is one run of the
  ## whole binary, which the per-test check rejects.
  let runs = report.createdRuns(PlainCollector)
  checkpoint("plain:\n" & runs.describe)
  check not runs.isPerTestCollection(["math::add", "math::mul"], PlainBinary,
    PlainCollector)
  check runs.len == 1
  if runs.len == 1:
    result = runs[0]
    check result.id == PlainCollector & ".whole-binary"
    check result.argv.len == 1 and
      result.argv[0].endsWith(addFileExt(PlainBinary, ExeExt))

suite "test_cs_m14_shim_answers_tests_entry":

  test "a shim-linked binary, with and without entrypoints, runs per test":
    let p = projectWith()
    let first = p.reproTest("first")
    check first.code == 0
    for (collector, names, binary) in [
        (ShimCollector, @ShimNames, ShimBinary),
        (EntryCollector, @EntryNames, EntryBinary)]:
      let listing = first.report.action(collector & ".list")
      checkpoint(collector & " listing: " & $listing)
      check listing{"status"}.getStr() == "asSucceeded"
      let runs = first.report.createdRuns(collector)
      checkpoint(collector & ":\n" & runs.describe)
      check runs.isPerTestCollection(names, binary, collector)
      for name in names:
        let run = runs.runFor(name)
        check run.status == "asSucceeded"
        check run.launched
        # Out of band: the run printed its own test's marker and no other.
        check run.stdout.markers == @[name]
      check first.report.action(collector){"status"}.getStr() ==
        "asSucceeded"

    # Negative control: no per-test runs for the plain binary; its one run
    # ran both its tests.
    let whole = first.report.checkWholeBinary()
    check whole.status == "asSucceeded"
    check whole.stdout.markers == @["math::add", "math::mul"]

    # Nothing changed: every run is served from the cache.
    let second = p.reproTest("second")
    check second.code == 0
    for collector in [ShimCollector, EntryCollector, PlainCollector]:
      let again = second.report.createdRuns(collector)
      checkpoint(collector & " second:\n" & again.describe)
      check again.len > 0
      for run in again:
        check run.status in ReuseStatuses
        check run.decision in ReuseDecisions
        check not run.launched

    # The binaries themselves. The shim's list is on stdout, alone: the
    # suite body's line went to stderr.
    let shimList = p.probe(ShimBinary, ["--entrypoint=tests", "--list"])
    check shimList.code == 0
    check shimList.stdout.lines == @ShimNames
    check SuiteMarker & "math" in shimList.stderr
    let shimCases = p.probe(ShimBinary,
      ["--entrypoint=tests", "--list", "--list-test-cases"])
    check shimCases.code == 0
    check shimCases.stdout.lines.len == 0
    let shimEntries = p.probe(ShimBinary, ["--entrypoint=list"])
    check shimEntries.code == 0
    let document = parseJson(shimEntries.stdout)
    check document{"schema"}.getStr() == "entrypoints/1"
    var testsEntry = newJNull()
    for entry in document{"entries"}:
      if entry{"name"}.getStr() == "tests":
        testsEntry = entry
    check testsEntry{"entries"} == %ShimNames
    check testsEntry{"select"} == %["runtime"]
    let unknown = p.probe(ShimBinary,
      ["--entrypoint=tests", "--run-exact=math::"])
    check unknown.code == 64
    check unknown.stdout.markers.len == 0
    # `--run` under the shim's own entry is refused, whatever it names: the
    # protocol-carrying std/unittest would read it as its own exact `--run`
    # and skip what the shim's matching selected (`math::`, `add`).
    for runArgs in [@["--run=math::add"], @["--run=math::"], @["--run=add"],
        @["--run", "loose"]]:
      let refused = p.probe(ShimBinary, @["--entrypoint=tests"] & runArgs)
      check refused.code == 64
      check refused.stdout.markers.len == 0
      check "--run-exact" in refused.stderr
    # With nim-entrypoints the list is on stdout too: the shim gave back the
    # descriptor the protocol-carrying std/unittest took for its own --list.
    let entryList = p.probe(EntryBinary, ["--entrypoint=tests", "--list"])
    check entryList.code == 0
    check entryList.stdout.lines == @EntryNames

  test "a failing test fails only its own action, and the command":
    let p = projectWith(mulBody = MulFails)
    let failing = p.reproTest("failing")
    check failing.code != 0
    for (collector, names, binary) in [
        (ShimCollector, @ShimNames, ShimBinary),
        (EntryCollector, @EntryNames, EntryBinary)]:
      check failing.report.action(collector & ".list"){"status"}.getStr() ==
        "asSucceeded"
      let runs = failing.report.createdRuns(collector)
      checkpoint(collector & " failing:\n" & runs.describe)
      check runs.isPerTestCollection(names, binary, collector)
      var failed: seq[string] = @[]
      for name in names:
        let run = runs.runFor(name)
        if run.status == "asFailed":
          failed.add(name)
        else:
          check run.status == "asSucceeded"
      check failed == @["math::mul"]
      check failing.report.action(collector){"status"}.getStr() !=
        "asSucceeded"

    # Negative control: the plain binary's one run runs every test, so it
    # fails with math::mul.
    let whole = failing.report.checkWholeBinary()
    check whole.status == "asFailed"
    check whole.stdout.markers == @["math::add", "math::mul"]

    # Why the plain binary is not listed: asked to run math::mul alone
    # through the entry it does not have, it runs nothing and passes.
    let vacuous = p.probe(PlainBinary,
      ["--entrypoint=tests", "--run-exact=math::mul"])
    check vacuous.code == 0
    check vacuous.stdout.markers.len == 0
    # Recorded, not asserted (it depends on the Nim's std/unittest): what the
    # plain binary prints for `--entrypoint=tests --list`.
    let plainList = p.probe(PlainBinary, ["--entrypoint=tests", "--list"])
    echo "measured: plain std/unittest binary, --entrypoint=tests --list: " &
      "exit ", plainList.code, ", stdout ", plainList.stdout.lines,
      ", stderr ", plainList.stderr.lines.len, " lines"
