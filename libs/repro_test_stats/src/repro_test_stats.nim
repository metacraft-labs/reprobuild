## ``repro_test_stats`` — ``stats flaky``, ``stats duration``,
## ``stats last-pass`` and ``stats new-failures`` over the
## FRAMEWORK-NEUTRAL test layer, plus the two schedulers that read the
## same rows.
##
## Normative specification:
##
## * ``reprobuild-specs/RunQuota-Observation-Store.milestones.org`` §M20
##   — the gate names the first two queries as the instrument: a second
##   runner's rows must "``stats flaky``/``duration`` query
##   indistinguishably from CodeTracer's";
## * ``reprobuild-specs/RunQuota-Observation-Store.milestones.org`` §M21
##   — "``stats last-pass`` reports the last passing execution with
##   timestamp, revision, and host. ``stats new-failures`` partitions
##   current failures into new versus long-standing, reported PER HOST as
##   well as pooled ... Adaptive timeouts (§17.4) and duration-based
##   sharding (§17.5) read from the shared store, with the documented
##   fallback when a test has no history";
## * ``codetracer-specs/Planned-Features/Nim-Parallel-Test-Framework.md``
##   §17.3 "Statistical Queries" and its "Point-in-time queries"
##   subsection, §17.4 "Adaptive Timeouts", §17.5 "Duration-Based
##   Sharding";
## * ``reprobuild-specs/RunQuota-Observation-Store.md`` §"Query
##   Interface" and invariants OS-5, OS-6, OS-8.
##
## **WHY THE PER-HOST PARTITION IS NOT A PRESENTATION CHOICE.** §17.3:
## "Where the store holds executions from more than one host, the
## partition MUST be reported per host as well as pooled: a test that
## passes everywhere except one machine is a host problem, not a
## regression, and pooling hides exactly that." The two answers are
## different VERDICTS with different OWNERS — "bisect your change" versus
## "look at that machine" — so ``newFailureReport`` computes both and
## names, by test, every case where they disagree. That naming is not
## decoration: a reader who is shown only the pooled column has no way to
## know the per-host column would have said something else.
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
import ct_test_interface/test_run_context_extension

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
    startedAtUnixMillis*: int64
      ## WHEN, taken from the SPINE row this extension row is joined to.
      ## The extension layer carries no clock of its own, and inventing
      ## one would let a runner's idea of the time disagree with the
      ## store's ordering.
      ##
      ## Zero means the join found no spine row, which the point-in-time
      ## queries treat as "unordered" rather than as "the epoch".
    startedAtKnown*: bool
    gitCommit*: string
    gitBranch*: string
    revisionKnown*: bool
      ## False when no ``ext_test_run_context`` row was joined — the
      ## runner did not know its revision, or predates the table. Read
      ## back as UNKNOWN, never as "".

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

  # WHEN each of those executions started, from the SPINE. Two queries
  # rather than one because the query interface joins an extension to the
  # spine's KEYS and returns none of the spine's own figures on the
  # extension subject; the executions subject returns them, over exactly
  # the same scope and span, so the same rows are selected on both sides.
  var startedAt = initTable[string, int64]()
  try:
    let spine = client.queryStats(statsSubjectExecutions,
      scope = scope, span = span)
    for entry in spine.executions:
      startedAt[entry.executionId] = int64(entry.startedAtUnixMillis)
  except CatchableError:
    discard

  # AND THE REVISION, from reprobuild's own run-context extension. A
  # store that has never seen a revision-recording runner has no such
  # table; the store answers an unknown table with no rows rather than
  # with an error, so this degrades to "revision unknown" for every row
  # instead of failing the query (OS-4).
  var revisions = initTable[string, tuple[commit, branch: string]]()
  try:
    let context = client.queryStats(statsSubjectExtensionRows,
      scope = scope, span = span,
      extensionId = TestRunContextExtensionId,
      extensionColumns = testRunContextColumns())
    for entry in context.extensionRows:
      var commit = ""
      var branch = ""
      for i, name in entry.columns:
        if i >= entry.values.len or entry.values[i] == NullMarker:
          continue
        if name == "git_commit": commit = entry.values[i]
        elif name == "git_branch": branch = entry.values[i]
      if commit.len > 0 or branch.len > 0:
        revisions[entry.executionId] = (commit: commit, branch: branch)
  except CatchableError:
    discard

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
    if startedAt.hasKey(entry.executionId):
      row.startedAtUnixMillis = startedAt[entry.executionId]
      row.startedAtKnown = true
    if revisions.hasKey(entry.executionId):
      row.gitCommit = revisions[entry.executionId].commit
      row.gitBranch = revisions[entry.executionId].branch
      row.revisionKnown = row.gitCommit.len > 0
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

# ---------------------------------------------------------------------------
# M21 — point-in-time queries
# ---------------------------------------------------------------------------

const RevisionUnknown* = "unknown"
  ## What ``last-pass`` prints where a revision would go when no run
  ## context was recorded. §17.3: "A key with no history returns
  ## *unknown* rather than zero, and the runner MUST fall back to its
  ## configured default rather than treating an absent history as a
  ## measurement." A blank field, or a zero-length sha, would read as a
  ## revision.

type
  LastPassAnswer* = object
    ## "When did this test last pass, and at which revision?"
    ##
    ## THREE OUTCOMES, NOT TWO. "never ran here", "ran here and never
    ## passed" and "passed at T" are different answers to "did this ever
    ## work here", and a reader that cannot tell the first two apart will
    ## read a typo'd test name as a broken test.
    testId*: string
    everSeen*: bool
    found*: bool
    startedAtUnixMillis*: int64
    startedAtKnown*: bool
    hostId*: string
    profileId*: string
    revision*: string
    revisionKnown*: bool
    branch*: string
    executions*: int
      ## How many executions of this test the window holds, so the answer
      ## carries its own sample size (OS-6's companion rule: a figure
      ## without its sample size is not a statistic).

  FailureAge* = enum
    ## The partition §17.3 asks for: "the distinction between a
    ## regression worth bisecting and a test that was already red".
    faNew = "new"
    faLongStanding = "long-standing"

  NewFailureEntry* = object
    testId*: string
    hostId*: string
      ## Empty on a POOLED entry. Not a host called "": the pooled answer
      ## is the one that has no host, which is the whole complaint
      ## against it.
    age*: FailureAge
    lastPassUnixMillis*: int64
    lastPassKnown*: bool
    lastPassRevision*: string
    lastPassRevisionKnown*: bool
    executions*: int
    failures*: int

  DisagreementKind* = enum
    dkAgeDiffers = "age-differs"
      ## The pooled partition put this test on one side of new /
      ## long-standing and a host that is currently failing it put it on
      ## the other.
    dkNotFailingEverywhere = "not-failing-everywhere"
      ## Pooled says this test is currently failing; on at least one host
      ## its most recent VERDICT is not a failure. The pooled reading is
      ## "the test is failing"; the per-host reading is "it is failing on
      ## that machine and not on this one".
      ##
      ## "NOT A FAILURE" RATHER THAN "A PASS", and the wording is exact
      ## rather than tidy: a host whose only rows are ``skip`` produced no
      ## verdict at all, which is still not the failure the pooled column
      ## reports, but calling it a pass would state a result nobody
      ## observed.

  Disagreement* = object
    testId*: string
    kind*: DisagreementKind
    pooledAge*: FailureAge
    hostId*: string
    hostAge*: FailureAge
    hostFailing*: bool
    detail*: string

  NewFailureReport* = object
    pooled*: seq[NewFailureEntry]
    perHost*: seq[NewFailureEntry]
    hostIds*: seq[string]
    disagreements*: seq[Disagreement]
      ## Every test whose pooled verdict differs from a per-host one.
      ## NOT a summary of the two lists above — it is the evidence that
      ## reporting only the first would have misled, and it is empty when
      ## the two agree.

proc rowsForTest(rows: seq[GenericTestRow]; testId: string):
    seq[GenericTestRow] =
  for row in rows:
    if row.testId == testId:
      result.add(row)

proc isPass(row: GenericTestRow): bool = row.status in PassingStatuses
proc isFail(row: GenericTestRow): bool = row.status in FailingStatuses

proc byStartedAtDesc(a, b: GenericTestRow): int =
  ## Most recent first, with a total order.
  ##
  ## THE TIE-BREAK IS NOT COSMETIC. Two executions of the same test can
  ## share a millisecond under a parallel runner, and "the last one" must
  ## still be a single well-defined row or ``last-pass`` would answer
  ## differently on two runs over the same store.
  if a.startedAtUnixMillis > b.startedAtUnixMillis: -1
  elif a.startedAtUnixMillis < b.startedAtUnixMillis: 1
  else: cmp(b.executionId, a.executionId)

proc lastPass*(rows: seq[GenericTestRow]; testId: string): LastPassAnswer =
  ## The most recent PASSING execution of ``testId``, with its timestamp,
  ## revision and host.
  ##
  ## THE WHOLE ROW SET IS SEARCHED, NOT ONLY THE MOST RECENT RUN. The
  ## question is "when did this last work", and answering it from the
  ## latest run alone would answer "is it working now", which the caller
  ## already knows.
  result.testId = testId
  var mine = rowsForTest(rows, testId)
  result.executions = mine.len
  result.everSeen = mine.len > 0
  result.revision = RevisionUnknown
  if mine.len == 0:
    return
  mine.sort(byStartedAtDesc)
  for row in mine:
    if not row.isPass:
      continue
    result.found = true
    result.startedAtUnixMillis = row.startedAtUnixMillis
    result.startedAtKnown = row.startedAtKnown
    result.hostId = row.hostId
    result.profileId = row.profileId
    result.revisionKnown = row.revisionKnown
    result.branch = row.gitBranch
    if row.revisionKnown:
      result.revision = row.gitCommit
    return

proc partitionFor(mine: seq[GenericTestRow]): tuple[age: FailureAge;
    lastPassAt: int64; lastPassKnown: bool; revision: string;
    revisionKnown: bool; failures: int] =
  ## The partition itself, over ONE test's executions in ONE scope
  ## (pooled, or a single host's).
  ##
  ## ``mine`` is expected sorted most-recent-first. §17.3 defines the two
  ## sides as "those with a passing execution in the window and those
  ## without", so the predicate is the PRESENCE of a pass in the window
  ## and nothing more: a threshold on how long ago it was would be a
  ## number this specification does not have, and choosing one here would
  ## be inventing policy in a query.
  result.age = faLongStanding
  result.revision = RevisionUnknown
  for row in mine:
    if row.isFail:
      inc result.failures
    if result.lastPassKnown or not row.isPass:
      continue
    result.age = faNew
    result.lastPassAt = row.startedAtUnixMillis
    result.lastPassKnown = true
    result.revisionKnown = row.revisionKnown
    if row.revisionKnown:
      result.revision = row.gitCommit

proc currentlyFailing(mine: seq[GenericTestRow]): bool =
  ## Whether the MOST RECENT execution in this scope failed.
  ##
  ## "Current failure" is the latest verdict, not "failed at least once":
  ## the latter would list every test that has ever been red, and the
  ## partition below would then be answering a question nobody asked.
  ## ``mine`` is expected sorted most-recent-first, and a leading run of
  ## non-verdicts (``skip``, which produced no verdict at all) is stepped
  ## over rather than treated as a pass.
  for row in mine:
    if row.isFail: return true
    if row.isPass: return false
  false

proc newFailureReport*(rows: seq[GenericTestRow]): NewFailureReport =
  ## ``stats new-failures``: pooled AND per host, plus the disagreements.
  var byTest = initOrderedTable[string, seq[GenericTestRow]]()
  var byTestHost = initOrderedTable[string, seq[GenericTestRow]]()
  for row in rows:
    if not byTest.hasKey(row.testId):
      byTest[row.testId] = @[]
    byTest[row.testId].add(row)
    let key = row.testId & "\x1f" & row.hostId
    if not byTestHost.hasKey(key):
      byTestHost[key] = @[]
    byTestHost[key].add(row)
    if row.hostId.len > 0 and row.hostId notin result.hostIds:
      result.hostIds.add(row.hostId)
  result.hostIds.sort()

  var pooledAge = initTable[string, FailureAge]()
  var pooledFailing = initTable[string, bool]()
  for testId, unsorted in byTest.mpairs:
    unsorted.sort(byStartedAtDesc)
    let failing = currentlyFailing(unsorted)
    pooledFailing[testId] = failing
    let part = partitionFor(unsorted)
    pooledAge[testId] = part.age
    if failing:
      result.pooled.add(NewFailureEntry(
        testId: testId, hostId: "", age: part.age,
        lastPassUnixMillis: part.lastPassAt,
        lastPassKnown: part.lastPassKnown,
        lastPassRevision: part.revision,
        lastPassRevisionKnown: part.revisionKnown,
        executions: unsorted.len, failures: part.failures))

  for key, unsorted in byTestHost.mpairs:
    let split = key.split('\x1f')
    let testId = split[0]
    let hostId = if split.len > 1: split[1] else: ""
    unsorted.sort(byStartedAtDesc)
    let failing = currentlyFailing(unsorted)
    let part = partitionFor(unsorted)
    if failing:
      result.perHost.add(NewFailureEntry(
        testId: testId, hostId: hostId, age: part.age,
        lastPassUnixMillis: part.lastPassAt,
        lastPassKnown: part.lastPassKnown,
        lastPassRevision: part.revision,
        lastPassRevisionKnown: part.revisionKnown,
        executions: unsorted.len, failures: part.failures))
    # THE COMPARISON, AND IT IS MADE FOR EVERY (test, host) PAIR RATHER
    # THAN ONLY FOR THE FAILING ONES. A host on which the test is FINE is
    # exactly the evidence that the pooled "this test is failing" was the
    # wrong shape of answer, and restricting the comparison to failing
    # hosts would have discarded it.
    if not pooledFailing.getOrDefault(testId, false):
      continue
    let pooled = pooledAge.getOrDefault(testId, faLongStanding)
    if not failing:
      result.disagreements.add(Disagreement(
        testId: testId, kind: dkNotFailingEverywhere,
        pooledAge: pooled, hostId: hostId, hostAge: part.age,
        hostFailing: false,
        detail: "pooled reports this test as a current failure; on " &
          hostId & " its most recent verdict is not a failure"))
    elif part.age != pooled:
      result.disagreements.add(Disagreement(
        testId: testId, kind: dkAgeDiffers,
        pooledAge: pooled, hostId: hostId, hostAge: part.age,
        hostFailing: true,
        detail: "pooled reports " & $pooled & "; on " & hostId &
          " this failure is " & $part.age))

  result.pooled.sort(proc (a, b: NewFailureEntry): int = cmp(a.testId, b.testId))
  result.perHost.sort(proc (a, b: NewFailureEntry): int =
    if a.testId != b.testId: cmp(a.testId, b.testId) else: cmp(a.hostId, b.hostId))
  result.disagreements.sort(proc (a, b: Disagreement): int =
    if a.testId != b.testId: cmp(a.testId, b.testId) else: cmp(a.hostId, b.hostId))

# ---------------------------------------------------------------------------
# M21 — history-fed scheduling (§17.4 adaptive timeouts, §17.5 sharding)
#
# BOTH READ THE SAME ROWS AS THE QUERIES ABOVE, which is the point of
# putting them here: §17.3 §"How these read" says the query interface
# "serves the runner's *adaptive timeouts* (§17.4) and RunQuota's own
# admission estimates — the same rows at a different aggregation". A
# second reader with its own store would be a second thing to keep
# correct.
#
# AND BOTH FALL BACK RATHER THAN GUESS. §17.3: "A key with no history
# returns *unknown* rather than zero, and the runner MUST fall back to
# its configured default rather than treating an absent history as a
# measurement." A test with no history and a test that has always taken
# no measurable time are different, and a zero would merge them — into
# the shortest timeout and the emptiest shard, which is the direction
# that breaks things.
# ---------------------------------------------------------------------------

type
  TimeoutMetric* = enum
    tmMean = "mean"
    tmMedian = "median"
    tmP90 = "p90"
    tmP99 = "p99"

  AdaptiveTimeoutConfig* = object
    enabled*: bool
    metric*: TimeoutMetric
    multiplier*: float
    minimumMs*: int
    fallbackMs*: int
    globalTimeoutMs*: int
      ## The profile's own ``timeout``. Zero means "no global ceiling",
      ## which is what the runner's own ``--test-timeout=0`` means.
    runs*: int
      ## The window, in executions per test. Zero means every execution
      ## the store holds for it.

  TimeoutSource* = enum
    tsHistory = "history"
    tsMinimum = "minimum"
    tsFallback = "fallback"
    tsCapped = "capped"

  AdaptiveTimeout* = object
    testId*: string
    timeoutMs*: int
    source*: TimeoutSource
    samples*: int
    metricMs*: int

proc defaultAdaptiveTimeoutConfig*(): AdaptiveTimeoutConfig =
  ## §17.4's own example block, verbatim, minus ``enabled``.
  AdaptiveTimeoutConfig(
    enabled: false, metric: tmP99, multiplier: 3.0, minimumMs: 5_000,
    fallbackMs: 60_000, globalTimeoutMs: 60_000, runs: 20)

proc recentRowsPerTest*(rows: seq[GenericTestRow]; runs: int):
    seq[GenericTestRow] =
  ## The last ``runs`` executions of each test, most recent first.
  ##
  ## PER TEST, NOT PER RUN, and the difference matters on a store that
  ## several projects write to: "the last 20 runs" of a test that is
  ## executed once a week is a much older window than the same phrase
  ## applied to the store as a whole, and the statistic §17.4 wants is
  ## the one about the test.
  if runs <= 0:
    return rows
  var byTest = initOrderedTable[string, seq[GenericTestRow]]()
  for row in rows:
    if not byTest.hasKey(row.testId):
      byTest[row.testId] = @[]
    byTest[row.testId].add(row)
  for _, mine in byTest.mpairs:
    mine.sort(byStartedAtDesc)
    for i in 0 ..< min(runs, mine.len):
      result.add(mine[i])

proc metricMs*(entry: DurationEntry; metric: TimeoutMetric): int =
  case metric
  of tmMean: int(entry.meanMs)
  of tmMedian: entry.medianMs
  of tmP90: entry.p90Ms
  of tmP99: entry.p99Ms

proc adaptiveTimeoutFor*(entry: DurationEntry;
                         config: AdaptiveTimeoutConfig): AdaptiveTimeout =
  ## §17.4 step 2: ``max(minimum, metric_value * multiplier)``, step 3's
  ## fallback for a test with no history, step 5's cap at the global
  ## timeout.
  ##
  ## ``samples`` IS THE PREDICATE, NOT ``meanMs == 0``. A test whose
  ## runner reported no duration has ``samples == 0`` and a mean of zero;
  ## a test that genuinely runs in under a millisecond has samples and a
  ## mean of zero too. Keying the fallback on the mean would give the
  ## second one a 60-second timeout while claiming it came from history.
  result.testId = entry.testId
  result.samples = entry.samples
  result.metricMs = entry.metricMs(config.metric)
  if entry.samples == 0:
    result.timeoutMs = config.fallbackMs
    result.source = tsFallback
  else:
    let scaled = int(float(result.metricMs) * config.multiplier)
    if scaled < config.minimumMs:
      result.timeoutMs = config.minimumMs
      result.source = tsMinimum
    else:
      result.timeoutMs = scaled
      result.source = tsHistory
  if config.globalTimeoutMs > 0 and result.timeoutMs > config.globalTimeoutMs:
    result.timeoutMs = config.globalTimeoutMs
    result.source = tsCapped

proc adaptiveTimeouts*(rows: seq[GenericTestRow];
                       testIds: openArray[string];
                       config: AdaptiveTimeoutConfig): seq[AdaptiveTimeout] =
  ## One answer per test the caller is about to run — INCLUDING the ones
  ## the store has never heard of, which is where the fallback lives. A
  ## proc that returned only the tests it had history for would leave its
  ## caller to invent the rest, and the invention is the whole risk.
  let window = recentRowsPerTest(rows, config.runs)
  var stats = initTable[string, DurationEntry]()
  for entry in durationReport(window):
    stats[entry.testId] = entry
  for testId in testIds:
    let entry =
      if stats.hasKey(testId): stats[testId]
      else: DurationEntry(testId: testId, samples: 0)
    result.add(adaptiveTimeoutFor(entry, config))

type
  ShardStrategy* = enum
    ssCount = "count"
    ssDuration = "duration"

  ShardPlan* = object
    requested*: ShardStrategy
    applied*: ShardStrategy
      ## What was ACTUALLY used. §17.5: "When no history is available,
      ## ``duration`` falls back to ``count``." A plan that reported the
      ## requested strategy would make that fallback invisible, and a
      ## reader comparing two CI runs would have no way to see that one
      ## of them bin-packed on nothing.
    fellBack*: bool
    reason*: string
    assignment*: seq[int]
      ## Shard index per input test, in the caller's own order.
    shardEstimateMs*: seq[int]
    withHistory*: int
    withoutHistory*: int

proc durationEstimates*(rows: seq[GenericTestRow]; runs = 0):
    Table[string, int] =
  ## Median duration per test, over the tests that HAVE one. A test
  ## absent from this table has no estimate — which is different from an
  ## estimate of zero, and is why the answer is a table rather than a
  ## sequence with holes filled in.
  ##
  ## MEDIAN RATHER THAN MEAN, because the input is wall-clock durations
  ## under a parallel runner: one execution that happened to share the
  ## machine with a link step drags a mean and does not move a median,
  ## and the bin-packer wants the typical cost rather than the worst one.
  result = initTable[string, int]()
  for entry in durationReport(recentRowsPerTest(rows, runs)):
    if entry.samples > 0:
      result[entry.testId] = entry.medianMs

proc planShards*(testIds: seq[string];
                 estimates: Table[string, int];
                 shards: int;
                 requested = ssDuration): ShardPlan =
  ## §17.5's greedy bin-packing: "sort tests by estimated duration
  ## (descending), assign each test to the shard with the lowest total
  ## estimated time so far", with the documented fallback to ``count``
  ## when no history is available.
  result.requested = requested
  result.applied = requested
  result.assignment = newSeq[int](testIds.len)
  let shardCount = max(shards, 1)
  result.shardEstimateMs = newSeq[int](shardCount)
  for testId in testIds:
    if estimates.hasKey(testId): inc result.withHistory
    else: inc result.withoutHistory

  if requested == ssDuration and result.withHistory == 0:
    # THE DOCUMENTED FALLBACK, and it is keyed on "no test in this run
    # has history" rather than on "the store is empty": a store full of
    # some other project's rows is just as useless for bin-packing this
    # one, and the caller must be told the plan is a count plan either
    # way.
    result.applied = ssCount
    result.fellBack = true
    result.reason = "no test in this run has duration history; " &
      "bin-packing on nothing would be a count split that claimed to be " &
      "a duration split"

  if result.applied == ssCount:
    for i in 0 ..< testIds.len:
      result.assignment[i] = i mod shardCount
    return

  var order: seq[int] = @[]
  for i in 0 ..< testIds.len:
    order.add(i)
  order.sort(proc (a, b: int): int =
    let ea = estimates.getOrDefault(testIds[a], 0)
    let eb = estimates.getOrDefault(testIds[b], 0)
    if ea > eb: -1
    elif ea < eb: 1
    else: cmp(testIds[a], testIds[b]))
  for index in order:
    var best = 0
    for shard in 1 ..< shardCount:
      if result.shardEstimateMs[shard] < result.shardEstimateMs[best]:
        best = shard
    result.assignment[index] = best
    # A TEST WITH NO ESTIMATE CONTRIBUTES NOTHING TO THE BIN, rather than
    # a made-up average. It still gets placed — into whichever bin is
    # lightest at the time — so the unknowns spread out instead of
    # clumping, and the caller is told how many of them there were.
    result.shardEstimateMs[best] += estimates.getOrDefault(testIds[index], 0)

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

proc lastPassJson*(answer: LastPassAnswer;
                   window: TestStatsWindow): JsonNode =
  %*{
    "schemaId": "reprobuild.test-stats.last-pass.v1",
    "command": "stats last-pass",
    "window": windowJson(window),
    "testId": answer.testId,
    "everSeen": answer.everSeen,
    "found": answer.found,
    "executions": answer.executions,
    "timestampUnixMs": answer.startedAtUnixMillis,
    "timestampKnown": answer.startedAtKnown,
    "revision": answer.revision,
    "revisionKnown": answer.revisionKnown,
    "branch": answer.branch,
    "hostId": answer.hostId,
    "profileId": answer.profileId
  }

proc failureEntryJson(entry: NewFailureEntry): JsonNode =
  %*{
    "testId": entry.testId,
    "hostId": entry.hostId,
    "age": $entry.age,
    "lastPassUnixMs": entry.lastPassUnixMillis,
    "lastPassKnown": entry.lastPassKnown,
    "lastPassRevision": entry.lastPassRevision,
    "lastPassRevisionKnown": entry.lastPassRevisionKnown,
    "executions": entry.executions,
    "failures": entry.failures
  }

proc newFailuresJson*(report: NewFailureReport;
                      window: TestStatsWindow): JsonNode =
  ## BOTH PARTITIONS IN ONE DOCUMENT, AND THE DISAGREEMENTS BESIDE THEM.
  ## Emitting the pooled answer alone — or emitting the per-host one only
  ## on request — would let the default reading be the misleading one,
  ## which is the failure §17.3 describes.
  var pooled = newJArray()
  for entry in report.pooled:
    pooled.add(failureEntryJson(entry))
  var perHost = newJArray()
  for entry in report.perHost:
    perHost.add(failureEntryJson(entry))
  var disagreements = newJArray()
  for item in report.disagreements:
    disagreements.add(%*{
      "testId": item.testId,
      "kind": $item.kind,
      "pooledAge": $item.pooledAge,
      "hostId": item.hostId,
      "hostAge": $item.hostAge,
      "hostFailing": item.hostFailing,
      "detail": item.detail
    })
  %*{
    "schemaId": "reprobuild.test-stats.new-failures.v1",
    "command": "stats new-failures",
    "window": windowJson(window),
    "hostIds": report.hostIds,
    "pooled": pooled,
    "perHost": perHost,
    "disagreements": disagreements
  }

proc renderLastPassText*(node: JsonNode): string =
  let window = node{"window"}
  let testId = node{"testId"}.getStr()
  if window{"state"}.getStr() != "known":
    return "Last pass for " & testId & ": " & window{"state"}.getStr() & "\n"
  if not node{"everSeen"}.getBool():
    return "Last pass for " & testId &
      ": no execution of this test in the window (" &
      $window{"rowCount"}.getInt() & " executions of other tests)\n"
  if not node{"found"}.getBool():
    return "Last pass for " & testId & ": NEVER PASSED in the window (" &
      $node{"executions"}.getInt() & " executions, all non-passing)\n"
  "Last pass for " & testId & ": at " &
    $node{"timestampUnixMs"}.getBiggestInt() & "ms, revision " &
    node{"revision"}.getStr() & ", host " & node{"hostId"}.getStr() &
    " (" & $node{"executions"}.getInt() & " executions in window)\n"

proc renderNewFailuresText*(node: JsonNode): string =
  let window = node{"window"}
  if window{"state"}.getStr() != "known":
    return "New failures: " & window{"state"}.getStr() & "\n"
  result = "Current failures (" & $window{"rowCount"}.getInt() &
    " executions across " & $node{"hostIds"}.len & " host(s)):\n"
  result.add("  pooled:\n")
  if node{"pooled"}.len == 0:
    result.add("    none\n")
  for row in node{"pooled"}:
    result.add("    " & row{"testId"}.getStr() & "   " &
      row{"age"}.getStr() & " (last pass revision " &
      row{"lastPassRevision"}.getStr() & ")\n")
  result.add("  per host:\n")
  if node{"perHost"}.len == 0:
    result.add("    none\n")
  for row in node{"perHost"}:
    result.add("    " & row{"hostId"}.getStr() & "  " &
      row{"testId"}.getStr() & "   " & row{"age"}.getStr() & "\n")
  if node{"disagreements"}.len > 0:
    result.add("  POOLED ANSWER DISAGREES WITH PER-HOST:\n")
    for row in node{"disagreements"}:
      result.add("    " & row{"testId"}.getStr() & ": " &
        row{"detail"}.getStr() & "\n")

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

proc readSchedulingHistory*(hostScope = false):
    tuple[rows: seq[GenericTestRow]; answered: bool] =
  ## The history the two schedulers read, through the same reader every
  ## query above uses.
  ##
  ## ``answered`` FALSE IS NOT AN EMPTY HISTORY. A runner that could not
  ## reach a daemon must fall back to its configured defaults and SAY SO;
  ## treating an unreachable daemon as "no test has history" would give
  ## the same plan and a different explanation, and the explanation is
  ## what a reader uses to decide whether to trust the plan.
  try:
    var client = connectDefault()
    defer: client.close()
    result.rows = client.readGenericTestRows(
      scope = if hostScope: statsScopeWireHost else: statsScopeWireOwner)
    result.answered = true
  except CatchableError:
    result.rows = @[]
    result.answered = false

type TestStatsAnswer* = object
  json*: JsonNode
  text*: string
  exitCode*: int

proc runTestStatsQuery*(subcommand: string; asJson: bool;
                        hostScope = false; target = "";
                        runs = 0): TestStatsAnswer =
  ## Answer ``stats flaky`` / ``duration`` / ``last-pass`` /
  ## ``new-failures`` from the shared store.
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
  # THE WINDOW IS COMPUTED OVER EVERY ROW READ, and only then is the
  # per-test ``--runs`` window applied. A ``rowCount`` that described the
  # narrowed set would tell a reader the store holds less than it does,
  # which is the same dishonesty as an unstated scope.
  let window = windowFor(rows, answered)
  let windowed = recentRowsPerTest(rows, runs)
  case subcommand
  of "flaky":
    result.json = flakyJson(flakyReport(windowed), window)
    result.text = renderFlakyText(result.json)
  of "duration":
    result.json = durationJson(durationReport(windowed), window)
    result.text = renderDurationText(result.json)
  of "last-pass":
    if target.len == 0:
      result.json = %*{"error": "stats last-pass needs a test id"}
      result.text = "stats last-pass needs a test id\n"
      result.exitCode = 2
      return
    result.json = lastPassJson(lastPass(rows, target), window)
    result.text = renderLastPassText(result.json)
  of "new-failures":
    result.json = newFailuresJson(newFailureReport(windowed), window)
    result.text = renderNewFailuresText(result.json)
  else:
    result.json = %*{"error": "unknown stats subcommand: " & subcommand}
    result.text = "unknown stats subcommand: " & subcommand & "\n"
    result.exitCode = 2
    return
  if asJson:
    result.text = pretty(result.json) & "\n"
