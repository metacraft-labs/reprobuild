## A cacheable action created by a dynamic graph fragment is monitored,
## replayed from the action cache, and rekeyed by what it read, exactly as a
## declared edge is.
##
## A `create-action` record that is `cacheable` names its dependency policy
## (`t_create_action_record_carries_dependency_policy` covers the parsing).
## With the monitor as its policy, the created action's key must cover:
##   * its argv;
##   * the content of its declared inputs;
##   * what the monitor saw it read, declared or not.
## A per-test run created from a test binary's listing is the shape this
## serves: its argv names the test, its declared input is the binary, and
## everything else it reads is found by the monitor.
##
## MOCK POLICY: NO MOCKS. Every case drives the real `runBuild` scheduler,
## the real dynamic-fragment ingest, the real per-edge action cache and CAS,
## the real graph-built io-monitor (`build/bin/repro internal io monitor`
## plus the graph-built shim), and a real `/bin/sh` script over real files
## in a temporary directory. What is under test is the monitor evidence of
## a created action; a harness that supplied its own evidence would assert
## nothing about it.
##
## Out-of-band corroboration: the created action appends one line to a run
## log per execution, so "replayed, not rerun" is checked against the log as
## well as against the engine's own decision.
##
## Negative control: the same fragment with the record's policy removed is
## refused before anything runs.

import std/[os, sequtils, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_test_support

const RepoRootMarker = "repro.nim"

proc findRepoRoot(): string =
  var dir = currentSourcePath().parentDir
  while dir.len > 0:
    if fileExists(dir / RepoRootMarker) and fileExists(dir / "repro_tests.nim"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raise newException(IOError,
    "cannot locate reprobuild repo root from " & currentSourcePath())

var cachedMonitorTools: MonitorTools
var cachedMonitorToolsReady = false

proc monitorTools(repoRoot: string): MonitorTools =
  if not cachedMonitorToolsReady:
    cachedMonitorTools = prepareMonitorTools(repoRoot,
      repoRoot / "build" / "test-monitor-created-action", "created-action")
    putEnv("REPRO_MONITOR_SHIM_LIB", cachedMonitorTools.shim)
    cachedMonitorToolsReady = true
  cachedMonitorTools

const ReuseDecisions = {cdHit, cdHybridCutoff}
const CreatedId = "consumer.created.alpha"

## The created action. It reads `input.txt`, which its record declares, and
## `undeclared.txt`, which it does not: only the monitor can know about the
## second. It writes its declared output and a depfile naming only the
## declared input (read under the `makeDepfile` policy), and appends to the
## run log.
const RunnerScript = """#!/bin/sh
set -e
cat input.txt undeclared.txt > out/created.txt
printf 'out/created.txt: input.txt\n' > out/created.d
echo ran >> runs.log
"""

type Fixture = object
  root: string
  workRoot: string
  cacheRoot: string

proc runCount(f: Fixture): int =
  let log = f.workRoot / "runs.log"
  if not fileExists(log):
    return 0
  log.readFile.splitLines.countIt(it.strip().len > 0)

proc makeFixture(): Fixture =
  let root = createTempDir("repro-created-action-", "")
  let workRoot = root / "work"
  createDir(workRoot / "out")
  writeFile(workRoot / "input.txt", "declared-generation-1\n")
  writeFile(workRoot / "undeclared.txt", "undeclared-generation-1\n")
  let runner = workRoot / "run.sh"
  writeFile(runner, RunnerScript)
  setFilePermissions(runner, {fpUserRead, fpUserWrite, fpUserExec})
  Fixture(root: root, workRoot: workRoot, cacheRoot: root / "cache")

proc writeFragment(f: Fixture; policy: string; cacheable = true) =
  ## The fragment a listing edge would write: one `create-action` record,
  ## and the consumer's dependency on it. `policy` is the record's
  ## `dependencyPolicy` JSON, or "" for none.
  var record = "{\"id\":\"" & CreatedId & "\"," &
    "\"argv\":[\"./run.sh\"]," &
    "\"cwd\":\"" & f.workRoot & "\"," &
    "\"inputs\":[\"run.sh\",\"input.txt\"]," &
    "\"outputs\":[\"out/created.txt\"]," &
    "\"optionalOutputs\":[\"out/created.d\"]," &
    "\"commandStatsId\":\"created-action-fixture::alpha\"," &
    "\"cacheable\":" & $cacheable
  if policy.len > 0:
    record.add(",\"dependencyPolicy\":" & policy)
  record.add("}")
  writeFile(f.workRoot / "consumer.rbdyn",
    "repro-dynamic-graph-v1\n" &
    "create-action\t" & record & "\n" &
    "dep\tconsumer\t" & CreatedId & "\n")

proc consumer(f: Fixture): BuildAction =
  ## The static edge whose fragment creates the action. It is not cacheable
  ## and reads nothing of interest; it exists to carry the fragment.
  action("consumer", ["/bin/sh", "-c", "true"],
    cwd = f.workRoot,
    dynamicDepsFile = "consumer.rbdyn",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc monitoredConfig(repoRoot, cacheRoot: string): BuildEngineConfig =
  ## `repro build`'s warm mode, plus the real monitor driver.
  ##
  ## Not the restore configuration (`enableCachedOutputRestore`): restoring
  ## a deleted output needs complete output evidence, and the run log the
  ## action appends to, which is how this test sees a rerun, is a write it
  ## does not declare. The replay asserted here is the cache hit.
  let tools = monitorTools(repoRoot)
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.fallbackToRunQuotaBypass = true
  result.maxParallelism = 1'u32
  result.monitorCliPath = tools.monitorCliPath
  result.monitorCliArgs = tools.monitorCliArgs

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

proc describe(r: ActionResult): string =
  "status=" & $r.status & " decision=" & $r.cacheDecision &
    " launched=" & $r.launched & " policy=" & $r.dependencyPolicyKind &
    " reads=" & $r.monitorReadCount & " reason=" & r.reason

const MonitorPolicy = "{\"kind\":\"automaticMonitor\"}"

suite "a created cacheable action is monitored, replayed and rekeyed":

  test "it replays on the second build and reports its monitored reads":
    let repoRoot = findRepoRoot()
    let f = makeFixture()
    defer: removeDir(f.root)
    f.writeFragment(MonitorPolicy)
    let g = graph([f.consumer()])
    let config = monitoredConfig(repoRoot, f.cacheRoot)

    let first = runBuild(g, config)
    let r1 = first.byId(CreatedId)
    checkpoint("first: " & r1.describe)
    check r1.status == asSucceeded
    check r1.launched
    check r1.dependencyPolicyKind == dgAutomaticMonitor
    check first.byId("consumer").status == asSucceeded
    check f.runCount() == 1
    check readFile(f.workRoot / "out" / "created.txt") ==
      "declared-generation-1\nundeclared-generation-1\n"

    # The monitor saw the created action read the file its record does not
    # declare. This is the evidence its key is made of.
    check r1.monitorReadCount > 0
    require not r1.evidencePathsElided
    let sawUndeclared = r1.evidence.monitorReads.paths.anyIt(
      it.endsWith("undeclared.txt"))
    checkpoint("monitor reads: " & $r1.monitorReadCount &
      "; undeclared.txt among them: " & $sawUndeclared)
    check sawUndeclared

    # Second build, nothing changed: served from the cache, not rerun.
    let second = runBuild(g, config)
    let r2 = second.byId(CreatedId)
    checkpoint("second: " & r2.describe)
    # Outputs present and the record matches: the warm-mode hit.
    check r2.status == asUpToDate
    check r2.cacheDecision in ReuseDecisions
    check not r2.launched
    check f.runCount() == 1
    # The replay reports the reads its record carries.
    check r2.monitorReadCount > 0
    check readFile(f.workRoot / "out" / "created.txt") ==
      "declared-generation-1\nundeclared-generation-1\n"

  test "it reruns when its declared input changes":
    let repoRoot = findRepoRoot()
    let f = makeFixture()
    defer: removeDir(f.root)
    f.writeFragment(MonitorPolicy)
    let g = graph([f.consumer()])
    let config = monitoredConfig(repoRoot, f.cacheRoot)

    check runBuild(g, config).byId(CreatedId).launched
    check not runBuild(g, config).byId(CreatedId).launched
    check f.runCount() == 1

    writeFile(f.workRoot / "input.txt", "declared-generation-2-longer\n")
    let after = runBuild(g, config).byId(CreatedId)
    checkpoint("after changing the declared input: " & after.describe)
    check after.status == asSucceeded
    check after.cacheDecision notin ReuseDecisions
    check after.launched
    check f.runCount() == 2
    check readFile(f.workRoot / "out" / "created.txt").startsWith(
      "declared-generation-2-longer\n")

    # The new state is itself reusable.
    check not runBuild(g, config).byId(CreatedId).launched
    check f.runCount() == 2

  test "it reruns when a file only the monitor saw changes":
    let repoRoot = findRepoRoot()
    let f = makeFixture()
    defer: removeDir(f.root)
    f.writeFragment(MonitorPolicy)
    let g = graph([f.consumer()])
    let config = monitoredConfig(repoRoot, f.cacheRoot)

    check runBuild(g, config).byId(CreatedId).launched
    check not runBuild(g, config).byId(CreatedId).launched
    check f.runCount() == 1

    writeFile(f.workRoot / "undeclared.txt", "undeclared-generation-2-longer\n")
    let after = runBuild(g, config).byId(CreatedId)
    checkpoint("after changing the undeclared input: " & after.describe)
    check after.cacheDecision notin ReuseDecisions
    check after.launched
    check f.runCount() == 2
    check readFile(f.workRoot / "out" / "created.txt").endsWith(
      "undeclared-generation-2-longer\n")

  test "a changed policy is a different key: the monitored record is not served":
    let repoRoot = findRepoRoot()
    let f = makeFixture()
    defer: removeDir(f.root)
    f.writeFragment(MonitorPolicy)
    let g = graph([f.consumer()])
    let config = monitoredConfig(repoRoot, f.cacheRoot)

    check runBuild(g, config).byId(CreatedId).launched
    check not runBuild(g, config).byId(CreatedId).launched
    check f.runCount() == 1

    # Same command, same inputs; only the policy differs.
    f.writeFragment(
      "{\"kind\":\"makeDepfile\",\"depfiles\":[\"out/created.d\"]}")
    let after = runBuild(g, config).byId(CreatedId)
    checkpoint("after switching to the depfile policy: " & after.describe)
    check after.dependencyPolicyKind == dgRecognizedFormat
    check after.cacheDecision notin ReuseDecisions
    check after.launched
    check f.runCount() == 2

suite "negative control: the same record without a policy":

  test "is accepted when it is not cacheable, and still monitored":
    # A record that is not cacheable keeps the engine's default policy, the
    # monitor; only the cacheable record has to say how it is keyed.
    let repoRoot = findRepoRoot()
    let f = makeFixture()
    defer: removeDir(f.root)
    f.writeFragment("", cacheable = false)
    let g = graph([f.consumer()])
    let config = monitoredConfig(repoRoot, f.cacheRoot)

    let first = runBuild(g, config).byId(CreatedId)
    checkpoint("not cacheable: " & first.describe)
    check first.status == asSucceeded
    check first.cacheDecision == cdNotCacheable
    check first.dependencyPolicyKind == dgAutomaticMonitor
    check first.monitorReadCount > 0
    check runBuild(g, config).byId(CreatedId).launched
    check f.runCount() == 2

  test "is refused before anything runs":
    let repoRoot = findRepoRoot()
    let f = makeFixture()
    defer: removeDir(f.root)
    f.writeFragment("")
    let g = graph([f.consumer()])
    let config = monitoredConfig(repoRoot, f.cacheRoot)

    var message = ""
    try:
      discard runBuild(g, config)
    except BuildEngineError as err:
      message = err.msg
    checkpoint("refusal: " & message)
    check "consumer.rbdyn:2" in message
    check "'" & CreatedId & "' is cacheable but declares no " &
      "'dependencyPolicy'" in message
    check f.runCount() == 0
    check not fileExists(f.workRoot / "out" / "created.txt")
