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
## Still to come (round 4): "changing one test reruns only that test", with
## one binary per test. `projectWith` already writes a variant of the test
## source; that round adds the edit of `beta`'s body and the reruns it
## expects. With one binary for all three tests, as here, any edit of the
## source changes the binary every run is keyed on, so all three rerun.
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
  ReuseStatuses = ["asUpToDate", "asCacheHit"]
  ReuseDecisions = ["cdHit", "cdHybridCutoff"]

proc entrypointsSrc(): string =
  ## nim-entrypoints' `src/`, as this repository's `config.nims` finds it:
  ## the `../nim-entrypoints` checkout, else `$ENTRYPOINTS_SRC`.
  let sibling = ReprobuildRepoRoot.parentDir / "nim-entrypoints" / "src"
  if fileExists(sibling / "entrypoints.nim"):
    return sibling
  getEnv("ENTRYPOINTS_SRC")

type Project = object
  scratch: string
  root: string
  reportDir: string

proc projectWith(producer = ""; betaBody = BetaBody): Project =
  ## A scratch copy of the fixture with its placeholders filled in;
  ## `producer` is the listing edge's producer ("" for the engine's own),
  ## `betaBody` the line `beta` runs.
  let entrypoints = entrypointsSrc()
  doAssert fileExists(entrypoints / "entrypoints" / "tests.nim"),
    "nim-entrypoints not found: no ../nim-entrypoints beside this checkout " &
    "and no $ENTRYPOINTS_SRC"
  doAssert "--run-exact" in readFile(entrypoints / "entrypoints" /
    "tests.nim"), entrypoints & " predates --run-exact"
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
    .replace("__TESTS_FRAGMENT_PRODUCER__", producer))
  let source = readFile(FixtureDir / "src" / "per_entry_suite.nim")
  doAssert BetaBody in source
  writeFile(result.root / "src" / "per_entry_suite.nim",
    source.replace(BetaBody, betaBody))

proc reproTest(p: Project; label: string): tuple[code: int; report: JsonNode] =
  ## `repro test` in the project, with this checkout's `repro` and DSL, and
  ## the report it writes.
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

proc perTestRuns(report: JsonNode; collector: string): seq[PerTestRun] =
  ## The actions the collector's fragment created, with the argv the engine
  ## recorded for each and its outcome, in creation order.
  if report.kind != JObject:
    return
  var ids: seq[string] = @[]
  for event in report{"trace"}:
    if event{"event"}.getStr() == "action-create" and
        event{"detail"}.getStr() == "producer=" & collector:
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

proc runFor(runs: seq[PerTestRun]; name: string): PerTestRun =
  ## The run whose argv selects exactly the test `name`.
  for run in runs:
    if run.argv.len == 3 and run.argv[1 .. 2] ==
        @["--entrypoint=tests", "--run-exact=" & name]:
      return run
  PerTestRun()

proc isPerTestCollection(runs: seq[PerTestRun];
                         names: openArray[string]): bool =
  ## One run per test, each running the test binary's tests entry with
  ## exactly that test selected, and nothing else.
  if runs.len != names.len:
    return false
  for name in names:
    let run = runs.runFor(name)
    if run.id.len == 0 or
        not run.argv[0].endsWith(addFileExt(BinaryTail, ExeExt)):
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
