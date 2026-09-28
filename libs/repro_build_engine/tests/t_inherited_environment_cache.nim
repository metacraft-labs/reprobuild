## Real process observations, cache decisions and output bytes. No synthetic
## depfiles: the child calls libc getenv under the graph-built monitor.
##
## No mocks. The RunQuota lease the engine takes for every launch is served by
## a real ``runquotad`` this fixture starts on a private socket (unless the
## caller bypasses RunQuota with ``REPROBUILD_NO_RUNQUOTA=1``), because the
## assertions include that the launch was actually leased — an ambient
## host-wide daemon is not something a test may assume.
import std/[os, osproc, tempfiles, unittest]

import repro_build_engine
import repro_local_store
import repro_test_support
from repro_runquota import isRunQuotaDaemonReachable

const
  ProbeName = "REPRO_TEST_INHERITED_CACHE_INPUT"
  UnreadName = "REPRO_TEST_UNREAD_CACHE_INPUT"

proc cGetEnv(name: cstring): cstring {.importc: "getenv", header: "<stdlib.h>".}

if paramCount() == 3 and paramStr(1) == "--environment-cache-child":
  let value = cGetEnv(paramStr(2))
  writeFile(paramStr(3), if value == nil: "unset" else: "set:" & $value)
  quit(0)

type Fixture = object
  root, work, output: string
  config: BuildEngineConfig
  saved: seq[tuple[name: string, present: bool, value: string]]
  runQuotaDaemon: Process

proc runQuotaBypassed(): bool =
  getEnv("REPROBUILD_NO_RUNQUOTA") == "1"

proc startRunQuotaDaemon(f: var Fixture) =
  ## A private ``runquotad`` for this fixture, reached through
  ## ``RUNQUOTA_SOCKET``. Without one the engine's lease helper dials the
  ## host-wide default endpoint, which an unprovisioned host does not have,
  ## and every launch fails before the child runs.
  let socket = runquotaRendezvousDir(f.root / "runquota") / "runquota.sock"
  f.runQuotaDaemon = startProcess(requireRunQuotaDaemonBin(ReprobuildRepoRoot),
    args = ["--socket", socket, "--cpu-milli", "4000",
      "--memory-bytes", "17179869184"],
    options = {poParentStreams})
  putEnv("RUNQUOTA_SOCKET", socket)
  for _ in 0 ..< 400:
    # A protocol probe rather than a file check: ``fileExists`` is false
    # for a Unix socket, and a bound socket is not yet an accepting daemon.
    if isRunQuotaDaemonReachable():
      return
    if not f.runQuotaDaemon.running:
      break
    sleep(25)
  f.runQuotaDaemon.terminate()
  discard f.runQuotaDaemon.waitForExit()
  f.runQuotaDaemon.close()
  f.runQuotaDaemon = nil
  raise newException(IOError, "runquotad did not become reachable at " & socket)

proc setupFixture(): Fixture =
  result.root = createTempDir("repro-inherited-env-", "")
  result.work = result.root / "work"
  result.output = result.work / "value.txt"
  createDir(result.work)
  for name in [ProbeName, UnreadName, "REPRO_MONITOR_SHIM_LIB",
               "RUNQUOTA_SOCKET"]:
    result.saved.add((name, existsEnv(name), getEnv(name)))
  if not runQuotaBypassed():
    result.startRunQuotaDaemon()
  let tools = prepareMonitorTools(ReprobuildRepoRoot, result.root, "inherited-env")
  putEnv("REPRO_MONITOR_SHIM_LIB", tools.shim)
  result.config = defaultBuildEngineConfig(result.root / "cache")
  result.config.runQuotaCliPath = tools.monitorCliPath
  result.config.monitorCliPath = tools.monitorCliPath
  result.config.monitorCliArgs = tools.monitorCliArgs

proc cleanup(f: Fixture) =
  if f.runQuotaDaemon != nil:
    f.runQuotaDaemon.terminate()
    discard f.runQuotaDaemon.waitForExit()
    f.runQuotaDaemon.close()
  for entry in f.saved:
    if entry.present: putEnv(entry.name, entry.value)
    else: delEnv(entry.name)
  removeDir(f.root)

proc edge(f: Fixture; name = ProbeName; env: seq[string] = @[];
          passthrough: seq[string] = @[]): BuildAction =
  action("read-inherited-environment",
    [getAppFilename(), "--environment-cache-child", name, f.output],
    cwd = f.work, outputs = [f.output], cacheable = true,
    env = env, envPassthrough = passthrough, actionCachePolicy = ffpChecksum,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc run(f: Fixture; action: BuildAction): ActionResult =
  let build = runBuild(graph([action]), f.config)
  doAssert build.results.len == 1
  build.results[0]

proc checkRun(f: Fixture; action: BuildAction; expected: string) =
  let res = f.run(action)
  checkpoint(res.stderr)
  check res.status == asSucceeded
  check res.launched
  check res.cacheDecision != cdHit
  check action.argv[2] in res.evidence.monitorEnvReads
  if not runQuotaBypassed():
    check res.runQuotaBackend.len > 0
    check res.runQuotaBackend != "runquota-bypass"
  check readFile(f.output) == expected

proc checkHit(f: Fixture; action: BuildAction; expected: string) =
  let res = f.run(action)
  checkpoint(res.stderr)
  check res.status in {asCacheHit, asUpToDate}
  check res.cacheDecision == cdHit
  check not res.launched
  check readFile(f.output) == expected

proc inheritedTransitions(f: Fixture) =
  let action = f.edge()
  putEnv(ProbeName, "one")
  f.checkRun(action, "set:one")
  f.checkHit(action, "set:one")
  putEnv(UnreadName, "unread-change")
  f.checkHit(action, "set:one")
  putEnv(ProbeName, "two")
  f.checkRun(action, "set:two")
  f.checkHit(action, "set:two")
  delEnv(ProbeName)
  f.checkRun(action, "unset")
  f.checkHit(action, "unset")
  putEnv(ProbeName, "")
  f.checkRun(action, "set:")
  f.checkHit(action, "set:")

suite "inherited environment cache inputs":
  test "normal lookup tracks live inherited values, not unread variables":
    let f = setupFixture()
    defer: f.cleanup()
    f.inheritedTransitions()

  test "both whole-graph hot-cache paths track inherited changes":
    for skipEvidence in [false, true]:
      var f = setupFixture()
      defer: f.cleanup()
      f.config.rebuildMissingOutputsOnCacheHit = true
      f.config.deferLocalOutputBlobs = true
      f.config.skipCacheHitEvidence = skipEvidence
      f.inheritedTransitions()

  test "explicit values override inheritance with last-write-wins":
    let f = setupFixture()
    defer: f.cleanup()
    let action = f.edge(env = @[ProbeName & "=first", ProbeName & "=last"])
    putEnv(ProbeName, "caller-one")
    f.checkRun(action, "set:last")
    putEnv(ProbeName, "caller-two")
    f.checkHit(action, "set:last")
    check action.actionEnvLookup(ProbeName) == (true, "last")

  test "explicit passthrough retains its name-only cache policy":
    let f = setupFixture()
    defer: f.cleanup()
    let action = f.edge(passthrough = @[ProbeName])
    putEnv(ProbeName, "one")
    f.checkRun(action, "set:one")
    putEnv(ProbeName, "two")
    f.checkHit(action, "set:one")

  test "engine-derived PWD matches the observed child and record":
    let f = setupFixture()
    defer: f.cleanup()
    let action = f.edge(name = "PWD")
    let first = f.run(action)
    require first.status == asSucceeded
    check "PWD" in first.evidence.monitorEnvReads
    check readFile(f.output) == "set:" & f.work
    let inputs = action.cacheEnvInputs(first.evidence, unsafeAddr f.config)
    var found = false
    for entry in inputs:
      if entry.name == "PWD":
        found = true
        check entry.present
        check entry.value == f.work
    check found
    f.checkHit(action, "set:" & f.work)

  test "the inherited resolver snapshots values and preserves unset versus empty":
    let f = setupFixture()
    defer: f.cleanup()
    let action = f.edge()
    putEnv(ProbeName, "one")
    let resolve = action.actionEnvResolver()
    putEnv(ProbeName, "two")
    check resolve(ProbeName) == (true, "one")
    delEnv(ProbeName)
    check action.actionEnvResolver()(ProbeName) == (false, "")
    putEnv(ProbeName, "")
    check action.actionEnvResolver()(ProbeName) == (true, "")
