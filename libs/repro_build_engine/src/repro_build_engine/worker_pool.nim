## Engine-Threadpool TP-1 — the engine's reusable worker pool.
##
## WHAT THIS IS FOR. ``In-Process-Monitor-Hosting`` measured hosting as a null
## at the default parallelism and a 1.5-2.4x REGRESSION on cheap actions, and
## attributed both to one cause: the spawned form pays its post-exit evidence
## assembly inside N concurrent monitor PROCESSES, while the hosted form pays
## it serially on the scheduler's single poll loop. The spawn was buying
## concurrency. This module buys it back for the price of a thread handoff.
##
## WHAT SHIPS HERE is the pool, its shutdown discipline, its backpressure, and
## its tenant table. TWO tenants use it today: HM-5's depfile flush
## (``monitor_flush.nim``, absorbed from a bespoke thread by TP-1) and TP-2's
## ``finishMonitor`` (the TP-2 block in ``repro_build_engine.nim``, which
## lives there rather than in a leaf module of its own because
## ``t_every_launch_path_is_monitored`` requires every ``finishMonitor``
## call site — and every import of ``io_mon`` — to be in that one file).
##
## TP-2 SOLVED THE HANDOFF PROBLEM THIS HEADER USED TO CALL UNSOLVED, and it
## did so WITHOUT relaxing anything. ``MonitorHandle`` is still non-copyable
## and ``createThread``'s ``param`` is still not ``sink`` — 16 of DH-2's 19
## attacks are still refused by the compiler, and TP-2's own probes re-check
## that against its carrier. The way out was that this pool never hands a
## worker a ``createThread`` payload in the first place: a job is a ``ptr`` to
## an intrusive node in ``allocShared0`` memory, so a handle is MOVED into the
## node on one thread and MOVED out of it on another, and a copy is refused at
## every step. See the TP-2 block's header for the LF-2 argument in
## full, and for the one rule of this module that tenant has to break.
##
## NOTHING GARBAGE-COLLECTED CROSSES THE BOUNDARY, AND THAT IS PROVED BY THE
## COMPILER RATHER THAN ASSERTED HERE.
##
##   * Every global in this module is a lock, a condition variable, a raw
##     pointer, a ``Thread`` object, a fixed ``array`` of ints or a fixed
##     ``array`` of ``char``. Not one of them holds GC'd memory, so
##     ``enginePoolWorkerLoop`` is ``gcsafe`` because the compiler can see it
##     is, not because it was cast. HM-5's worker was written this way after
##     its first draft — which used GC'd ``seq``s — was rejected outright
##     (``not GC-safe as it accesses 'flushQueue'``), and the same discipline
##     is what this module inherits. A ``{.cast(gcsafe).}`` anywhere below
##     would be a defect, not a workaround.
##   * A job is an INTRUSIVE node in ``allocShared0`` memory. A tenant embeds
##     ``EnginePoolJobObj`` as the FIRST field of its own node type and casts
##     back inside its task; the pool never sees the tenant's payload and the
##     tenant never hands the pool a Nim value.
##   * The task and release hooks are ``{.nimcall, gcsafe.}`` proc types —
##     bare code pointers with no closure environment. A ``closure`` would
##     carry a GC'd environment across the boundary and is refused by the type.
##
## WHY NOT A ``ref``, STATED BECAUSE THE OBVIOUS SHAPE WAS TRIED AND MEASURED.
## ORC's reference counts are atomic only under ``-d:gcAtomicArc``. HM-3
## shipped a ``ref object`` shared across six threads and it raced its own
## counter: 12 TSAN races on ``nimIncRef``, surfacing as a ONE-IN-SIX SIGSEGV
## in an unrelated test. That is why nim-shm-gset's ``SetPool`` became a raw
## ``ptr``, and it is why every handle in this file is one too. A clean run
## proves nothing about this class of bug; the pool's own tests are run under
## TSAN and ASan/UBSan for that reason.
##
## THE PROCESS-GLOBAL WINDOW THIS POOL RUNS ALONGSIDE, checked rather than
## assumed. ``beginMonitorSpawnContext`` (``repro_build_engine.nim``) redirects
## descriptors 0/1/2 and sets ``umask(0022)`` around a hosted spawn, and its
## doc-comment says in so many words that this is safe only while the engine is
## single-threaded and that a worker thread is the first thing to break it.
## It still holds, and it holds for REASONS that are properties of the tenants
## rather than of the pool — so EVERY NEW TENANT OWES THIS PARAGRAPH AN ANSWER:
##
##   * ``dup2`` on 0/1/2 — ``dup2`` never leaves a standard descriptor closed,
##     so there is no window in which an ``open`` on a worker could be handed
##     1 or 2. The flush worker opens nothing at all (io-mon creates the
##     scratch file; the worker renames it). The FINISH worker does create a
##     file — io-mon's canonical iomon — at an absolute path the scheduler
##     chose, which is safe for the reason just given.
##   * ``umask(0022)`` — the flush worker creates no file, so no mode is
##     decided inside the window. The finish worker can create one inside it,
##     and the consequence is bounded and declared in
##     the TP-2 block's header: 0022 is the canonical mask this
##     repository pins for every spawned tool, so a depfile created inside the
##     window is masked MORE canonically, never less.
##
## THE WORKERS NEVER WRITE TO ``stdout``, and write to ``stderr`` on exactly
## one error-only path (io-mon's ``MonitorHandle`` destructor warning, declared
## in the TP-2 block). The reason for the rule is that a diagnostic
## emitted inside the redirect window would land in some action's captured
## output. Failures come back as outcomes.

import std/[cpuinfo, locks, os, strutils]

from std/times import epochTime

const
  MaxEnginePoolWorkers* = 64
    ## Hard ceiling on the worker array. The array is fixed rather than a
    ## ``seq`` so this module keeps no GC'd global at all (see the header).

  MaxEnginePoolTenants* = 8
    ## Fixed tenant table, same reason. Two tenants today — HM-5's depfile
    ## flush and TP-2's monitor finish — and P5 may add a chain provider.

  EnginePoolWorkersEnvVar* = "REPROBUILD_ENGINE_POOL_WORKERS"
  EnginePoolQueueLimitEnvVar* = "REPROBUILD_ENGINE_POOL_QUEUE_LIMIT"

  DefaultEnginePoolQueueLimit* = 1024
    ## See ``submitEnginePoolJob`` for why a bound exists and what happens
    ## when it is reached.

  EnginePoolTenantNameLimit = 48

type
  EnginePoolTenant* = distinct int
    ## An opaque index into the pool's fixed tenant table, handed out by
    ## ``registerEnginePoolTenant``. Distinct so it cannot be confused with a
    ## queue depth or a worker index at a call site.

  EnginePoolJob* = ptr EnginePoolJobObj

  EnginePoolTask* = proc (job: EnginePoolJob): cstring {.nimcall, gcsafe.}
    ## The tenant's work, run on a worker thread.
    ##
    ## Returns ``nil`` on success, or a message allocated with
    ## ``sharedDup`` that the POOL takes ownership of and frees. Returning a
    ## Nim ``string`` is not an option and that is deliberate: it would be the
    ## GC'd value crossing the boundary that this whole module exists to make
    ## unrepresentable.
    ##
    ## A task MAY raise. The worker catches it and turns it into a failed
    ## outcome for that job alone — see ``runOneEnginePoolJob``.

  EnginePoolRelease* = proc (job: EnginePoolJob) {.nimcall, gcsafe.}
    ## Free the tenant's own node, INCLUDING the ``EnginePoolJobObj`` header
    ## embedded in it. Called on the worker thread after the task has run and
    ## after the pool has taken what it needs out of the header.

  EnginePoolJobObj* = object
    ## The pool's half of a job. A tenant embeds this as the FIRST field of
    ## its own node type so ``cast`` between the two is an identity on the
    ## address; every tenant asserts that statically.
    next: EnginePoolJob
    run: EnginePoolTask
    release: EnginePoolRelease
    tenant: int
    key: cstring
      ## The tenant's own name for this job — an action id, for the flush.
      ## Owned by the POOL: allocated in ``submitEnginePoolJob`` and moved
      ## into the outcome, so a tenant's ``release`` must not touch it.

  EnginePoolOutcome* = object
    ## One completed job, as the submitting thread learns about it.
    key*: string
    error*: string
      ## Empty on success. Non-empty is either the message the task returned
      ## or the description of an exception that escaped it.

  OutcomeNode = ptr OutcomeNodeObj
  OutcomeNodeObj = object
    next: OutcomeNode
    tenant: int
    key: cstring
    error: cstring

var poolLock: Lock
var poolWork: Cond
  ## Signalled when a job is queued or when shutdown is requested. Waited on
  ## by workers.
var poolProgress: Cond
  ## Signalled when a job leaves the queue or completes. Waited on by
  ## submitters blocked on backpressure.
var jobHead: EnginePoolJob = nil
var jobTail: EnginePoolJob = nil
var outcomeHead: OutcomeNode = nil
var queuedJobs: int = 0
var tenantPending: array[MaxEnginePoolTenants, int]
var tenantNames: array[MaxEnginePoolTenants, array[EnginePoolTenantNameLimit, char]]
var tenantCount: int = 0
var poolWorkers: array[MaxEnginePoolWorkers, Thread[int]]
var poolWorkerCount: int = 0
var poolQueueLimit: int = 0
var configuredWorkers: int = 0
var configuredQueueLimit: int = 0
var poolStarted: bool = false
var poolStopping: bool = false

initLock(poolLock)
initCond(poolWork)
initCond(poolProgress)

proc sharedDup*(value: string): cstring =
  ## Copy a Nim string into shared, manually-managed memory. NOT the GC's:
  ## the block outlives the caller's string and is released by ``sharedFree``
  ## on whichever thread consumes it.
  let n = value.len
  result = cast[cstring](allocShared0(n + 1))
  if n > 0:
    copyMem(result, value.cstring, n)

proc sharedFree*(value: var cstring) =
  if value != nil:
    deallocShared(value)
    value = nil

proc enginePoolJobKey*(job: EnginePoolJob): cstring =
  ## The key this job was submitted under, readable from inside a task. Valid
  ## for the duration of the task and not afterwards.
  job.key

proc `==`*(a, b: EnginePoolTenant): bool {.borrow.}

proc registerEnginePoolTenant*(name: string): EnginePoolTenant =
  ## Claim a slot in the fixed tenant table. Called once, from a tenant
  ## module's initialisation, on the main thread and before any worker exists.
  ##
  ## Registering the SAME name twice returns the SAME slot rather than
  ## consuming a second one, so a tenant module that is initialised twice —
  ## which a test binary linking two entry points can do — does not silently
  ## split its pending count across two slots and make ``awaitEnginePool*``
  ## report idle while its own work is still queued.
  ## A name longer than ``EnginePoolTenantNameLimit - 1`` is REFUSED rather
  ## than truncated. Truncating broke the idempotence promised above: the
  ## stored name was cut to fit but compared against the FULL argument, so a
  ## long name never matched itself and claimed a fresh slot on every call.
  ## Comparing prefix-to-prefix would be worse — two tenants sharing a
  ## 47-character prefix would silently share one slot, and each would then
  ## see the other's pending count. Tenant names are compile-time constants,
  ## so refusing is a programming error caught on the first call rather than
  ## a hazard that waits for a long name.
  if name.len > EnginePoolTenantNameLimit - 1:
    raise newException(ValueError,
      "engine pool: tenant name " & name.escape & " is " & $name.len &
      " characters; the limit is " & $(EnginePoolTenantNameLimit - 1) &
      ". Names are fixed-size because the tenant table must hold no GC'd " &
      "memory (a worker touching a GC'd global is refused by the compiler).")
  var stored = -1
  acquire(poolLock)
  for i in 0 ..< tenantCount:
    if $cast[cstring](addr tenantNames[i][0]) == name:
      stored = i
      break
  if stored < 0:
    if tenantCount >= MaxEnginePoolTenants:
      release(poolLock)
      raise newException(ValueError,
        "engine pool: more than " & $MaxEnginePoolTenants &
        " tenants registered; raise MaxEnginePoolTenants")
    stored = tenantCount
    let n = name.len          # bounded by the refusal above
    for i in 0 ..< n:
      tenantNames[stored][i] = name[i]
    tenantNames[stored][n] = '\0'
    inc tenantCount
  release(poolLock)
  EnginePoolTenant(stored)

proc defaultWorkerCount(): int =
  ## SIZING, and the number is a floor rather than a guess at the optimum.
  ##
  ## The work a tenant puts here is post-exit: HM-5's publication and TP-2's
  ## ``finishMonitor``, whose §4.1 ``/proc`` sweep cannot run until
  ## the monitored root has exited. Its natural concurrency is therefore the
  ## number of actions finishing at once, which is bounded by the build's
  ## parallelism — but this pool is a process-global started lazily on first
  ## use, and the engine's ``maxParallelism`` is not known here. Callers that
  ## do know it can say so through ``configureEnginePool``.
  ##
  ## Four is small on purpose. The whole point of the milestone is to remove a
  ## SERIALISATION, and the second worker removes most of it; the marginal
  ## worker after that competes with the scheduler's own poll loop and with N
  ## monitored children for the same cores. A machine with fewer cores than
  ## that gets fewer workers. TP-3's acceptance run is where a different number
  ## would have to be argued from measurement rather than from taste.
  let fromEnv = getEnv(EnginePoolWorkersEnvVar, "")
  if fromEnv.len > 0:
    try:
      return max(1, min(parseInt(fromEnv), MaxEnginePoolWorkers))
    except ValueError:
      discard
  max(1, min(4, countProcessors()))

proc defaultQueueLimit(): int =
  let fromEnv = getEnv(EnginePoolQueueLimitEnvVar, "")
  if fromEnv.len > 0:
    try:
      return max(1, parseInt(fromEnv))
    except ValueError:
      discard
  DefaultEnginePoolQueueLimit

proc configureEnginePool*(workers = 0; queueLimit = 0) =
  ## Set the sizing the NEXT start will use. Takes effect when the pool is
  ## started, so a caller that wants to be heard must call this before the
  ## first submit (or after ``shutdownEnginePool``). Zero means "leave to the
  ## default", which is what makes this safe to call with one field set.
  acquire(poolLock)
  if workers > 0:
    configuredWorkers = max(1, min(workers, MaxEnginePoolWorkers))
  if queueLimit > 0:
    configuredQueueLimit = queueLimit
  release(poolLock)

proc resetEnginePoolConfiguration*() =
  ## Forget everything ``configureEnginePool`` was told, so the next start
  ## derives its sizing the way an ordinary build does. Exists so a test that
  ## narrows the pool to make a property observable cannot leave the next
  ## test — or the next build in the same process — running under its sizing.
  acquire(poolLock)
  configuredWorkers = 0
  configuredQueueLimit = 0
  release(poolLock)

proc runOneEnginePoolJob(job: EnginePoolJob) {.gcsafe.} =
  ## Run one job to completion and record its outcome.
  ##
  ## A FAULT FAILS ITS JOB, NOT THE BUILD. This is the pool's half of the
  ## property ``t_monitor_fault_fails_the_action_not_the_daemon`` pins for the
  ## in-process host: hosting removed the process boundary that used to
  ## contain a decode or parse fault, and a pool removes the remaining one —
  ## an exception escaping a worker's thread proc terminates the whole
  ## process. Both arms are caught here, ``CatchableError`` for the ordinary
  ## case and ``Exception`` for a ``Defect`` (which, with the default
  ## ``--panics:off``, is raised as an ordinary exception and would otherwise
  ## take the engine down).
  ##
  ## The strings built below are created and destroyed on THIS thread; only
  ## the ``sharedDup`` copy crosses back.
  var err: cstring = nil
  try:
    if job.run != nil:
      err = job.run(job)
  except CatchableError as caught:
    err = sharedDup("engine pool worker fault: " & $caught.name & ": " &
      caught.msg)
  except Exception as caught:
    err = sharedDup("engine pool worker fault (defect): " & $caught.name &
      ": " & caught.msg)

  let outcome = cast[OutcomeNode](allocShared0(sizeof(OutcomeNodeObj)))
  outcome.tenant = job.tenant
  # MOVED, not copied: the pool owns ``key`` and hands ownership to the
  # outcome, so the tenant's ``release`` below cannot free it twice.
  outcome.key = job.key
  job.key = nil
  outcome.error = if err == nil: sharedDup("") else: err
  let tenant = job.tenant

  if job.release != nil:
    try:
      job.release(job)
    except CatchableError:
      discard
    except Exception:
      discard

  acquire(poolLock)
  outcome.next = outcomeHead
  outcomeHead = outcome
  dec tenantPending[tenant]
  broadcast(poolProgress)
  release(poolLock)

proc enginePoolWorkerLoop(index: int) {.thread.} =
  discard index
  while true:
    acquire(poolLock)
    while jobHead == nil and not poolStopping:
      wait(poolWork, poolLock)
    if jobHead == nil:
      # Only reachable with ``poolStopping`` set AND the queue empty. THE
      # ORDER OF THE TWO CONDITIONS IS THE DRAIN GUARANTEE: a stop request
      # never abandons queued work, it only stops the loop once there is none
      # left. Reversing them is the mutation that makes
      # ``the pool drains on shutdown`` red.
      release(poolLock)
      break
    let job = jobHead
    jobHead = job.next
    if jobHead == nil:
      jobTail = nil
    dec queuedJobs
    # A submitter parked on backpressure may now have room.
    broadcast(poolProgress)
    release(poolLock)

    runOneEnginePoolJob(job)

proc ensureEnginePoolWorkers() =
  ## Start the workers on first use and never before: a build that submits
  ## nothing — which is every build today, since monitor hosting is off by
  ## default — creates no thread at all. Inherited verbatim from HM-5's
  ## ``ensureMonitorFlushWorker``, whose behaviour this preserves.
  var toStart = 0
  acquire(poolLock)
  if poolStarted:
    release(poolLock)
    return
  poolStopping = false
  poolQueueLimit =
    if configuredQueueLimit > 0: configuredQueueLimit else: defaultQueueLimit()
  poolWorkerCount =
    if configuredWorkers > 0: configuredWorkers else: defaultWorkerCount()
  poolStarted = true
  toStart = poolWorkerCount
  release(poolLock)
  for i in 0 ..< toStart:
    createThread(poolWorkers[i], enginePoolWorkerLoop, i)

proc submitEnginePoolJob*(tenant: EnginePoolTenant; key: string;
                          job: EnginePoolJob; run: EnginePoolTask;
                          releaseHook: EnginePoolRelease) =
  ## Hand one job to the pool. Returns as soon as it is queued.
  ##
  ## BACKPRESSURE. The queue is BOUNDED and a submitter that finds it full
  ## BLOCKS until a worker takes something off it. That is a deliberate choice
  ## between three options, and the other two are worse: an unbounded queue
  ## makes a slow filesystem look like a memory leak (a real ``nim c`` action
  ## carries an 18 MB record set, and the queue is the only thing between the
  ## scheduler and however many of those are in flight), while DROPPING a job
  ## would make "no work is silently dropped" false by construction. Blocking
  ## costs the scheduler a pause exactly when the pool is already the
  ## bottleneck, which is the case where serialising was going to happen
  ## anyway.
  ##
  ## The default bound is 1024, so no build that exists today reaches it; it
  ## is a guard, not a scheduling policy. ``configureEnginePool`` lowers it,
  ## which is how the property is tested at all.
  ensureEnginePoolWorkers()
  job.run = run
  job.release = releaseHook
  job.tenant = int(tenant)
  job.key = sharedDup(key)
  job.next = nil

  acquire(poolLock)
  while queuedJobs >= poolQueueLimit and not poolStopping:
    wait(poolProgress, poolLock)
  if jobTail == nil:
    jobHead = job
    jobTail = job
  else:
    jobTail.next = job
    jobTail = job
  inc queuedJobs
  # PENDING COUNTS QUEUED **AND** IN FLIGHT, and is decremented only when the
  # outcome is recorded. ``awaitEnginePoolOutcome``'s idle test reads it, so a
  # count that dropped at dequeue would let a caller conclude "nothing left to
  # wait for" while a worker was still mid-job.
  inc tenantPending[int(tenant)]
  signal(poolWork)
  release(poolLock)

proc takeOutcomes(tenant: EnginePoolTenant): seq[EnginePoolOutcome] =
  ## Move this tenant's completed outcomes out of shared memory and back into
  ## ordinary Nim values, leaving every OTHER tenant's outcomes in place.
  var takenHead: OutcomeNode = nil
  var takenTail: OutcomeNode = nil
  var keptHead: OutcomeNode = nil
  var keptTail: OutcomeNode = nil
  let want = int(tenant)

  acquire(poolLock)
  var node = outcomeHead
  while node != nil:
    let nxt = node.next
    node.next = nil
    if node.tenant == want:
      if takenTail == nil: takenHead = node else: takenTail.next = node
      takenTail = node
    else:
      if keptTail == nil: keptHead = node else: keptTail.next = node
      keptTail = node
    node = nxt
  outcomeHead = keptHead
  release(poolLock)

  # Both lists are built head-first by the workers, so walking either yields
  # newest-first. The split above preserves that for what is kept (so a later
  # drain reverses correctly) and the loop below reverses what is taken into
  # completion order, because a diagnostic naming several jobs should read in
  # the order they happened.
  var collected: seq[EnginePoolOutcome] = @[]
  node = takenHead
  while node != nil:
    let nxt = node.next
    collected.add EnginePoolOutcome(key: $node.key, error: $node.error)
    sharedFree(node.key)
    sharedFree(node.error)
    deallocShared(node)
    node = nxt
  result = @[]
  for i in countdown(collected.len - 1, 0):
    result.add collected[i]

proc drainEnginePoolOutcomes*(tenant: EnginePoolTenant):
    seq[EnginePoolOutcome] =
  ## Every job of this tenant that has COMPLETED since the last drain, without
  ## blocking on the ones that have not.
  takeOutcomes(tenant)

proc enginePoolPending*(tenant: EnginePoolTenant): int =
  ## Jobs of this tenant that are queued or in flight.
  acquire(poolLock)
  result = tenantPending[int(tenant)]
  release(poolLock)

proc enginePoolQueueDepth*(): int =
  ## Jobs waiting for a worker, across every tenant. The quantity the
  ## backpressure bound applies to.
  acquire(poolLock)
  result = queuedJobs
  release(poolLock)

proc enginePoolWorkerCount*(): int =
  acquire(poolLock)
  result = poolWorkerCount
  release(poolLock)

proc awaitEnginePoolOutcome*(tenant: EnginePoolTenant; key: string;
                             timeoutSeconds = 30.0): seq[EnginePoolOutcome] =
  ## Block until ONE named job has completed, then drain every outcome this
  ## tenant has accumulated.
  ##
  ## ``idle`` is not a timeout in disguise. With nothing of this tenant's in
  ## flight, the named job's outcome was either drained by an earlier call —
  ## in which case the caller already recorded it — or never queued, which is
  ## what a monitor fault leaves behind. Waiting longer would answer neither.
  let deadline = epochTime() + timeoutSeconds
  while true:
    var found = false
    var idle = false
    acquire(poolLock)
    var n = outcomeHead
    while n != nil:
      if n.tenant == int(tenant) and $n.key == key:
        found = true
        break
      n = n.next
    idle = tenantPending[int(tenant)] <= 0
    release(poolLock)
    if found or idle or epochTime() >= deadline:
      break
    sleep(1)
  takeOutcomes(tenant)

proc awaitEnginePoolTenantIdle*(tenant: EnginePoolTenant;
                                timeoutSeconds = 30.0):
    seq[EnginePoolOutcome] =
  ## Wait for every one of this tenant's queued jobs and return the outcomes
  ## not yet drained.
  let deadline = epochTime() + timeoutSeconds
  while true:
    acquire(poolLock)
    let remaining = tenantPending[int(tenant)]
    release(poolLock)
    if remaining <= 0 or epochTime() >= deadline:
      break
    sleep(1)
  takeOutcomes(tenant)

proc awaitEnginePoolIdle*(timeoutSeconds = 30.0): bool {.discardable.} =
  ## Wait for EVERY tenant's work to finish. Returns false if the deadline
  ## expired first.
  ##
  ## Outcomes are deliberately left in place: they belong to their tenants,
  ## and a generic drain that consumed them would make a tenant's own
  ## ``drain`` silently return nothing.
  let deadline = epochTime() + timeoutSeconds
  while true:
    var remaining = 0
    acquire(poolLock)
    for i in 0 ..< tenantCount:
      remaining += tenantPending[i]
    release(poolLock)
    if remaining <= 0:
      return true
    if epochTime() >= deadline:
      return false
    sleep(1)

proc shutdownEnginePool*() =
  ## Stop the workers and join them.
  ##
  ## NO WORK IS DROPPED, AND THE JOIN IS THE ONLY MECHANISM THAT MAKES THAT
  ## TRUE. A worker exits its loop only when the queue is EMPTY **and**
  ## stopping is set, and it never abandons the job it is holding, so joining
  ## every worker is exactly "every submitted job has run". There is
  ## deliberately no pre-wait on ``awaitEnginePoolIdle`` in front of this: a
  ## belt-and-braces wait would drain the queue before the stop flag was ever
  ## seen, and the loop's own ordering — the thing that actually guarantees
  ## this — would then be untested. ``the pool drains on shutdown`` reddens on
  ## reversing that ordering precisely because nothing else here covers for
  ## it.
  ##
  ## AND THEREFORE NO TIMEOUT. A guard here could only be honoured by
  ## abandoning a worker mid-job, which is the failure this call exists to
  ## rule out. Callers that want a bounded wait want
  ## ``awaitEnginePoolIdle``, which has one and does not stop anything.
  ##
  ## The pool can be started again afterwards — the next ``submit`` brings up
  ## fresh workers. That is what keeps a test process able to exercise the
  ## pool more than once.
  var toJoin = 0
  acquire(poolLock)
  if not poolStarted:
    release(poolLock)
    return
  poolStopping = true
  toJoin = poolWorkerCount
  broadcast(poolWork)
  broadcast(poolProgress)
  release(poolLock)

  for i in 0 ..< toJoin:
    joinThread(poolWorkers[i])

  acquire(poolLock)
  poolStarted = false
  poolStopping = false
  poolWorkerCount = 0
  release(poolLock)
