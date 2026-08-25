## ``repro_test_stats`` — ``stats flaky`` and ``stats duration`` over the
## FRAMEWORK-NEUTRAL test layer.
##
## Normative specification:
##
## * ``reprobuild-specs/RunQuota-Observation-Store.milestones.org`` §M20
##   — the gate names these two queries as the instrument: a second
##   runner's rows must "``stats flaky``/``duration`` query
##   indistinguishably from CodeTracer's";
## * ``codetracer-specs/Planned-Features/Nim-Parallel-Test-Framework.md``
##   §17.3 "Statistical Queries", which specifies their shape and output;
## * ``reprobuild-specs/RunQuota-Observation-Store.md`` §"Query
##   Interface" and invariants OS-5, OS-6, OS-8.
##
## **THIS LIBRARY IS WHERE THE OS-8 CLAIM IS EITHER TRUE OR FALSE.** A
## generic layer that two runners can WRITE but that only one runner's
## queries can READ has not achieved anything: the second runner's rows
## would be present and invisible. So the query is written once, over the
## generic table only, and both runners' rows go through it.
##
## **IT KNOWS NO FRAMEWORK, AND IT CANNOT.** The only columns it names are
## the generic layer's, taken from
## ``ct_test_interface/test_execution_extension``; it never asks for
## ``ext_codetracer_test`` and cannot join to it. That is not a
## convention — a query that could name a CodeTracer column would be able
## to tell which runner produced a row, and telling them apart in the
## SHARED layer is exactly the failure OS-8 describes.
##
## **IT DOES NOT LIVE IN ``ct_test_history``, DELIBERATELY.** Hosting the
## generic query inside CodeTracer's reporter library would make every
## other runner's statistics reachable only by linking CodeTracer's write
## path — the capture OS-8 forbids, arriving by the back door.
##
## **IT NEVER OPENS THE STORE.** §"Query Interface": "``runquotad`` MUST
## expose a query interface over the recorded rows, and it is the **only**
## sanctioned reader: no client may open the database file directly."
## There is no ``sqlite`` import here and no path to a store file.

import std/[algorithm, json, math, strutils, tables]

import ct_test_interface/test_execution_extension

import runquota_client
import runquota_protocol

const NullMarker* = "~"
  ## How the store renders SQL NULL on the wire. Pinned because the
  ## difference between "the runner reported no duration" and "the runner
  ## reported 0 ms" is load-bearing for every figure below: averaging a
  ## missing measurement as zero is how a duration report becomes a
  ## fiction.

type
  GenericTestRow* = object
    ## One ``ext_test_execution`` row, as read back through the sanctioned
    ## reader.
    executionId*: string
    hostId*: string
    profileId*: string
    testId*: string
    suite*: string
    status*: string
    durationMs*: int
    durationKnown*: bool
    attempt*: int

  FlakyEntry* = object
    ## One test that has BOTH passed and failed in the window.
    testId*: string
    runs*: int
    failures*: int
    flakePercent*: float

  DurationEntry* = object
    ## Duration statistics for one test.
    ##
    ## ``samples`` counts the executions that REPORTED a duration, not the
    ## executions that ran. A test whose runner reports no duration has no
    ## duration statistics, and says so with ``samples == 0`` rather than
    ## with a mean of zero.
    testId*: string
    samples*: int
    meanMs*: float
    medianMs*: int
    p90Ms*: int
    p99Ms*: int

  TestStatsWindow* = object
    ## OS-6: no aggregate may be reported without the host and
    ## hardware-profile dimension. Carried alongside every answer.
    rowCount*: int
    hostIds*: seq[string]
    profileIds*: seq[string]
    state*: string
      ## ``unavailable`` (no daemon answered), ``empty`` (a daemon
      ## answered and knows nothing yet), or ``known``.

const FailingStatuses* = ["fail", "timeout", "leak"]
  ## What counts as a failure for flakiness.
  ##
  ## ``xfail`` IS NOT ONE. An expected failure is a recorded expectation,
  ## not an unreliable test, and counting it would report every
  ## known-broken case as permanently flaky. ``skip`` is not one either:
  ## a skipped case produced no verdict at all, so it is neither a pass
  ## nor a failure and must not dilute the denominator.
const PassingStatuses* = ["pass", "xpass"]

proc readGenericTestRows*(client: var RunQuotaClient;
                          scope = statsScopeWireOwner;
                          span = profileSpanWireAll): seq[GenericTestRow] =
  ## Read every generic test row this caller may see.
  ##
  ## THE COLUMN LIST IS THE SHARED ONE, not a local restatement: a column
  ## the store has and this query never asks for is a column no statistic
  ## can ever be computed over, and a name that drifted would come back
  ## empty rather than erroring.
  let columns = testExecutionColumns()
  let answer = client.queryStats(statsSubjectExtensionRows,
    scope = scope, span = span,
    extensionId = TestExecutionExtensionId, extensionColumns = columns)
  for entry in answer.extensionRows:
    var values = initTable[string, string]()
    for i, name in entry.columns:
      values[name] = entry.values[i]
    var row = GenericTestRow(
      executionId: entry.executionId,
      hostId: entry.hostId,
      profileId: entry.profile.profileId,
      testId: values.getOrDefault("test_id"),
      suite: values.getOrDefault("suite"),
      status: values.getOrDefault("status"),
      attempt: 1)
    let duration = values.getOrDefault("duration_ms")
    if duration.len > 0 and duration != NullMarker:
      try:
        row.durationMs = parseInt(duration)
        row.durationKnown = true
      except ValueError:
        discard
    let attempt = values.getOrDefault("attempt")
    if attempt.len > 0 and attempt != NullMarker:
      try: row.attempt = parseInt(attempt)
      except ValueError: discard
    if row.testId.len > 0 and row.testId != NullMarker:
      result.add(row)

proc windowFor*(rows: seq[GenericTestRow]; daemonAnswered: bool):
    TestStatsWindow =
  ## The qualification OS-6 requires, computed from the rows themselves.
  ##
  ## AN EMPTY WINDOW IS NEVER RENDERED AS ZEROS. "No daemon answered" and
  ## "a daemon answered and knows nothing" are different states and a
  ## reader that cannot tell them apart will read the first as the second.
  result.rowCount = rows.len
  for row in rows:
    if row.hostId.len > 0 and row.hostId notin result.hostIds:
      result.hostIds.add(row.hostId)
    if row.profileId.len > 0 and row.profileId notin result.profileIds:
      result.profileIds.add(row.profileId)
  result.hostIds.sort()
  result.profileIds.sort()
  result.state =
    if not daemonAnswered: "unavailable"
    elif rows.len == 0: "empty"
    else: "known"

proc flakyReport*(rows: seq[GenericTestRow]): seq[FlakyEntry] =
  ## Tests that have BOTH passed and failed in the window.
  ##
  ## BOTH DIRECTIONS ARE REQUIRED, and that is the definition doing the
  ## work: a test that only ever failed is BROKEN, not flaky, and
  ## reporting it as flaky sends somebody looking for a race in code that
  ## simply does not work. §17.3: "tests that have both passed and failed
  ## in last N runs".
  var passes = initTable[string, int]()
  var failures = initTable[string, int]()
  var order: seq[string] = @[]
  for row in rows:
    if row.testId notin order:
      order.add(row.testId)
      passes[row.testId] = 0
      failures[row.testId] = 0
    if row.status in PassingStatuses:
      inc passes[row.testId]
    elif row.status in FailingStatuses:
      inc failures[row.testId]
  for testId in order:
    let passed = passes[testId]
    let failed = failures[testId]
    if passed > 0 and failed > 0:
      let total = passed + failed
      result.add(FlakyEntry(
        testId: testId,
        runs: total,
        failures: failed,
        flakePercent: 100.0 * float(failed) / float(total)))
  result.sort(proc (a, b: FlakyEntry): int =
    if a.flakePercent > b.flakePercent: -1
    elif a.flakePercent < b.flakePercent: 1
    else: cmp(a.testId, b.testId))

proc percentileMs(sorted: seq[int]; fraction: float): int =
  ## Nearest-rank percentile over a MEASURED sample.
  ##
  ## Nearest-rank rather than interpolated, because the sample is a set of
  ## observed durations and an interpolated p90 reports a duration no
  ## execution ever had.
  if sorted.len == 0:
    return 0
  let rank = max(1, min(sorted.len, int(ceil(fraction * float(sorted.len)))))
  sorted[rank - 1]

proc durationReport*(rows: seq[GenericTestRow]): seq[DurationEntry] =
  ## Per-test duration statistics over the case durations the runners
  ## reported.
  ##
  ## ROWS WITH NO DURATION ARE EXCLUDED FROM THE SAMPLE, NOT COUNTED AS
  ## ZERO. §"executions": "A figure the writer was not given MUST be
  ## stored as NULL, never as zero. Zero is a measurement." The same rule
  ## applies to reading it back: a NULL admitted into a mean would drag
  ## every figure toward zero in proportion to how much the runner did not
  ## measure.
  var samples = initTable[string, seq[int]]()
  var order: seq[string] = @[]
  for row in rows:
    if row.testId notin order:
      order.add(row.testId)
      samples[row.testId] = @[]
    if row.durationKnown:
      samples[row.testId].add(row.durationMs)
  for testId in order:
    var values = samples[testId]
    values.sort()
    var entry = DurationEntry(testId: testId, samples: values.len)
    if values.len > 0:
      var total = 0
      for value in values:
        total += value
      entry.meanMs = float(total) / float(values.len)
      entry.medianMs = percentileMs(values, 0.5)
      entry.p90Ms = percentileMs(values, 0.9)
      entry.p99Ms = percentileMs(values, 0.99)
    result.add(entry)
  result.sort(proc (a, b: DurationEntry): int =
    if a.meanMs > b.meanMs: -1
    elif a.meanMs < b.meanMs: 1
    else: cmp(a.testId, b.testId))

proc windowJson*(window: TestStatsWindow): JsonNode =
  %*{
    "state": window.state,
    "rowCount": window.rowCount,
    "hostIds": window.hostIds,
    "profileIds": window.profileIds
  }

proc flakyJson*(entries: seq[FlakyEntry]; window: TestStatsWindow): JsonNode =
  ## The machine-readable answer.
  ##
  ## EVERY FIELD IS A FACT OF THE GENERIC LAYER, and there is no field
  ## naming a runner, a framework or a language. A reader of this document
  ## cannot tell which runner produced any entry — which is the property
  ## M20's gate calls "indistinguishably", asserted here by construction
  ## and asserted again from outside by
  ## ``tests/integration/t_m20_second_runner_generic_layer.nim``.
  var rows = newJArray()
  for entry in entries:
    rows.add(%*{
      "testId": entry.testId,
      "runs": entry.runs,
      "failures": entry.failures,
      "flakePercent": entry.flakePercent
    })
  %*{
    "schemaId": "reprobuild.test-stats.flaky.v1",
    "command": "stats flaky",
    "window": windowJson(window),
    "rows": rows
  }

proc durationJson*(entries: seq[DurationEntry];
                   window: TestStatsWindow): JsonNode =
  var rows = newJArray()
  for entry in entries:
    rows.add(%*{
      "testId": entry.testId,
      "samples": entry.samples,
      "meanMs": entry.meanMs,
      "medianMs": entry.medianMs,
      "p90Ms": entry.p90Ms,
      "p99Ms": entry.p99Ms
    })
  %*{
    "schemaId": "reprobuild.test-stats.duration.v1",
    "command": "stats duration",
    "window": windowJson(window),
    "rows": rows
  }

proc renderFlakyText*(node: JsonNode): string =
  let window = node{"window"}
  if window{"state"}.getStr() != "known":
    return "Flaky tests: " & window{"state"}.getStr() & "\n"
  result = "Flaky tests (" & $window{"rowCount"}.getInt() &
    " executions, hosts " & window{"hostIds"}.len.`$` & "):\n"
  for row in node{"rows"}:
    result.add("  " & row{"testId"}.getStr() & "   " &
      $row{"failures"}.getInt() & "/" & $row{"runs"}.getInt() &
      " failures (" & formatFloat(row{"flakePercent"}.getFloat(),
        ffDecimal, 1) & "% flaky)\n")

proc renderDurationText*(node: JsonNode): string =
  let window = node{"window"}
  if window{"state"}.getStr() != "known":
    return "Duration statistics: " & window{"state"}.getStr() & "\n"
  result = "Duration statistics (" & $window{"rowCount"}.getInt() &
    " executions):\n"
  for row in node{"rows"}:
    result.add("  " & row{"testId"}.getStr() & "   samples=" &
      $row{"samples"}.getInt() & " mean=" &
      formatFloat(row{"meanMs"}.getFloat(), ffDecimal, 1) & "ms median=" &
      $row{"medianMs"}.getInt() & "ms p90=" & $row{"p90Ms"}.getInt() &
      "ms p99=" & $row{"p99Ms"}.getInt() & "ms\n")

type TestStatsAnswer* = object
  json*: JsonNode
  text*: string
  exitCode*: int

proc runTestStatsQuery*(subcommand: string; asJson: bool;
                        hostScope = false): TestStatsAnswer =
  ## Answer ``stats flaky`` / ``stats duration`` from the shared store.
  ##
  ## A MISSING DAEMON IS NOT AN ERROR (OS-4) and is not an empty result
  ## either: the window says ``unavailable``, and the exit code stays 0
  ## because nothing about the caller's request was wrong.
  var rows: seq[GenericTestRow] = @[]
  var answered = false
  try:
    var client = connectDefault()
    defer: client.close()
    rows = client.readGenericTestRows(
      scope = if hostScope: statsScopeWireHost else: statsScopeWireOwner)
    answered = true
  except CatchableError:
    answered = false
  let window = windowFor(rows, answered)
  case subcommand
  of "flaky":
    result.json = flakyJson(flakyReport(rows), window)
    result.text = renderFlakyText(result.json)
  of "duration":
    result.json = durationJson(durationReport(rows), window)
    result.text = renderDurationText(result.json)
  else:
    result.json = %*{"error": "unknown stats subcommand: " & subcommand}
    result.text = "unknown stats subcommand: " & subcommand & "\n"
    result.exitCode = 2
    return
  if asJson:
    result.text = pretty(result.json) & "\n"
