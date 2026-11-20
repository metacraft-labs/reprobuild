## A build tells RunQuota what sizing replay needs: the project and entry
## point of its session, and, with the `sizing-data` measurement on, which
## earlier actions each action waited for (its `after` list, from the action
## graph).
##
## WHY. RunQuota replays a project's recorded runs at N CPUs to say how much
## memory N CPUs need. Without `after` it can only replay each action
## at its recorded offset, which serialises nothing that the graph
## serialised: a chain recorded on a wide host replays as if its links could
## run together. Only the engine knows the graph, so the engine declares it.
##
## WHAT THIS RUNS. A real `runquotad` with capture on, on a private endpoint,
## and a real build through the inline RunQuota session of a four-action
## graph: `a`; `b` after `a`; `c` after `b`; `d` after `a` and `c`. The rows
## are read back with the daemon's own sizing export (`QuerySizing`), the
## path `runquota observations export --format sizing` takes. With
## `sizing-data` on, each action's `after` names exactly the executions of
## its dependencies (`a`'s is declared and empty); with it off (the default)
## no `after` is declared, and the project and entry point still are, since
## they are a declaration and not a measurement.
##
## FALSIFYING MUTATION: not calling `declareAfter` in the engine's inline
## finish leaves every `after` undeclared and the "on" case fails; declaring
## the dependency's own lease only, without the frontier walk, fails the
## unit case for a dependency that took no lease.
##
## NO MOCKS: the real daemon, engine and launcher. The unit case drives the
## engine's frontier function over a hand-built table, because making an
## action skip its lease (a cache hit) in a real build would test the cache,
## not the walk.

# The RunQuota helper role of the image this test stands in for: its
# command line read by repro's generated parser.
from repro_cli_support/runquota_helper_cli import runRunQuotaHelperArgs,
  selectsRunQuotaHelper
import std/[algorithm, json, os, osproc, sets, strutils, tables, tempfiles,
  unittest]

import repro_build_engine
import repro_core
import repro_depfile
import repro_runquota
import runquota_client
import runquota_protocol

import repro_test_support
import repro_test_support/process_fixtures

proc fixtureWrite(path, content: string) =
  createDir(path.splitPath.head)
  writeFile(path, content)

when isMainModule:
  let params = commandLineParams()
  if params.len == 4 and params[0] == "fixture-action":
    # fixture-action <name> <output> <depfile>
    sleep(100)
    fixtureWrite(params[2], params[1] & "\n")
    fixtureWrite(params[3], "out/" & params[1] & ".txt:\n")
    quit 0
  if selectsRunQuotaHelper(params):
    quit runRunQuotaHelperArgs(params)

proc startCapturingDaemon(repoRoot, root: string): Process =
  let socket = runquotaSocketEndpoint("repro-sizing-" &
    $getCurrentProcessId() & "-" & root.extractFilename)
  when defined(posix):
    releaseDirAtProcessExit(socket.parentDir)
  if fileExists(socket):
    removeFile(socket)
  writeFile(root / "runquotad.toml", "schema = \"runquota.host-config.v1\"\n")
  putEnv("RUNQUOTA_SOCKET", socket)
  result = startProcess(requireRunQuotaDaemonBin(repoRoot), args = [
    "--socket", socket, "--host-config", root / "runquotad.toml",
    "--host-identity-file", root / "host-id",
    "--observation-db", root / "observations.sqlite3",
    "--measurement", "capture=on",
    "--ambient-sample-interval-millis", "0",
    "--memory-pressure-source", "unavailable"],
    options = {poUsePath, poParentStreams})
  when defined(posix):
    terminateAtProcessExit(processID(result))
  for _ in 0 ..< 600:
    if isRunQuotaDaemonReachable():
      # Reachable is not recording: the store opens on a thread of its own
      # after the endpoint is bound, and a session opened before capture is
      # on records nothing.
      try:
        var client = connectDefault()
        defer: client.close()
        if "\"capture_enabled\":true" in client.inspectionJson("observations"):
          return
      except CatchableError:
        discard
    sleep(50)
  raise newException(OSError, "runquotad did not start capturing")

proc chainGraph(app, workRoot: string): BuildGraph =
  var actions: seq[BuildAction] = @[]
  for (name, deps) in [("a", newSeq[string]()), ("b", @["a"]), ("c", @["b"]),
                       ("d", @["a", "c"])]:
    let depfile = "deps/" & name & ".d"
    actions.add action(name, [app, "fixture-action", name,
      workRoot / "out" / (name & ".txt"), workRoot / depfile],
      cwd = workRoot, deps = deps, outputs = ["out/" & name & ".txt"],
      commandStatsId = "sizing-" & name,
      dependencyPolicy = DependencyGatheringPolicy(
        kind: dgRecognizedFormat,
        completeness: decComplete,
        recognizedReports: @[RecognizedDependencyReportSpec(
          formatName: DependencyFormatName(MakeDepfileFormatName),
          outputs: @[ExpectedDependencyFile(logicalName: "deps",
            path: depfile, required: true)],
          completeness: decComplete)]),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
  graph(actions)

type Recorded = object
  failure: string
  runs: seq[JsonNode]
  executions: Table[string, JsonNode]
    ## By command stats key.

proc buildAndExport(repoRoot, tag, measurement: string): Recorded =
  let saved = @["RUNQUOTA_SOCKET", "RUNQUOTA_ENDPOINT_SCOPE",
    "RUNQUOTA_MEASUREMENT", "RUNQUOTA_PROJECT", "RUNQUOTA_ENTRY_POINT"]
  var prior = initTable[string, string]()
  for name in saved:
    if existsEnv(name): prior[name] = getEnv(name)
  defer:
    for name in saved:
      if prior.hasKey(name): putEnv(name, prior[name])
      else: delEnv(name)
  when defined(posix):
    putEnv("RUNQUOTA_ENDPOINT_SCOPE", "private")
  putEnv("RUNQUOTA_MEASUREMENT", measurement)
  putEnv("RUNQUOTA_PROJECT", "sizing-" & tag)
  delEnv("RUNQUOTA_ENTRY_POINT")
  let root = createTempDir("repro-sizing-" & tag, "")
  releaseDirAtProcessExit(root)
  defer: removeDir(root)
  var daemon = startCapturingDaemon(repoRoot, root)
  defer:
    daemon.terminate()
    discard daemon.waitForExit(5000)
    daemon.close()
  let workRoot = root / "work"
  createDir(workRoot)
  try:
    discard runBuild(chainGraph(getAppFilename(), workRoot),
      BuildEngineConfig(
        cacheRoot: root / ".repro-cache",
        runQuotaCliPath: getAppFilename(),
        maxParallelism: 4'u32,
        stdoutLimit: 64 * 1024,
        stderrLimit: 64 * 1024,
        inlineRunQuota: true))
  except CatchableError as err:
    result.failure = err.msg
  var client = connectDefault()
  defer: client.close()
  let page = parseJson(client.querySizing(QuerySizingMessage(what: swExport,
    project: "sizing-" & tag, allUsers: true, redaction: srNone)))
  for line in page{"lines"}.getElems():
    let record = parseJson(line.getStr())
    case record{"type"}.getStr()
    of "run": result.runs.add(record)
    of "execution":
      result.executions[record{"command_stats_id"}.getStr()] = record
    else: discard

proc afterOf(r: Recorded; name: string): HashSet[string] =
  for id in r.executions["sizing-" & name]{"after"}.getElems():
    result.incl(id.getStr())

proc idOf(r: Recorded; name: string): string =
  r.executions["sizing-" & name]{"execution_id"}.getStr()

suite "a build declares sizing data to RunQuota":
  let repoRoot = getCurrentDir()

  test "with sizing-data on, each action's after names its dependencies":
    let r = buildAndExport(repoRoot, "on", "sizing-data=on")
    checkpoint "build failure: " & r.failure
    check r.failure.len == 0
    check r.executions.len == 4
    check r.runs.len == 1
    if r.runs.len == 1:
      check r.runs[0]{"entry_point"}.getStr() == "build"
    if r.executions.len == 4:
      check r.executions["sizing-a"]{"after"}.kind == JArray
      check r.afterOf("a").len == 0
      check r.afterOf("b") == [r.idOf("a")].toHashSet
      check r.afterOf("c") == [r.idOf("b")].toHashSet
      check r.afterOf("d") == [r.idOf("a"), r.idOf("c")].toHashSet

  test "with sizing-data off, no after is declared but the project is":
    let r = buildAndExport(repoRoot, "off", "")
    checkpoint "build failure: " & r.failure
    check r.failure.len == 0
    check r.executions.len == 4
    check r.runs.len == 1
    for name, record in r.executions:
      check record{"after"}.kind == JNull
      check record{"memory_profile"}.kind == JNull

  test "a dependency that took no lease stands for the leases behind it":
    # `x` ran under lease 5, `y` (a cache hit, say) under none and depends
    # on `x`; `z` depends on `y` and on `w` (lease 9). `z` waited for 5 and
    # 9.
    var actions = initTable[string, BuildAction]()
    actions["x"] = BuildAction(id: "x",
      governingLockIdentity: lockIdentityOutsideSolvedGraph())
    actions["w"] = BuildAction(id: "w",
      governingLockIdentity: lockIdentityOutsideSolvedGraph())
    actions["y"] = BuildAction(id: "y", deps: @["x"],
      governingLockIdentity: lockIdentityOutsideSolvedGraph())
    actions["z"] = BuildAction(id: "z", deps: @["y", "w"],
      governingLockIdentity: lockIdentityOutsideSolvedGraph())
    let leases = {"x": 5'u64, "w": 9'u64}.toTable
    var memo = initTable[string, seq[uint64]]()
    var got = afterLeases(actions["z"].deps, actions, leases, memo)
    got.sort()
    check got == @[5'u64, 9]
