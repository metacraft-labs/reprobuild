## In-Process-Monitor-Hosting HM-5 — the depfile flush is ASYNCHRONOUS and
## ATOMIC.
##
## WHAT IS BEING PINNED, and why each case is shaped the way it is.
##
## HM-5 moves the publication of an action's ``.rdep`` off the scheduler's
## serial path: ``finishMonitorHostAction`` hands the action's result and its
## in-memory records forward and queues a rename behind them. Two things can go
## wrong with that, and they fail in opposite directions:
##
##   * a publication that is not ATOMIC lets a reader observe a half-written
##     depfile, which decoded as truth is a WRONG DEPENDENCY SET — the cardinal
##     sin. ``rename(2)`` is atomic only within one filesystem and degrades
##     SILENTLY to copy-then-unlink across one, so the scratch file's placement
##     is the whole mechanism and is asserted by comparing ``st_dev``, not by
##     reading the implementation.
##   * a publication that FAILS must cost a re-execution and nothing else. The
##     engine's evidence comes from memory since HM-5, so the action itself is
##     unaffected; what must not happen is a cache entry published for an
##     action whose artefact never landed.
##
## NO MOCKS. Every case runs a real build, with a real monitored child, real
## shared memory and real files. The two seams the cases drive —
## ``REPROBUILD_MONITOR_FLUSH_DELAY_MS`` and ``REPROBUILD_MONITOR_FLUSH_FAIL``
## — are read by the SHIPPING code path (``enqueueMonitorFlush`` /
## ``publishOneFlush``); they do not substitute anything, they make a real
## rename late and a real publication fail. Without the delay the publication
## is one ``rename`` and lands in microseconds, so "the next edge started
## first" would be a statement about scheduling luck rather than about
## ordering.
##
## THE ORDERING ORACLE IS THE BUILD ITSELF, not a sampling thread: each action
## in the chained cases LOOKS FOR ITS PREDECESSOR'S depfile and records what it
## saw. An action running is proof the scheduler started that edge, and the
## observation is taken at exactly the instant that matters instead of whenever
## a poller happened to wake up.

import std/[os, strutils, unittest]
when defined(posix):
  from std/posix import Stat, stat, S_ISDIR

import repro_build_engine
import repro_build_engine/monitor_flush
from repro_test_support import prepareMonitorTools, testCaseScratchSlug

when defined(linux) or defined(macosx):
  import io_mon

  template checkOrEcho(cond: untyped; msg: string) =
    ## `check` inside a plain `proc` prints "Check failed" and still reports
    ## `[OK]`, so every helper that asserts in this file is a template.
    if not (cond):
      echo msg
    check cond

  proc deviceOf(path: string): uint =
    ## The filesystem a path lives on, straight out of ``stat``. This is the
    ## whole oracle for `flush temp is on the destination filesystem`: nothing
    ## here reads the implementation's intent.
    var st: Stat
    if stat(path.cstring, st) != 0:
      raise newException(OSError, "stat failed for " & path)
    uint(st.st_dev)

  proc flushScratchRoot(name: string): string =
    let root = absolutePath("build" / "test-tmp" /
      "test_monitor_depfile_flush" / testCaseScratchSlug() / name)
    if dirExists(root):
      removeDir(root)
    createDir(root)
    root

  proc hostedConfig(cacheRoot: string; parallelism: uint32): BuildEngineConfig =
    ## The L1 bypass path with a monitor driver wired — the one combination
    ## the engine hosts in-process, and therefore the only one HM-5's flush
    ## runs on. Hosting is opt-in and off by default, so it is requested here
    ## explicitly; see ``BuildEngineConfig.monitorHosting``.
    let tools = prepareMonitorTools(getCurrentDir(),
      getCurrentDir() / "build" / "test-hm5-flush", "hm5-flush")
    putEnv("REPRO_MONITOR_SHIM_LIB", tools.shim)
    BuildEngineConfig(
      cacheRoot: cacheRoot,
      runQuotaCliPath: tools.monitorCliPath,
      monitorCliPath: tools.monitorCliPath,
      monitorCliArgs: tools.monitorCliArgs,
      maxParallelism: parallelism,
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024,
      bypassRunQuota: true,
      monitorHosting: mhmWhereSupported)

  proc depfilePathFor(cacheRoot, actionId: string): string =
    ## Where the engine publishes one action's depfile. Derived the same way
    ## ``monitoredAction`` derives it; the ids used below are already
    ## filename-safe, so no sanitisation is involved and this cannot drift
    ## into agreeing with the engine by accident.
    cacheRoot / "monitor-depfiles" / (actionId & ".rdep")

  type TornReaderCtx = object
    ## The concurrent reader's whole world, in manually-managed shared memory.
    ##
    ## NOT a set of ``{.global.}`` Nim values, and the compiler is the reason:
    ## a thread proc that touches a global holding GC'd memory is rejected as
    ## not GC-safe, and casting that away would be exactly the hazard HM-3
    ## measured with TSAN in nim-shm-gset's pool. The reader therefore reaches
    ## nothing but this block, which it is handed as its thread argument.
    stop: bool
    complete: int
    torn: int
    pathCount: int
    paths: array[16, cstring]
    firstTornPath: array[512, char]
    firstTornWhy: array[256, char]

  proc sharedCopy(value: string): cstring =
    let n = value.len
    result = cast[cstring](allocShared0(n + 1))
    if n > 0:
      copyMem(result, value.cstring, n)

  proc storeInto(dest: var openArray[char]; value: string) =
    let n = min(value.len, dest.len - 1)
    for i in 0 ..< n:
      dest[i] = value[i]
    dest[n] = '\0'

  proc readU64Le(s: string; pos: int): uint64 =
    for i in 0 ..< 8:
      result = result or (uint64(uint8(s[pos + i])) shl (8 * i))

  proc envelopeFault(raw: string): string =
    ## "" when ``raw`` is a structurally complete RMDF envelope, otherwise why
    ## it is not. A file caught mid-copy is a PREFIX of a complete one, so it
    ## fails on the length or on the trailer that is no longer where the header
    ## says it should be.
    if raw.len < 44:
      return "too short (" & $raw.len & " bytes)"
    if raw[0 .. 3] != RmdfMagic:
      return "bad magic"
    let headerCount = readU64Le(raw, 8)
    let bodyLen = readU64Le(raw, 16)
    if bodyLen > uint64(int.high):
      return "absurd body length"
    let bodyEnd = 24 + int(bodyLen)
    if bodyEnd + 20 != raw.len:
      return "body/trailer length mismatch: header says body ends at " &
        $bodyEnd & " but the file is " & $raw.len & " bytes"
    if raw[bodyEnd .. bodyEnd + 3] != RmdfTrailerMagic:
      return "missing trailer magic at " & $bodyEnd
    if readU64Le(raw, bodyEnd + 4) != headerCount:
      return "header/trailer record-count mismatch"
    ""

  proc tornReaderLoop(ctx: ptr TornReaderCtx) {.thread.} =
    while not ctx.stop:
      for i in 0 ..< ctx.pathCount:
        let path = $ctx.paths[i]
        if not fileExists(path): continue
        var raw = ""
        try:
          raw = readFile(path)
        except CatchableError:
          # The file was replaced between the existence check and the open.
          # ``rename`` makes that a swap of a COMPLETE file for a complete
          # one, so a failed open here is not evidence of tearing.
          continue
        let fault = envelopeFault(raw)
        if fault.len == 0:
          inc ctx.complete
        else:
          if ctx.torn == 0:
            storeInto(ctx.firstTornPath, path)
            storeInto(ctx.firstTornWhy, fault)
          inc ctx.torn

  proc flushScratchLeftovers(cacheRoot: string): seq[string] =
    result = @[]
    let dir = cacheRoot / "monitor-depfiles"
    if not dirExists(dir): return
    for kind, path in walkDir(dir):
      if kind == pcFile and path.extractFilename.contains(".flush-"):
        result.add path

  suite "HM-5 monitor depfile flush":
    test "flush temp is on the destination filesystem":
      ## THE PROPERTY, ASSERTED DIRECTLY. ``rename`` is atomic within one
      ## filesystem and a silent copy-then-unlink across one, so this compares
      ## ``st_dev`` of the scratch file and of the destination.
      ##
      ## AND IT IS EXERCISED ON THE PATH WHERE SCRATCH IS RELOCATED: ``TMPDIR``
      ## is pointed at a directory on a DIFFERENT device for the duration, so
      ## an implementation that derived the scratch path from ``getTempDir()``
      ## — which is what this repository's Windows ``MAX_PATH`` workaround does
      ## elsewhere — lands on the wrong device and reddens here.
      ##
      ## MUTATION TARGET: make ``monitorFlushTempPath`` return
      ## ``getTempDir() / ...`` and this case fails on
      ## ``deviceOf(temp) == deviceOf(destDir)``.
      when not defined(linux):
        skip()
      else:
        # ``/dev/shm`` is a tmpfs and the workspace is not, so the two are
        # different devices on any normal Linux host. If they are NOT — a
        # machine where everything is one filesystem — the comparison below
        # could pass while proving nothing, so the test RAISES instead of
        # quietly succeeding.
        let onOtherFs = "/dev/shm" / ("repro-hm5-" & $getCurrentProcessId())
        let onCacheFs = flushScratchRoot("tempfs")
        createDir(onOtherFs)
        defer: removeDir(onOtherFs)

        if deviceOf(onOtherFs) == deviceOf(onCacheFs):
          raise newException(ValueError,
            "this host puts /dev/shm and the workspace on the SAME device (" &
            $deviceOf(onOtherFs) & "), so this case cannot tell a " &
            "same-filesystem scratch path from a relocated one. It refuses " &
            "to report a pass it did not earn.")

        let previousTmp = getEnv("TMPDIR")
        putEnv("TMPDIR", onOtherFs)
        defer:
          if previousTmp.len > 0: putEnv("TMPDIR", previousTmp)
          else: delEnv("TMPDIR")

        # The destination is on the workspace filesystem; the relocated
        # scratch dir is on the other one. A correct derivation follows the
        # DESTINATION.
        let dest = onCacheFs / "hm5-fs-probe.rdep"
        let temp = monitorFlushTempPath(dest, 1)
        writeFile(temp, "scratch")
        writeFile(dest, "destination")
        defer:
          removeFile(temp)
          removeFile(dest)

        checkOrEcho deviceOf(temp) == deviceOf(dest),
          "flush scratch " & temp & " is on device " & $deviceOf(temp) &
          " but its destination " & dest & " is on device " & $deviceOf(dest) &
          " — rename(2) across that boundary is a copy, not an atomic publish"
        # Non-vacuity: the relocated temp dir really is somewhere else, so the
        # equality above is a fact about the derivation and not about the host
        # having one filesystem.
        checkOrEcho deviceOf(getTempDir()) != deviceOf(dest),
          "TMPDIR was relocated to " & getTempDir() &
          " but it resolves to the destination's own device, so this case " &
          "cannot distinguish the two derivations"
        checkOrEcho temp.parentDir == dest.parentDir,
          "flush scratch is not a sibling of its destination: " & temp

    test "a failed flush causes a re-execution, not a wrong answer":
      ## The conservative direction. When the publication fails, the action
      ## itself still SUCCEEDS — its evidence came from memory and nothing
      ## about it is in doubt — but its cache entry is not published, so the
      ## next build MISSES and re-runs.
      ##
      ## The control run below is what makes this non-vacuous: with the same
      ## graph, the same cache root and no injected failure, the second build
      ## is a cache HIT. So "it re-ran" is a consequence of the injected
      ## failure and not of the fixture being incapable of a hit.
      ##
      ## MUTATION TARGET: drop the ``monitorFlushFailures`` consultation in
      ## the scheduler and this case reddens on the second build being a hit.
      let root = flushScratchRoot("failed")
      let work = root / "work"
      createDir(work)
      let cacheRoot = root / "cache"
      let outName = "flush-fail-out.txt"

      proc oneAction(): BuildGraph =
        # ``cacheable = true`` is load-bearing and was NOT the default: with
        # the default the action can never publish an entry, every build
        # reports ``cdNotCacheable``, and "the second build did not hit"
        # would be true for a reason that has nothing to do with the flush.
        # The control at the bottom of this case is what caught that.
        graph([action("hm5-flushfail",
          @["sh", "-c", "printf produced > " & quoteShell(outName)],
          cwd = work,
          outputs = [outName],
          cacheable = true,
          governingLockIdentity = lockIdentityOutsideSolvedGraph())])

      putEnv("REPROBUILD_MONITOR_FLUSH_FAIL", "hm5-flushfail")
      var first: BuildRunResult
      try:
        first = runBuild(oneAction(), hostedConfig(cacheRoot, 1'u32))
      finally:
        delEnv("REPROBUILD_MONITOR_FLUSH_FAIL")

      check first.results.len == 1
      checkOrEcho first.results[0].status == asSucceeded,
        "an action whose depfile flush failed must still SUCCEED (its " &
        "evidence came from memory); got " & $first.results[0].status &
        " stderr=" & first.results[0].stderr
      checkOrEcho not fileExists(depfilePathFor(cacheRoot, "hm5-flushfail")),
        "the injected failure was supposed to leave no published depfile"

      # The re-run. Same graph, same cache root, no injected failure.
      removeFile(work / outName)
      let second = runBuild(oneAction(), hostedConfig(cacheRoot, 1'u32))
      check second.results.len == 1
      checkOrEcho second.results[0].status == asSucceeded,
        "the second build should have RE-EXECUTED the action; got " &
        $second.results[0].status
      checkOrEcho second.results[0].cacheDecision != cdHit,
        "the second build hit the action cache, so the failed flush did NOT " &
        "cost a re-execution: " & $second.results[0].cacheDecision
      checkOrEcho fileExists(depfilePathFor(cacheRoot, "hm5-flushfail")),
        "the re-run's own flush should have published a depfile"

      # CONTROL: a third build over the now-published entry IS a cache hit,
      # which is what proves the assertion above is about the injected
      # failure rather than about this fixture never hitting.
      removeFile(work / outName)
      let third = runBuild(oneAction(), hostedConfig(cacheRoot, 1'u32))
      check third.results.len == 1
      checkOrEcho third.results[0].cacheDecision == cdHit,
        "control: with a successful flush behind it the next build must be " &
        "a cache HIT, otherwise the case above proves nothing; got " &
        $third.results[0].cacheDecision

    test "the scheduler starts the next edges before the file lands":
      ## THE POINT OF THE MILESTONE, MEASURED RATHER THAN ASSUMED — and
      ## measured by the build itself. The second action's command looks for
      ## the first action's depfile and records what it saw, so the
      ## observation is taken at the instant the next edge RUNS.
      ##
      ## The publication is delayed so the question is decidable at all: a
      ## bare rename lands in microseconds, and "the next edge got there
      ## first" would then be a race this test happened to win.
      ##
      ## AND THE BOUNDARY IS ASSERTED, not left implicit. The engine waits for
      ## a CACHEABLE hosted action's publication before publishing its cache
      ## entry — see ``awaitMonitorFlush`` for why the conservative direction
      ## cannot be a race — so this case runs the chain TWICE: non-cacheable,
      ## where the next edge must see ``NOTYET``, and cacheable, where it must
      ## see ``LANDED``. Asserting the second half positively is what stops the
      ## first half from being read as an unconditional claim, and stops a
      ## future change from quietly making every action wait.
      ##
      ## MUTATION TARGET: make ``finishMonitorHostAction`` wait for its own
      ## flush before returning (``discard awaitMonitorFlushes()`` after the
      ## enqueue) and the non-cacheable arm reddens on ``NOTYET``.
      let witness = "order-witness.txt"

      # A TEMPLATE, NOT A PROC, and that is not a style choice: `check` inside
      # a plain `proc` prints "Check failed" and the case still reports [OK],
      # so a helper that asserts must inline into the test body.
      template runOrderingChain(tag: string; firstIsCacheable: bool):
          tuple[observed, firstDep, cacheRoot: string] =
        let root = flushScratchRoot("ordering-" & tag)
        let work = root / "work"
        createDir(work)
        let chainCacheRoot = root / "cache"
        let chainFirstDep = depfilePathFor(chainCacheRoot,
          "hm5-order-a-" & tag)

        putEnv("REPROBUILD_MONITOR_FLUSH_DELAY_MS", "400")
        var run: BuildRunResult
        try:
          run = runBuild(graph([
            action("hm5-order-a-" & tag,
              @["sh", "-c", "printf a > first.txt"],
              cwd = work,
              outputs = ["first.txt"],
              cacheable = firstIsCacheable,
              governingLockIdentity = lockIdentityOutsideSolvedGraph()),
            action("hm5-order-b-" & tag,
              @["sh", "-c",
                "if [ -e " & quoteShell(chainFirstDep) &
                " ]; then printf LANDED; " &
                "else printf NOTYET; fi > " & quoteShell(witness)],
              cwd = work,
              inputs = ["first.txt"],
              outputs = [witness],
              governingLockIdentity = lockIdentityOutsideSolvedGraph())]),
            hostedConfig(chainCacheRoot, 1'u32))
        finally:
          delEnv("REPROBUILD_MONITOR_FLUSH_DELAY_MS")

        check run.results.len == 2
        for res in run.results:
          checkOrEcho res.status == asSucceeded,
            res.id & " failed: exit=" & $res.exitCode & " " & res.stderr
        checkOrEcho fileExists(work / witness),
          "the second edge never ran, so the " & tag &
          " arm measured nothing"
        (
          (if fileExists(work / witness): readFile(work / witness).strip()
           else: ""),
          chainFirstDep, chainCacheRoot)

      # THE MILESTONE'S PROPERTY. Nothing about this action is published to
      # the action cache, so nothing about it waits: the next edge runs while
      # the publication is still in flight.
      let asyncArm = runOrderingChain("async", firstIsCacheable = false)
      checkOrEcho asyncArm.observed == "NOTYET",
        "the second edge ran only AFTER the first edge's depfile had landed" &
        " (saw '" & asyncArm.observed & "'), so the publication is still on" &
        " the scheduler's serial path"

      # And it does land: asynchronous, not abandoned. ``runBuild`` waits for
      # every queued publication before it returns.
      checkOrEcho fileExists(asyncArm.firstDep),
        "the delayed publication never landed at all: " & asyncArm.firstDep
      checkOrEcho flushScratchLeftovers(asyncArm.cacheRoot).len == 0,
        "scratch files were left behind: " &
        flushScratchLeftovers(asyncArm.cacheRoot).join(", ")

      # THE DECLARED BOUNDARY. A cacheable action does not publish a cache
      # entry over an artefact that has not landed, so it waits — and the next
      # edge therefore finds the file. If this ever reports NOTYET, the
      # conservative direction in `a failed flush causes a re-execution` has
      # become a race again.
      let syncArm = runOrderingChain("sync", firstIsCacheable = true)
      checkOrEcho syncArm.observed == "LANDED",
        "a CACHEABLE action published its cache entry without waiting for" &
        " its own depfile (saw '" & syncArm.observed & "'), so a failed" &
        " publication can no longer be relied on to cost a re-execution"

    test "a recycled slot cannot disturb a publication still in flight":
      ## The reprobuild-side form of the milestone's "snapshot the records
      ## into the flush job's own buffer so the segment can be released
      ## immediately".
      ##
      ## READ THE MAPPING, because the milestone's wording does not survive
      ## contact with this code: the shared-memory segment is released by
      ## io-mon inside ``finishMonitor``, BEFORE a flush job exists at all, so
      ## no reprobuild change can make a job hold one. What a job CAN hold is
      ## the scheduler's own recyclable state — the ``MonitorHostPool`` slot,
      ## which ``finishMonitorHostAction`` releases immediately so the next
      ## action can have it. So the property with teeth here is that a slot
      ## recycled into the next action cannot disturb the previous action's
      ## publication.
      ##
      ## Three chained actions at parallelism 1 all take slot 0, and each
      ## reads a DISTINCT marker file, so each published depfile is
      ## identifiable by its own contents. With every publication lagging
      ## behind the next action's whole lifetime, a job that borrowed
      ## anything from its slot would publish the wrong bytes or none.
      ##
      ## MUTATION TARGET, and the FIRST GUESS WAS WRONG, which is recorded
      ## here rather than quietly replaced. Dropping ``pool.flushNonce`` (a
      ## constant nonce) reddens NOTHING: the scratch name is derived from the
      ## DESTINATION filename, and three actions have three destinations, so
      ## the nonce is not what keeps them apart. The mutation that does redden
      ## it is the one that actually attaches the scratch file to the
      ## recyclable state — deriving it from the pool SLOT
      ## (``depDest.parentDir / ".monitor-host-slot-scratch.tmp"``) instead of
      ## from the destination. Measured red, on the PRIMARY assertions:
      ## action 0's depfile records action 2's marker and not its own, and
      ## actions 1 and 2 publish no depfile at all.
      let root = flushScratchRoot("recycle")
      let work = root / "work"
      createDir(work)
      let cacheRoot = root / "cache"
      var markers: seq[string] = @[]
      var actions: seq[BuildAction] = @[]
      for i in 0 .. 2:
        let marker = work / ("marker-" & $i & ".txt")
        writeFile(marker, "marker " & $i)
        markers.add marker
        let outName = "recycled-" & $i & ".txt"
        actions.add action("hm5-recycle-" & $i,
          @["sh", "-c",
            "cat " & quoteShell(marker) & " > " & quoteShell(outName)],
          cwd = work,
          outputs = [outName],
          governingLockIdentity = lockIdentityOutsideSolvedGraph())

      putEnv("REPROBUILD_MONITOR_FLUSH_DELAY_MS", "250")
      var run: BuildRunResult
      try:
        run = runBuild(graph(actions), hostedConfig(cacheRoot, 1'u32))
      finally:
        delEnv("REPROBUILD_MONITOR_FLUSH_DELAY_MS")

      check run.results.len == 3
      for res in run.results:
        checkOrEcho res.status == asSucceeded,
          res.id & " failed: exit=" & $res.exitCode & " " & res.stderr

      for i in 0 .. 2:
        let dep = depfilePathFor(cacheRoot, "hm5-recycle-" & $i)
        checkOrEcho fileExists(dep), "no depfile published for action " & $i
        if not fileExists(dep): continue
        var paths: seq[string] = @[]
        for record in readMonitorDepFile(dep).records:
          if record.path.len > 0: paths.add record.path
        # Its OWN marker, and NOBODY ELSE'S. A publication that picked up a
        # recycled slot's next action would carry the wrong marker.
        checkOrEcho markers[i] in paths,
          "action " & $i & "'s depfile does not record its own marker " &
          markers[i]
        for j in 0 .. 2:
          if j == i: continue
          checkOrEcho markers[j] notin paths,
            "action " & $i & "'s depfile records action " & $j &
            "'s marker — a publication was disturbed by a recycled slot"

      checkOrEcho flushScratchLeftovers(cacheRoot).len == 0,
        "scratch files were left behind: " &
        flushScratchLeftovers(cacheRoot).join(", ")

    test "a torn depfile is never observable":
      ## A reader running CONCURRENTLY with many publications sees only
      ## complete depfiles or no file at all.
      ##
      ## The reader is a real thread hammering every destination while a real
      ## parallel build publishes into them, and it validates the RMDF ENVELOPE
      ## on every observation: magic, declared body length, trailer magic,
      ## header-count == trailer-count, and total size. That is exactly what a
      ## file caught mid-copy fails, and it is the first thing the engine's own
      ## reader checks.
      ##
      ## IT IS NOT THE CHECKSUM, and the reason is worth stating rather than
      ## leaving as an apparent oversight. Decoding through io-mon's
      ## ``readMonitorDepFile`` would also verify the trailer checksum, but it
      ## reaches module-level state the compiler cannot prove thread-safe, and
      ## it is not needed here: a torn file is a PREFIX of a complete one, so
      ## its trailer is either absent or lands at the wrong offset. The
      ## envelope check decides that case, and it decides it without a GC'd
      ## global crossing into the worker — see ``monitor_flush.nim``'s header
      ## for why that boundary is kept sharp on both sides.
      ##
      ## Every observation is also cross-checked on the MAIN thread after the
      ## build, with a full ``readMonitorDepFile`` of each published file, so
      ## the checksum is verified — just not concurrently.
      ##
      ## MUTATION TARGET: replace ``moveFile(tempPath, destPath)`` in
      ## ``publishOneFlush`` with a chunked copy into the destination. Measured
      ## red, on the PRIMARY assertion: the reader observes incomplete
      ## depfiles, reported as "header says body ends at 18322 but the file is
      ## 8192 bytes".
      ##
      ## AND ONE MUTATION THAT DOES *NOT* REDDEN IT, recorded because the
      ## obvious guess is wrong and a reader would otherwise assume this case
      ## covers more than it does. Returning ``getTempDir() / ...`` from
      ## ``monitorFlushTempPath`` — the cross-filesystem hazard the first case
      ## in this file catches — leaves this one GREEN on this host, because
      ## ``$TMPDIR`` is unset during the build and ``/tmp`` happens to be the
      ## same device as the workspace, so ``moveFile`` is still a rename. The
      ## hazard is real; it is simply not observable from here on a host whose
      ## temp directory shares a filesystem with the build tree, which is why
      ## the ``st_dev`` comparison above exists as a SEPARATE case that
      ## relocates ``$TMPDIR`` deliberately.
      let root = flushScratchRoot("torn")
      let work = root / "work"
      createDir(work)
      let cacheRoot = root / "cache"

      var actions: seq[BuildAction] = @[]
      var deps: seq[string] = @[]
      for i in 0 .. 7:
        let outName = "torn-" & $i & ".txt"
        actions.add action("hm5-torn-" & $i,
          @["sh", "-c", "printf " & $i & " > " & quoteShell(outName)],
          cwd = work,
          outputs = [outName],
          governingLockIdentity = lockIdentityOutsideSolvedGraph())
        deps.add depfilePathFor(cacheRoot, "hm5-torn-" & $i)

      createDir(cacheRoot / "monitor-depfiles")

      var ctx = cast[ptr TornReaderCtx](allocShared0(sizeof(TornReaderCtx)))
      ctx.pathCount = min(deps.len, ctx.paths.len)
      for i in 0 ..< ctx.pathCount:
        ctx.paths[i] = sharedCopy(deps[i])

      var reader: Thread[ptr TornReaderCtx]
      createThread(reader, tornReaderLoop, ctx)

      putEnv("REPROBUILD_MONITOR_FLUSH_DELAY_MS", "30")
      var run: BuildRunResult
      try:
        run = runBuild(graph(actions), hostedConfig(cacheRoot, 4'u32))
      finally:
        delEnv("REPROBUILD_MONITOR_FLUSH_DELAY_MS")
        ctx.stop = true
        joinThread(reader)

      let observedComplete = ctx.complete
      let observedTorn = ctx.torn
      let firstTornPath = $cast[cstring](addr ctx.firstTornPath[0])
      let firstTornWhy = $cast[cstring](addr ctx.firstTornWhy[0])
      for i in 0 ..< ctx.pathCount:
        deallocShared(ctx.paths[i])
      deallocShared(ctx)

      check run.results.len == 8
      for res in run.results:
        checkOrEcho res.status == asSucceeded,
          res.id & " failed: exit=" & $res.exitCode & " " & res.stderr

      checkOrEcho observedTorn == 0,
        "a concurrent reader observed " & $observedTorn &
        " incomplete depfile(s); first was " & firstTornPath & ": " &
        firstTornWhy
      # NOT VACUOUS: a reader that never managed to read anything would
      # report zero torn files while proving nothing.
      checkOrEcho observedComplete > 0,
        "the concurrent reader never observed a published depfile at all, " &
        "so it could not have observed a torn one either"

      # And the full decode, checksum included, on the quiet side of the
      # build: what the envelope check above could not cover.
      for path in deps:
        checkOrEcho fileExists(path), "no depfile published at " & path
        if not fileExists(path): continue
        var decoded = false
        try:
          discard readMonitorDepFile(path).records.len
          decoded = true
        except CatchableError as err:
          echo "published depfile does not decode: ", path, ": ", err.msg
        check decoded
