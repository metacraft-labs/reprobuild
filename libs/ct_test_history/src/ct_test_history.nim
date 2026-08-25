## ``ct_test_history`` — the ``HistoryReporter``: the parallel test
## runner's WRITE PATH into RunQuota's observation store.
##
## Normative specification:
##
## * ``codetracer-specs/Planned-Features/Nim-Parallel-Test-Framework.md``
##   §17 "Test History via the Reporter Interface", §17.1.2 "Storage:
##   The Shared Observation Store";
## * ``reprobuild-specs/RunQuota-Observation-Store.md`` §"The Execution
##   Spine", §"Domain Extensions", and invariants OS-1, OS-3, OS-4,
##   OS-5, OS-8.
##
## THE RUNNER DOES NOT DEFINE A DATABASE, AND DOES NOT OPEN ONE. §17.3
## §"How these read" is explicit: "The runner MUST NOT open the store's
## database file directly: ``runquotad`` is the only sanctioned reader,
## and a second access path would be a second thing to keep correct as
## the schema moves." Everything below travels over RQSP on the session's
## own socket. There is no ``sqlite`` import in this module, and no path
## to a store file anywhere in it. In particular there is no
## ``.nimtest/history.db``: that was the retired per-runner backend, and
## §17.1.2 replaced it with the shared store rather than migrating it.
##
## WHAT IT WRITES, PER TEST EXECUTION
## ----------------------------------
##
## 1. A SPINE ROW, which the runner does not compose. It is produced by
##    RunQuota when the lease this reporter takes around the test
##    process finishes, and it carries the universal facts — times,
##    duration, exit status, termination kind, peak RSS, host and
##    hardware profile. The runner's only contribution is to make the
##    lease SPAN the execution, so those figures describe the test
##    rather than the bookkeeping.
##
## 2. ``ext_test_execution`` — the framework-neutral layer
##    (``ct_test_interface/test_execution_extension``).
##
## 3. ``ext_codetracer_test`` — this framework's own facts
##    (``ct_test_interface/codetracer_test_extension``).
##
## The split between 2 and 3 is not organisational. OS-8 requires the
## generic layer to be populated by at least two different runners, and
## M20 adds the second one; anything framework-specific placed in layer
## 2 is a column that second runner would have to invent a value for.
##
## TERMINATION: THE ONE FACT AN EXIT STATUS CANNOT CARRY
## ----------------------------------------------------
##
## §"executions": "An OOM kill and an assertion failure are both
## non-zero, and telling them apart is most of the value when reading a
## failure history." §17.1.2 adds why it matters *here*: "Under a
## parallel runner, OOM kills correlate with concurrency rather than
## with the test, so conflating the two produces flake verdicts that
## blame the wrong thing."
##
## The runner therefore does not infer OOM from an exit status — it
## cannot, because the two are indistinguishable there. It ENFORCES a
## per-test memory ceiling: while a test runs, the reporter samples the
## resident size of the child's whole process tree through RunQuota's
## own host backend, and when a test crosses the ceiling the runner
## kills it and reports ``hardLimitOrOom`` on the lease. The daemon maps
## that to ``termination = oom_killed`` while an ordinary non-zero exit
## maps to ``exited``. This is a fact the runner OBSERVED (it did the
## killing), not a heuristic over a status byte.
##
## The ceiling is off unless configured, so an unconfigured run behaves
## exactly as it did before and reports ``exited`` for every ordinary
## failure.
##
## DEGRADATION (OS-4)
## ------------------
##
## A missing daemon, a refused extension, a dead socket: none of them
## may fail a test run, and a missing daemon MUST NOT be reported as an
## error. Every entry point below is total — it returns a "no capture"
## answer rather than raising — and the runner's behaviour with capture
## off is byte-for-byte what it was before this module existed.

import std/[locks, strutils]

import ct_test_interface/test_execution_extension
import ct_test_interface/codetracer_test_extension
import ct_test_interface/test_run_context_extension
export test_execution_extension, codetracer_test_extension,
  test_run_context_extension

import runquota_core
import runquota_codec
import runquota_client
import runquota_protocol

when defined(linux):
  import runquota_host_linux
elif defined(windows):
  import runquota_host_windows
else:
  import runquota_host_macos

const
  HistoryToolName* = "ct-test-runner"
    ## The ``runs.tool`` value. Free-form and client-declared per
    ## §"runs"; this is the name §17 uses for the runner throughout.
  HistoryToolVersion* = "1"

  MaxStatsKeyBytes = 64
    ## The protocol's own bound on ``command_stats_id``. The encoder
    ## TRUNCATES silently past it, which would collapse two long test
    ## names onto one statistics key — so this module never hands it an
    ## over-long value; see ``statsKeyForTest``.

type
  TestHistoryStatus* = enum
    ## The framework-neutral ``status`` vocabulary, as an enum so a
    ## caller cannot spell one of the seven wrong. The string values are
    ## the column's ``check`` constraint verbatim.
    thsPass = "pass"
    thsFail = "fail"
    thsSkip = "skip"
    thsXfail = "xfail"
    thsXpass = "xpass"
    thsLeak = "leak"
    thsTimeout = "timeout"

  GenericTestFacts* = object
    ## Everything one ``ext_test_execution`` row carries. A VALUE, so a
    ## row is constructible without a runner — and, more to the point,
    ## so a DIFFERENT runner can construct one (OS-8).
    testId*: string
    suite*: string
      ## Empty means "this framework has no suite for this case", and
      ## is written as SQL NULL rather than as the empty string.
    status*: TestHistoryStatus
    durationMs*: int
    durationKnown*: bool
      ## False when the framework reported no duration. NULL, not zero:
      ## "took no measurable time" and "nobody said" are different
      ## facts and an average cannot recover the difference.
    attempt*: int
    retryOf*: string
    errorMessage*: string
    skipReason*: string
    stdoutLen*: int
    stdoutKnown*: bool
    stderrLen*: int
    stderrKnown*: bool
      ## A runner that merges the two streams knows the combined size
      ## and not the split. NULL says so; 0 would claim the test wrote
      ## nothing to stderr.

  CodetracerTestFacts* = object
    ## Everything one ``ext_codetracer_test`` row carries. EVERY FIELD
    ## IS OPTIONAL, which is what makes M20's "no CodeTracer-specific
    ## column is required to record a test outcome" true by
    ## construction.
    recordingPath*: string
    traceId*: string
    traceFormatVersion*: string
    recorder*: string
    replayOk*: bool
    replayKnown*: bool
    protocolAware*: bool
    runName*: string
    bodyHash*: string
    checkpointCount*: int
    statusDisagreement*: string
    harnessError*: string

  TestExecutionOutcome* = object
    ## What the runner OBSERVED about the process it ran. The spine row
    ## is composed by RunQuota from these.
    exitCode*: int
    signal*: int
    signalled*: bool
    peakRssBytes*: uint64
    processCount*: uint32
    ## THE OOM FLAG. True only when the runner itself enforced a memory
    ## ceiling against this process and killed it, which is the only
    ## way a runner can KNOW rather than guess.
    memoryLimitExceeded*: bool
    timedOut*: bool
    launchFailed*: bool
      ## The harness never obtained a verdict — the child was not
      ## started, or was started and then could not be reached. The
      ## daemon maps this to ``termination = refused``, which is the
      ## honest label: nothing about the code under test was observed.

  TestLease* = object
    ## A lease handed to a worker. ``captured == false`` is the ordinary
    ## no-daemon answer and is not an error.
    captured*: bool
    leaseId*: uint64
    lease: RunQuotaLease

  HistoryReporter* = object
    ## Shared by every worker thread. THE SOCKET IS THE SHARED RESOURCE
    ## AND THE LOCK GUARDS IT: RQSP is a request/response protocol on one
    ## connection, so two threads writing frames concurrently would
    ## interleave them. Nothing below ever blocks on a grant while
    ## holding the lock — see ``acquireLease``.
    ##
    ## ONE SESSION, NOT ONE PER WORKER, and that is deliberate: the
    ## daemon opens exactly one ``runs`` row per registered session, so
    ## a session per worker would shatter a single test run into N run
    ## records and every cross-run query in §17.3 would count them as N
    ## runs.
    lock: Lock
    client: RunQuotaClient
    session: RunQuotaSession
    active: bool
    genericOk: bool
    codetracerOk: bool
    runContextOk: bool
    gitCommit: string
    gitBranch: string
      ## THE REVISION THIS RUN IS OF, resolved ONCE by the caller and
      ## held for the whole session. Not re-read per execution: a
      ## checkout that moved mid-run would otherwise attribute some
      ## cases to one revision and some to another, and every one of
      ## those attributions would be a guess about when the move
      ## happened. Empty means "the caller did not know", which is
      ## written as SQL NULL and read back as UNKNOWN.
    nextCandidateId: uint64
    uncapturedExecutions: int
      ## Executions whose history is INCOMPLETE — the daemon queued or
      ## denied the candidate, or a row send faulted. COUNTED, because
      ## OS-2 forbids presenting a thinned sample as a complete one and a
      ## count is where that honesty starts. One counter rather than two,
      ## because the reader's question is "how much of this run is
      ## missing", not "at which of two steps was it lost".

proc statsKeyForTest*(testId: string): string =
  ## The ``command_stats_id`` for a test, which is the key every
  ## statistic in §17.3 groups by.
  ##
  ## THE PROTOCOL TRUNCATES SILENTLY PAST 64 BYTES, so handing it a long
  ## test name would silently pool two different tests under one key and
  ## every duration and flake figure derived from them would be a blend
  ## of both. Names that fit are used verbatim, because a readable key
  ## is worth having; names that do not are given a stable, unique form
  ## instead of a prefix.
  if testId.len <= MaxStatsKeyBytes:
    return testId
  # FNV-1a over the WHOLE name, so the discriminator depends on the part
  # that was cut rather than on the part that was kept.
  var h = 0xcbf29ce484222325'u64
  for ch in testId:
    h = h xor uint64(ord(ch))
    h = h * 0x100000001b3'u64
  let digest = toHex(h, 16).toLowerAscii()
  testId[0 ..< (MaxStatsKeyBytes - 1 - digest.len)] & "~" & digest

proc sampleProcessTreeRss*(rootPid: uint64): uint64 =
  ## Resident size of the process tree rooted at ``rootPid``, or 0 when
  ## it cannot be read.
  ##
  ## RUNQUOTA'S OWN HOST BACKEND, not a ``ps`` subprocess. ``ps -o rss``
  ## requires an entitlement on current macOS and fails outright there,
  ## so a shell-based sampler would have made the memory ceiling a
  ## Linux-only mechanism while reading green on macOS (it would simply
  ## never fire).
  let sample =
    when defined(linux):
      sampleLinuxProcessTreeTelemetry(rootPid)
    elif defined(windows):
      sampleWindowsProcessTreeTelemetry(rootPid)
    else:
      sampleMacosProcessTreeTelemetry(rootPid)
  if sample.diagnostic.code == diagOk: sample.residentMemoryBytes
  else: 0'u64

proc open*(reporter: ptr HistoryReporter;
           gitCommit = ""; gitBranch = ""): bool =
  ## Connect, register the session and declare the extensions.
  ##
  ## RETURNS FALSE RATHER THAN RAISING when there is no daemon. OS-4: "a
  ## missing daemon MUST NOT be reported as an error". The caller keeps
  ## running tests with capture off.
  ##
  ## THE REVISION IS THE CALLER'S TO RESOLVE, and both parameters default
  ## to empty. A caller that does not know it records no revision, which
  ## ``last-pass`` reports as UNKNOWN — never as a fabricated value.
  initLock(reporter.lock)
  reporter.nextCandidateId = 1'u64
  reporter.gitCommit = gitCommit
  reporter.gitBranch = gitBranch
  try:
    reporter.client = connectDefault()
  except CatchableError:
    return false
  try:
    reporter.session = reporter.client.registerSession(
      HistoryToolName, HistoryToolVersion)
    reporter.active = true
  except CatchableError:
    try: reporter.client.close()
    except CatchableError: discard
    return false
  # DECLARED UP FRONT, BOTH OF THEM, AND INDEPENDENTLY. A refusal of one
  # extension is not a reason to stop writing the other: the generic
  # layer is the one OS-8 is about, and losing it because CodeTracer's
  # own table could not be created would be the dependency inverted.
  try:
    reporter.genericOk = reporter.session.declareExtension(
      TestExecutionExtensionId, TestExecutionExtensionOwner,
      TestExecutionSchemaVersion, testExecutionMigrations()).len == 0
  except CatchableError:
    reporter.genericOk = false
  try:
    reporter.codetracerOk = reporter.session.declareExtension(
      CodetracerTestExtensionId, CodetracerTestExtensionOwner,
      CodetracerTestSchemaVersion, codetracerTestMigrations()).len == 0
  except CatchableError:
    reporter.codetracerOk = false
  # THE THIRD DECLARATION IS CONDITIONAL ON KNOWING SOMETHING TO PUT IN
  # IT. A run with no revision declares no table, so a store that has
  # only ever seen revision-less runs does not carry an empty one, and
  # "no ``ext_test_run_context`` row" keeps one meaning rather than two.
  if gitCommit.len > 0 or gitBranch.len > 0:
    try:
      reporter.runContextOk = reporter.session.declareExtension(
        TestRunContextExtensionId, TestRunContextExtensionOwner,
        TestRunContextSchemaVersion, testRunContextMigrations()).len == 0
    except CatchableError:
      reporter.runContextOk = false
  true

proc capturing*(reporter: ptr HistoryReporter): bool =
  not reporter.isNil and reporter.active

proc acquireLease*(reporter: ptr HistoryReporter; testId: string;
                   cpuMilli = 1000'u32;
                   memoryBytes = 128'u64 * 1024'u64 * 1024'u64): TestLease =
  ## Take a lease for one test execution.
  ##
  ## **ADMISSION NEVER GATES THE RUNNER, AND THE ABANDONMENT BELOW IS
  ## THE WHOLE REASON.** A candidate the daemon QUEUES is released and
  ## capture is given up for that one execution; the test then runs
  ## exactly when the runner's own scheduler would have run it.
  ##
  ## OS-1 is why: "Recording an observation MUST NOT block ... Losing an
  ## observation is always preferable to perturbing the work being
  ## observed." A reporter that waited for capacity would be reordering
  ## and delaying the very executions it is measuring, and the durations
  ## it recorded would then describe a run that only happened because it
  ## was being recorded.
  ##
  ## It also removes a deadlock that a waiting reporter would have: the
  ## capacity a queued worker waits for is released by another worker's
  ## ``finishExecution``, which needs this same socket lock.
  ##
  ## Whether RunQuota should also SCHEDULE this runner is a real
  ## question with a real answer, and it is not a reporter's to decide.
  ##
  ## THE LOSS IS COUNTED, not swallowed: ``uncapturedExecutions`` is
  ## what stops an absent history from reading like a complete one
  ## (OS-2).
  if not reporter.capturing():
    return TestLease(captured: false)
  var candidateId = 0'u64
  var granted = false
  var lease: RunQuotaLease
  acquire(reporter.lock)
  try:
    candidateId = reporter.nextCandidateId
    inc reporter.nextCandidateId
    let request = ResourceRequest(
      label: testId,
      commandStatsId: statsKeyForTest(testId),
      resources: resourceVector(milliCpu(cpuMilli), bytes(memoryBytes)),
      deadline: noDeadline(),
      priority: priorityNormal,
      metadata: metadataNone())
    for decision in reporter.session.offerCandidates(
        [toCandidate(candidateId, request)]):
      if decision.clientCandidateId != candidateId:
        continue
      if decision.lease.active and not decision.queued:
        granted = true
        lease = decision.lease
      elif decision.lease.active and decision.queued:
        # QUEUED: hand the lease straight back rather than wait for it.
        # A lease left un-released would hold its reservation until the
        # session closes, so abandoning it silently is not an option —
        # abandoning it is fine, leaking it is not.
        var queuedLease = decision.lease
        try:
          queuedLease.release()
        except CatchableError:
          discard
      # A DENIED candidate holds no lease, so there is nothing to
      # release and nothing to record.
  except CatchableError:
    granted = false
  finally:
    if not granted:
      inc reporter.uncapturedExecutions
    release(reporter.lock)
  if granted:
    return TestLease(captured: true, leaseId: lease.id.value, lease: lease)
  TestLease(captured: false)

proc markStarting*(reporter: ptr HistoryReporter; testLease: var TestLease) =
  ## Tell the daemon the child is about to start. THIS IS WHAT STAMPS
  ## ``started_at`` on the spine row, so it must happen immediately
  ## before the spawn and not at admission time — otherwise every
  ## recorded duration includes however long the test waited in the
  ## runner's own queue.
  if not testLease.captured or not reporter.capturing():
    return
  acquire(reporter.lock)
  try:
    testLease.lease.markStarting()
  except CatchableError:
    testLease.captured = false
  release(reporter.lock)

proc markRunning*(reporter: ptr HistoryReporter; testLease: var TestLease;
                  childProcessId, processGroupId: uint64) =
  if not testLease.captured or not reporter.capturing():
    return
  acquire(reporter.lock)
  try:
    testLease.lease.markRunning(childProcessId = childProcessId,
      processGroupId = processGroupId, cleanupRegistered = true)
  except CatchableError:
    testLease.captured = false
  release(reporter.lock)

proc finishExecution*(reporter: ptr HistoryReporter; testLease: var TestLease;
                      outcome: TestExecutionOutcome) =
  ## Close the lease with the facts the spine row is composed from.
  ##
  ## ``hardLimitOrOom`` IS THE WHOLE POINT OF THIS PROC. It is the one
  ## bit that decides between ``termination = oom_killed`` and
  ## ``termination = exited`` for two processes whose exit statuses are
  ## both non-zero and carry no other difference.
  if not testLease.captured or not reporter.capturing():
    return
  acquire(reporter.lock)
  try:
    testLease.lease.finish(
      # THERE IS NO ``leaseFinishTimedOut``, AND NOT INVENTING ONE IS
      # THE POINT. The protocol's outcome set was designed for
      # admission accounting; the runner's own timeout kill arrives at
      # the daemon as a signalled exit, which is what it is. Mapping it
      # onto ``leaseFinishResourceLimit`` to get a distinct termination
      # would put a timeout in the ``oom_killed`` bucket and destroy
      # the one distinction this milestone exists to preserve.
      outcome =
        if outcome.memoryLimitExceeded: leaseFinishResourceLimit
        elif outcome.launchFailed: leaseFinishLaunchFailed
        elif outcome.signalled: leaseFinishCrashed
        elif outcome.exitCode != 0: leaseFinishFailed
        else: leaseFinishSucceeded,
      exitCode = uint32(max(outcome.exitCode, 0)),
      signal = uint32(max(outcome.signal, 0)),
      peakMemoryBytes = outcome.peakRssBytes,
      processCount = outcome.processCount,
      hardLimitOrOom = outcome.memoryLimitExceeded)
  except CatchableError:
    testLease.captured = false
  release(reporter.lock)

proc cellText(value: string): ExtensionCellWire =
  if value.len == 0: wireNull() else: wireText(value)

proc recordRows*(reporter: ptr HistoryReporter; testLease: var TestLease;
                 generic: GenericTestFacts; specific: CodetracerTestFacts) =
  ## Write both extension rows for this execution.
  ##
  ## ONE BUFFERED WRITE EACH, NO REPLY (OS-1). Ordered generic-first so
  ## that a connection that dies between them loses the layer that is
  ## reconstructible from the other's absence, rather than the one every
  ## framework shares.
  if not testLease.captured or not reporter.capturing():
    return
  acquire(reporter.lock)
  try:
    if reporter.genericOk:
      reporter.session.recordExtensionRow(testLease.leaseId,
        TestExecutionExtensionId, TestExecutionSchemaVersion,
        testExecutionColumns(),
        @[
          wireText(generic.testId),
          cellText(generic.suite),
          wireText($generic.status),
          (if generic.durationKnown: wireInt(int64(generic.durationMs))
           else: wireNull()),
          wireInt(int64(generic.attempt)),
          cellText(generic.retryOf),
          cellText(generic.errorMessage),
          cellText(generic.skipReason),
          (if generic.stdoutKnown: wireInt(int64(generic.stdoutLen))
           else: wireNull()),
          (if generic.stderrKnown: wireInt(int64(generic.stderrLen))
           else: wireNull())
        ])
    if reporter.codetracerOk:
      reporter.session.recordExtensionRow(testLease.leaseId,
        CodetracerTestExtensionId, CodetracerTestSchemaVersion,
        codetracerTestColumns(),
        @[
          cellText(specific.recordingPath),
          cellText(specific.traceId),
          cellText(specific.traceFormatVersion),
          cellText(specific.recorder),
          (if specific.replayKnown: wireInt(if specific.replayOk: 1'i64 else: 0'i64)
           else: wireNull()),
          wireInt(if specific.protocolAware: 1'i64 else: 0'i64),
          cellText(specific.runName),
          cellText(specific.bodyHash),
          wireInt(int64(specific.checkpointCount)),
          cellText(specific.statusDisagreement),
          cellText(specific.harnessError)
        ])
    if reporter.runContextOk:
      # THE REVISION, ONE ROW PER EXECUTION AND NOT ONE PER RUN. It is a
      # run-level fact stored at execution grain because the spine is the
      # only key the extension mechanism offers, and because that is the
      # grain ``last-pass`` reads it back at: the answer to "when did this
      # test last pass, and at which revision" is one execution's, not one
      # run's.
      reporter.session.recordExtensionRow(testLease.leaseId,
        TestRunContextExtensionId, TestRunContextSchemaVersion,
        testRunContextColumns(),
        @[cellText(reporter.gitCommit), cellText(reporter.gitBranch)])
  except CatchableError:
    inc reporter.uncapturedExecutions
  release(reporter.lock)

proc releaseLease*(reporter: ptr HistoryReporter; testLease: var TestLease) =
  if not testLease.captured or not reporter.capturing():
    return
  acquire(reporter.lock)
  try:
    testLease.lease.release()
  except CatchableError:
    discard
  testLease.captured = false
  release(reporter.lock)

proc uncaptured*(reporter: ptr HistoryReporter): int =
  ## How many executions ran without a lease behind them.
  if reporter.isNil: 0 else: reporter.uncapturedExecutions

proc close*(reporter: ptr HistoryReporter) =
  if reporter.isNil or not reporter.active:
    return
  acquire(reporter.lock)
  try:
    if reporter.session.active:
      reporter.session.closeSession()
  except CatchableError:
    discard
  try:
    reporter.client.close()
  except CatchableError:
    discard
  reporter.active = false
  release(reporter.lock)
  deinitLock(reporter.lock)
