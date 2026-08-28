## Every producer of an action-cache record must carry the enumerated
## directories the evidence collector found. A producer that drops them
## writes a record whose directories are all `mtimeNs = 0`, and a recorded
## 0 is never re-listed — so the record is PERMANENTLY membership-blind
## and never upgrades, because the hit path does not re-record.
##
## MOCK POLICY — ONE justified stand-in, named below; nothing else is
## mocked. Every assertion drives the real `runBuild` scheduler, the real
## per-edge `ActionCache` + CAS in `repro_local_store`, the real
## `collectEvidence` / `runConverters` / `readReproPathSet` /
## `foldMonitorDepFileEvidence` evidence path, the real graph-built
## io-monitor (`build/bin/repro internal io monitor` + the graph-built
## shim), real subprocesses and real directories on a real filesystem.
## Every iomon consumed here was written by the production monitor
## observing a production process that really listed a real directory —
## none is synthesized.
##
## The one stand-in is `BuildEngineConfig.brokerSpawn` in the elevated
## suite. It is the SAME hook `repro infra apply` installs — the engine
## has no other way to reach an elevated edge — and the closure here
## really forks the action's argv under the real io-monitor, so the
## process, its observations and its exit code are genuine. What it does
## not do is elevate; a test that required real privilege escalation
## could not run unattended. The code under test is the RECORD site
## downstream of the broker dispatch, reached identically whether the
## fork was privileged or not.
## `libs/repro_build_engine/tests/test_elevated_inline_exec_hook.nim`
## established this shape.
##
## Governing spec text:
##
## * Incremental-Invalidation.md §"Validation Criteria" (:759-763):
##   "adding or removing a file in an enumerated directory invalidates
##   the action. This is a statement about ENUMERATED directories
##   specifically, and the distinction is load-bearing on the input
##   side".
## * Incremental-Invalidation.md (:814-821): "a reader that finds NO
##   membership evidence on a recorded directory cannot tell a
##   pre-upgrade record from a directory that was correctly only probed
##   ... those keep comparing existence-only, permanently, because the
##   hit path does not re-record."
## * Caching-Architecture.md:252-256 — strong fingerprint computation
##   "should distinguish at least ... membership fingerprints for
##   enumerations".
## * Reprobuild-Repository-Layout.md:278 — `repro_pathset` records
##   "file reads, absent probes, existing probes, DIRECTORY ENUMERATIONS,
##   writes, creates, deletes, renames, executes, and load-library
##   observations".
##
## THE THREE PRODUCERS UNDER TEST:
##
##   1. `repro-pathset-v1` (`libs/repro_depfile`) had kinds
##      input/output/probe/diagnostic and no `enumerate`, so a converter
##      that observed an enumeration could only FAIL the edge on the
##      parser's unknown-kind arm. Covered by the parser suite plus the
##      converter suite, which drives it end-to-end through the process
##      record site.
##   2. The plan/builtin record site called `recordActionResult` without
##      `enumeratedDirectories`. Reached here through the seam
##      `monitoredAction` documents — "direct engine callers may provide
##      a monitor depfile path for actions that produce iomon evidence
##      themselves" — because a builtin runs in-process and can never
##      have an io-monitor wrapped around it.
##   3. The elevated-broker record site did the same. Reached with a
##      broker closure that runs the real monitor.

import std/[algorithm, os, osproc, strutils, unittest]

import repro_build_engine
import repro_core
import repro_core/paths as corepaths
import repro_depfile
import repro_hash
import repro_local_store
import repro_test_support

const ReuseDecisions = {cdHit, cdHybridCutoff}

const TmpDir = "build/test-tmp/t_enumerated_directory_evidence_producers"
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
      repoRoot / "build" / "test-monitor-enum", "enum-monitor")
    putEnv("REPRO_MONITOR_SHIM_LIB", cachedMonitorTools.shim)
    cachedMonitorToolsReady = true
  cachedMonitorTools

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("enumerated-directory-producers." & name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

# ---------------------------------------------------------------------------
# This binary doubles as the fixture: `--fixture-list` is the edge payload
# (it really enumerates a directory) and `--fixture-converter` is the
# post-build dependency converter that reports that enumeration. Reusing
# the test binary is the pattern
# `tests/integration/t_dependency_report_and_converter_paths.nim` uses; it
# keeps the suite from shelling out to a compiler at test time.
# ---------------------------------------------------------------------------

proc fixtureListMain(args: seq[string]) =
  ## Enumerate `args[1]` and append one line to `args[2]`, so "did not
  ## re-run" is corroborated out of band rather than by the engine
  ## agreeing with itself. The `walkDir` here is a real `readdir`, which
  ## is what the io-monitor records as `mrDirectoryEnumerate`.
  if args.len != 3:
    quit 64
  let listDir = args[1]
  let logPath = args[2]
  var names: seq[string] = @[]
  for _, path in walkDir(listDir, relative = true):
    names.add(path)
  names.sort()
  createDir(logPath.splitPath.head)
  let existing = if fileExists(logPath): readFile(logPath) else: ""
  writeFile(logPath, existing & "ran listing=[" & names.join(",") & "]\n")

proc fixtureConverterMain(args: seq[string]) =
  ## Emit a `repro-pathset-v1` report saying the edge ENUMERATED
  ## `args[1]`. This is what a converter for a globbing tool would emit;
  ## before the fix the format had no way to express it.
  if args.len != 3:
    quit 64
  let listDir = args[1]
  let outPath = args[2]
  createDir(outPath.splitPath.head)
  writeFile(outPath, "repro-pathset-v1\nenumerate\t" & listDir & "\n")

proc selfPath(): string =
  getAppFilename()

proc selfNormalized(): corepaths.NormalizedPath =
  corepaths.normalizedPath(getAppFilename())

when isMainModule:
  # The fixture dispatch MUST precede the suites: `unittest` runs a suite
  # body at module scope, so a dispatch placed after them would let the
  # whole suite re-run inside every fixture subprocess.
  let fixtureParams = commandLineParams()
  if fixtureParams.len > 0 and fixtureParams[0] == "--fixture-list":
    fixtureListMain(fixtureParams)
    quit 0
  if fixtureParams.len > 0 and fixtureParams[0] == "--fixture-converter":
    fixtureConverterMain(fixtureParams)
    quit 0

type Fixture = object
  root: string
  workRoot: string
  cacheRoot: string
  listDir: string
  runLogPath: string
  pathSetPath: string
  rmdfPath: string

proc runCount(f: Fixture): int =
  if not fileExists(f.runLogPath):
    return 0
  var n = 0
  for line in f.runLogPath.readFile.splitLines:
    if line.strip().len > 0:
      inc n
  n

proc makeFixture(name: string): Fixture =
  let root = absolutePath(TmpDir / name)
  if dirExists(root):
    removeDir(root)
  let workRoot = root / "work"
  createDir(workRoot / "listed")
  createDir(workRoot / "out")
  writeFile(workRoot / "listed" / "first.txt", "one\n")
  Fixture(
    root: root,
    workRoot: workRoot,
    cacheRoot: root / "cache",
    listDir: workRoot / "listed",
    runLogPath: workRoot / "out" / "runs.log",
    pathSetPath: workRoot / "out" / "paths.rps",
    rmdfPath: workRoot / "out" / "observed.iomon")

proc converterPolicy(f: Fixture): DependencyGatheringPolicy =
  DependencyGatheringPolicy(
    kind: dgPostBuildConverter,
    completeness: decComplete,
    postBuildConverters: @[
      PostBuildDependencyConverterSpec(
        converterProcess: directProcess(
          selfNormalized(),
          ["--fixture-converter", f.listDir, f.pathSetPath],
          corepaths.normalizedPath(f.workRoot)),
        inputs: @[],
        outputs: @[ExpectedDependencyFile(
          logicalName: "path-set",
          path: f.pathSetPath,
          required: true)],
        outputKind: dcoReproPathSet,
        outputFormatName: DependencyFormatName(ReproPathSetFormatName),
        completeness: decComplete)
    ])

proc testConfig(cacheRoot: string): BuildEngineConfig =
  ## `repro build`'s warm mode.
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.fallbackToRunQuotaBypass = true
  result.maxParallelism = 1'u32

proc recordedInputsFor(f: Fixture; action: BuildAction): seq[FileFingerprint] =
  ## NOTE the key: `action()` / `builtinAction()` run the supplied weak
  ## fingerprint through `keyedOnGoverningLock`, so the action's OWN
  ## `weakFingerprint` is what the cache is keyed on.
  var cache = openActionCache(f.cacheRoot / "action-cache")
  let hot = cache.readHotRecord(action.weakFingerprint)
  if not hot.found:
    return @[]
  hot.record.inputs

proc directoryCounts(inputs: seq[FileFingerprint]):
    tuple[dirs, tracked: int] =
  for input in inputs:
    if input.metadata.kind == ffkDirectory:
      inc result.dirs
      if input.metadata.membershipTrackedDirectory():
        inc result.tracked

proc runUnderMonitor(repoRoot, depfile: string; argv: seq[string]) =
  ## Drive the real io-monitor over a real process, writing a real iomon.
  let tools = monitorTools(repoRoot)
  createDir(depfile.splitPath.head)
  let child = startProcess(tools.monitorCliPath,
    args = tools.monitorCliArgs & @["--depfile", depfile, "--"] & argv,
    options = {})
  let code = child.waitForExit()
  child.close()
  if code != 0:
    raise newException(OSError, "monitored fixture exited " & $code)

# ---------------------------------------------------------------------------
# Producer 1 — the `repro-pathset-v1` reader.
# ---------------------------------------------------------------------------

suite "repro-pathset-v1 can report a directory enumeration":

  test "an `enumerate` record parses into the path set's enumerations":
    # Before the fix the reader's `case kind` had no `enumerate` arm and
    # fell through to `raiseReport(dreMalformed, ...)`.
    let root = absolutePath(TmpDir / "pathset-unit")
    if dirExists(root): removeDir(root)
    createDir(root)
    defer: removeDir(root)
    let reportPath = root / "paths.rps"
    writeFile(reportPath,
      "repro-pathset-v1\n" &
      "input\t/tmp/a.txt\n" &
      "probe\t/tmp/absent\n" &
      "enumerate\t/tmp/somedir\n")

    let parsed = readReproPathSet(reportPath)
    checkpoint("inputs=" & $parsed.inputs.len &
      " probes=" & $parsed.probes.len &
      " enumerations=" & $parsed.enumerations.len)
    check parsed.inputs == @["/tmp/a.txt"]
    check parsed.enumerations == @["/tmp/somedir"]
    # An enumeration is also an existence dependency, but the two sets
    # stay distinct: `probe` must NOT silently absorb it, or the engine
    # cannot tell membership evidence from existence evidence.
    check parsed.probes == @["/tmp/absent"]

  test "an unknown record kind is still rejected":
    # The `enumerate` arm must not have widened the parser into accepting
    # anything: a typo has to stay a hard error.
    let root = absolutePath(TmpDir / "pathset-unit-unknown")
    if dirExists(root): removeDir(root)
    createDir(root)
    defer: removeDir(root)
    let reportPath = root / "paths.rps"
    writeFile(reportPath, "repro-pathset-v1\nenumerated\t/tmp/somedir\n")
    var raised = false
    try:
      discard readReproPathSet(reportPath)
    except DependencyReportError as err:
      raised = true
      check err.kind == dreMalformed
    check raised

  test "a converter-reported enumeration reaches the action-cache record":
    # End-to-end for producer 1 through the ordinary process record site:
    # converter emits `enumerate`, the engine folds it, the record carries
    # a membership digest, and a membership change re-runs the edge.
    let f = makeFixture("converter")
    defer: removeDir(f.root)
    let act = action("converter/enumerating",
      [selfPath(), "--fixture-list", f.listDir, f.runLogPath],
      cwd = f.workRoot,
      inputs = [],
      outputs = [],
      cacheable = true,
      weakFingerprint = weak("converter/enumerating"),
      actionCachePolicy = ffpHybrid,
      dependencyPolicy = f.converterPolicy(),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    let g = graph([act])
    let config = testConfig(f.cacheRoot)

    let first = runBuild(g, config)
    checkpoint("first: status=" & $first.byId(act.id).status &
      " stderr=" & first.byId(act.id).stderr)
    check first.byId(act.id).status == asSucceeded
    check f.runCount() == 1

    let counts = directoryCounts(f.recordedInputsFor(act))
    checkpoint("directories=" & $counts.dirs &
      " membership-tracked=" & $counts.tracked)
    check counts.tracked > 0

    let warm = runBuild(g, config)
    checkpoint("warm: decision=" & $warm.byId(act.id).cacheDecision)
    check warm.byId(act.id).cacheDecision in ReuseDecisions
    check f.runCount() == 1

    writeFile(f.listDir / "newcomer.txt", "appeared\n")

    let after = runBuild(g, config)
    let r = after.byId(act.id)
    checkpoint("after adding a file: decision=" & $r.cacheDecision &
      " launched=" & $r.launched & " reason=" & r.reason)
    check r.cacheDecision notin ReuseDecisions
    check f.runCount() == 2

# ---------------------------------------------------------------------------
# Producer 2 — the plan/builtin record site.
# ---------------------------------------------------------------------------

suite "the builtin record site carries enumerated directories":

  test "a file added to an enumerated directory re-runs a builtin edge":
    # A builtin runs in-process, so no io-monitor can ever wrap it. The
    # engine's documented seam for that is a PREWIRED monitor depfile
    # (`monitoredAction`: "direct engine callers may provide a monitor
    # depfile path for actions that produce iomon evidence themselves").
    # The iomon here is produced by the real monitor observing a real
    # process that really listed the directory — it is not synthesized.
    let repoRoot = findRepoRoot()
    let f = makeFixture("builtin")
    defer: removeDir(f.root)
    runUnderMonitor(repoRoot, f.rmdfPath,
      @[selfPath(), "--fixture-list", f.listDir, f.runLogPath])
    check fileExists(f.rmdfPath)

    let outputPath = f.workRoot / "out" / "stamp.txt"
    var act = builtinAction(bakWriteText, "builtin/enumerating",
      cwd = f.workRoot,
      outputs = [outputPath],
      cacheable = true,
      weakFingerprint = weak("builtin/enumerating"),
      actionCachePolicy = ffpHybrid,
      text = "stamp\n",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    act.monitorDepfile = f.rmdfPath
    let g = graph([act])
    let config = testConfig(f.cacheRoot)

    let first = runBuild(g, config)
    checkpoint("first: status=" & $first.byId(act.id).status &
      " stderr=" & first.byId(act.id).stderr)
    check first.byId(act.id).status == asSucceeded
    check first.byId(act.id).launched

    # Denominator: the record must carry the directory, and carry it as
    # MEMBERSHIP-tracked, not as a bare existence probe.
    let inputs = f.recordedInputsFor(act)
    let counts = directoryCounts(inputs)
    checkpoint("recorded inputs=" & $inputs.len &
      " directories=" & $counts.dirs &
      " membership-tracked=" & $counts.tracked)
    check inputs.len > 0
    check counts.dirs > 0
    check counts.tracked > 0

    let warm = runBuild(g, config)
    checkpoint("warm: decision=" & $warm.byId(act.id).cacheDecision &
      " launched=" & $warm.byId(act.id).launched)
    check warm.byId(act.id).cacheDecision in ReuseDecisions
    check not warm.byId(act.id).launched

    writeFile(f.listDir / "newcomer.txt", "appeared\n")

    let after = runBuild(g, config)
    let r = after.byId(act.id)
    checkpoint("after adding a file: decision=" & $r.cacheDecision &
      " launched=" & $r.launched & " reason=" & r.reason)
    check r.cacheDecision notin ReuseDecisions
    check r.launched

# ---------------------------------------------------------------------------
# Producer 3 — the elevated-broker record site.
# ---------------------------------------------------------------------------

proc monitoringBrokerSpawn(repoRoot, depfile: string): ElevatedExecSpawner =
  ## Forks the edge's argv under the real io-monitor. See the MOCK POLICY
  ## note at the top of this file for why the elevation itself is not
  ## reproduced.
  let tools = monitorTools(repoRoot)
  let cliPath = tools.monitorCliPath
  let cliArgs = tools.monitorCliArgs
  result = proc (req: ElevatedExecRequest):
      ElevatedExecResult {.gcsafe, closure.} =
    createDir(depfile.splitPath.head)
    let child = startProcess(cliPath, workingDir = req.cwd,
      args = cliArgs & @["--depfile", depfile, "--"] & req.argv,
      options = {})
    let code = child.waitForExit()
    child.close()
    ElevatedExecResult(ok: code == 0, exitCode: code)

suite "the elevated-broker record site carries enumerated directories":

  test "a file added to an enumerated directory re-runs an elevated edge":
    let repoRoot = findRepoRoot()
    let f = makeFixture("elevated")
    defer: removeDir(f.root)
    var act = action("elevated/enumerating",
      [selfPath(), "--fixture-list", f.listDir, f.runLogPath],
      cwd = f.workRoot,
      inputs = [],
      outputs = [],
      cacheable = true,
      weakFingerprint = weak("elevated/enumerating"),
      actionCachePolicy = ffpHybrid,
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    act.requiresElevation = true
    act.monitorDepfile = f.rmdfPath
    let g = graph([act])
    var config = testConfig(f.cacheRoot)
    config.brokerSpawn = monitoringBrokerSpawn(repoRoot, f.rmdfPath)

    let first = runBuild(g, config)
    checkpoint("first: status=" & $first.byId(act.id).status &
      " stderr=" & first.byId(act.id).stderr)
    check first.byId(act.id).status == asSucceeded
    check f.runCount() == 1

    let counts = directoryCounts(f.recordedInputsFor(act))
    checkpoint("directories=" & $counts.dirs &
      " membership-tracked=" & $counts.tracked)
    check counts.tracked > 0

    let warm = runBuild(g, config)
    checkpoint("warm: decision=" & $warm.byId(act.id).cacheDecision)
    check warm.byId(act.id).cacheDecision in ReuseDecisions
    check f.runCount() == 1

    writeFile(f.listDir / "newcomer.txt", "appeared\n")

    let after = runBuild(g, config)
    let r = after.byId(act.id)
    checkpoint("after adding a file: decision=" & $r.cacheDecision &
      " launched=" & $r.launched & " reason=" & r.reason)
    check r.cacheDecision notin ReuseDecisions
    check f.runCount() == 2
