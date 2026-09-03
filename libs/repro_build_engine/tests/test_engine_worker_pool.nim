## Engine-Threadpool TP-1 — the engine's reusable worker pool.
##
## WHAT IS BEING PINNED, and why each case is shaped the way it is.
##
## TP-1 introduces CONCURRENCY to a codebase that had almost none: before it,
## the only ``createThread`` under ``libs/*/src`` and ``apps/`` was HM-5's
## flush worker, which this pool absorbs. Two properties have to hold before
## anything else can be moved onto it, and they are exactly the two the
## milestone names:
##
##   * NO WORK IS SILENTLY DROPPED when the build ends — including when the
##     build ends by an exception unwinding out of it rather than by finishing;
##   * A WORKER FAULT FAILS ITS JOB, NOT THE BUILD. Hosting the monitor
##     in-process already removed the process boundary that used to contain a
##     decode or parse fault (``t_monitor_fault_fails_the_action_not_the_daemon``
##     pins that for the host); a thread pool removes the last one, because an
##     exception escaping a thread proc terminates the whole process.
##
## NO MOCKS. The pool cases run the real pool with real OS threads, real
## ``allocShared0`` memory and real files on disk; the fault is a real
## ``parseInt`` on a real malformed payload, raising a real ``ValueError``
## out of a real task. The unwinding case runs a real hosted build with a real
## monitored child and asserts on a real published ``.iomon``.
##
## HOW A RUN IS JUDGED. By its EXIT CODE, never by its label counts: a SIGSEGV
## exits 1 while printing ``0 [FAILED]``, which is exactly how a concurrency
## crash hides. Every assertion helper below is a ``template`` for the sibling
## reason — ``check`` inside a plain ``proc`` prints "Check failed" and the
## case still reports ``[OK]``.
##
## SANITIZERS. These cases are run under TSAN and under ASan/UBSan, not only
## under the ordinary build. HM-3's race surfaced as a ONE-IN-SIX segfault in
## an unrelated test and was settleable only by TSAN; a clean ordinary run
## proves nothing about this class of bug. ``-d:reproEnginePoolSanitizerSubset``
## drops the engine-level case from a sanitized build — not because it is
## uninteresting but because it drags io-mon, the shim and a monitored child
## under the same instrumentation, which measures somebody else's code.

import std/[os, strutils, unittest]

import repro_build_engine/worker_pool

when not defined(reproEnginePoolSanitizerSubset):
  # The engine-level case only. A sanitized build compiles the pool and
  # NOTHING ELSE: dragging the engine, io-mon, blake3 and xxh3 under TSAN
  # measures somebody else's code (and gcc refuses to build xxh3's
  # ``always_inline`` SSE2 kernels under ``-fsanitize=thread`` at all), while
  # the races this instrumentation is here to find are all in
  # ``worker_pool.nim``.
  import repro_build_engine
  from repro_test_support import prepareMonitorTools, testCaseScratchSlug

template checkOrEcho(cond: untyped; msg: string) =
  ## `check` inside a plain `proc` prints "Check failed" and still reports
  ## `[OK]`, so every helper that asserts in this file is a template.
  if not (cond):
    echo msg
  check cond

type
  ProbeNode = ptr ProbeNodeObj
  ProbeNodeObj = object
    ## One probe job. ``base`` MUST be first — see ``FlushNodeObj`` for the
    ## same requirement and the same static assertion.
    base: EnginePoolJobObj
    outPath: cstring
    payload: cstring
    sleepMs: int

static:
  doAssert offsetOf(ProbeNodeObj, base) == 0,
    "the pool job header must be the first field of ProbeNodeObj"

let probeTenant = registerEnginePoolTenant("engine-pool-probe")

proc runProbe(job: EnginePoolJob): cstring {.nimcall, gcsafe.} =
  ## THE WORK, AND THE FAULT, ARE THE SAME CODE PATH.
  ##
  ## The payload is DECODED with ``parseInt`` and the decoded value is what
  ## gets written. A malformed payload therefore raises ``ValueError`` out of
  ## the middle of a real task — the shape ``t_monitor_fault_fails_the_action_
  ## not_the_daemon`` calls a decode fault — rather than through a branch that
  ## exists only to fail.
  let node = cast[ProbeNode](job)
  if node.sleepMs > 0:
    sleep(node.sleepMs)
  let value = parseInt($node.payload)
  writeFile($node.outPath, $(value * 2))
  nil

proc releaseProbe(job: EnginePoolJob) {.nimcall, gcsafe.} =
  let node = cast[ProbeNode](job)
  sharedFree(node.outPath)
  sharedFree(node.payload)
  deallocShared(node)

proc submitProbe(key, outPath, payload: string; sleepMs = 0) =
  let node = cast[ProbeNode](allocShared0(sizeof(ProbeNodeObj)))
  node.outPath = sharedDup(outPath)
  node.payload = sharedDup(payload)
  node.sleepMs = sleepMs
  submitEnginePoolJob(probeTenant, key, addr node.base, runProbe, releaseProbe)

proc poolScratchRoot(name: string): string =
  let slug =
    when defined(reproEnginePoolSanitizerSubset): "sanitized"
    else: testCaseScratchSlug()
  let root = absolutePath("build" / "test-tmp" / "test_engine_worker_pool" /
    slug / name)
  if dirExists(root):
    removeDir(root)
  createDir(root)
  root

proc errorFor(outcomes: seq[EnginePoolOutcome]; key: string): string =
  ## "" when the key succeeded, the message when it failed, and a distinctive
  ## marker when the pool never reported it at all — a missing outcome and a
  ## successful one must not read the same.
  for outcome in outcomes:
    if outcome.key == key:
      return outcome.error
  "<no outcome reported>"

suite "TP-1 engine worker pool":
  test "a tenant name is deduplicated or refused, never truncated":
    ## THE DEFECT THIS PINS WAS LATENT AND ITS OWN DOC COMMENT WAS WRONG
    ## ABOUT IT. ``registerEnginePoolTenant`` promises that registering the
    ## SAME name twice returns the SAME slot, so a tenant module initialised
    ## twice — which a test binary linking two entry points does — cannot
    ## split its pending count across two slots and make ``awaitEnginePool*``
    ## report idle while its own work is still queued. The name was STORED
    ## truncated to 47 characters and COMPARED against the full argument, so
    ## for any longer name the lookup could never match: registering one
    ## 52-character name twice returned two different slots, and the promise
    ## was false exactly where it mattered.
    ##
    ## THE FIX IS A REFUSAL AND NOT A TRUNCATED COMPARISON, and the second
    ## half of this case is why. Comparing prefix-to-prefix would make the
    ## lookup consistent and make the failure WORSE: two distinct tenants
    ## sharing a 47-character prefix would silently share one slot and each
    ## would then wait on the other's pending count — the same corruption of
    ## ``awaitEnginePool*``, arrived at from the other side and with no
    ## diagnostic. Tenant names are compile-time constants, so a name that
    ## does not fit is a programming error and is reported as one.
    ##
    ## MUTATION TARGETS, one per direction.
    ## (1) Restore the truncating store
    ## (``let n = min(name.len, EnginePoolTenantNameLimit - 1)``) and drop the
    ## refusal: the first arm reddens, because an over-long name is accepted;
    ## and the second arm reddens on ``sameSlot``, because the truncated name
    ## never matches itself.
    ## (2) Keep the refusal but delete the dedup loop: the third arm reddens,
    ## because a repeated in-range name claims a fresh slot.
    const TooLong = "engine-pool-name-that-is-deliberately-far-too-long-to-fit"
    doAssert TooLong.len > 47
    var refused = false
    var refusalMessage = ""
    try:
      discard registerEnginePoolTenant(TooLong)
    except ValueError as err:
      refused = true
      refusalMessage = err.msg
    checkOrEcho refused,
      "a " & $TooLong.len & "-character tenant name was ACCEPTED. It is " &
      "then stored truncated and compared in full, so it never matches " &
      "itself and every registration claims a fresh slot — which is " &
      "precisely the split pending count the dedup exists to prevent."
    checkOrEcho refusalMessage.contains($TooLong.len),
      "the refusal does not say how long the offending name was, so it " &
      "cannot be acted on: " & refusalMessage

    # THE LONGEST NAME THAT DOES FIT IS STILL DEDUPLICATED. This is the arm
    # that makes the refusal a boundary rather than a blanket: 47 characters
    # is accepted, and accepted names keep the promise.
    let atLimit = "engine-pool-probe-at-the-limit" & repeat("x", 17)
    doAssert atLimit.len == 47
    let firstAtLimit = registerEnginePoolTenant(atLimit)
    let secondAtLimit = registerEnginePoolTenant(atLimit)
    checkOrEcho firstAtLimit == secondAtLimit,
      "a 47-character name — the longest that fits — was not deduplicated, " &
      "so its pending count is split across two slots"

    # AND SO IS AN ORDINARY ONE, which is the property the doc comment states
    # and the only one any shipped tenant relies on today.
    let firstShort = registerEnginePoolTenant("engine-pool-probe")
    let secondShort = registerEnginePoolTenant("engine-pool-probe")
    checkOrEcho firstShort == secondShort,
      "registering the same tenant name twice returned two different slots"
    # NOT VACUOUS: the dedup must return the SAME slot, not merely a valid
    # one, and two DIFFERENT names must still get different slots — a
    # ``registerEnginePoolTenant`` that returned a constant would satisfy
    # every assertion above.
    checkOrEcho firstShort != firstAtLimit,
      "two different tenant names were given the same slot, so the " &
      "assertions above cannot distinguish deduplication from a table " &
      "that hands everybody slot 0"

  test "the pool drains on shutdown":
    ## NO WORK IS SILENTLY DROPPED when the pool is stopped. Shutdown is
    ## requested with the queue deliberately still full, and every job must
    ## still run: the worker loop exits only when the queue is EMPTY and
    ## stopping is set, which is the guarantee rather than the wait in
    ## ``shutdownEnginePool``.
    ##
    ## MUTATION TARGET: in ``enginePoolWorkerLoop``, break out of the loop on
    ## ``poolStopping`` before the ``jobHead == nil`` test (i.e. reverse the
    ## order of the two conditions). This case then reddens on the missing
    ## output files.
    shutdownEnginePool()
    configureEnginePool(workers = 2, queueLimit = 64)
    let root = poolScratchRoot("drain")
    const JobCount = 24

    for i in 0 ..< JobCount:
      submitProbe("drain-" & $i, root / ("drain-" & $i & ".txt"), $i,
        sleepMs = 5)

    # NOT VACUOUS: with two workers and a 5 ms job, most of these are still
    # queued at this instant. A pool that had already finished everything
    # before the shutdown request would make the case above prove nothing.
    let stillPending = enginePoolPending(probeTenant)
    checkOrEcho stillPending > 0,
      "every job had already completed before shutdown was requested, so " &
      "this case did not exercise a drain at all"
    checkOrEcho enginePoolWorkerCount() == 2,
      "the pool was asked for 2 workers and started " &
      $enginePoolWorkerCount() & ", so this case is not measuring the " &
      "concurrency it believes it is"

    shutdownEnginePool()

    checkOrEcho enginePoolPending(probeTenant) == 0,
      "shutdown returned with " & $enginePoolPending(probeTenant) &
      " job(s) still pending"

    var missing: seq[string] = @[]
    var wrong: seq[string] = @[]
    for i in 0 ..< JobCount:
      let path = root / ("drain-" & $i & ".txt")
      if not fileExists(path):
        missing.add path
      elif readFile(path).strip() != $(i * 2):
        wrong.add path
    checkOrEcho missing.len == 0,
      $missing.len & " of " & $JobCount &
      " jobs were dropped by shutdown; first missing output " &
      (if missing.len > 0: missing[0] else: "")
    checkOrEcho wrong.len == 0,
      "job(s) produced the wrong output: " & wrong.join(", ")

    let outcomes = drainEnginePoolOutcomes(probeTenant)
    checkOrEcho outcomes.len == JobCount,
      "expected " & $JobCount & " outcomes after the drain, got " &
      $outcomes.len
    for i in 0 ..< JobCount:
      checkOrEcho errorFor(outcomes, "drain-" & $i) == "",
        "drain-" & $i & " reported: " & errorFor(outcomes, "drain-" & $i)

  test "a worker fault fails its job, not the build":
    ## The pool's half of HM-4's property. A decode fault inside a worker must
    ## fail exactly the job whose payload is bad, leave its neighbours alone,
    ## and leave the pool able to run more work — the "not session-wide" arm
    ## ``t_monitor_fault_fails_the_action_not_the_daemon`` asserts for the
    ## host.
    ##
    ## THAT THE PROCESS SURVIVES AT ALL is reported by the run's EXIT CODE and
    ## by nothing else, which is why this file's runs are judged on it: an
    ## exception that escaped a worker's thread proc would abort the binary
    ## mid-suite, and an abort prints a SHORTER list of ``[OK]`` lines rather
    ## than a ``[FAILED]`` one.
    ##
    ## MUTATION TARGET: make ``runOneEnginePoolJob``'s ``except`` arms swallow
    ## the fault (``err = nil``) instead of attributing it. The catch still
    ## keeps the process alive, so the run does not crash — it reports the
    ## faulting job as a SUCCESS, and this case reddens on
    ## ``badError.len > 0``. Deleting the ``except`` arms outright is not the
    ## interesting mutation: Nim refuses the ``{.thread.}`` proc for the
    ## escaping effect, so that variant cannot ship in the first place.
    shutdownEnginePool()
    configureEnginePool(workers = 2, queueLimit = 64)
    let root = poolScratchRoot("fault")

    submitProbe("fault-before", root / "before.txt", "7")
    submitProbe("fault-bad", root / "bad.txt", "not-a-number")
    submitProbe("fault-after", root / "after.txt", "9")

    let outcomes = awaitEnginePoolTenantIdle(probeTenant)

    let badError = errorFor(outcomes, "fault-bad")
    checkOrEcho badError.len > 0,
      "the faulting job reported success; the fault was swallowed rather " &
      "than attributed"
    checkOrEcho "ValueError" in badError,
      "the faulting job's outcome does not name the fault that caused it: " &
      badError
    checkOrEcho not fileExists(root / "bad.txt"),
      "the faulting job wrote its output anyway, so it did not fault where " &
      "this case believes it did"

    # ITS NEIGHBOURS ARE UNTOUCHED. This is the half that makes the case about
    # SCOPING rather than about catching.
    for key, name, expected in [("fault-before", "before.txt", "14"),
                                ("fault-after", "after.txt", "18")].items:
      checkOrEcho errorFor(outcomes, key) == "",
        key & " was failed by its neighbour's fault: " & errorFor(outcomes, key)
      checkOrEcho fileExists(root / name),
        key & " produced no output, so the fault was not scoped to one job"
      if fileExists(root / name):
        checkOrEcho readFile(root / name).strip() == expected,
          key & " produced " & readFile(root / name).strip() &
          " instead of " & expected

    # AND THE POOL IS STILL ALIVE — the "not session-wide" arm. A pool whose
    # worker died with its job would leave this one queued forever, which the
    # await's own deadline would then surface as a missing outcome.
    submitProbe("fault-later", root / "later.txt", "11")
    let later = awaitEnginePoolTenantIdle(probeTenant)
    checkOrEcho errorFor(later, "fault-later") == "",
      "the pool could not run further work after a fault: " &
      errorFor(later, "fault-later")
    checkOrEcho fileExists(root / "later.txt"),
      "the pool accepted work after a fault but never ran it"

  test "backpressure bounds the queue instead of dropping or growing":
    ## The third leg of the design. An unbounded queue turns a slow filesystem
    ## into what looks like a memory leak — a real ``nim c`` action carries an
    ## 18 MB record set — and dropping a job would make "no work is silently
    ## dropped" false by construction. So a submitter BLOCKS, and the queue
    ## never exceeds its bound.
    ##
    ## MUTATION TARGET: delete the ``while queuedJobs >= poolQueueLimit`` wait
    ## in ``submitEnginePoolJob``. The observed depth then exceeds the bound
    ## and this case reddens on ``deepest <= Limit``.
    shutdownEnginePool()
    const Limit = 3
    configureEnginePool(workers = 1, queueLimit = Limit)
    let root = poolScratchRoot("backpressure")
    const JobCount = 12

    var deepest = 0
    for i in 0 ..< JobCount:
      submitProbe("bp-" & $i, root / ("bp-" & $i & ".txt"), $i, sleepMs = 5)
      deepest = max(deepest, enginePoolQueueDepth())

    checkOrEcho deepest <= Limit,
      "the queue reached depth " & $deepest & " with a bound of " & $Limit &
      ", so the bound is not enforced"
    # NOT VACUOUS: a bound that is never approached says nothing. One worker
    # against twelve 5 ms jobs must fill it.
    checkOrEcho deepest > 0,
      "the queue was never observed to hold anything, so this case cannot " &
      "distinguish an enforced bound from a pool that is simply idle"

    let outcomes = awaitEnginePoolTenantIdle(probeTenant)
    checkOrEcho outcomes.len == JobCount,
      "backpressure lost work: expected " & $JobCount & " outcomes, got " &
      $outcomes.len
    for i in 0 ..< JobCount:
      checkOrEcho fileExists(root / ("bp-" & $i & ".txt")),
        "bp-" & $i & " never ran"

    # Do not leave the next case — or the next build in this process —
    # running under a one-worker, three-deep pool.
    shutdownEnginePool()
    resetEnginePoolConfiguration()

  when defined(linux) or defined(macosx):
    test "the pool drains when an exception unwinds out of the build":
      ## THE ERROR PATH, AT THE ENGINE RATHER THAN AT THE POOL. A clean finish
      ## drains because the scheduler reaches the end of its loop; an
      ## exception unwinding out of the middle of it drains only because both
      ## drains sit in ``runBuild``'s ``finally``. This case is what tells the
      ## two apart.
      ##
      ## THE UNWIND IS REAL AND IS NOT A SEAM ADDED FOR IT.
      ## ``BuildProgressCallback`` is an ordinary shipped hook with no
      ## ``raises`` restriction, and ``emitProgress`` calls it from inside the
      ## scheduling loop — after ``finishMonitorHostAction`` has queued this
      ## action's publication. Raising there is a genuine exception unwinding
      ## out of a build with pool work in flight.
      ##
      ## The action is NON-CACHEABLE on purpose: a cacheable one waits for its
      ## own publication before publishing a cache entry (``awaitMonitorFlush``),
      ## so its job would already be finished by the time the callback fires
      ## and the case would pass without a drain existing at all. The 400 ms
      ## delay is what keeps the publication in flight across the unwind.
      ##
      ## MUTATION TARGET: move ``awaitMonitorFlushes()`` / ``awaitEnginePoolIdle()``
      ## out of ``runBuild``'s ``finally`` and to the end of the ``try`` body.
      ## This case then reddens on the depfile never appearing.
      when defined(reproEnginePoolSanitizerSubset):
        skip()
      else:
        let root = poolScratchRoot("unwind")
        let work = root / "work"
        createDir(work)
        let cacheRoot = root / "cache"
        let depPath = cacheRoot / "monitor-depfiles" / "tp1-unwind.iomon"

        let tools = prepareMonitorTools(getCurrentDir(),
          getCurrentDir() / "build" / "test-tp1-pool", "tp1-pool")
        putEnv("REPRO_MONITOR_SHIM_LIB", tools.shim)

        var config = BuildEngineConfig(
          cacheRoot: cacheRoot,
          runQuotaCliPath: tools.monitorCliPath,
          monitorCliPath: tools.monitorCliPath,
          monitorCliArgs: tools.monitorCliArgs,
          maxParallelism: 1'u32,
          stdoutLimit: 256 * 1024,
          stderrLimit: 256 * 1024,
          bypassRunQuota: true,
          monitorHosting: mhmWhereSupported)
        config.progressCallback = proc(event: BuildProgressEvent) =
          if event.kind == bpkActionCompleted:
            raise newException(ValueError, "tp1: unwinding out of the build")

        let graphValue = graph([action("tp1-unwind",
          @["sh", "-c", "printf produced > unwound.txt"],
          cwd = work,
          outputs = ["unwound.txt"],
          cacheable = false,
          governingLockIdentity = lockIdentityOutsideSolvedGraph())])

        putEnv("REPROBUILD_MONITOR_FLUSH_DELAY_MS", "400")
        var unwound = false
        try:
          discard runBuild(graphValue, config)
        except ValueError as err:
          unwound = "unwinding out of the build" in err.msg
        finally:
          delEnv("REPROBUILD_MONITOR_FLUSH_DELAY_MS")

        checkOrEcho unwound,
          "the build did not unwind, so this case measured a clean finish " &
          "and not an error path"
        checkOrEcho fileExists(depPath),
          "the publication in flight when the build unwound was dropped: " &
          depPath & " never appeared"
        # And no scratch left beside it — a dropped rename leaves the
        # dot-prefixed temp file behind, which is the other observable of the
        # same defect.
        var leftovers: seq[string] = @[]
        if dirExists(cacheRoot / "monitor-depfiles"):
          for kind, path in walkDir(cacheRoot / "monitor-depfiles"):
            if kind == pcFile and path.extractFilename.contains(".flush-"):
              leftovers.add path
        checkOrEcho leftovers.len == 0,
          "flush scratch was left behind by the unwind: " & leftovers.join(", ")
