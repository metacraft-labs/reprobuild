## In-Process-Monitor-Hosting HM-5 — the depfile flush, made ASYNCHRONOUS and
## ATOMIC.
##
## WHAT A "FLUSH" IS HERE, precisely, because the milestone's one-line
## description does not survive contact with the code and a reader who assumes
## it does will mis-read every proc below.
##
## io-mon owns the canonical RMDF write. ``finishMonitor`` produces the evidence
## through ``collectMonitorEvidence`` -> ``mergeFragments`` ->
## ``writeCanonicalInPlace``, and there is no request field, no option and no
## alternative entry point that lets a host obtain the records WITHOUT that
## write happening. So reprobuild cannot move the encode+write off its serial
## path from this side; what it can do — and what this module does — is decide
## WHERE io-mon writes and WHEN that write becomes the published ``.rdep``:
##
##   * io-mon is pointed at a TEMPORARY file in the destination's OWN
##     directory (``monitorFlushTempPath``), never at the destination;
##   * the engine hands the action's result and its in-memory evidence to the
##     scheduler immediately;
##   * this module's worker publishes the temp file with a single ``rename``,
##     off the scheduler's thread.
##
## WITH ONE DELIBERATE EXCEPTION, stated here so the header is not read as an
## unconditional claim: a CACHEABLE action waits for its own publication at the
## point it publishes a cache entry (``awaitMonitorFlush``). Everything before
## that — the action's result, its evidence, its converters, its output
## invalidation — proceeds without waiting, and a non-cacheable action never
## waits at all. The reason is in ``awaitMonitorFlush``: without it the
## "a failed flush costs a re-execution" guarantee is a race, and it was
## measured going both ways.
##
## MEASURED, so the next agent does not have to re-derive it (Linux, this
## machine, a real ``nim c`` provider-compile depfile of 97 217 records /
## 18 MB, and a trivial monitored action's 140 records / 25 KB):
##
##   |             | encode+write | of which real I/O | decode (read-back) |
##   |-------------+--------------+-------------------+--------------------|
##   | 97 217 recs | ~584 ms      | ~114 ms           | ~193 ms            |
##   |    140 recs | ~1.1 ms      | negligible        | ~0.4 ms            |
##
## Four fifths of the write is CPU (``encodeFrame`` runs over every record
## TWICE inside ``writeCanonicalInPlace`` — once to size and checksum the body,
## once to emit it), and that CPU stays where io-mon puts it. What this module
## removes from the serial path is therefore the PUBLICATION, not the write —
## and the change that ships beside it, folding evidence from the records
## ``finishMonitor`` already returned instead of re-reading and re-decoding the
## file, removes the ~193 ms decode. Read ``repro_build_engine.nim``'s HM-5
## block for the arithmetic and for what an io-mon change would be worth.
##
## ATOMICITY IS NOT THE OPTIONAL HALF. A torn ``.rdep`` decoded as truth is a
## wrong dependency set. ``rename(2)`` is atomic only WITHIN one filesystem and
## degrades silently to copy-then-unlink across one, so the temp file is placed
## in the destination's own directory by construction — never in
## ``getTempDir()``, which on a normal Linux host is a different device from a
## cache root under the workspace (measured on this machine: ``/tmp`` is device
## 28, ``/dev/shm`` is 22) and which the rest of this repository already
## relocates scratch to for the Windows ``MAX_PATH`` workaround.
## ``flush_temp_is_on_the_destination_filesystem`` asserts the property by
## comparing ``st_dev``, not by reading this comment.
##
## THE WORKER IS THE ENGINE'S ONLY THREAD, AND NOTHING GARBAGE-COLLECTED
## CROSSES INTO IT. The queue is a pair of intrusive linked lists in
## ``allocShared0`` memory whose payloads are manually-owned ``cstring``s; the
## globals this module keeps are a lock, a condition variable, two node
## pointers and three integers. That is not fastidiousness, it is HM-3's
## finding applied: a ``ref`` shared across threads races ``nimIncRef`` /
## ``nimDecRef`` because ORC's counts are atomic only under ``-d:gcAtomicArc``,
## and TSAN found exactly that in nim-shm-gset's pool. Keeping GC'd values on
## one side of the boundary makes the whole question unrepresentable rather
## than argued — and it is also what makes ``flushWorkerLoop`` provably
## ``gcsafe`` instead of cast to it.
##
## THE WORKER NEVER WRITES TO ``stdout`` OR ``stderr``.
## ``beginMonitorSpawnContext`` redirects descriptors 0/1/2 around a hosted
## spawn, and a worker that wrote a diagnostic inside that window would land it
## in some action's captured output. Failures come back through
## ``drainMonitorFlushOutcomes`` instead.
##
## THE OTHER TWO PROCESS-GLOBAL THINGS THAT WINDOW TOUCHES, checked rather than
## assumed, because ``beginMonitorSpawnContext``'s doc-comment says in so many
## words that it is safe only while the engine is single-threaded and that this
## is the first thing to break if it ever grows a worker:
##
##   * ``dup2`` on descriptors 0/1/2 — the worker opens nothing (io-mon creates
##     the scratch file; the worker only renames it), and ``dup2`` never leaves
##     a standard descriptor closed, so there is no window in which an open
##     here could be handed 1 or 2;
##   * ``umask(0022)`` — the worker creates no file, so no mode is decided
##     inside the window.
##
## Both hold BECAUSE the worker's job is a rename. A future worker that wrote
## the file itself would re-open both questions, which is the concrete reason
## the "point io-mon at /dev/null and re-encode here" variant was rejected on
## more than its CPU cost.

import std/[locks, os, strutils]

from std/times import epochTime

type
  MonitorFlushJob* = object
    ## One pending publication, as the SCHEDULER states it. This is a plain
    ## Nim value that never crosses into the worker: ``enqueueMonitorFlush``
    ## copies it into shared memory and this object dies on the caller's side.
    ##
    ## The job owns its own copies of every string it needs, so the pool slot
    ## the action ran in — its ``MonitorHostRecord``, its stdio capture paths,
    ## its ``MonitorHandle`` — is released and recycled by the NEXT action
    ## while this publication is still in flight. That is the reprobuild-side
    ## form of the milestone's "snapshot the records into the flush job's own
    ## buffer": the shared-memory segment is released by ``finishMonitor``
    ## before a job exists at all, and what a job must not borrow is the
    ## scheduler's recyclable state.
    actionId*: string
    tempPath*: string
    destPath*: string

  MonitorFlushOutcome* = object
    ## The result of one publication, as the scheduler learns about it.
    actionId*: string
    error*: string
      ## Empty on success. Non-empty means the ``.rdep`` did NOT land, which
      ## costs a re-execution and never a wrong answer: the engine's evidence
      ## came from memory, so the action's own result stands, and the cache
      ## publish is skipped so the next build MISSES and re-runs.

  FlushNode = ptr FlushNodeObj
  FlushNodeObj = object
    ## A queued publication, in shared memory. Every string field is a
    ## manually-owned copy freed by whichever side consumes the node.
    next: FlushNode
    actionId: cstring
    tempPath: cstring
    destPath: cstring
    failSubstring: cstring
    delayMs: int

  OutcomeNode = ptr OutcomeNodeObj
  OutcomeNodeObj = object
    next: OutcomeNode
    actionId: cstring
    error: cstring

var flushLock: Lock
var flushSignal: Cond
var flushJobHead: FlushNode = nil
var flushJobTail: FlushNode = nil
var flushOutcomeHead: OutcomeNode = nil
var flushPending: int = 0
var flushStarted: bool = false
var flushWorker: Thread[void]

proc sharedDup(value: string): cstring =
  ## Copy a Nim string into shared, manually-managed memory. NOT the GC's:
  ## the block outlives the caller's string and is released by ``sharedFree``
  ## on whichever thread consumes it.
  let n = value.len
  result = cast[cstring](allocShared0(n + 1))
  if n > 0:
    copyMem(result, value.cstring, n)

proc sharedFree(value: var cstring) =
  if value != nil:
    deallocShared(value)
    value = nil

proc monitorFlushTempPath*(destPath: string; nonce: int): string =
  ## The scratch file io-mon writes, ALWAYS a sibling of ``destPath``.
  ##
  ## Deriving it from the destination is the whole mechanism: it is what makes
  ## the later ``rename`` a same-filesystem rename, hence atomic, and it is the
  ## one thing about this module a test can check without trusting any of it —
  ## ``stat`` both and compare ``st_dev``.
  ##
  ## Do NOT "simplify" this to ``getTempDir()``. It is not equivalent, it is
  ## not more portable, and the failure it introduces is silent: ``rename``
  ## across a filesystem boundary does not error, it copies and unlinks, and
  ## a reader can observe the half-copied file. The name is dot-prefixed so a
  ## crashed build's leftovers are visibly scratch rather than looking like a
  ## depfile, and carries the pid so two processes writing the same action's
  ## depfile cannot collide on it.
  let dir = destPath.parentDir
  let base = destPath.extractFilename
  let scratch = "." & base & ".flush-" & $getCurrentProcessId() & "-" &
    $nonce & ".tmp"
  if dir.len == 0: scratch else: dir / scratch

proc publishOneFlush(node: FlushNode): string =
  ## Do the publication. Returns "" on success, the failure message otherwise.
  ##
  ## ``failSubstring`` is the fault-injection seam
  ## (``REPROBUILD_MONITOR_FLUSH_FAIL``) that
  ## ``a failed flush causes a re-execution, not a wrong answer`` uses. It is a
  ## real failure of the real code path — the scratch file is removed so the
  ## rename has nothing to publish — rather than a mock: everything downstream
  ## sees exactly what a genuine ENOSPC would produce.
  let actionId = $node.actionId
  let tempPath = $node.tempPath
  let destPath = $node.destPath
  let failSubstring = $node.failSubstring
  if failSubstring.len > 0 and actionId.contains(failSubstring):
    try:
      removeFile(tempPath)
    except CatchableError:
      discard
    return "injected monitor depfile flush failure " &
      "(REPROBUILD_MONITOR_FLUSH_FAIL) for " & actionId
  if not fileExists(tempPath):
    return "monitor depfile flush: io-mon wrote no depfile at " & tempPath
  try:
    # ``moveFile`` is ``rename`` on POSIX and ``MoveFileEx`` with
    # ``MOVEFILE_REPLACE_EXISTING`` on Windows; both replace the destination
    # atomically WITHIN a filesystem, which is what ``monitorFlushTempPath``
    # guarantees.
    moveFile(tempPath, destPath)
  except CatchableError as err:
    try:
      removeFile(tempPath)
    except CatchableError:
      discard
    return "monitor depfile flush failed for " & actionId & ": " & err.msg
  ""

proc flushWorkerLoop() {.thread.} =
  while true:
    acquire(flushLock)
    while flushJobHead == nil:
      wait(flushSignal, flushLock)
    let node = flushJobHead
    flushJobHead = node.next
    if flushJobHead == nil:
      flushJobTail = nil
    release(flushLock)

    if node.delayMs > 0:
      # The seam ``the scheduler starts the next edges before the file lands``
      # measures through. Without it the publication is a single ``rename``
      # and lands so fast that the case could pass on a machine where nothing
      # overlapped at all, which would make it a test of scheduling luck.
      sleep(node.delayMs)
    let err = publishOneFlush(node)

    let outcome = cast[OutcomeNode](allocShared0(sizeof(OutcomeNodeObj)))
    outcome.actionId = sharedDup($node.actionId)
    outcome.error = sharedDup(err)
    sharedFree(node.actionId)
    sharedFree(node.tempPath)
    sharedFree(node.destPath)
    sharedFree(node.failSubstring)
    deallocShared(node)

    acquire(flushLock)
    outcome.next = flushOutcomeHead
    flushOutcomeHead = outcome
    dec flushPending
    signal(flushSignal)
    release(flushLock)

proc ensureMonitorFlushWorker() =
  ## Start the worker on first use and never before: a build with no hosted
  ## monitor — which is every build today, since hosting is off by default —
  ## creates no thread at all.
  if flushStarted:
    return
  initLock(flushLock)
  initCond(flushSignal)
  flushStarted = true
  createThread(flushWorker, flushWorkerLoop)

proc enqueueMonitorFlush*(job: MonitorFlushJob) =
  ## Hand one publication to the worker. Returns as soon as the job is queued —
  ## this is the call the scheduler makes BEFORE it collects evidence,
  ## publishes a cache entry, or launches the next edges.
  ##
  ## The two test seams are read HERE, per job, rather than once when the
  ## worker starts: a test process that runs several builds must not be stuck
  ## with whatever the first one happened to set.
  let delayMs =
    try:
      parseInt(getEnv("REPROBUILD_MONITOR_FLUSH_DELAY_MS", "0"))
    except ValueError:
      0
  let node = cast[FlushNode](allocShared0(sizeof(FlushNodeObj)))
  node.actionId = sharedDup(job.actionId)
  node.tempPath = sharedDup(job.tempPath)
  node.destPath = sharedDup(job.destPath)
  node.failSubstring = sharedDup(getEnv("REPROBUILD_MONITOR_FLUSH_FAIL", ""))
  node.delayMs = delayMs
  node.next = nil

  ensureMonitorFlushWorker()
  acquire(flushLock)
  if flushJobTail == nil:
    flushJobHead = node
    flushJobTail = node
  else:
    flushJobTail.next = node
    flushJobTail = node
  inc flushPending
  signal(flushSignal)
  release(flushLock)

proc takeOutcomes(): seq[MonitorFlushOutcome] =
  ## Move the completed publications out of shared memory and back into
  ## ordinary Nim values. Called only on the scheduler's thread.
  result = @[]
  var node: OutcomeNode = nil
  acquire(flushLock)
  node = flushOutcomeHead
  flushOutcomeHead = nil
  release(flushLock)
  # The list is built head-first, so walking it yields newest-first; reverse
  # into completion order because a diagnostic that names several actions
  # should read in the order they happened.
  var collected: seq[MonitorFlushOutcome] = @[]
  while node != nil:
    let nxt = node.next
    collected.add MonitorFlushOutcome(
      actionId: $node.actionId, error: $node.error)
    sharedFree(node.actionId)
    sharedFree(node.error)
    deallocShared(node)
    node = nxt
  for i in countdown(collected.len - 1, 0):
    result.add collected[i]

proc drainMonitorFlushOutcomes*(): seq[MonitorFlushOutcome] =
  ## Every publication that has COMPLETED since the last drain, without
  ## blocking on the ones that have not.
  if not flushStarted:
    return @[]
  takeOutcomes()

proc awaitMonitorFlush*(actionId: string; timeoutSeconds = 30.0):
    seq[MonitorFlushOutcome] =
  ## Block until ONE named action's publication has completed, then drain
  ## every outcome that has accumulated.
  ##
  ## WHY THIS EXISTS AT ALL, since it is the one place the milestone's
  ## asynchrony is deliberately given back. A publication that fails must cost
  ## a re-execution, and the only way to make that hold is to know the outcome
  ## BEFORE the action's cache entry is published. A non-blocking drain does
  ## not: it is a race between a rename and the scheduler's wrap-up, and the
  ## race was MEASURED to go both ways — three mutation runs of
  ## ``a failed flush causes a re-execution, not a wrong answer`` reported
  ## ``asCacheHit`` for reasons that had nothing to do with the mutation
  ## applied, because the worker had not got there yet. A conservative
  ## direction that holds "usually" is not a conservative direction.
  ##
  ## WHAT IT COSTS, and why it does not give the milestone back: the scheduler
  ## reaches this point AFTER collecting evidence, running post-build
  ## converters and invalidating cached outputs, and what it waits for is a
  ## single ``rename`` on a file io-mon finished writing before the action was
  ## even reaped. The publication has overlapped all of that. The wait is also
  ## taken ONLY by a cacheable action — an action with no entry to publish has
  ## nothing to be conservative about and never waits.
  if not flushStarted:
    return @[]
  let deadline = epochTime() + timeoutSeconds
  while true:
    var found = false
    var idle = false
    acquire(flushLock)
    var n = flushOutcomeHead
    while n != nil:
      if $n.actionId == actionId:
        found = true
        break
      n = n.next
    idle = flushPending <= 0
    release(flushLock)
    # ``idle`` is not a timeout in disguise. With nothing in flight, this
    # action's outcome was either drained by an earlier call — in which case
    # the caller already recorded it — or never queued, which is what a
    # monitor fault leaves behind. Waiting longer would answer neither.
    if found or idle or epochTime() >= deadline:
      break
    sleep(1)
  takeOutcomes()

proc awaitMonitorFlushes*(timeoutSeconds = 30.0): seq[MonitorFlushOutcome] =
  ## Wait for every queued publication and return the outcomes not yet drained.
  ##
  ## Called once, at the end of a build. The timeout is a guard against a
  ## worker wedged on a hung filesystem; it does not fail the build on its own,
  ## because a build whose actions all succeeded must not be failed by a
  ## debugging artefact that has not landed yet — the missing entry shows up as
  ## a skipped cache publish, which is a re-run.
  if not flushStarted:
    return @[]
  let deadline = epochTime() + timeoutSeconds
  while true:
    acquire(flushLock)
    let remaining = flushPending
    release(flushLock)
    if remaining <= 0 or epochTime() >= deadline:
      break
    sleep(1)
  takeOutcomes()
