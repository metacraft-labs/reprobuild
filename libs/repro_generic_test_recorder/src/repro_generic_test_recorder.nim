## ``repro_generic_test_recorder`` — the FRAMEWORK-NEUTRAL write path into
## RunQuota's observation store, for any runner built on the
## ``repro_test_adapters`` contract.
##
## Normative specification:
##
## * ``reprobuild-specs/RunQuota-Observation-Store.md`` §"The Execution
##   Spine", §"Domain Extensions" → "Generic test-execution extension",
##   and invariants OS-1, OS-4, OS-5, OS-8;
## * ``reprobuild-specs/RunQuota-Observation-Store.milestones.org`` §M20.
##
## **WHY THIS EXISTS SEPARATELY FROM ``ct_test_history``, WHICH IS THE
## FINDING M20 WAS BUILT TO SURFACE.** M19 shipped two things: the generic
## SCHEMA (``ct_test_interface/test_execution_extension``) and CodeTracer's
## REPORTER (``ct_test_history``). The schema is reusable from outside
## unchanged, and this milestone reuses it unchanged. The reporter is not,
## and could not be:
##
## * its ``open`` declares ``ext_codetracer_test`` unconditionally, so a
##   second runner using it would register a CodeTracer extension it has
##   no facts for;
## * its ``recordRows`` takes a ``CodetracerTestFacts`` parameter, so a
##   second runner would have to pass a value of a type describing a
##   framework it is not;
## * its ``runs.tool`` is fixed to ``ct-test-runner``, so every run by
##   another runner would be attributed to CodeTracer's.
##
## None of those is a defect in M19 — a reporter is allowed to be its own
## framework's — but together they mean "the generic layer is reusable"
## had to be demonstrated by a SECOND write path rather than by reusing
## the first. This module is that write path, and it is the control that
## makes the demonstration mean something: it declares ONE extension, and
## the only module it shares with CodeTracer's reporter is the schema.
##
## **IT NEVER DECLARES, AND CANNOT WRITE, ANY OTHER EXTENSION.** There is
## no second ``declareExtension`` below and no second ``recordExtensionRow``.
## That is the executable form of M20's "no CodeTracer-specific column is
## required to record a test outcome".
##
## **DEGRADATION (OS-4).** A missing daemon, a refused extension or a dead
## socket returns a "no capture" answer; none of them raises, and a
## missing daemon is never reported as an error.

import std/[locks, strutils]

import repro_test_adapters

import runquota_core
import runquota_codec
import runquota_client
import runquota_protocol

const MaxStatsKeyBytes = 64
  ## The protocol's own bound on ``command_stats_id``. The encoder
  ## TRUNCATES silently past it, which would collapse two long test names
  ## onto one statistics key.

proc statsKeyForGenericTest*(testId: string): string =
  ## The ``command_stats_id`` for a test.
  ##
  ## A SECOND IMPLEMENTATION OF THE SAME RULE ``ct_test_history`` applies,
  ## and — unlike the extension triple — that is acceptable here, for a
  ## reason worth stating rather than assuming. The triple must be shared
  ## because a drift in it LOSES ROWS SILENTLY (a second table nothing
  ## queries, an owner nothing re-validates). This is a bound of the RQSP
  ## ENCODER, not of the extension: two runners that derive keys
  ## differently produce differently-named admission keys, which is
  ## visible in every ``stats`` surface and costs no row. The generic
  ## queries in ``repro_test_stats`` group by the ``test_id`` COLUMN and
  ## never by this key, so nothing OS-8 is about depends on it.
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

type
  GenericTestLease* = object
    ## One test execution's lease. ``captured == false`` is the ordinary
    ## no-daemon answer and is not an error.
    captured*: bool
    leaseId*: uint64
    lease: RunQuotaLease

  GenericTestOutcomeProcess* = object
    ## What the runner OBSERVED about the process it ran. The spine row is
    ## composed by RunQuota from these; the runner composes none of it.
    exitCode*: int
    signalled*: bool
    signal*: int
    launchFailed*: bool

  GenericTestRecorder* = object
    ## Shared by every worker. THE SOCKET IS THE SHARED RESOURCE AND THE
    ## LOCK GUARDS IT, for the reason ``ct_test_history`` states: RQSP is
    ## request/response on one connection, so two threads writing frames
    ## concurrently would interleave them.
    ##
    ## ONE SESSION PER RUN, not one per worker: the daemon opens exactly
    ## one ``runs`` row per registered session, and a session per worker
    ## would shatter one test run into N run records.
    lock: Lock
    client: RunQuotaClient
    session: RunQuotaSession
    active: bool
    declared: bool
    nextCandidateId: uint64
    uncapturedExecutions: int
      ## Executions whose history is INCOMPLETE. COUNTED, because OS-2
      ## forbids presenting a thinned sample as a complete one.

proc open*(recorder: ptr GenericTestRecorder; toolName, toolVersion: string):
    bool =
  ## Connect, register the session under the RUNNER'S OWN identity, and
  ## declare the generic extension.
  ##
  ## ``toolName`` is the runner's, not CodeTracer's. The two runners'
  ## RUNS are therefore distinguishable — which is right, they are
  ## different tools — while their generic ROWS are not, which is what
  ## OS-8 requires.
  initLock(recorder.lock)
  recorder.nextCandidateId = 1'u64
  try:
    recorder.client = connectDefault()
  except CatchableError:
    return false
  try:
    recorder.session = recorder.client.registerSession(toolName, toolVersion)
    recorder.active = true
  except CatchableError:
    try: recorder.client.close()
    except CatchableError: discard
    return false
  # THE ONE DECLARATION, AND ITS TRIPLE IS NOT SPELLED HERE EITHER. The
  # value comes from ``repro_test_adapters``, which imports it from
  # ``ct_test_interface`` — the same constants ``ct_test_history``
  # declares. A second spelling anywhere on this path would produce a
  # second table that no query joins, and RunQuota would report nothing.
  let declaration = testExecutionDeclaration()
  try:
    recorder.declared = recorder.session.declareExtension(
      declaration.extensionId, declaration.owner, declaration.schemaVersion,
      declaration.migrations).len == 0
  except CatchableError:
    recorder.declared = false
  true

proc capturing*(recorder: ptr GenericTestRecorder): bool =
  not recorder.isNil and recorder.active

proc declaredOk*(recorder: ptr GenericTestRecorder): bool =
  not recorder.isNil and recorder.declared

proc uncaptured*(recorder: ptr GenericTestRecorder): int =
  if recorder.isNil: 0 else: recorder.uncapturedExecutions

proc acquireLease*(recorder: ptr GenericTestRecorder; testId: string;
                   cpuMilli = 1000'u32;
                   memoryBytes = 128'u64 * 1024'u64 * 1024'u64):
    GenericTestLease =
  ## Take a lease for one test execution.
  ##
  ## **ADMISSION NEVER GATES THE RUNNER.** A candidate the daemon QUEUES
  ## is released and capture is given up for that one execution, per OS-1:
  ## "Recording an observation MUST NOT block ... Losing an observation is
  ## always preferable to perturbing the work being observed." A reporter
  ## that waited for capacity would be delaying the very executions whose
  ## durations it is recording.
  ##
  ## Abandoning a queued lease is fine; LEAKING one is not — an
  ## unreleased lease holds its reservation until the session closes.
  if not recorder.capturing():
    return GenericTestLease(captured: false)
  var candidateId = 0'u64
  var granted = false
  var lease: RunQuotaLease
  acquire(recorder.lock)
  try:
    candidateId = recorder.nextCandidateId
    inc recorder.nextCandidateId
    let request = ResourceRequest(
      label: testId,
      commandStatsId: statsKeyForGenericTest(testId),
      resources: resourceVector(milliCpu(cpuMilli), bytes(memoryBytes)),
      deadline: noDeadline(),
      priority: priorityNormal,
      metadata: metadataNone())
    for decision in recorder.session.offerCandidates(
        [toCandidate(candidateId, request)]):
      if decision.clientCandidateId != candidateId:
        continue
      if decision.lease.active and not decision.queued:
        granted = true
        lease = decision.lease
      elif decision.lease.active and decision.queued:
        var queuedLease = decision.lease
        try:
          queuedLease.release()
        except CatchableError:
          discard
  except CatchableError:
    granted = false
  finally:
    if not granted:
      inc recorder.uncapturedExecutions
    release(recorder.lock)
  if granted:
    return GenericTestLease(captured: true, leaseId: lease.id.value,
      lease: lease)
  GenericTestLease(captured: false)

proc markStarting*(recorder: ptr GenericTestRecorder;
                   testLease: var GenericTestLease) =
  ## Stamps ``started_at``. Immediately before the spawn and not at
  ## admission time, or every recorded duration would include however long
  ## the case waited in the runner's own queue.
  if not testLease.captured or not recorder.capturing():
    return
  acquire(recorder.lock)
  try:
    testLease.lease.markStarting()
  except CatchableError:
    testLease.captured = false
  release(recorder.lock)

proc markRunning*(recorder: ptr GenericTestRecorder;
                  testLease: var GenericTestLease;
                  childProcessId, processGroupId: uint64) =
  if not testLease.captured or not recorder.capturing():
    return
  acquire(recorder.lock)
  try:
    testLease.lease.markRunning(childProcessId = childProcessId,
      processGroupId = processGroupId, cleanupRegistered = true)
  except CatchableError:
    testLease.captured = false
  release(recorder.lock)

proc finishExecution*(recorder: ptr GenericTestRecorder;
                      testLease: var GenericTestLease;
                      process: GenericTestOutcomeProcess) =
  ## Close the lease with the facts the spine row is composed from.
  ##
  ## NO ``leaseFinishResourceLimit`` ARM, and its absence is deliberate:
  ## this runner enforces no memory ceiling, so it never KNOWS a kill was
  ## an OOM. Reporting one would put a guess where ``ct_test_history``
  ## puts an observation, and ``termination = oom_killed`` would stop
  ## meaning what §"executions" says it means.
  if not testLease.captured or not recorder.capturing():
    return
  acquire(recorder.lock)
  try:
    testLease.lease.finish(
      outcome =
        if process.launchFailed: leaseFinishLaunchFailed
        elif process.signalled: leaseFinishCrashed
        elif process.exitCode != 0: leaseFinishFailed
        else: leaseFinishSucceeded,
      exitCode = uint32(max(process.exitCode, 0)),
      signal = uint32(max(process.signal, 0)),
      peakMemoryBytes = 0'u64,
      processCount = 1'u32,
      hardLimitOrOom = false)
  except CatchableError:
    testLease.captured = false
  release(recorder.lock)

proc toWire(cell: ObservationCell): ExtensionCellWire =
  case cell.kind
  of ockNull: wireNull()
  of ockText: wireText(cell.text)
  of ockInt: wireInt(cell.number)

proc recordRow*(recorder: ptr GenericTestRecorder;
                testLease: var GenericTestLease; outcome: TestOutcome) =
  ## Write the ONE extension row this runner has.
  ##
  ## ONE BUFFERED WRITE, NO REPLY (OS-1). The values come from
  ## ``repro_test_adapters``' row builder, positionally matched to its
  ## column list, so the two cannot drift apart here.
  if not testLease.captured or not recorder.capturing() or
      not recorder.declared:
    return
  var cells: seq[ExtensionCellWire] = @[]
  for cell in testExecutionRow(outcome):
    cells.add(cell.toWire())
  acquire(recorder.lock)
  try:
    recorder.session.recordExtensionRow(testLease.leaseId,
      TestExecutionExtensionId, TestExecutionSchemaVersion,
      testExecutionRowColumns(), cells)
  except CatchableError:
    inc recorder.uncapturedExecutions
  release(recorder.lock)

proc releaseLease*(recorder: ptr GenericTestRecorder;
                   testLease: var GenericTestLease) =
  if not testLease.captured or not recorder.capturing():
    return
  acquire(recorder.lock)
  try:
    testLease.lease.release()
  except CatchableError:
    discard
  testLease.captured = false
  release(recorder.lock)

proc close*(recorder: ptr GenericTestRecorder) =
  if recorder.isNil or not recorder.active:
    return
  acquire(recorder.lock)
  try:
    if recorder.session.active:
      recorder.session.closeSession()
  except CatchableError:
    discard
  try:
    recorder.client.close()
  except CatchableError:
    discard
  recorder.active = false
  release(recorder.lock)
  deinitLock(recorder.lock)
