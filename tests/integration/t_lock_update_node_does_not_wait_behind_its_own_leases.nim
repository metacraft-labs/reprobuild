## A scheduler never suspends itself, holding RunQuota leases, in an inline
## node whose own engine pass needs a lease it cannot get.
##
## THE DEFECT. A certifying
## ``repro test`` adds an HL-10 lock-update node (``bakLockUpdate``) to its
## graph. The scheduler runs that node INLINE, on its own thread, and the
## node's writers evaluate the recipe: an interface extract or a provider
## compile, each a nested engine pass with its own RunQuota session. The
## node was started while a test-build edge of the same scheduler still held
## its lease. The nested pass queued for a lease that did not fit beside it,
## and the test-build's lease could be released only when the scheduler
## reaped that edge -- which it could not do while it was inside the node.
## Hold-and-wait: the build printed ``runquota.waiting ... capacity is held
## by: lease 16 "nim_termctl.test_build..."`` every 5 s until CI's 6-hour
## job limit killed it.
##
## THE PROPERTIES.
##
##   1. A lock-update node is a barrier for this scheduler's leases: it runs
##      only when nothing of this scheduler is in flight, and no process edge
##      launches while it waits to run (Build-Engine-And-Scheduler.md §"Inline
##      nodes that run nested engine passes").
##   2. A nested engine pass whose queued lease can never be granted, because
##      every lease holding the capacity belongs to a scheduler of this thread
##      that is suspended in an inline node, fails at once with a reason that
##      names the holder, instead of waiting for a timeout or forever.
##
## WHAT THIS RUNS. A real ``runquotad`` on a private endpoint with a fixed
## four-CPU budget (``--cpu-milli``), so both cases run the same way on every
## host whatever its processor count, and real ``runBuild`` passes:
##
##   * property 1: an outer graph with a build edge holding all but one CPU,
##     a one-CPU ``prep`` edge, and a lock-update node that depends on
##     ``prep``. ``prep`` finishes first, so the node becomes ready while the
##     build edge still runs. The node's executor runs a nested engine pass
##     whose one action needs two CPUs: it fits only once the build edge's
##     lease is released. The nested pass carries a queue bound, so the
##     defect shows as a bounded failure rather than a hung test;
##   * property 2: an outer RunQuota session holding the whole budget, marked
##     suspended as the scheduler marks itself around an inline node, and a
##     nested pass with a ONE-MINUTE queue bound that needs one CPU. It must
##     fail well inside that bound, naming the holder.
##
## NO MOCKS: the real engine, launcher and RunQuota daemon, real ``/bin/sh``
## subprocesses and real files in a temporary directory. The lock-update
## executor is the test's own, because the real one (the commit-time lock
## writers in ``repro_cli_support``) needs a workspace and sibling checkouts;
## what it does that matters here -- run a nested engine pass that takes a
## lease -- is done for real.
##
## FALSIFYING MUTATIONS: dropping the lock-update barrier from the ready scan
## (``nestedPassBarrier``) fails property 1 with the nested pass's queue
## timeout; dropping the suspended-holder verdict from ``tickRunQuotaQueue``
## fails property 2 with the one-minute ``gave up`` message instead.

from repro_cli_support/runquota_helper_cli import runRunQuotaHelperArgs,
  selectsRunQuotaHelper
import std/[monotimes, os, osproc, strutils, tables, tempfiles, times,
  unittest]

import repro_build_engine
import repro_core
import repro_runquota

import repro_test_support
import repro_test_support/process_fixtures

when isMainModule:
  let params = commandLineParams()
  if selectsRunQuotaHelper(params):
    quit runRunQuotaHelperArgs(params)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

const DaemonCpuMilli = 4000'u32
  ## The private daemon's CPU budget. Fixed rather than the host's processor
  ## count: the first case needs room for a build edge of all but one CPU
  ## plus a two-CPU nested action that fits only once that edge is gone.

proc startDaemon(repoRoot, root, tag: string): Process =
  ## A private ``runquotad`` with a fixed CPU budget (``DaemonCpuMilli``),
  ## ambient sampling off so the budget does not move under the test.
  let socket = runquotaSocketEndpoint("repro-lock-update-barrier-" & tag &
    "-" & $getCurrentProcessId())
  when defined(posix):
    releaseDirAtProcessExit(socket.parentDir)
  if fileExists(socket):
    removeFile(socket)
  writeFile(root / "runquotad.toml", "schema = \"runquota.host-config.v1\"\n")
  putEnv("RUNQUOTA_SOCKET", socket)
  result = startProcess(requireRunQuotaDaemonBin(repoRoot), args = [
    "--socket", socket, "--host-config", root / "runquotad.toml",
    "--host-identity-file", root / "host-id",
    "--cpu-milli", $DaemonCpuMilli,
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

proc engineConfig(root: string; queueTimeoutMs: int): BuildEngineConfig =
  BuildEngineConfig(
    cacheRoot: root,
    runQuotaCliPath: getAppFilename(),
    maxParallelism: 4'u32,
    stdoutLimit: 64 * 1024,
    stderrLimit: 64 * 1024,
    inlineRunQuota: true,
    runQuotaQueueTimeoutMs: queueTimeoutMs)

proc nestedPass(workRoot, cacheRoot: string; cpuMilli: uint32;
                queueTimeoutMs: int): BuildRunResult =
  ## The nested engine pass an inline node runs: one uncacheable process
  ## that needs ``cpuMilli`` and appends to the shared launch log.
  let nested = action("nested-compile",
    ["/bin/sh", "-c", "echo nested-start >> launches.log && " &
      "echo done > out/nested.txt && echo nested-end >> launches.log"],
    cwd = workRoot, outputs = ["out/nested.txt"], cpuMilli = cpuMilli,
    cacheable = false, governingLockIdentity = lockIdentityOutsideSolvedGraph())
  runBuild(graph([nested]), engineConfig(cacheRoot, queueTimeoutMs))

template withPrivateRunQuota(tag: string; body: untyped) =
  let saved = @["RUNQUOTA_SOCKET", "RUNQUOTA_ENDPOINT_SCOPE",
    "REPRO_RUNQUOTA_QUEUE_TIMEOUT"]
  var prior = initTable[string, string]()
  for name in saved:
    if existsEnv(name): prior[name] = getEnv(name)
  defer:
    for name in saved:
      if prior.hasKey(name): putEnv(name, prior[name])
      else: delEnv(name)
  # The bound each pass sets in its config is the one under test.
  delEnv("REPRO_RUNQUOTA_QUEUE_TIMEOUT")
  when defined(posix):
    putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
  let root {.inject.} = createTempDir("repro-lock-update-barrier-", "")
  releaseDirAtProcessExit(root)
  defer: removeDir(root)
  var daemon = startDaemon(getCurrentDir(), root, tag)
  defer:
    daemon.terminate()
    discard daemon.waitForExit(5000)
    daemon.close()
  let workRoot {.inject.} = root / "work"
  createDir(workRoot / "out")
  body

suite "a scheduler does not wait behind its own leases":
  const budget = DaemonCpuMilli

  test "the lock-update node runs only once the build edge's lease is released":
    withPrivateRunQuota("barrier"):
      var nestedResult: BuildRunResult
      var nestedRan = false
      registerLockUpdateExecutor(proc(a: BuildAction): ActionResult
          {.gcsafe.} =
        {.cast(gcsafe).}:
          nestedRan = true
          # Two CPUs: it fits only once the build edge's lease (all but
          # one CPU) is released. Bounded at 20 s, so the defect fails this
          # case instead of hanging it.
          nestedResult = nestedPass(workRoot, root / "nested-cache",
            2000'u32, 20_000)
          ActionResult(id: a.id, status: asSucceeded, exitCode: 0))
      defer: clearLockUpdateExecutor()
      let buildEdge = action("build-edge",
        ["/bin/sh", "-c", "echo build-start >> launches.log && sleep 3 && " &
          "echo done > out/build.txt && echo build-end >> launches.log"],
        cwd = workRoot, outputs = ["out/build.txt"],
        cpuMilli = budget - 1000'u32, cacheable = false,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      let prep = action("prep",
        ["/bin/sh", "-c", "echo done > out/prep.txt"],
        cwd = workRoot, outputs = ["out/prep.txt"], cpuMilli = 1000'u32,
        cacheable = false,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      let lockUpdate = builtinAction(bakLockUpdate,
        "repro-lock-update:work", cwd = workRoot, deps = ["prep"],
        cacheable = false, text = workRoot,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      let started = getMonoTime()
      let outer = runBuild(graph([buildEdge, prep, lockUpdate]),
        engineConfig(root / "cache", 0))
      let elapsedMs = inMilliseconds(getMonoTime() - started)
      checkpoint "outer pass took " & $elapsedMs & " ms"
      for item in outer.results:
        checkpoint "outer: " & item.id & " " & $item.status & " " &
          item.stderr
        check item.status == asSucceeded
      check nestedRan
      for item in nestedResult.results:
        checkpoint "nested: " & item.id & " " & $item.status & " " &
          item.stderr
      check nestedResult.results.len == 1
      check nestedResult.byId("nested-compile").status == asSucceeded
      # The nested pass ran after the build edge, never beside it.
      let log = readFile(workRoot / "launches.log").splitLines()
      checkpoint "launch log: " & log.join(" | ")
      check log.find("build-end") >= 0
      check log.find("nested-start") > log.find("build-end")

  test "a nested pass blocked only by a suspended scheduler's lease fails at once":
    withPrivateRunQuota("suspended"):
      let outerSession = openRunQuotaSession("suspended outer scheduler")
      defer: outerSession.close()
      # The outer scheduler's in-flight edge: granted the whole budget.
      var holder = startWithRunQuota(outerSession, ReproResourceRequest(
          label: "outer.test_build.holds_everything", cpuMilli: budget,
          memoryBytes: 16'u64 * 1024 * 1024),
        ReproCommandSpec(argv: @["/bin/sh", "-c", "sleep 120"],
          cwd: workRoot))
      defer: discard cancelAndWait(holder)
      let started = getMonoTime()
      var nested: BuildRunResult
      withRunQuotaSessionSuspended(outerSession):
        nested = nestedPass(workRoot, root / "nested-cache", 1000'u32,
          60_000)
      let elapsedMs = inMilliseconds(getMonoTime() - started)
      checkpoint "nested pass ended after " & $elapsedMs & " ms"
      check nested.results.len == 1
      let item = nested.byId("nested-compile")
      checkpoint "nested: " & $item.status & " " & item.stderr
      check item.status == asFailed
      check "can never be granted" in item.stderr
      check "outer.test_build.holds_everything" in item.stderr
      check "gave up after" notin item.stderr
      check elapsedMs < 30_000
