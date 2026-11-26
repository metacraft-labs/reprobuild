## A cache hit is served as soon as it is ready, whether or not the build
## could launch anything at that moment.
##
## THE DEFECT. The scheduler's ready scan was bounded by LAUNCH capacity: it
## stopped as soon as the parallel slots were taken (``maxParallelism``),
## the RunQuota frontier was full of candidates queued for a lease, a named
## pool was at capacity, or the site-table first run held a toolchain. Every
## ready action behind that point waited -- including the ones the action
## cache would have served without launching anything. A cache hit takes no
## slot, no lease and no pool unit, but it was consulted only when a launch
## would have been allowed, so on a busy host a mostly-warm build served its
## hits at the rate its misses were granted: a 91% cache-hit `.#test-builds`
## completed about 25 actions a minute with most slots idle, because RunQuota
## shrinks the frontier to two queued candidates on a busy host and every hit
## queued behind them.
##
## THE PROPERTY: launch capacity gates launches, not cache consultation.
## While launch capacity is exhausted,
## each ready action is still consulted once. One the cache or its
## outputs-present check can serve completes there; one that would have to
## launch is deferred, its result restored, and consulted again when it can
## launch.
##
## WHAT THIS RUNS. A real `runBuild` twice over one graph: slow actions
## (`sleep`) that are not cacheable and so re-run on every build, ahead of
## cacheable built-in copy actions in the ready order. The first build warms
## the copies; the second must serve every copy from the cache BEFORE the
## first slow action finishes. Ordering is read from the engine's scheduler
## trace sequence, so the assertion does not depend on wall-clock timing:
## with the defect each copy completes only after the slow actions ahead of
## it have finished, whatever the host's speed. One case per launch gate:
##
##   * parallel slots, on the bypass launch path;
##   * a named pool at capacity, on the bypass launch path;
##   * the RunQuota frontier, through a real `runquotad` on a private
##     endpoint whose budget admits one slow action at a time (each asks for
##     every CPU of the host), so the others queue for a lease.
##
## NO MOCKS: the real engine, action cache, launcher and RunQuota daemon,
## real `/bin/sh` subprocesses and real files in a temporary directory.
##
## The slow actions' own launches are graded too, from a log each one appends
## its start and end to: no more of them run at once than the gate allows.
## A change that served hits early by launching past capacity fails there in
## the slots and pool cases. (In the RunQuota case the daemon's own grant
## still admits one slow action at a time, so that case cannot see such a
## change; the other two can.)
##
## FALSIFYING MUTATION: restoring the ready scan's loop guard
## (``running.len + staged < maxParallel`` and the frontier bound) and the
## pool / site-table ``continue`` makes every case fail with the copies
## ordered after the first slow action.

from repro_cli_support/runquota_helper_cli import runRunQuotaHelperArgs,
  selectsRunQuotaHelper
import std/[os, osproc, strutils, tables, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_hash
import repro_local_store
import repro_runquota

import repro_test_support
import repro_test_support/process_fixtures

when isMainModule:
  let params = commandLineParams()
  if selectsRunQuotaHelper(params):
    quit runRunQuotaHelperArgs(params)

const
  SlowCount = 4
  HitCount = 12
  SlowSeconds = 2

proc terminalSeq(res: BuildRunResult; id: string): uint64 =
  ## The sequence number of `id`'s first terminal trace event: the status
  ## `completeSuccess` (or a failure) records when the action settles.
  const terminal = [$asSucceeded, $asCacheHit, $asUpToDate, $asFailed,
    $asBlocked]
  for event in res.trace:
    if event.actionId == id and event.event in terminal:
      return event.seq
  0'u64

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

proc slowId(i: int): string = "slow-" & $i
proc hitId(i: int): string = "copy-" & $i

proc makeGraph(workRoot: string; slowCpuMilli = 1000'u32;
               slowPool = ""; poolCapacity = 0'u32): BuildGraph =
  ## Slow actions first, so they lead the ready order (the scheduler sorts
  ## the ready queue by graph position).
  var actions: seq[BuildAction] = @[]
  for i in 0 ..< SlowCount:
    var slow = action(slowId(i),
      # `launches.log` records each run's start and end, in the order they
      # happen (appends), so the test can read how many ran at once.
      ["/bin/sh", "-c", "echo start >> launches.log && sleep " &
        $SlowSeconds & " && echo end >> launches.log && echo " & $i &
        " > out/" & slowId(i) & ".txt"],
      cwd = workRoot, outputs = ["out/" & slowId(i) & ".txt"],
      pool = slowPool, cpuMilli = slowCpuMilli, cacheable = false,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    actions.add(slow)
  for i in 0 ..< HitCount:
    var copy = builtinAction(bakCopyFile, hitId(i), cwd = workRoot,
      inputs = ["src/" & hitId(i) & ".txt"],
      outputs = ["out/" & hitId(i) & ".txt"],
      cacheable = true,
      weakFingerprint = weakFingerprintFromText(
        "hits-not-held-behind-launch-capacity." & hitId(i)),
      actionCachePolicy = ffpChecksum,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    # In the pool case the copies share the slow actions' pool: a pool at
    # capacity gates a LAUNCH from it, and a hit launches nothing.
    copy.pool = slowPool
    actions.add(copy)
  if slowPool.len > 0:
    graph(actions, [pool(slowPool, poolCapacity)])
  else:
    graph(actions)

proc prepareWorkRoot(root: string): string =
  result = root / "work"
  createDir(result / "src")
  createDir(result / "out")
  for i in 0 ..< HitCount:
    writeFile(result / "src" / (hitId(i) & ".txt"), "content " & $i & "\n")

proc peakConcurrentSlow(workRoot: string): int =
  ## The most slow actions that were running at once, from `launches.log`.
  var current = 0
  for line in readFile(workRoot / "launches.log").splitLines():
    case line.strip()
    of "start":
      inc current
      result = max(result, current)
    of "end":
      dec current
    else:
      discard

proc checkHitsServedFirst(second: BuildRunResult; workRoot: string;
                          launchLimit: int) =
  ## Every copy is a cache hit that launched nothing, and every one settled
  ## before ANY slow action did -- while the slow actions themselves still
  ## launched within the gate (`launchLimit` at once): serving hits early
  ## must not be bought by launching past capacity.
  let peak = peakConcurrentSlow(workRoot)
  checkpoint "peak concurrent slow actions: " & $peak & " (limit " &
    $launchLimit & ")"
  check peak >= 1
  check peak <= launchLimit
  var firstSlow = high(uint64)
  for i in 0 ..< SlowCount:
    let item = second.byId(slowId(i))
    check item.status == asSucceeded
    check item.launched
    let s = second.terminalSeq(slowId(i))
    check s > 0'u64
    firstSlow = min(firstSlow, s)
  for i in 0 ..< HitCount:
    let item = second.byId(hitId(i))
    checkpoint hitId(i) & ": status=" & $item.status & " decision=" &
      $item.cacheDecision & " reason=" & item.reason
    check item.status in {asCacheHit, asUpToDate}
    check item.cacheDecision == cdHit
    check not item.launched
    let s = second.terminalSeq(hitId(i))
    checkpoint hitId(i) & " settled at trace seq " & $s &
      "; first slow action settled at " & $firstSlow
    check s > 0'u64
    check s < firstSlow

proc warmThenRebuild(g: BuildGraph; config: BuildEngineConfig):
    BuildRunResult =
  let first = runBuild(g, config)
  for item in first.results:
    checkpoint "first build: " & item.id & " " & $item.status & " " &
      item.stderr
    check item.status == asSucceeded
  # Only the second build's launches are graded.
  removeFile(g.actions[0].cwd / "launches.log")
  runBuild(g, config)

proc startDaemon(repoRoot, root: string): Process =
  ## A private `runquotad` whose CPU budget is the host's processors, with
  ## ambient sampling off so the budget does not move under the test.
  let socket = runquotaSocketEndpoint("repro-hits-capacity-" &
    $getCurrentProcessId())
  when defined(posix):
    releaseDirAtProcessExit(socket.parentDir)
  if fileExists(socket):
    removeFile(socket)
  writeFile(root / "runquotad.toml", "schema = \"runquota.host-config.v1\"\n")
  putEnv("RUNQUOTA_SOCKET", socket)
  result = startProcess(requireRunQuotaDaemonBin(repoRoot), args = [
    "--socket", socket, "--host-config", root / "runquotad.toml",
    "--host-identity-file", root / "host-id",
    "--ambient-sample-interval-millis", "0",
    "--memory-pressure-source", "unavailable"],
    options = {poUsePath, poParentStreams})
  when defined(posix):
    terminateAtProcessExit(processID(result))
  for _ in 0 ..< 600:
    if isRunQuotaDaemonReachable():
      return
    sleep(50)
  raise newException(OSError, "runquotad did not become reachable")

suite "cache hits are not held behind launch capacity":
  let repoRoot = getCurrentDir()

  test "full parallel slots do not hold back ready cache hits":
    let root = createTempDir("repro-hits-slots-", "")
    defer: removeDir(root)
    let workRoot = prepareWorkRoot(root)
    var config = defaultBuildEngineConfig(root / "cache")
    config.bypassRunQuota = true
    # Fewer slots than slow actions: the slow ones fill every slot.
    config.maxParallelism = 2'u32
    let second = warmThenRebuild(makeGraph(workRoot), config)
    check second.results.len == SlowCount + HitCount
    checkHitsServedFirst(second, workRoot, launchLimit = 2)

  test "a named pool at capacity does not hold back its ready cache hits":
    let root = createTempDir("repro-hits-pool-", "")
    defer: removeDir(root)
    let workRoot = prepareWorkRoot(root)
    var config = defaultBuildEngineConfig(root / "cache")
    config.bypassRunQuota = true
    config.maxParallelism = 8'u32
    let second = warmThenRebuild(
      makeGraph(workRoot, slowPool = "serial", poolCapacity = 1'u32), config)
    check second.results.len == SlowCount + HitCount
    checkHitsServedFirst(second, workRoot, launchLimit = 1)

  test "candidates queued at RunQuota do not hold back ready cache hits":
    let saved = @["RUNQUOTA_SOCKET", "RUNQUOTA_ENDPOINT_SCOPE"]
    var prior = initTable[string, string]()
    for name in saved:
      if existsEnv(name): prior[name] = getEnv(name)
    defer:
      for name in saved:
        if prior.hasKey(name): putEnv(name, prior[name])
        else: delEnv(name)
    when defined(posix):
      putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
    let root = createTempDir("repro-hits-runquota-", "")
    releaseDirAtProcessExit(root)
    defer: removeDir(root)
    var daemon = startDaemon(repoRoot, root)
    defer:
      daemon.terminate()
      discard daemon.waitForExit(5000)
      daemon.close()
    let workRoot = prepareWorkRoot(root)
    var config = BuildEngineConfig(
      cacheRoot: root / "cache",
      runQuotaCliPath: getAppFilename(),
      # More slots than the daemon admits slow actions, fewer than there
      # are slow actions: the frontier fills with queued candidates.
      maxParallelism: 3'u32,
      stdoutLimit: 64 * 1024,
      stderrLimit: 64 * 1024,
      inlineRunQuota: true)
    # Each slow action asks for every CPU of the host, so RunQuota grants
    # one at a time and the rest wait for a lease.
    let wholeHost = uint32(max(1, countProcessors())) * 1000'u32
    let second = warmThenRebuild(
      makeGraph(workRoot, slowCpuMilli = wholeHost), config)
    check second.results.len == SlowCount + HitCount
    checkHitsServedFirst(second, workRoot, launchLimit = 1)
