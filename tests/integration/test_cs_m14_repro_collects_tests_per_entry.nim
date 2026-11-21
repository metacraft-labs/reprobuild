## `repro test` lists a package's tests through its test binary's `tests`
## entry and runs, caches and reports them one by one.
##
## The fixture package (`tests/fixtures/cs_m14_tests_per_entry`, copied to a
## scratch directory so it is a project outside this tree) builds one test
## binary with nim-entrypoints, holding the `testCase`s `alpha`, `beta` and
## `gamma` and a `main:`, and puts `runPerTest`'s collector into its `test`
## collection. Each case runs the real `repro test` on it and reads the
## build report:
##
##   1. the listing edge runs, and the fragment it writes creates three
##      actions whose argv is `<binary> --entrypoint=tests
##      --run-exact=<name>`, one per test, each running only its test (its
##      stdout carries its own marker and no other); a second `repro test`
##      serves all three from the cache without launching them;
##   2. with `beta` made to fail, `beta`'s action fails, `alpha`'s and
##      `gamma`'s succeed, and the command fails.
##
## The per-test actions are found in the report by the `action-create`
## trace events whose producer is the collector, and their argv by the
## `action-create-argv` event the engine records beside each.
##
## Negative control: the same package with the listing edge's producer
## replaced by one that emits ONE action running the whole binary. The build
## passes (the whole binary's tests pass), and the per-test check, the same
## procedure the positive cases use, rejects it: one action, not three, and
## its argv selects no single test.
##
## Changing one test reruns only that test, with one binary per test
## (`runPerTest(perTestBinaries = true)`, which builds each test with
## nim-entrypoints' `-d:entrypointsTest=<name>`):
##
##   3. the fragment also creates a compile per test, and each run launches
##      its own test's binary; after an edit of `beta`'s body that keeps its
##      line count, the reruns read from the report (status, cache decision,
##      launched) are `beta`'s alone: `alpha`'s and `gamma`'s compiles run
##      again (the source changed) and produce byte-identical binaries, so
##      their runs are cache hits; `beta`'s binary differs and its run is
##      launched;
##   4. negative control: the same edit with one binary for every test (the
##      default) reruns all three, so the check can see a rerun;
##   5. a binary with a `tests:` block test as well: one binary per test
##      fails the listing edge, naming that test and saying to use
##      `testCase` or turn `perTestBinaries` off, before any compile is
##      created. Control: one binary for every test lists and runs it.
##
## Measured and recorded, not asserted: an edit that moves `alpha`'s lines
## (a line inserted above it). Case 3 prints, for each test, whether its
## binary changed and whether its run reran. A test's line numbers are in
## its binary, so the expectation is that every test below the inserted
## line reruns.
##
## nim-entrypoints is found as this repository's `config.nims` finds it (the
## `../nim-entrypoints` checkout, else `$ENTRYPOINTS_SRC`;
## `REPRO_SIBLING_POLICY=pin` takes `$ENTRYPOINTS_SRC` even when the checkout
## exists), and must be one that has `-d:entrypointsTest`.
##
## MOCKS: none in the positive cases. The real `repro` of this build compiles
## the fixture's recipe, compiles the test binary with the real Nim, runs the
## real `repro-tests-fragment` under the io monitor, and the engine creates,
## monitors and caches the per-test runs. The negative control's producer is
## a shell script standing in for `repro-tests-fragment`: it is the thing the
## control varies.

import std/[json, os, strtabs, strutils, tempfiles, unittest]

import repro_test_support
import repro_test_support/process_fixtures

const
  FixtureDir = ReprobuildRepoRoot / "tests" / "fixtures" /
    "cs_m14_tests_per_entry"
  CollectorId = "cs_m14.tests"
  ListingId = CollectorId & ".list"
  CompileId = "cs_m14.compile"
  TestNames = ["alpha", "beta", "gamma"]
  BinaryTail = "build/test-bin/per_entry_suite"
  Marker = "CSM14MARKER "
  BetaBody = "echo \"CSM14MARKER beta\" # beta's body"
  BetaEdited = "stdout.writeLine \"CSM14MARKER beta\" # beta's body"
    ## The same output from other code, on the same line.
  AlphaLine = "testCase \"alpha\":"
  MainLine = "\nmain:\n"
  FrameworkBlock = "\ntemplate suite(name: string; body: untyped) = body\n" &
    "template test(name: string; body: untyped) = body\n\ntests:\n" &
    "  suite \"block\":\n    test \"framework\":\n" &
    "      echo \"CSM14MARKER framework\"\n"
    ## A `tests:` block of one test, listed as `block::framework`. Its
    ## framework is the two templates above, not `std/unittest`: the Nim this
    ## repository's dev shell provides is a fork whose `std/unittest` points
    ## descriptor 1 at standard error at start-up whenever the arguments hold
    ## `--list`, so a binary importing it answers `--entrypoint=tests --list`
    ## on standard error and the listing edge reads no tests. nim-entrypoints
    ## finds a block's tests by their `suite`/`test` syntax, so any framework
    ## of that shape is listed and guarded the same way.
  ReuseStatuses = ["asUpToDate", "asCacheHit"]
  ReuseDecisions = ["cdHit", "cdHybridCutoff"]

proc entrypointsSrc(): string =
  ## nim-entrypoints' `src/`, as this repository's `config.nims` finds it:
  ## the `../nim-entrypoints` checkout, else `$ENTRYPOINTS_SRC`, and
  ## `$ENTRYPOINTS_SRC` first under `REPRO_SIBLING_POLICY=pin`.
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

proc writeSource(p: Project; betaBody = BetaBody; aboveAlpha = "";
                 aboveMain = "") =
  ## The fixture's test source with `beta`'s line replaced by `betaBody`,
  ## and `aboveAlpha` and `aboveMain` (whole lines) inserted above `alpha`
  ## and above `main:`.
  let source = readFile(FixtureDir / "src" / "per_entry_suite.nim")
  doAssert BetaBody in source and AlphaLine in source and
    MainLine in source
  writeFile(p.root / "src" / "per_entry_suite.nim", source
    .replace(BetaBody, betaBody)
    .replace(AlphaLine, aboveAlpha & AlphaLine)
    .replace(MainLine, aboveMain & MainLine))

proc projectWith(producer = ""; betaBody = BetaBody;
                 perTestBinaries = false; aboveMain = ""): Project =
  ## A scratch copy of the fixture with its placeholders filled in;
  ## `producer` is the listing edge's producer ("" for the engine's own),
  ## `betaBody` the line `beta` runs, `perTestBinaries` whether each test
  ## gets a binary of its own.
  let entrypoints = entrypointsSrc()
  doAssert fileExists(entrypoints / "entrypoints" / "tests.nim"),
    "nim-entrypoints not found: no ../nim-entrypoints beside this checkout " &
    "and no $ENTRYPOINTS_SRC"
  let testsModule = readFile(entrypoints / "entrypoints" / "tests.nim")
  doAssert "--run-exact" in testsModule, entrypoints &
    " predates --run-exact"
  doAssert "entrypointsTest" in testsModule, entrypoints &
    " predates -d:entrypointsTest (one binary per test)"
  result.scratch = expandFilename(createTempDir("cs-m14-per-entry-", ""))
  releaseDirAtProcessExit(result.scratch)
  result.root = result.scratch / "project"
  result.reportDir = result.scratch / "reports"
  createDir(result.root / "src")
  createDir(result.reportDir)
  let backend = when defined(macosx): "clang" else: "gcc"
  writeFile(result.root / "repro.nim", readFile(FixtureDir / "repro.nim")
    .replace("__ENTRYPOINTS_SRC__", entrypoints)
    .replace("__NATIVE_BACKEND__", backend)
    .replace("__TESTS_FRAGMENT_PRODUCER__", producer)
    .replace("__PER_TEST_BINARIES__", $perTestBinaries))
  result.writeSource(betaBody, aboveMain = aboveMain)

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
  let env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  env["REPROBUILD_REPO_ROOT"] = repoRoot
  env["REPROBUILD_LIBS_DIR"] = repoRoot / "libs"
  env["REPRO_MONITOR_SHIM_LIB"] = shim
  env.del("LD_PRELOAD")
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

type PerTestRun = object
  id: string
  argv: seq[string]
  status: string
  launched: bool
  decision: string
  stdout: string

proc createdActions(report: JsonNode; collector, kind: string):
    seq[PerTestRun] =
  ## The actions the collector's fragment created whose id is
  ## `<collector>.<kind>.<...>` (`test` for the runs, `compile` for the
  ## per-test compiles), with the argv the engine recorded for each and its
  ## outcome, in creation order.
  if report.kind != JObject:
    return
  var ids: seq[string] = @[]
  for event in report{"trace"}:
    if event{"event"}.getStr() == "action-create" and
        event{"detail"}.getStr() == "producer=" & collector and
        event{"actionId"}.getStr().startsWith(collector & "." & kind & "."):
      ids.add(event{"actionId"}.getStr())
  for id in ids:
    var run = PerTestRun(id: id)
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

proc perTestRuns(report: JsonNode; collector: string): seq[PerTestRun] =
  report.createdActions(collector, "test")

proc perTestCompiles(report: JsonNode; collector: string): seq[PerTestRun] =
  report.createdActions(collector, "compile")

proc perTestBinary(name: string): string =
  ## Where test `name`'s own binary is, under the project root.
  addFileExt((BinaryTail & ".per-test") / name / BinaryTail.extractFilename,
    ExeExt)

proc reran(run: PerTestRun): bool =
  ## Whether the run was executed rather than served from the cache.
  run.launched and run.decision notin ReuseDecisions

proc runFor(runs: seq[PerTestRun]; name: string): PerTestRun =
  ## The run whose argv selects exactly the test `name`.
  for run in runs:
    if run.argv.len == 3 and run.argv[1 .. 2] ==
        @["--entrypoint=tests", "--run-exact=" & name]:
      return run
  PerTestRun()

proc isPerTestCollection(runs: seq[PerTestRun]; names: openArray[string];
                         perTestBinaries = false): bool =
  ## One run per test, each running the tests entry of the test binary (or,
  ## with `perTestBinaries`, of that test's own binary) with exactly that
  ## test selected, and nothing else.
  if runs.len != names.len:
    return false
  for name in names:
    let run = runs.runFor(name)
    let binary =
      if perTestBinaries: perTestBinary(name)
      else: addFileExt(BinaryTail, ExeExt)
    if run.id.len == 0 or not run.argv[0].endsWith(binary):
      return false
  true

proc describe(runs: seq[PerTestRun]): string =
  for run in runs:
    result.add(run.id & " argv=" & $run.argv & " status=" & run.status &
      " launched=" & $run.launched & " decision=" & run.decision & "\n")

proc markers(output: string): seq[string] =
  for line in output.splitLines():
    let at = line.find(Marker)
    if at >= 0:
      result.add(line[at + Marker.len .. ^1].strip())

suite "test_cs_m14_repro_collects_tests_per_entry":

  test "repro test runs each test as its own action, and caches each":
    let p = projectWith()
    let first = p.reproTest("first")
    check first.code == 0
    let listing = first.report.action(ListingId)
    checkpoint("listing: " & $listing)
    check listing{"status"}.getStr() == "asSucceeded"
    check listing{"launched"}.getBool()
    check first.report.action(CompileId){"status"}.getStr() == "asSucceeded"

    let runs = first.report.perTestRuns(CollectorId)
    checkpoint("first:\n" & runs.describe)
    check runs.isPerTestCollection(TestNames)
    for name in TestNames:
      let run = runs.runFor(name)
      check run.id == CollectorId & ".test." & name
      check run.status == "asSucceeded"
      check run.launched
      # Out of band: the run printed its own test's marker and no other.
      check run.stdout.markers == @[name]
    check first.report.action(CollectorId){"status"}.getStr() ==
      "asSucceeded"

    # Nothing changed: the listing replays its fragment, and each test's
    # run is served from the cache without launching.
    let second = p.reproTest("second")
    check second.code == 0
    check not second.report.action(ListingId){"launched"}.getBool(true)
    let again = second.report.perTestRuns(CollectorId)
    checkpoint("second:\n" & again.describe)
    check again.isPerTestCollection(TestNames)
    for name in TestNames:
      let run = again.runFor(name)
      check run.status in ReuseStatuses
      check run.decision in ReuseDecisions
      check not run.launched

  test "a failing beta fails only beta's action and the command":
    let p = projectWith(betaBody =
      "doAssert false, \"CSM14MARKER beta fails\"")
    let failing = p.reproTest("failing")
    check failing.code != 0
    check failing.report.action(ListingId){"status"}.getStr() ==
      "asSucceeded"
    let runs = failing.report.perTestRuns(CollectorId)
    checkpoint("failing:\n" & runs.describe)
    check runs.isPerTestCollection(TestNames)
    check runs.runFor("alpha").status == "asSucceeded"
    check runs.runFor("gamma").status == "asSucceeded"
    check runs.runFor("beta").status == "asFailed"
    var failed = 0
    for run in runs:
      if run.status == "asFailed":
        inc failed
    check failed == 1
    # The collector waits for every test, so it does not succeed.
    check failing.report.action(CollectorId){"status"}.getStr() !=
      "asSucceeded"

  test "negative control: a whole-binary producer fails the per-test count":
    # Stands in for `repro-tests-fragment`, taking its arguments, but writes
    # ONE record that runs the whole binary.
    let tools = expandFilename(createTempDir("cs-m14-whole-binary-", ""))
    releaseDirAtProcessExit(tools)
    let producer = tools / "whole-binary-producer"
    writeFile(producer, """#!/bin/sh
set -eu
binary= out= collector= cwd=. check=
for arg in "$@"; do
  case "$arg" in
    --binary=*) binary=${arg#--binary=} ;;
    --out=*) out=${arg#--out=} ;;
    --collector=*) collector=${arg#--collector=} ;;
    --cwd=*) cwd=${arg#--cwd=} ;;
    --check=*) check=${arg#--check=} ;;
  esac
done
if [ -n "$check" ]; then
  echo "whole-binary producer: collected $check"
  exit 0
fi
mkdir -p "$(dirname "$out")"
printf 'repro-dynamic-graph-v1\ncreate-action\t{"id":"%s.test.whole","argv":["%s","--entrypoint=tests"],"cwd":"%s","inputs":["%s"],"dependencyPolicy":{"kind":"automaticMonitor"},"cacheable":true}\ndep\t%s\t%s.test.whole\n' \
  "$collector" "$binary" "$cwd" "$binary" "$collector" "$collector" > "$out"
""")
    setFilePermissions(producer, {fpUserRead, fpUserWrite, fpUserExec})
    let p = projectWith(producer = producer)
    let whole = p.reproTest("whole-binary")
    # The build itself passes: the whole binary's three tests pass.
    check whole.code == 0
    let runs = whole.report.perTestRuns(CollectorId)
    checkpoint("whole binary:\n" & runs.describe)
    check runs.len == 1
    if runs.len == 1:
      check runs[0].status == "asSucceeded"
      check runs[0].stdout.markers == @["alpha", "beta", "gamma"]
    # The check the positive cases rely on rejects it.
    check not runs.isPerTestCollection(TestNames)

  test "with one binary per test, an edit of beta's body reruns only beta":
    let p = projectWith(perTestBinaries = true)
    let first = p.reproTest("first")
    check first.code == 0
    let compiles = first.report.perTestCompiles(CollectorId)
    let runs = first.report.perTestRuns(CollectorId)
    checkpoint("first:\n" & compiles.describe & runs.describe)
    check runs.isPerTestCollection(TestNames, perTestBinaries = true)
    check compiles.len == TestNames.len
    for name in TestNames:
      var compile = PerTestRun()
      for c in compiles:
        if c.id == CollectorId & ".compile." & name:
          compile = c
      check compile.status == "asSucceeded"
      check ("-d:entrypointsTest=" & name) in compile.argv
      var outputs: seq[string] = @[]
      for arg in compile.argv:
        if arg.startsWith("--out:"):
          outputs.add(arg)
      check outputs.len == 1 and outputs[0].endsWith(perTestBinary(name))
      let run = runs.runFor(name)
      check run.id == CollectorId & ".test." & name
      check run.status == "asSucceeded"
      check run.launched
      check run.stdout.markers == @[name]
    var before: seq[string] = @[]
    for name in TestNames:
      before.add(readFile(p.root / perTestBinary(name)))

    # beta's body: other code, the same output, the same line count.
    p.writeSource(betaBody = BetaEdited)
    let second = p.reproTest("beta-edited")
    check second.code == 0
    # The listed binary changed, so its compile and the listing ran again.
    check second.report.action(CompileId){"launched"}.getBool()
    check second.report.action(ListingId){"launched"}.getBool()
    let recompiles = second.report.perTestCompiles(CollectorId)
    let reruns = second.report.perTestRuns(CollectorId)
    checkpoint("beta edited:\n" & recompiles.describe & reruns.describe)
    # Printed on success too: the reruns are the round's evidence.
    for run in recompiles & reruns:
      echo "beta edited: ", run.id, " status=", run.status, " decision=",
        run.decision, " launched=", run.launched
    check reruns.isPerTestCollection(TestNames, perTestBinaries = true)
    # Every test's compile read the edited source, so each ran again ...
    check recompiles.len == TestNames.len
    for c in recompiles:
      check c.status == "asSucceeded"
      check c.reran
    # ... and only beta's binary changed (compared as booleans, so a
    # failure does not print the binaries).
    var same: seq[bool] = @[]
    for i, name in TestNames:
      same.add(readFile(p.root / perTestBinary(name)) == before[i])
    check same == @[true, false, true]
    # The reruns, from the engine's report: beta's run alone.
    for name in TestNames:
      let run = reruns.runFor(name)
      if name == "beta":
        check run.status == "asSucceeded"
        check run.launched
        check run.decision notin ReuseDecisions
        check run.stdout.markers == @["beta"]
      else:
        check run.status in ReuseStatuses
        check run.decision in ReuseDecisions
        check not run.launched
    var rerun: seq[string] = @[]
    for run in reruns:
      if run.reran:
        rerun.add(run.id)
    check rerun == @[CollectorId & ".test.beta"]

    # Measured, not asserted: a line inserted above alpha moves the line
    # numbers of every test, which are in each test's binary.
    var afterBeta: seq[string] = @[]
    for name in TestNames:
      afterBeta.add(readFile(p.root / perTestBinary(name)))
    p.writeSource(betaBody = BetaEdited,
      aboveAlpha = "# a line that moves alpha down\n")
    let third = p.reproTest("alpha-moved")
    check third.code == 0
    let moved = third.report.perTestRuns(CollectorId)
    var record = "measured, alpha's lines moved by one:"
    for i, name in TestNames:
      let run = moved.runFor(name)
      let changed = readFile(p.root / perTestBinary(name)) != afterBeta[i]
      record.add(" " & name & ": binary " &
        (if changed: "changed" else: "unchanged") & ", run " &
        (if run.reran: "reran" else: "cached") & " (" & run.status & "/" &
        run.decision & ");")
    checkpoint(record)
    echo record

  test "negative control: with one binary, the same edit reruns all three":
    let p = projectWith()
    let first = p.reproTest("first")
    check first.code == 0
    check first.report.perTestRuns(CollectorId).isPerTestCollection(TestNames)
    p.writeSource(betaBody = BetaEdited)
    let second = p.reproTest("beta-edited")
    check second.code == 0
    let reruns = second.report.perTestRuns(CollectorId)
    checkpoint("beta edited, one binary:\n" & reruns.describe)
    check reruns.isPerTestCollection(TestNames)
    # No per-test compiles in this mode.
    check second.report.perTestCompiles(CollectorId).len == 0
    var rerun: seq[string] = @[]
    for run in reruns:
      check run.status == "asSucceeded"
      if run.reran:
        rerun.add(run.id)
    check rerun == @[CollectorId & ".test.alpha", CollectorId & ".test.beta",
      CollectorId & ".test.gamma"]

  test "with one binary per test, a tests: block's test is refused by name":
    let p = projectWith(perTestBinaries = true, aboveMain = FrameworkBlock)
    let refused = p.reproTest("framework-block")
    check refused.code != 0
    let listing = refused.report.action(ListingId)
    checkpoint("listing: " & $listing & "\n" & refused.output)
    check listing{"status"}.getStr() == "asFailed"
    # The refusal names the test and the two ways out, in the listing
    # edge's output or the command's.
    let said = $listing & refused.output
    check "block::framework" in said
    check "testCase" in said
    check "perTestBinaries off" in said
    # Refused before any compile was created.
    check refused.report.perTestCompiles(CollectorId).len == 0
    check refused.report.perTestRuns(CollectorId).len == 0

    # Control: with one binary for every test, the same source lists the
    # block's test too and runs it as its own action.
    let whole = projectWith(aboveMain = FrameworkBlock)
    let all = whole.reproTest("framework-block-one-binary")
    check all.code == 0
    let runs = all.report.perTestRuns(CollectorId)
    checkpoint("one binary:\n" & runs.describe)
    check runs.isPerTestCollection(@TestNames & @["block::framework"])
    check runs.runFor("block::framework").stdout.markers == @["framework"]
