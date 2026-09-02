## In-Process-Monitor-Hosting HM-5 — the depfile flush, made ASYNCHRONOUS and
## ATOMIC.
##
## WHAT A "FLUSH" IS HERE, precisely, because the milestone's one-line
## description does not survive contact with the code and a reader who assumes
## it does will mis-read every proc below.
##
## io-mon owns the canonical iomon write. ``finishMonitor`` produces the evidence
## through ``collectMonitorEvidence`` -> ``mergeFragments`` ->
## ``writeCanonicalInPlace``, and there is no request field, no option and no
## alternative entry point that lets a host obtain the records WITHOUT that
## write happening. So reprobuild cannot move the encode+write off its serial
## path from this side; what it can do — and what this module does — is decide
## WHERE io-mon writes and WHEN that write becomes the published ``.iomon``:
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
## ATOMICITY IS NOT THE OPTIONAL HALF. A torn ``.iomon`` decoded as truth is a
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
## THIS MODULE NO LONGER OWNS A THREAD — Engine-Threadpool TP-1.
##
## HM-5 shipped a bespoke worker here, and it was the engine's only one. TP-1
## replaced it with a reusable pool (``worker_pool.nim``) that this module is
## now simply the first TENANT of: the queue, the worker loop, the outcome
## list, the shutdown discipline and the backpressure bound all live there, and
## what remains here is the publication itself plus the flush-shaped API the
## scheduler calls. The spec asked for one pool with several users rather than
## a second bespoke thread, and this is that move.
##
## NOTHING ABOUT THE SEMANTICS MOVED WITH IT, and the two that matter are
## restated because they are load-bearing and mutation-pinned:
##
##   * a CACHEABLE hosted action waits for its OWN publication before it
##     publishes a cache entry (``awaitMonitorFlush``); a non-cacheable one
##     never waits;
##   * a build does not end with a publication in flight
##     (``awaitMonitorFlushes``), so no scratch file is left beside a depfile
##     that never appeared.
##
## Both are now expressed through the pool's per-tenant primitives, which were
## written to have exactly the shape HM-5's globals had — including the
## "``idle`` is not a timeout in disguise" test that closes the
## drained-by-an-earlier-call case.
##
## NOTHING GARBAGE-COLLECTED CROSSES INTO A WORKER. A job is an intrusive node
## in ``allocShared0`` memory whose payload is manually-owned ``cstring``s,
## embedded in the pool's own job header; the task and release hooks are
## ``{.nimcall, gcsafe.}`` code pointers with no environment. That is not
## fastidiousness, it is HM-3's finding applied: a ``ref`` shared across
## threads races ``nimIncRef`` / ``nimDecRef`` because ORC's counts are atomic
## only under ``-d:gcAtomicArc``, and TSAN found exactly that in nim-shm-gset's
## pool. Keeping GC'd values on one side of the boundary makes the whole
## question unrepresentable rather than argued — and it is also what makes
## ``publishOneFlush`` provably ``gcsafe`` instead of cast to it.
##
## THE WORKERS NEVER WRITE TO ``stdout`` OR ``stderr``.
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
## Both hold BECAUSE this tenant's job is a rename, and they now have to hold
## for EVERY tenant of the shared pool rather than for one thread — see
## ``worker_pool.nim``'s header, which states that as the obligation the second
## tenant inherits. A future worker that wrote the file itself would re-open
## both questions, which is the concrete reason the "point io-mon at /dev/null
## and re-encode here" variant was rejected on more than its CPU cost.

import std/[os, strutils]

import ./worker_pool

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
      ## Empty on success. Non-empty means the ``.iomon`` did NOT land, which
      ## costs a re-execution and never a wrong answer: the engine's evidence
      ## came from memory, so the action's own result stands, and the cache
      ## publish is skipped so the next build MISSES and re-runs.

  FlushNode = ptr FlushNodeObj
  FlushNodeObj = object
    ## A queued publication, in shared memory. Every string field is a
    ## manually-owned copy freed by ``releaseFlushJob`` on the worker.
    ##
    ## ``base`` MUST be first: the pool hands a task a ``ptr
    ## EnginePoolJobObj`` and the task casts it back to this type, which is
    ## an identity on the address only while the header sits at offset 0. The
    ## ``static`` assertion below is what makes that a compile error rather
    ## than a memory-corruption bug if the fields are ever reordered.
    base: EnginePoolJobObj
    tempPath: cstring
    destPath: cstring
    failSubstring: cstring
    delayMs: int

static:
  doAssert offsetOf(FlushNodeObj, base) == 0,
    "the pool job header must be the first field of FlushNodeObj"

let monitorFlushTenant = registerEnginePoolTenant("monitor-depfile-flush")

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

proc publishOneFlush(node: FlushNode): string {.gcsafe.} =
  ## Do the publication. Returns "" on success, the failure message otherwise.
  ##
  ## Runs ON A POOL WORKER. Every value it touches is either a manually-owned
  ## ``cstring`` out of the job node or a Nim string it creates and destroys
  ## itself; it reaches no module-level state at all, which is why the
  ## compiler accepts the ``gcsafe`` above rather than needing it cast.
  ##
  ## ``failSubstring`` is the fault-injection seam
  ## (``REPROBUILD_MONITOR_FLUSH_FAIL``) that
  ## ``a failed flush causes a re-execution, not a wrong answer`` uses. It is a
  ## real failure of the real code path — the scratch file is removed so the
  ## rename has nothing to publish — rather than a mock: everything downstream
  ## sees exactly what a genuine ENOSPC would produce.
  let actionId = $enginePoolJobKey(addr node.base)
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

proc runFlushJob(job: EnginePoolJob): cstring {.nimcall, gcsafe.} =
  ## The pool task. ``job`` is the ``base`` field of a ``FlushNodeObj``, which
  ## the ``static`` assertion above pins at offset 0.
  let node = cast[FlushNode](job)
  if node.delayMs > 0:
    # The seam ``the scheduler starts the next edges before the file lands``
    # measures through. Without it the publication is a single ``rename``
    # and lands so fast that the case could pass on a machine where nothing
    # overlapped at all, which would make it a test of scheduling luck.
    sleep(node.delayMs)
  let err = publishOneFlush(node)
  if err.len == 0: nil else: sharedDup(err)

proc releaseFlushJob(job: EnginePoolJob) {.nimcall, gcsafe.} =
  ## Free this tenant's half of the node. ``base.key`` is NOT freed here: the
  ## pool owns it and has already moved it into the outcome.
  let node = cast[FlushNode](job)
  sharedFree(node.tempPath)
  sharedFree(node.destPath)
  sharedFree(node.failSubstring)
  deallocShared(node)

proc enqueueMonitorFlush*(job: MonitorFlushJob) =
  ## Hand one publication to the pool. Returns as soon as the job is queued —
  ## this is the call the scheduler makes BEFORE it collects evidence,
  ## publishes a cache entry, or launches the next edges.
  ##
  ## The two test seams are read HERE, per job, rather than once when the
  ## pool starts: a test process that runs several builds must not be stuck
  ## with whatever the first one happened to set.
  let delayMs =
    try:
      parseInt(getEnv("REPROBUILD_MONITOR_FLUSH_DELAY_MS", "0"))
    except ValueError:
      0
  let node = cast[FlushNode](allocShared0(sizeof(FlushNodeObj)))
  node.tempPath = sharedDup(job.tempPath)
  node.destPath = sharedDup(job.destPath)
  node.failSubstring = sharedDup(getEnv("REPROBUILD_MONITOR_FLUSH_FAIL", ""))
  node.delayMs = delayMs
  submitEnginePoolJob(monitorFlushTenant, job.actionId, addr node.base,
    runFlushJob, releaseFlushJob)

proc asFlushOutcomes(outcomes: seq[EnginePoolOutcome]):
    seq[MonitorFlushOutcome] =
  result = @[]
  for outcome in outcomes:
    result.add MonitorFlushOutcome(
      actionId: outcome.key, error: outcome.error)

proc drainMonitorFlushOutcomes*(): seq[MonitorFlushOutcome] =
  ## Every publication that has COMPLETED since the last drain, without
  ## blocking on the ones that have not.
  asFlushOutcomes(drainEnginePoolOutcomes(monitorFlushTenant))

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
  ##
  ## The "``idle`` is not a timeout in disguise" reasoning that used to live
  ## here now lives in ``awaitEnginePoolOutcome``, unchanged: with nothing of
  ## this tenant's in flight, the outcome was either drained by an earlier call
  ## or never queued, and waiting longer would answer neither.
  asFlushOutcomes(
    awaitEnginePoolOutcome(monitorFlushTenant, actionId, timeoutSeconds))

proc awaitMonitorFlushes*(timeoutSeconds = 30.0): seq[MonitorFlushOutcome] =
  ## Wait for every queued publication and return the outcomes not yet drained.
  ##
  ## Called once, at the end of a build. The timeout is a guard against a
  ## worker wedged on a hung filesystem; it does not fail the build on its own,
  ## because a build whose actions all succeeded must not be failed by a
  ## debugging artefact that has not landed yet — the missing entry shows up as
  ## a skipped cache publish, which is a re-run.
  asFlushOutcomes(
    awaitEnginePoolTenantIdle(monitorFlushTenant, timeoutSeconds))
