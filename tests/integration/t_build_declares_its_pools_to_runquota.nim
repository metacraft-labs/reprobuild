## A build's named pools reach a ``runquotad`` that was started with no
## ``--pool`` flag: the engine declares them on its own session.
##
## WHY. Until 2026-10-01 a recipe's pools reached RunQuota only as
## ``runquotad --pool NAME=UNITS`` flags, passed when THIS build spawned the
## daemon. A daemon somebody else started -- the installed service (no
## flags; its seeded host file sizes no pool), or on Windows the one a
## previous build left running -- never heard of them, and every lease in
## them was refused (``lease request exceeds named-pool budget``) until the
## denial deadline failed the build. Flags also pinned the pool against the
## host file. Now the engine declares the pools its graph uses before its
## first lease (``runQuotaPoolDeclaration`` / ``declareRunQuotaPools``), and
## the out-of-process helper declares its lease's pool on its own session
## (reprobuild-specs/RunQuota-Host-Configuration.md, "Pools a build
## declares").
##
## WHAT THIS RUNS. A real ``runquotad`` on a private endpoint with a private,
## empty host file and NO budget flag -- the shape of both the installed
## service and, since 2026-10-01, reprobuild's own auto-spawn. A graph whose
## three actions share a recipe pool of capacity 1, built once through the
## inline session and once through the helper path.
##
## TWO ASSERTIONS PER PATH. The build completes (before the declaration
## existed it ended in ``static-capacity deadlock`` -- the denial timeout is
## shortened so that failure is quick), and the pooled actions never
## overlapped. The second is what proves the DAEMON received capacity 1:
## with RunQuota active the engine does not gate a named pool itself (RA-13,
## Build-Engine-And-Scheduler.md "One executor, one resource authority"), so
## nothing else could have serialized them.
##
## The actions declare a recognized ``.d`` report rather than the automatic
## monitor, so this needs no monitor tools and runs on Windows as well.
##
## NO MOCKS.

import std/[algorithm, os, osproc, strutils, tempfiles, times, unittest]

import repro_build_engine
import repro_core
import repro_depfile
import repro_runquota

import repro_test_support

proc fixtureWrite(path, content: string) =
  createDir(path.splitPath.head)
  writeFile(path, content)

proc fixtureMain(args: seq[string]) =
  # "pool" <index> <log-prefix> <output> <depfile>
  if args.len != 6 or args[1] != "pool":
    quit 64
  fixtureWrite(args[3] & "." & args[2] & ".start", $epochTime())
  sleep(250)
  fixtureWrite(args[3] & "." & args[2] & ".end", $epochTime())
  fixtureWrite(args[4], "pool " & args[2] & "\n")
  # A relative target: a drive-letter colon would read as the rule separator.
  fixtureWrite(args[5], "out/" & args[2] & ".txt:\n")

when isMainModule:
  let params = commandLineParams()
  if params.len > 0 and params[0] == "fixture-action":
    fixtureMain(params)
    quit 0
  if params.len > 0 and params[0] == "__repro-runquota-helper":
    quit runRunQuotaHelperCli(params[1 .. ^1])

proc maxConcurrency(prefix: string; count: int): int =
  var events: seq[tuple[t: float, delta: int]] = @[]
  for i in 0 ..< count:
    let startPath = prefix & "." & $i & ".start"
    let endPath = prefix & "." & $i & ".end"
    if not fileExists(startPath) or not fileExists(endPath):
      checkpoint("missing pool log for index " & $i)
      return count + 1
    events.add((t: parseFloat(readFile(startPath)), delta: 1))
    events.add((t: parseFloat(readFile(endPath)), delta: -1))
  events.sort(proc(a, b: tuple[t: float, delta: int]): int =
    result = cmp(a.t, b.t)
    if result == 0: result = cmp(a.delta, b.delta))
  var current = 0
  for event in events:
    current += event.delta
    result = max(result, current)

proc startFlaglessDaemon(repoRoot, root: string): Process =
  ## No --cpu-milli, --memory-bytes or --pool: the budget is the (empty)
  ## host file's and the daemon's own defaults.
  let socket = runquotaSocketEndpoint("repro-pooldecl-" &
    $getCurrentProcessId() & "-" & root.extractFilename)
  if fileExists(socket):
    removeFile(socket)
  writeFile(root / "runquotad.toml", "schema = \"runquota.host-config.v1\"\n")
  putEnv("RUNQUOTA_SOCKET", socket)
  result = startProcess(requireRunQuotaDaemonBin(repoRoot), args = [
    "--socket", socket, "--host-config", root / "runquotad.toml",
    "--host-identity-file", root / "host-id", "--no-write-stats",
    "--ambient-sample-interval-millis", "0",
    "--memory-pressure-source", "unavailable"],
    options = {poUsePath, poParentStreams})
  for _ in 0 ..< 400:
    if isRunQuotaDaemonReachable():
      return
    sleep(25)
  raise newException(OSError, "runquotad did not become reachable")

proc pooledGraph(app, workRoot, logPrefix: string): BuildGraph =
  var actions: seq[BuildAction] = @[]
  for i in 0 ..< 3:
    let depfile = "deps/" & $i & ".d"
    actions.add action("serial-" & $i, [app, "fixture-action", "pool", $i,
      logPrefix, workRoot / "out" / ($i & ".txt"), workRoot / depfile],
      cwd = workRoot, outputs = ["out/" & $i & ".txt"],
      pool = "rq-test.serial", poolUnits = 1'u32,
      commandStatsId = "serial-" & $i,
      dependencyPolicy = DependencyGatheringPolicy(
        kind: dgRecognizedFormat,
        completeness: decComplete,
        recognizedReports: @[RecognizedDependencyReportSpec(
          formatName: DependencyFormatName(MakeDepfileFormatName),
          outputs: @[ExpectedDependencyFile(logicalName: "deps",
            path: depfile, required: true)],
          completeness: decComplete)]),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
  graph(actions, [pool("rq-test.serial", 1'u32)])

proc runPooledBuild(repoRoot, tag: string; inline: bool) =
  let root = createTempDir("repro-pooldecl-" & tag, "")
  defer: removeDir(root)
  let oldTimeout = getEnv("REPRO_RUNQUOTA_DENIAL_TIMEOUT", "")
  putEnv("REPRO_RUNQUOTA_DENIAL_TIMEOUT", "3000")
  defer:
    if oldTimeout.len > 0: putEnv("REPRO_RUNQUOTA_DENIAL_TIMEOUT", oldTimeout)
    else: delEnv("REPRO_RUNQUOTA_DENIAL_TIMEOUT")
  var daemon = startFlaglessDaemon(repoRoot, root)
  defer:
    daemon.terminate()
    discard daemon.waitForExit(5000)
    daemon.close()
    delEnv("RUNQUOTA_SOCKET")
  let app = getAppFilename()
  let workRoot = root / "work"
  createDir(workRoot)
  let logPrefix = root / "serial-log"
  var failure = ""
  try:
    discard runBuild(pooledGraph(app, workRoot, logPrefix),
      BuildEngineConfig(
        cacheRoot: root / ".repro-cache",
        runQuotaCliPath: app,
        maxParallelism: 4'u32,
        stdoutLimit: 256 * 1024,
        stderrLimit: 256 * 1024,
        inlineRunQuota: inline))
  except CatchableError as err:
    failure = err.msg
  checkpoint("build failure: " & failure)
  check failure.len == 0
  check "named-pool budget" notin failure
  for i in 0 ..< 3:
    check fileExists(workRoot / "out" / ($i & ".txt"))
  # Capacity 1 reached the daemon: the engine does not gate the pool itself.
  check maxConcurrency(logPrefix, 3) == 1

suite "a build declares its named pools to a runquotad started without them":
  let repoRoot = getCurrentDir()

  test "inline session":
    runPooledBuild(repoRoot, "inline", inline = true)

  test "out-of-process helper":
    runPooledBuild(repoRoot, "helper", inline = false)
