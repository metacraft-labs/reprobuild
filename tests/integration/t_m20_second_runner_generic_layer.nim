## M20 / OS-8: a SECOND, NON-CODETRACER RUNNER populates
## ``ext_test_execution``, and ``stats flaky`` / ``stats duration`` cannot
## tell the two runners' rows apart.
##
## Gate (``reprobuild-specs/RunQuota-Observation-Store.milestones.org``
## §M20): "A non-CodeTracer runner via ``reprobuild-test-adapters`` writes
## ``ext_test_execution`` rows that ``stats flaky``/``duration`` query
## indistinguishably from CodeTracer's. Asserts no CodeTracer-specific
## column is required to record a test outcome."
##
## And the milestone's own note on why it exists: "Without it, CodeTracer's
## schema becomes the de facto generic one without ever having been
## designed as such."
##
## NO MOCKS, AND NOTHING SUBSTITUTED. Every arm starts the real
## ``runquotad`` on a real Unix-domain socket and drives TWO REAL RUNNER
## BINARIES against it — ``build/bin/repro_test_runner`` (CodeTracer's,
## M19's subject) and ``build/bin/repro_tap_test_runner`` (the TAP runner
## built on ``reprobuild-test-adapters``). The answers are read back
## through the real RQSP query interface and through the real
## ``stats flaky`` / ``stats duration`` surface, invoked as a subprocess.
## Nothing here writes a row and nothing here opens the store's database.
##
## WHAT "INDISTINGUISHABLY" IS ASSERTED TO MEAN, AND WHY THE WEAKER FORM
## WOULD PROVE NOTHING. A test that ran one runner and checked its rows
## look right passes against a store the other runner cannot write at all.
## So both runners' rows go through ONE query, and the two answers are
## required to be IDENTICAL once the test's own name is removed — same
## field set, same values, no field naming a runner, a framework or a
## language. The fixtures are built so the two runners produce the SAME
## flakiness pattern (three executions, one failure), which is what makes
## "identical" a meaningful demand rather than an accident of shape.
##
## AND THE CONVERSE, WITHOUT WHICH THE ABOVE IS SATISFIED BY A QUERY THAT
## DISTINGUISHES NOTHING AT ALL. A query that SHOULD tell them apart — by
## extension table — must still be able to: ``ext_codetracer_test`` carries
## rows for exactly the CodeTracer executions and for none of the TAP ones.
## The generic layer is shared; the framework layer is not; and both halves
## are asserted in the same run against the same store.

import std/[algorithm, json, os, osproc, posix, sequtils, sets, streams,
    strutils, tables, tempfiles, times, unittest]

import repro_test_support

import runquota_client
import runquota_protocol

const
  GenericExtensionId = "test_execution"
  CodetracerExtensionId = "codetracer_test"
  NullMarker = "~"
    ## How the store renders SQL NULL on the wire, so a column a runner
    ## deliberately left absent stays distinguishable from the empty
    ## string. Load-bearing here: TAP has no suite and no per-case output
    ## sizes, and "absent" is the whole claim being made about them.

  GenericColumns = ["test_id", "suite", "status", "duration_ms", "attempt",
    "retry_of", "error_message", "skip_reason", "stdout_len", "stderr_len"]
  CodetracerColumns = ["recording_path", "trace_id", "trace_format_version",
    "recorder", "replay_ok", "protocol_aware", "run_name", "body_hash",
    "checkpoint_count", "status_disagreement", "harness_error"]

  Runs = 3
    ## Three executions of each fixture, one of which fails. Two would
    ## give a 50% flake rate that a "half the runs failed" bug also
    ## produces; three separates "flaky" from "alternating".

  CtFlakyTestId = "m20Flaky::sometimes"
  CtStableTestId = "m20Flaky::always"
  TapFlakyTestId = "tap_sometimes"
  TapStableTestId = "tap_always"
  TapUntimedTestId = "tap_untimed"

  CtTests = 2
  TapTests = 3

  FrameworkTokens = ["codetracer", "nim", "unittest", "ct_", "ct-", "trace",
    "recorder", "replay", "checkpoint", "tap", "junit", "pytest", "cargo",
    "nextest", "rspec", "gtest", "runner", "framework"]
    ## Words that name ONE framework, ONE language, ONE protocol or ONE
    ## runner. None of them may appear in a KEY of the flaky or duration
    ## answer: a field a reader could use to tell which runner produced an
    ## entry is the failure OS-8 describes, arriving through the query
    ## surface rather than through the schema.

proc repoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / "repro.nim") and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError, "cannot locate reprobuild repo root")

proc requireBin(name: string): string =
  ## ``build/bin/<name>`` is an INPUT to this test, not an output of
  ## compiling it. A run that recompiled only this file would drive
  ## whatever binary happened to be on disk — so a missing one is a hard
  ## error rather than a skip, and a skip here would make every assertion
  ## below vacuous.
  let path = repoRoot() / "build" / "bin" / addFileExt(name, ExeExt)
  if not fileExists(path):
    raise newException(OSError,
      name & " missing at " & path & "; build it before running this test")
  path

proc socketIsBound(path: string): bool =
  var info: Stat
  lstat(path.cstring, info) == 0 and S_ISSOCK(info.st_mode)

proc rendezvousDir(root: string): string =
  result = root / "ep"
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

type DaemonHandle = object
  process: Process

proc startRunQuotaDaemon(socketPath, identityFile: string): DaemonHandle =
  let process = startProcess(requireRunQuotaDaemonBin(repoRoot()),
    args = @["--socket", socketPath,
             "--host-identity-file", identityFile,
             "--ambient-sample-interval-millis", "0"],
    options = {poStdErrToStdOut})
  for _ in 0 ..< 400:
    if socketIsBound(socketPath): break
    sleep(25)
  for _ in 0 ..< 3:
    discard process.outputStream.readLine()
  DaemonHandle(process: process)

proc stop(handle: var DaemonHandle) =
  if handle.process.running:
    handle.process.terminate()
    discard handle.process.waitForExit(5000)
  if handle.process.running:
    handle.process.kill()
    discard handle.process.waitForExit(5000)
  handle.process.close()

# ---------------------------------------------------------------------------
# Fixtures
#
# THE TWO FIXTURES PRODUCE THE SAME PATTERN THROUGH COMPLETELY DIFFERENT
# MACHINERY, which is the point of the comparison downstream. One is a Nim
# binary speaking CodeTracer's ``--list-json`` protocol and reporting through
# ``std/unittest``; the other is a POSIX shell script printing TAP 13 lines.
# They share a language, a runtime and a reporting mechanism in exactly no
# respect.
# ---------------------------------------------------------------------------

proc writeCtFixture(path, counterPath: string) =
  ## Fails on the SECOND execution of ``sometimes`` and passes on the other
  ## two, driven by a counter file that survives across runner invocations.
  ## ``always`` passes every time and is the negative control: a flaky
  ## report that listed it would be reporting every test as flaky.
  writeFile(path, """
import std/[os, strutils]
import ct_test_unittest_parallel

const CounterPath = "$COUNTER"

proc bump(): int =
  var n = 0
  try:
    n = parseInt(readFile(CounterPath).strip())
  except CatchableError:
    n = 0
  n += 1
  writeFile(CounterPath, $n)
  n

suite "m20Flaky":
  test "always":
    # THE SLEEP IS THE MEASUREMENT, NOT PADDING. Without it these cases
    # run in under a millisecond and report ``duration_ms = 0`` — which
    # is a correct measurement and makes every "the duration query
    # computed something" assertion unfalsifiable, because zero is also
    # what a query that computes nothing returns.
    sleep(20)
    check 1 == 1
  test "sometimes":
    sleep(20)
    check bump() != 2
""".replace("$COUNTER", counterPath))

proc writeTapFixture(path, counterPath: string) =
  ## The same pattern from a shell script emitting TAP 13. It reports a
  ## per-case ``duration_ms`` in the YAML diagnostic block — which is what
  ## ``stats duration`` reads — and reports NO suite and NO per-case output
  ## sizes, because TAP has neither.
  writeFile(path, """#!/bin/sh
COUNTER="$COUNTER"
n=$(cat "$COUNTER" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$COUNTER"
echo "TAP version 13"
echo "1..3"
echo "ok 1 - tap_always"
echo "  ---"
echo "  duration_ms: 3"
echo "  ..."
if [ "$n" -eq 2 ]; then
  echo "not ok 2 - tap_sometimes"
  echo "  ---"
  echo "  message: 'nondeterministic failure on execution 2'"
  echo "  duration_ms: 7"
  echo "  ..."
else
  echo "ok 2 - tap_sometimes"
  echo "  ---"
  echo "  duration_ms: 5"
  echo "  ..."
fi
# A CASE THAT REPORTS NO DURATION AT ALL, which TAP permits and which a
# runner must not turn into a zero. It is here so the "NULL is excluded
# from the sample, never averaged as zero" rule has a row to be true of;
# without it every duration in the fixture is present and the rule is
# asserted against a case that cannot occur.
echo "ok 3 - tap_untimed"
""".replace("$COUNTER", counterPath))
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc compileCtFixture(repoRoot, workRoot, source, binary: string): bool =
  let shimSrc = repoRoot / "libs" / "ct_test_unittest_parallel" / "src"
  let cmd = "nim c --threads:on --hints:off --warnings:off " &
    "--path:" & quoteShell(shimSrc) & " " &
    "--nimcache:" & quoteShell(workRoot / ("nimcache-" & splitFile(source).name)) &
      " " &
    "--out:" & quoteShell(binary) & " " &
    quoteShell(source)
  execCmd(cmd) == 0

# ---------------------------------------------------------------------------
# Reading back over RQSP
# ---------------------------------------------------------------------------

type ExtRow = object
  executionId: string
  hostId: string
  profileId: string
  values: Table[string, string]

proc readExtRows(socketPath, extensionId: string;
                 columns: openArray[string]): seq[ExtRow] =
  putEnv("RUNQUOTA_SOCKET", socketPath)
  var client = connectDefault()
  defer: client.close()
  let answer = client.queryStats(statsSubjectExtensionRows,
    extensionId = extensionId, extensionColumns = columns)
  for entry in answer.extensionRows:
    var row = ExtRow(
      executionId: entry.executionId,
      hostId: entry.hostId,
      profileId: entry.profile.profileId,
      values: initTable[string, string]())
    for i, name in entry.columns:
      row.values[name] = entry.values[i]
    result.add(row)

proc waitForExtRows(socketPath, extensionId: string;
                    columns: openArray[string]; atLeast: int): seq[ExtRow] =
  ## The observation writer drains on a tick, so a query issued
  ## immediately after a run can legitimately see nothing yet. Polling for
  ## a MINIMUM (never a maximum) cannot turn an absent row into a present
  ## one.
  let deadline = epochTime() + 60.0
  while epochTime() < deadline:
    result = readExtRows(socketPath, extensionId, columns)
    if result.len >= atLeast:
      return
    sleep(150)

proc rowsFor(rows: seq[ExtRow]; testId: string): seq[ExtRow] =
  for row in rows:
    if row.values.getOrDefault("test_id") == testId:
      result.add(row)

# ---------------------------------------------------------------------------
# The query surface under test
# ---------------------------------------------------------------------------

proc runStatsQuery(socketPath, subcommand: string): JsonNode =
  ## ``stats flaky`` / ``stats duration`` as a real subprocess against the
  ## real store. The SAME binary and the SAME invocation answer for both
  ## runners; there is no per-runner query and no way to ask for one.
  putEnv("RUNQUOTA_SOCKET", socketPath)
  let (output, code) = execCmdEx(quoteShell(requireBin("repro_test_runner")) &
    " stats " & subcommand & " --json")
  if code != 0:
    raise newException(ValueError,
      "stats " & subcommand & " exited " & $code & ": " & output)
  parseJson(output)

proc entryFor(answer: JsonNode; testId: string): JsonNode =
  for row in answer{"rows"}:
    if row{"testId"}.getStr() == testId:
      return row
  nil

proc withoutTestId(entry: JsonNode): JsonNode =
  ## The entry with the only field that legitimately differs removed.
  ## Whatever is left must be identical for the two runners, because
  ## nothing left describes anything but the executions themselves.
  ##
  ## NIL-TOLERANT ON PURPOSE. ``check`` records a failure and carries on,
  ## so an arm that has already found a missing entry reaches here anyway;
  ## dereferencing nil there would turn a diagnosable red into a
  ## segmentation fault, and a crashed mutation run says much less than a
  ## failed one.
  result = newJObject()
  if entry == nil:
    return
  for key, value in entry:
    if key != "testId":
      result[key] = value

proc keysOf(entry: JsonNode): seq[string] =
  if entry == nil: @[] else: toSeq(entry.keys).sorted()

proc present(entry: JsonNode): bool = entry != nil
  ## ``check e != nil`` CANNOT BE USED ON A ``JsonNode`` HERE. ``check``
  ## stringifies its operands when it fails, and ``$`` on a nil
  ## ``JsonNode`` segfaults — so the one formulation that reads naturally
  ## turns every red into a crash with no failing line named. Reduced to a
  ## bool before the assertion sees it.

# ---------------------------------------------------------------------------

type RunEnvironment = object
  tempRoot: string
  socketRoot: string
  socketPath: string
  ctBinDir: string
  tapBinDir: string
  resultsDir: string
  daemon: DaemonHandle
  previousSocket: string

proc setUpRun(tag: string): RunEnvironment =
  result.tempRoot = createTempDir("repro-m20-" & tag & "-", "")
  result.previousSocket = getEnv("RUNQUOTA_SOCKET", "")
  # A SHORT SOCKET ROOT: a Unix-domain socket path has a ~104 byte ceiling
  # and ``createTempDir``'s root is long enough on some hosts that the
  # daemon dies on ``bindUnix`` before it ever listens.
  result.socketRoot = getTempDir() / ("rq-m20-" & tag & "-" &
    $getCurrentProcessId())
  removeDir(result.socketRoot)
  createDir(result.socketRoot)
  result.socketPath = rendezvousDir(result.socketRoot) / "d.sock"
  let stateDir = result.socketRoot / "state"
  createDir(stateDir)
  result.daemon = startRunQuotaDaemon(result.socketPath, stateDir / "host-id")
  result.ctBinDir = result.tempRoot / "ct-bin"
  result.tapBinDir = result.tempRoot / "tap-bin"
  result.resultsDir = result.tempRoot / "results"
  createDir(result.ctBinDir)
  createDir(result.tapBinDir)
  createDir(result.tempRoot / "src")

proc tearDown(env: var RunEnvironment) =
  env.daemon.stop()
  putEnv("RUNQUOTA_SOCKET", env.previousSocket)
  removeDir(env.socketRoot)
  removeDir(env.tempRoot)

proc runCtRunner(env: RunEnvironment; tag: string): tuple[output: string;
    exitCode: int; summary: JsonNode] =
  let summaryPath = env.tempRoot / ("ct-summary-" & tag & ".json")
  let cmd = quoteShell(requireBin("repro_test_runner")) & " --no-build" &
    " --threads=2 --quiet --test-timeout=120" &
    " --bin-dir=" & quoteShell(env.ctBinDir) &
    " --summary-json=" & quoteShell(summaryPath) &
    " --results-dir=" & quoteShell(env.resultsDir / tag)
  putEnv("RUNQUOTA_SOCKET", env.socketPath)
  let (output, code) = execCmdEx(cmd)
  (output, code, parseJson(readFile(summaryPath)))

proc runTapRunner(env: RunEnvironment; tag: string): tuple[output: string;
    exitCode: int; summary: JsonNode] =
  let summaryPath = env.tempRoot / ("tap-summary-" & tag & ".json")
  let cmd = quoteShell(requireBin("repro_tap_test_runner")) &
    " --quiet" &
    " --bin-dir=" & quoteShell(env.tapBinDir) &
    " --summary-json=" & quoteShell(summaryPath)
  putEnv("RUNQUOTA_SOCKET", env.socketPath)
  let (output, code) = execCmdEx(cmd)
  (output, code, parseJson(readFile(summaryPath)))

proc buildFixtures(env: RunEnvironment) =
  ## RAISES RATHER THAN RETURNING FALSE. A fixture that did not compile
  ## makes every assertion downstream meaningless, and a ``check`` that
  ## merely records the failure lets the arm carry on and report a second,
  ## unrelated error from the first missing file.
  let ctSrc = env.tempRoot / "src" / "t_m20_ct.nim"
  writeCtFixture(ctSrc, env.tempRoot / "ct-counter")
  if not compileCtFixture(repoRoot(), env.tempRoot, ctSrc,
      env.ctBinDir / addFileExt("t_m20_ct", ExeExt)):
    raise newException(OSError, "M20 CodeTracer fixture did not compile")
  writeTapFixture(env.tapBinDir / "t_m20_tap.sh", env.tempRoot / "tap-counter")

suite "M20 a second runner populates the generic layer":

  test "both runners' rows land in one table and query indistinguishably":
    var env = setUpRun("both")
    defer: tearDown(env)
    buildFixtures(env)

    var ctExit: seq[int] = @[]
    var tapExit: seq[int] = @[]
    var ctTool = ""
    var tapTool = ""
    for run in 1 .. Runs:
      let ct = runCtRunner(env, "r" & $run)
      ctExit.add(ct.exitCode)
      check ct.summary["summary"]["runquota_history"].getBool()
      let tap = runTapRunner(env, "r" & $run)
      tapExit.add(tap.exitCode)
      check tap.summary["summary"]["runquota_history"].getBool()
      # THE TWO RUNNERS ARE DIFFERENT TOOLS AND SAY SO. RunQuota's ``runs``
      # dimension is where a runner's identity belongs; the shared ROW is
      # where it must not be. Recorded here so the "indistinguishable"
      # claim below is about the rows and not about a fixture in which the
      # two runners were the same program.
      tapTool = tap.summary["summary"]["tool"].getStr()
      ctTool = "ct-test-runner"
      check tap.summary["summary"]["recorded"].getInt() == TapTests
    check tapTool.len > 0
    check tapTool != ctTool
    # THE FIXTURES REALLY DID FLAKE. Exactly one of the three invocations
    # of each runner failed; if none had, the flaky report below would be
    # empty and every assertion about it would pass trivially.
    check ctExit.countIt(it != 0) == 1
    check tapExit.countIt(it != 0) == 1

    # --- one table, one extension id, both runners --------------------
    #
    # ONE QUERY, ONE EXTENSION ID. If the TAP runner had spelled the
    # registry triple itself and drifted, its rows would be in a second
    # table and this query would return only CodeTracer's — a failure
    # RunQuota reports nowhere, because ``declareExtension`` writes
    # ``owner`` once and never compares it again.
    let generic = waitForExtRows(env.socketPath, GenericExtensionId,
      GenericColumns, Runs * (CtTests + TapTests))
    check generic.len == Runs * (CtTests + TapTests)

    let ctFlaky = generic.rowsFor(CtFlakyTestId)
    let ctStable = generic.rowsFor(CtStableTestId)
    let tapFlaky = generic.rowsFor(TapFlakyTestId)
    let tapStable = generic.rowsFor(TapStableTestId)
    let tapUntimed = generic.rowsFor(TapUntimedTestId)
    check tapUntimed.len == Runs
    check ctFlaky.len == Runs
    check ctStable.len == Runs
    check tapFlaky.len == Runs
    check tapStable.len == Runs

    # Every one of them is a DISTINCT execution on the spine. A join that
    # attached all four rows of a test to one execution would satisfy a
    # count and mean the history has one sample, not three.
    var executionIds = initHashSet[string]()
    for row in generic:
      check row.executionId.len > 0
      check row.hostId.len > 0
      # OS-6: every answer is qualified by the hardware it describes.
      check row.profileId.len > 0
      executionIds.incl(row.executionId)
    check executionIds.len == Runs * (CtTests + TapTests)

    # --- the TAP rows are COMPLETE, and complete without inventing -----
    for row in tapFlaky & tapStable & tapUntimed:
      # The three ``not null`` columns, filled.
      check row.values["test_id"].len > 0
      check row.values["test_id"] != NullMarker
      check row.values["status"] in ["pass", "fail"]
      check row.values["attempt"] == "1"
      # AND THE FACTS TAP DOES NOT HAVE ARE ABSENT, NOT FABRICATED. This
      # is the half of OS-8 that a runner sharing CodeTracer's shape could
      # never exercise: ``suite`` is NULL because TAP has no suite, and the
      # output sizes are NULL because a TAP producer reports no per-case
      # split. An implementation that wrote "" or 0 would be asserting
      # facts nobody measured, and no reader could tell.
      check row.values["suite"] == NullMarker
      check row.values["stdout_len"] == NullMarker
      check row.values["stderr_len"] == NullMarker
      check row.values["retry_of"] == NullMarker
    # The one optional fact TAP producers CAN carry, so the NULLs above are
    # the absence and not the encoding — and the one case that carries none
    # writes NULL rather than 0.
    for row in tapFlaky & tapStable:
      check row.values["duration_ms"] != NullMarker
      check parseInt(row.values["duration_ms"]) > 0
    for row in tapUntimed:
      check row.values["duration_ms"] == NullMarker
    # The failing TAP execution carried its producer's own message through
    # the generic layer.
    check tapFlaky.countIt(it.values["status"] == "fail") == 1
    for row in tapFlaky:
      if row.values["status"] == "fail":
        check row.values["error_message"].contains("nondeterministic")

    # --- the converse control: a query that SHOULD distinguish still can
    #
    # Without this, "the two runners are indistinguishable" is satisfied
    # by a store in which nothing is distinguishable from anything.
    let codetracer = waitForExtRows(env.socketPath, CodetracerExtensionId,
      CodetracerColumns, Runs * 2)
    check codetracer.len == Runs * 2
    var codetracerExecutions = initHashSet[string]()
    for row in codetracer:
      codetracerExecutions.incl(row.executionId)
    var ctExecutions = initHashSet[string]()
    for row in ctFlaky & ctStable:
      ctExecutions.incl(row.executionId)
    var tapExecutions = initHashSet[string]()
    for row in tapFlaky & tapStable & tapUntimed:
      tapExecutions.incl(row.executionId)
    # Exactly the CodeTracer executions carry a CodeTracer row ...
    check codetracerExecutions == ctExecutions
    # ... and not one TAP execution does. THE TAP RUNNER NEVER DECLARED
    # THAT EXTENSION AT ALL, which is what "no CodeTracer-specific column
    # is required to record a test outcome" means when it is a fact about
    # a running client rather than about a DDL.
    check (codetracerExecutions * tapExecutions).len == 0
    check tapExecutions.len == Runs * TapTests

    # --- ONE QUERY, BOTH RUNNERS, IDENTICAL ANSWERS -------------------
    let flaky = runStatsQuery(env.socketPath, "flaky")
    check flaky{"window"}{"state"}.getStr() == "known"
    check flaky{"window"}{"rowCount"}.getInt() == Runs * (CtTests + TapTests)
    check flaky{"window"}{"profileIds"}.len >= 1

    let ctEntry = flaky.entryFor(CtFlakyTestId)
    let tapEntry = flaky.entryFor(TapFlakyTestId)
    # NON-VACUITY BEFORE COMPARISON: a query returning nothing for both
    # would make "the two are identical" trivially true.
    let ctEntryPresent = present(ctEntry)
    let tapEntryPresent = present(tapEntry)
    check ctEntryPresent
    check tapEntryPresent
    check ctEntry{"runs"}.getInt() == Runs
    check ctEntry{"failures"}.getInt() == 1
    # THE CLAUSE ITSELF. Same field set, same values, once the test's own
    # name is removed. A query that could tell which runner produced an
    # entry would differ somewhere in here.
    check withoutTestId(ctEntry) == withoutTestId(tapEntry)
    check keysOf(ctEntry) == keysOf(tapEntry)
    check keysOf(ctEntry).len > 0

    # AND THE NEGATIVE CONTROL, without which "flaky" could mean "every
    # test": the tests that passed every time are NOT listed.
    let ctStableListed = present(flaky.entryFor(CtStableTestId))
    let tapStableListed = present(flaky.entryFor(TapStableTestId))
    let tapUntimedListed = present(flaky.entryFor(TapUntimedTestId))
    check not ctStableListed
    check not tapStableListed
    check not tapUntimedListed

    # No key of the answer names a runner, a framework, a language or a
    # protocol — so a reader cannot recover the provenance the shared
    # layer deliberately does not carry.
    for row in flaky{"rows"}:
      for key in row.keys:
        for token in FrameworkTokens:
          checkpoint("flaky key " & key & " vs token " & token)
          check token notin key.toLowerAscii()

    let duration = runStatsQuery(env.socketPath, "duration")
    check duration{"window"}{"state"}.getStr() == "known"
    let ctDuration = duration.entryFor(CtFlakyTestId)
    let ctStableDuration = duration.entryFor(CtStableTestId)
    let tapDuration = duration.entryFor(TapFlakyTestId)
    let ctStableDurationPresent = present(ctStableDuration)
    let ctDurationPresent = present(ctDuration)
    let tapDurationPresent = present(tapDuration)
    check ctStableDurationPresent
    check ctDurationPresent
    check tapDurationPresent
    # SAME SAMPLE COUNT AND SAME FIELD SET. The MEASURED figures differ,
    # and must: they are two different tests taking two different amounts
    # of time. What may not differ is what the query can say about them.
    check keysOf(ctDuration) == keysOf(tapDuration)
    check keysOf(ctDuration).len > 0
    check ctDuration{"samples"}.getInt() == Runs
    check tapDuration{"samples"}.getInt() == Runs

    # THE EXACT CONTROL, AND IT IS THE TAP SIDE THAT SUPPLIES IT. The TAP
    # fixture DECLARES its per-case durations (5, 7, 5 ms for the flaky
    # case; 3 ms three times for the stable one), so the statistics over
    # them are arithmetic rather than timing: mean 17/3, nearest-rank
    # median 5, p90 and p99 7. Asserting them to the millisecond is what
    # makes the CodeTracer-side assertions below evidence of a working
    # computation rather than of a query that returns zeros for
    # everything.
    check abs(tapDuration{"meanMs"}.getFloat() - 17.0 / 3.0) < 0.001
    check tapDuration{"medianMs"}.getInt() == 5
    check tapDuration{"p90Ms"}.getInt() == 7
    check tapDuration{"p99Ms"}.getInt() == 7
    let tapStableDuration = duration.entryFor(TapStableTestId)
    let tapStableDurationPresent = present(tapStableDuration)
    check tapStableDurationPresent
    check tapStableDuration{"samples"}.getInt() == Runs
    check abs(tapStableDuration{"meanMs"}.getFloat() - 3.0) < 0.001
    check tapStableDuration{"medianMs"}.getInt() == 3

    # A CASE WHOSE RUNNER REPORTED NO DURATION HAS NO DURATION STATISTICS,
    # and says so with ``samples == 0`` rather than with a mean of zero.
    # An implementation that admitted the NULLs into the sample would
    # report three samples averaging zero here — a figure indistinguishable
    # from a test that genuinely took no measurable time.
    let tapUntimedDuration = duration.entryFor(TapUntimedTestId)
    let tapUntimedDurationPresent = present(tapUntimedDuration)
    check tapUntimedDurationPresent
    check tapUntimedDuration{"samples"}.getInt() == 0
    check tapUntimedDuration{"meanMs"}.getFloat() == 0.0

    # And the CodeTracer side, whose durations are MEASURED rather than
    # declared: the fixture sleeps 20 ms per case, so a floor of 10 ms is
    # a bound on a measured quantity and not on a sampled one — no
    # sampler decides it, the case's own clock does.
    for entry in [ctDuration, ctStableDuration]:
      check entry{"meanMs"}.getFloat() >= 10.0
      check entry{"medianMs"}.getInt() >= 10
      # Ordering, which any implementation that shuffled the percentiles
      # would break while still reporting plausible numbers.
      check entry{"medianMs"}.getInt() <= entry{"p90Ms"}.getInt()
      check entry{"p90Ms"}.getInt() <= entry{"p99Ms"}.getInt()
    for row in duration{"rows"}:
      for key in row.keys:
        for token in FrameworkTokens:
          checkpoint("duration key " & key & " vs token " & token)
          check token notin key.toLowerAscii()

  test "the TAP runner can declare the layer FIRST and CodeTracer's still fits":
    ## THE ORDER THE OTHER ARM CANNOT TEST. ``declareExtension`` takes the
    ## first declaration as the registry's own and never re-validates the
    ## ``owner`` of any later one, so in the arm above CodeTracer's
    ## declaration is the one that created the table and the TAP runner's
    ## agreement was never really put to the question. Here the TAP runner
    ## creates it, and CodeTracer's runner is the one that has to fit —
    ## which it can only do if the two are declaring the same version of
    ## the same ladder under the same id.
    var env = setUpRun("order")
    defer: tearDown(env)
    buildFixtures(env)

    let tap = runTapRunner(env, "first")
    check tap.exitCode == 0
    check tap.summary["summary"]["runquota_history"].getBool()
    check tap.summary["summary"]["recorded"].getInt() == TapTests

    # Non-vacuity: the TAP runner's rows are in the table BEFORE
    # CodeTracer's runner has ever connected to this daemon.
    let tapOnly = waitForExtRows(env.socketPath, GenericExtensionId,
      GenericColumns, TapTests)
    check tapOnly.len == TapTests
    check tapOnly.allIt(it.values["test_id"] in
      [TapFlakyTestId, TapStableTestId, TapUntimedTestId])

    let ct = runCtRunner(env, "second")
    check ct.summary["summary"]["runquota_history"].getBool()

    let both = waitForExtRows(env.socketPath, GenericExtensionId,
      GenericColumns, CtTests + TapTests)
    check both.len == CtTests + TapTests
    check both.rowsFor(CtStableTestId).len == 1
    check both.rowsFor(CtFlakyTestId).len == 1
    check both.rowsFor(TapStableTestId).len == 1
    check both.rowsFor(TapFlakyTestId).len == 1
    check both.rowsFor(TapUntimedTestId).len == 1

  test "the second runner degrades to no capture with no daemon":
    ## OS-4, on the new write path: "A missing daemon ... MUST degrade to
    ## no capture. None of them MAY fail a build or a test run, and a
    ## missing daemon MUST NOT be reported as an error."
    ##
    ## POSITIVE CONTROL FIRST, in the arms above: the same binary DOES
    ## record when a daemon is there. Without that, "it did not fail" would
    ## be satisfied by a runner that never records anything at all.
    let tempRoot = createTempDir("repro-m20-nodaemon-", "")
    defer: removeDir(tempRoot)
    let previousSocket = getEnv("RUNQUOTA_SOCKET", "")
    defer: putEnv("RUNQUOTA_SOCKET", previousSocket)
    let binDir = tempRoot / "tap-bin"
    createDir(binDir)
    writeTapFixture(binDir / "t_m20_tap.sh", tempRoot / "counter")
    let summaryPath = tempRoot / "summary.json"
    # A socket path that is not bound by anything.
    putEnv("RUNQUOTA_SOCKET", tempRoot / "absent.sock")
    let (output, code) = execCmdEx(
      quoteShell(requireBin("repro_tap_test_runner")) & " --quiet" &
      " --bin-dir=" & quoteShell(binDir) &
      " --summary-json=" & quoteShell(summaryPath))
    checkpoint("tap runner output: " & output)
    # The tests themselves ran and their verdicts are unchanged.
    check code == 0
    let summary = parseJson(readFile(summaryPath))
    check summary["summary"]["total"].getInt() == TapTests
    check summary["summary"]["failed"].getInt() == 0
    # And it says so rather than pretending it recorded.
    check not summary["summary"]["runquota_history"].getBool()
    check summary["summary"]["recorded"].getInt() == 0
    # A MISSING DAEMON IS NOT AN ERROR: nothing on the output says it was.
    check "error" notin output.toLowerAscii()
