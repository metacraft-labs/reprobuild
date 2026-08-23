## A monitored zero-output edge must re-run when anything it OBSERVED
## changes — including a file appearing in a directory it enumerated.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every assertion drives the real `runBuild` scheduler, the real per-edge
## `ActionCache` + CAS, the real graph-built io-monitor
## (`build/bin/repro internal io monitor` + the graph-built shim), and real
## subprocesses over real files. The defect class under test IS the monitor
## evidence path: a harness that supplied its own evidence would assert
## nothing about what production records or compares.
##
## WHY THIS FILE EXISTS SEPARATELY FROM
## `libs/repro_build_engine/tests/t_zero_output_edge_is_cacheable.nim`
## ---------------------------------------------------------------------
## That file's edges all carry a `depfile=`, which `action()` downgrades to
## `legacyDepfileGatheringPolicy` (`dgRecognizedFormat`). It therefore
## proves the cache-reuse gate on DECLARED inputs and needs no monitor,
## which is what lets it run everywhere in under a minute. But a real test
## execute edge — `ct_test_nim_unittest.run`, via `automaticMonitorPolicy()`
## — runs under `dgAutomaticMonitor`, and the mechanism that decides
## whether its recorded input set is COMPLETE is the monitor, not the
## declaration. Measured on one real edge
## (`reprobuild.test_execute.t_ti1_interface_artifact_edge`): 7,688 monitor
## reads and 18,497 probes, against 1 declared input. So the production
## question is entirely about discovered inputs, and it needs its own file
## because it needs the graph-built monitor binaries.
##
## Governing spec text:
##
## * Incremental-Invalidation.md §"Validation Criteria": "changing a read
##   input invalidates the action under timestamp, checksum, and hybrid
##   policies according to each policy's declared semantics".
## * Incremental-Invalidation.md §"Validation Criteria": "adding or
##   removing a file in an enumerated directory invalidates the action".
## * Test-Edges-And-Parallel-Runner.milestones.org §Introduction,
##   initiative goal (1).
##
## HISTORY. Before "Reuse a cached result for an edge that produces no
## output", a zero-output edge was an unconditional cache miss, so it was
## accidentally immune to every under-description below — it re-ran no
## matter what. Making such an edge cacheable moves it into the class where
## the recorded input set has to be complete on its own merits, and these
## are the cases that say whether it is.

import std/[options, os, osproc, sequtils, strutils, tempfiles, unittest]

import repro_build_engine
import repro_core
import repro_hash
import repro_local_store
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
      repoRoot / "build" / "test-monitor-zoe", "zoe-monitor")
    putEnv("REPRO_MONITOR_SHIM_LIB", cachedMonitorTools.shim)
    cachedMonitorToolsReady = true
  cachedMonitorTools

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("monitored-zero-output-edge." & name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

const ReuseDecisions = {cdHit, cdHybridCutoff}

## The edge under test. It is a shell script rather than a compiled binary
## because what matters here is what it OBSERVES, not what it is:
##
##   * `ls fixtures/` enumerates a directory — the mechanism in the
##     "adding or removing a file in an enumerated directory" criterion.
##   * `cat fixtures/greeting.txt` reads a file that is NEVER DECLARED as
##     an input. Only the monitor can know the edge depends on it.
##   * it appends one line to a run log so "did not re-run" is corroborated
##     out of band, not just by the engine agreeing with itself.
##   * it declares NO outputs. That is the shape under test.
const RunnerScript = """#!/bin/sh
set -e
# `tr` flattens the listing onto ONE line. Without it a directory with N
# entries writes N lines per run and `runCount` -- the out-of-band evidence
# that the edge did or did not execute -- silently counts entries instead of
# runs, which reads exactly like a spurious re-execution.
listing=$(ls "$1" | tr '\n' ',')
payload=$(cat "$1/greeting.txt" | tr '\n' ',')
printf 'ran listing=[%s] payload=[%s]\n' "$listing" "$payload" >> "$2"
"""

type Fixture = object
  root: string
  workRoot: string
  cacheRoot: string
  fixtureDir: string
  runLogPath: string

proc runCount(f: Fixture): int =
  if not fileExists(f.runLogPath):
    return 0
  f.runLogPath.readFile.splitLines.countIt(it.strip().len > 0)

proc makeFixture(): Fixture =
  let root = createTempDir("repro-monitored-zero-output-", "")
  let workRoot = root / "work"
  createDir(workRoot / "fixtures")
  createDir(workRoot / "out")
  writeFile(workRoot / "fixtures" / "greeting.txt", "hello-generation-1\n")
  let runner = workRoot / "run.sh"
  writeFile(runner, RunnerScript)
  setFilePermissions(runner, {fpUserRead, fpUserWrite, fpUserExec})
  Fixture(
    root: root,
    workRoot: workRoot,
    cacheRoot: root / "cache",
    fixtureDir: workRoot / "fixtures",
    runLogPath: workRoot / "out" / "runs.log")

proc monitoredRunEdge(f: Fixture): BuildAction =
  ## NOTE what is NOT here: `fixtures/greeting.txt` is not in `inputs`, and
  ## `fixtures` is not either. The only declared input is the script. Under
  ## `dgAutomaticMonitor` — the policy `ct_test_nim_unittest.run` uses —
  ## everything else has to come from the monitor.
  action("monitored/run",
    ["./run.sh", "fixtures", "out/runs.log"],
    cwd = f.workRoot,
    inputs = ["run.sh"],
    outputs = [],
    cacheable = true,
    weakFingerprint = weak("monitored/run"),
    actionCachePolicy = ffpHybrid,
    dependencyPolicy = automaticMonitorGatheringPolicy(),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc monitoredConfig(repoRoot, cacheRoot: string): BuildEngineConfig =
  ## `repro build`'s warm mode, plus the real monitor driver.
  let tools = monitorTools(repoRoot)
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.fallbackToRunQuotaBypass = true
  result.maxParallelism = 1'u32
  result.monitorCliPath = tools.monitorCliPath
  result.monitorCliArgs = tools.monitorCliArgs

proc recordedInputs(f: Fixture): seq[FileFingerprint] =
  ## The record the engine just wrote, read back through the public store
  ## API. NOTE the key: `action()` runs the supplied weak fingerprint
  ## through `keyedOnGoverningLock`, so the action's OWN `weakFingerprint`
  ## is what the cache is keyed on -- looking up the raw `weak(...)` value
  ## silently finds nothing and would make every denominator below read 0.
  var cache = openActionCache(f.cacheRoot / "action-cache")
  let hot = cache.readHotRecord(f.monitoredRunEdge().weakFingerprint)
  if not hot.found:
    return @[]
  hot.record.inputs

proc directoryInputCount(f: Fixture): tuple[dirs, tracked, total: int] =
  ## Cost denominator for the membership fingerprint: how many recorded
  ## inputs are directories at all, and how many of those carry a membership
  ## digest (i.e. how many extra `readdir` sweeps a warm consultation pays).
  for input in f.recordedInputs():
    inc result.total
    if input.metadata.kind == ffkDirectory:
      inc result.dirs
      if input.metadata.membershipTrackedDirectory():
        inc result.tracked

suite "monitored zero-output edge: recorded inputs must be complete":

  test "a file added to an enumerated directory re-runs the edge":
    # Incremental-Invalidation.md §"Validation Criteria": "adding or
    # removing a file in an enumerated directory invalidates the action".
    #
    # The edge runs `ls fixtures/`. Its behaviour therefore depends on the
    # MEMBERSHIP of that directory, and nothing else about it. Add a file;
    # the listing the edge would produce changes; the edge must re-run.
    let repoRoot = findRepoRoot()
    let f = makeFixture()
    defer: removeDir(f.root)
    let g = graph([f.monitoredRunEdge()])
    let config = monitoredConfig(repoRoot, f.cacheRoot)

    let first = runBuild(g, config)
    checkpoint("first: status=" & $first.byId("monitored/run").status &
      " reason=" & first.byId("monitored/run").reason)
    check first.byId("monitored/run").status == asSucceeded
    check first.byId("monitored/run").launched
    check f.runCount() == 1
    check f.runLogPath.readFile.contains("listing=[greeting.txt,]")

    # Denominators: the monitor must actually have observed the directory,
    # otherwise this test is asserting nothing about directory handling.
    let counts = directoryInputCount(f)
    checkpoint("recorded inputs: " & $counts.total &
      " directories: " & $counts.dirs &
      " membership-tracked: " & $counts.tracked)
    check counts.total > 0
    check counts.dirs > 0
    # The cost statement, asserted rather than assumed: only the directory
    # the edge actually ENUMERATED is re-listed on a warm consultation. The
    # rest are existence probes and stay one `lstat` each.
    check counts.tracked > 0
    check counts.tracked < counts.dirs

    # Warm, nothing touched: the edge is reusable.
    let warm = runBuild(g, config)
    check warm.byId("monitored/run").cacheDecision in ReuseDecisions
    check not warm.byId("monitored/run").launched
    check f.runCount() == 1

    # Add a file to the enumerated directory. Nothing the edge previously
    # READ has changed; what changed is what the directory CONTAINS.
    writeFile(f.fixtureDir / "newcomer.txt", "appeared\n")

    let after = runBuild(g, config)
    let r = after.byId("monitored/run")
    checkpoint("after adding a file to the enumerated directory: status=" &
      $r.status & " cacheDecision=" & $r.cacheDecision &
      " launched=" & $r.launched & " reason=" & r.reason)
    check r.cacheDecision notin ReuseDecisions
    check r.launched
    check f.runCount() == 2
    check f.runLogPath.readFile.contains("newcomer.txt")

    # ... and the new state is itself reusable.
    check not runBuild(g, config).byId("monitored/run").launched
    check f.runCount() == 2

  test "a file removed from an enumerated directory re-runs the edge":
    # The other half of the same criterion. Removal is not symmetric with
    # addition for a membership digest that only sums entries in, so it is
    # asserted separately rather than assumed.
    let repoRoot = findRepoRoot()
    let f = makeFixture()
    defer: removeDir(f.root)
    writeFile(f.fixtureDir / "doomed.txt", "here for now\n")
    let g = graph([f.monitoredRunEdge()])
    let config = monitoredConfig(repoRoot, f.cacheRoot)

    check runBuild(g, config).byId("monitored/run").launched
    check f.runCount() == 1
    check f.runLogPath.readFile.contains("doomed.txt")
    check not runBuild(g, config).byId("monitored/run").launched
    check f.runCount() == 1

    removeFile(f.fixtureDir / "doomed.txt")

    let after = runBuild(g, config)
    let r = after.byId("monitored/run")
    checkpoint("after removing a file: status=" & $r.status &
      " cacheDecision=" & $r.cacheDecision & " launched=" & $r.launched &
      " reason=" & r.reason)
    check r.cacheDecision notin ReuseDecisions
    check r.launched
    check f.runCount() == 2

  test "NIX_STORE_DIR cannot exempt a directory from membership tracking":
    # The store-root exemption is read in the ENGINE process at fingerprint
    # time. Honouring `NIX_STORE_DIR` there let any ambient value nominate a
    # directory as exempt, and the damage outlived the variable: the record
    # was written with `mtimeNs = 0`, and a recorded 0 is never re-listed, so
    # clearing the variable did not recover. Measured before the fix; this
    # pins that the environment has no say.
    let repoRoot = findRepoRoot()
    let f = makeFixture()
    defer: removeDir(f.root)
    let g = graph([f.monitoredRunEdge()])
    let config = monitoredConfig(repoRoot, f.cacheRoot)

    let priorStoreDir = getEnv("NIX_STORE_DIR")
    putEnv("NIX_STORE_DIR", f.fixtureDir)
    defer:
      if priorStoreDir.len > 0: putEnv("NIX_STORE_DIR", priorStoreDir)
      else: delEnv("NIX_STORE_DIR")

    check runBuild(g, config).byId("monitored/run").launched
    check f.runCount() == 1
    # The directory the env var nominated is still tracked.
    let counts = directoryInputCount(f)
    checkpoint("with NIX_STORE_DIR=" & f.fixtureDir &
      " membership-tracked: " & $counts.tracked)
    check counts.tracked > 0
    check not runBuild(g, config).byId("monitored/run").launched
    check f.runCount() == 1

    writeFile(f.fixtureDir / "newcomer.txt", "appeared\n")

    let after = runBuild(g, config)
    checkpoint("after adding a file while NIX_STORE_DIR names it: launched=" &
      $after.byId("monitored/run").launched &
      " decision=" & $after.byId("monitored/run").cacheDecision)
    check after.byId("monitored/run").cacheDecision notin ReuseDecisions
    check after.byId("monitored/run").launched
    check f.runCount() == 2

  test "an unlistable directory does not read as an empty one":
    # `walkDir` at Nim's default `checkDir = false` turns an `opendir`
    # failure into zero entries and no exception, so an unreadable directory
    # produced a digest bit-identical to an empty one. Two false hits follow:
    # recorded-empty then unlistable-and-non-empty, and a record written
    # under a transient EMFILE that claims the directory is empty forever.
    # This is the unit-level pin; it needs no monitor.
    let root = createTempDir("repro-unlistable-", "")
    defer:
      # Restore permissions or `removeDir` cannot clean up.
      try: setFilePermissions(root / "locked", {fpUserRead, fpUserWrite, fpUserExec})
      except CatchableError: discard
      removeDir(root)
    createDir(root / "empty")
    createDir(root / "locked")
    writeFile(root / "locked" / "secret.txt", "content\n")

    var walked = 0'i64
    let emptyDigest = directoryMembershipDigest(root / "empty", walked)
    checkpoint("empty digest=" & $emptyDigest & " entries=" & $walked)

    setFilePermissions(root / "locked", {})
    let lockedMeta = fingerprintDirectoryMembership(root / "locked")
    checkpoint("locked mtimeNs=" & $lockedMeta.mtimeNs)
    # Fail closed, and distinguishably so.
    check lockedMeta.kind == ffkDirectory
    check lockedMeta.mtimeNs == DirectoryMembershipUnlistable
    check lockedMeta.mtimeNs != emptyDigest
    check lockedMeta.membershipTrackedDirectory()

    # Becoming listable again must compare unequal to "was unlistable".
    setFilePermissions(root / "locked", {fpUserRead, fpUserWrite, fpUserExec})
    let relisted = fingerprintDirectoryMembership(root / "locked")
    checkpoint("relisted mtimeNs=" & $relisted.mtimeNs)
    check relisted.mtimeNs != DirectoryMembershipUnlistable
    check relisted.mtimeNs != emptyDigest
    check relisted.mtimeNs != 0'u64

  test "a changed monitor-discovered undeclared input re-runs the edge":
    # `fixtures/greeting.txt` is read by the edge and declared nowhere. The
    # sibling engine test proves invalidation on a DECLARED input; this is
    # the production mechanism, where the recorded input set comes entirely
    # from the monitor.
    let repoRoot = findRepoRoot()
    let f = makeFixture()
    defer: removeDir(f.root)
    let g = graph([f.monitoredRunEdge()])
    let config = monitoredConfig(repoRoot, f.cacheRoot)

    check runBuild(g, config).byId("monitored/run").launched
    check f.runCount() == 1
    check not runBuild(g, config).byId("monitored/run").launched
    check f.runCount() == 1

    # Denominator: the undeclared file must actually be in the record, or
    # the assertion below could pass for an unrelated reason.
    let inputs = f.recordedInputs()
    check inputs.len > 0
    let recorded = inputs.anyIt(it.path.endsWith("greeting.txt"))
    checkpoint("recorded inputs: " & $inputs.len &
      "; undeclared 'greeting.txt' among them: " & $recorded)
    check recorded

    writeFile(f.fixtureDir / "greeting.txt", "hello-generation-2-longer\n")

    let after = runBuild(g, config)
    let r = after.byId("monitored/run")
    checkpoint("after changing the undeclared input: status=" & $r.status &
      " cacheDecision=" & $r.cacheDecision & " launched=" & $r.launched &
      " reason=" & r.reason)
    check r.cacheDecision notin ReuseDecisions
    check r.launched
    check f.runCount() == 2
    check f.runLogPath.readFile.contains("hello-generation-2-longer")
