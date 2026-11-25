## A grant that arrives in the same GrantNext batch as a denial is not dropped.
##
## WHY. The daemon answers a GrantNext with the denials a budget change
## decided for the session's queued leases FIRST, then at most one grant, and
## it marks that grant delivered: it is never sent again. The engine's grant
## loop returned at the first denial, so the grant behind it was dropped. Its
## action waited for a grant that had already been sent, and the lease stayed
## GRANTED with no child -- the shape of reprobuild-specs issue
## 2026-11-04-repro-build-fails-with-session-still-owns-leases-after-every-
## action-executed, observed again 2026-11-24 as
## `session still owns leases (unreleased: lease 626 "c-sudoku-object-tup"
## state=granted child=0)`.
##
## THE SET-UP. A real `runquotad` whose budget comes from its host-config file
## alone (no budget flags, so a reload can change it): 4000m CPU, 4 GiB.
## Three independent actions reach it in one batch:
##
## * `hold`  1000m, 3 GiB -- granted, runs for a while;
## * `big`   3000m, 3 GiB -- queued (memory);
## * `small` 1000m, 2 GiB -- queued (memory).
##
## While `hold` runs, the progress observer rewrites the file to 2000m CPU,
## 8 GiB and asks the daemon to reload. `big` can never fit 2000m, so it is
## denied; `small` now fits beside `hold`, so it is granted. Both decisions
## are made in that one reload, while the engine is inside the observer and
## not polling, so its next GrantNext carries [denial big, grant small].
##
## NO MOCKS: every decision is the daemon's, every child is a real process.

import std/[json, os, osproc, strutils, tables, tempfiles, times, unittest]

import runquota_client
import repro_build_engine
import repro_core
import repro_depfile
import repro_runquota

import repro_test_support

const GiB = 1024'u64 * 1024'u64 * 1024'u64

proc fixtureMain(args: seq[string]) =
  # <mode> <marker-dir> <tag> <output> <depfile>
  if args.len < 6:
    quit 64
  let dir = args[2]
  let tag = args[3]
  if args[1] == "linger":
    sleep(2000)
  createDir(dir)
  writeFile(dir / (tag & ".done"), $epochTime())
  createDir(args[4].splitPath.head)
  writeFile(args[4], tag & "\n")
  createDir(args[5].splitPath.head)
  writeFile(args[5], "out/" & tag & ".txt:\n")

when isMainModule:
  let params = commandLineParams()
  if params.len > 0 and params[0] == "fixture-action":
    fixtureMain(params)
    quit 0

proc writeBudget(path: string; cpuMilli: int; memoryGiB: uint64) =
  writeFile(path, "schema = \"runquota.host-config.v1\"\n[machine]\n" &
    "memory_bytes = " & $(memoryGiB * GiB) & "\ncpu_milli = " &
    $cpuMilli & "\n")

proc daemonLeases(): seq[JsonNode] =
  var client = runquota_client.connectDefault()
  try:
    for lease in parseJson(client.inspectionJson("leases"))["leases"]:
      result.add(lease)
  finally:
    client.close()

proc describe(leases: seq[JsonNode]): string =
  for lease in leases:
    result.add("\n  lease " & $lease{"id"}.getBiggestInt() & " " &
      lease{"label"}.getStr() & " state=" & lease{"state"}.getStr() &
      " child=" & $lease{"child_process_id"}.getBiggestInt())

proc depfilePolicy(depfile: string): DependencyGatheringPolicy =
  DependencyGatheringPolicy(
    kind: dgRecognizedFormat,
    completeness: decComplete,
    recognizedReports: @[RecognizedDependencyReportSpec(
      formatName: DependencyFormatName(MakeDepfileFormatName),
      outputs: @[ExpectedDependencyFile(logicalName: "deps",
        path: depfile, required: true)],
      completeness: decComplete)])

proc sizedAction(app, workRoot, markers, mode, tag: string; cpuMilli: uint32;
                 memoryGiB: uint64): BuildAction =
  let depfile = "deps/" & tag & ".d"
  action(tag, [app, "fixture-action", mode, markers, tag,
    workRoot / "out" / (tag & ".txt"), workRoot / depfile],
    cwd = workRoot, outputs = ["out/" & tag & ".txt"],
    commandStatsId = tag, cpuMilli = cpuMilli,
    memoryBytes = memoryGiB * GiB,
    dependencyPolicy = depfilePolicy(depfile),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

suite "a grant behind a denial in one GrantNext batch":
  test "the granted action runs and the session closes empty":
    let root = createTempDir("repro-denialgrant", "")
    defer: removeDir(root)
    let socket = runquotaSocketEndpoint("repro-denialgrant-" &
      $getCurrentProcessId() & "-" & root.extractFilename)
    let budget = root / "runquotad.toml"
    writeBudget(budget, 4000, 4)
    putEnv("RUNQUOTA_SOCKET", socket)
    var daemon = startProcess(requireRunQuotaDaemonBin(getCurrentDir()),
      args = ["--socket", socket, "--host-config", budget,
        "--host-identity-file", root / "host-id", "--no-write-stats",
        "--ambient-sample-interval-millis", "0",
        "--memory-pressure-source", "unavailable"],
      options = {poUsePath, poParentStreams})
    defer:
      if daemon.running:
        daemon.terminate()
        discard daemon.waitForExit(5000)
      daemon.close()
      delEnv("RUNQUOTA_SOCKET")
    for _ in 0 ..< 400:
      if isRunQuotaDaemonReachable(): break
      sleep(25)
    check isRunQuotaDaemonReachable()

    let app = getAppFilename()
    let workRoot = root / "work"
    let markers = root / "markers"
    createDir(workRoot)
    createDir(markers)
    var config = BuildEngineConfig(
      cacheRoot: root / ".repro-cache",
      runQuotaCliPath: app,
      maxParallelism: 4'u32,
      stdoutLimit: 256 * 1024,
      stderrLimit: 256 * 1024,
      inlineRunQuota: true,
      # Bounds the unfixed engine, which waits for the dropped grant until
      # this fails `small`; the fixed one never comes near it.
      runQuotaQueueTimeoutMs: 20_000)
    var reloaded = false
    var queuedBeforeReload: seq[JsonNode]
    var reloadAnswer = ""
    config.progressCallback = proc(event: BuildProgressEvent) =
      if event.kind == bpkActionStarted and event.actionId == "hold" and
          not reloaded:
        reloaded = true
        queuedBeforeReload = daemonLeases()
        writeBudget(budget, 2000, 8)
        var client = runquota_client.connectDefault()
        try:
          discard client.reloadHostConfig()
          reloadAnswer = "reloaded"
        except CatchableError as err:
          reloadAnswer = err.msg
        finally:
          client.close()
    let g = graph([
      sizedAction(app, workRoot, markers, "linger", "hold", 1000, 3),
      sizedAction(app, workRoot, markers, "quick", "big", 3000, 3),
      sizedAction(app, workRoot, markers, "quick", "small", 1000, 2)])
    var buildFailure = ""
    var run: BuildRunResult
    let started = epochTime()
    try:
      run = runBuild(g, config)
    except CatchableError as err:
      buildFailure = err.msg
    let elapsed = epochTime() - started

    # Positive controls: the batch really was {hold running, big and small
    # queued} when the budget changed, and the reload took.
    check reloaded
    check reloadAnswer == "reloaded"
    checkpoint("leases before the reload:" & describe(queuedBeforeReload))
    var queuedLabels: seq[string]
    for lease in queuedBeforeReload:
      if lease{"state"}.getStr() == "queued":
        queuedLabels.add(lease{"label"}.getStr())
    check "big" in queuedLabels
    check "small" in queuedLabels

    checkpoint("build failure: " & buildFailure)
    checkpoint("elapsed: " & $elapsed)
    check "session still owns leases" notin buildFailure
    check buildFailure.len == 0
    var status = initTable[string, ActionStatus]()
    for res in run.results:
      checkpoint(res.id & " " & $res.status & ": " & res.stderr)
      status[res.id] = res.status
    # `big` is denied (the engine still fails a late denial, a known gap);
    # `small` got the grant that came with that denial and ran.
    check status.getOrDefault("big", asSucceeded) == asFailed
    check status.getOrDefault("small", asFailed) == asSucceeded
    check fileExists(markers / "small.done")
    check status.getOrDefault("hold", asFailed) == asSucceeded
    let left = daemonLeases()
    checkpoint("leases after the build:" & describe(left))
    check left.len == 0
