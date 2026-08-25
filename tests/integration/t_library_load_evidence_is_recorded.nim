## A shared library the dynamic loader mapped into the action is an input
## of that action, and must be in its cache key.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every assertion drives the real `runBuild` scheduler, the real per-edge
## `ActionCache` + CAS in `repro_local_store`, the real graph-built
## io-monitor (`build/bin/repro internal io monitor` + the graph-built
## shim), a real C compiler (`cc`), a real `DT_NEEDED` link, the real
## dynamic loader, and real files in a real temporary directory. The
## defect class under test IS the monitor evidence path: a harness that
## supplied its own evidence would assert nothing about what production
## records.
##
## WHY A REAL LINK RATHER THAN A SYNTHETIC RECORD
## ---------------------------------------------------------------------
## The hole exists precisely because the loader does NOT go through the
## interposed `open`. `ld.so` resolves `DT_NEEDED` entries with its own
## internal open before the preloaded shim's hooks are installed, so a
## dependent library is recorded by io-mon ONLY as `mrLibraryLoad`
## (io-mon `types.nim:36`, emitted from `shim/linux_preload.nim` via the
## loaded-object enumeration, not from a hooked `open`). Reproducing that
## requires a genuine link — a test that `dlopen`ed at runtime, or that
## wrote the record by hand, would exercise a different mechanism than
## the one that leaks.
##
## Measured on this host before the fix, monitoring `env true` — a
## process that touches no file of its own:
##
##     records: 33
##       kind mrLibraryLoad = 18
##     fold status: mesComplete
##     monitorReads: 0   monitorWrites: 0   monitorProbes: 0
##
## Eighteen library-load records covering fourteen distinct paths and
## nine distinct sonames (libc, libdl, libm, libpthread, librt, libacl,
## libattr, libgmp, ld-linux), and not one of them reached the cache key.
## Record count exceeds path count because four sonames are emitted twice
## under the identical path; path count exceeds soname count because
## `env` exec'd a second image linked against a different glibc, so five
## sonames appear under two store paths each.
##
## Governing spec text:
##
## * Sandbox-And-Monitoring.md:12-19 — the observation set includes
##   "loaded tools and libraries when observable on the platform".
## * Sandbox-And-Monitoring.md:865-870 — "`dlopen` and equivalent
##   dynamic-loading events where available ... This matters because tool
##   identity and loaded helper libraries affect reproducibility."
## * Failure-Semantics.md:11-12 — "Ambiguous correctness failures MUST
##   fail closed: reject cache reuse, rerun, or require review rather
##   than silently accepting stale state."
## * io-mon-Lossless-Event-Capture.milestones.org:713-716 — the
##   completeness oracle's captured INPUT set is "records of kind
##   `mrFileRead` ∪ `mrLibraryLoad` (both `moFileRead` — the content deps
##   a cache key covers)".
##
## Sandbox-And-Monitoring.md §"Open Design Questions" listed "how much
## library-load information is required for correctness" as undecided.
## This suite is the decision: ALL of it, unconditionally, folded as a
## content read. The alternative — an allowlist for immutable package
## stores — was rejected because it is exactly the shape that made this
## hole invisible for so long (on NixOS every loaded DSO is a store path,
## so the leak is masked; on a host with a mutable `/usr/lib` it is a
## stale hit). The cost is one `lstat` per loaded DSO on the warm path.
##
## HISTORY. While a zero-output edge was an unconditional cache miss this
## was harmless — such an edge re-ran no matter what its record said.
## Making test-execute edges cacheable on their recorded inputs alone
## moves them into the class where the recorded input set has to be
## complete on its own merits.

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
      repoRoot / "build" / "test-monitor-libload", "libload-monitor")
    putEnv("REPRO_MONITOR_SHIM_LIB", cachedMonitorTools.shim)
    cachedMonitorToolsReady = true
  cachedMonitorTools

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("library-load-evidence." & name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

const ReuseDecisions = {cdHit, cdHybridCutoff}

proc ccPath(): string =
  result = findExe("cc")
  if result.len == 0:
    result = findExe("gcc")

## The shared library. `greet_value` is the only thing in it, and its
## value is what changes between generations.
const LibrarySource = """
#ifndef GREET_VALUE
#define GREET_VALUE 1
#endif
int greet_value(void) { return GREET_VALUE; }
"""

## The edge's payload. It calls into the library and appends one line to
## a run log, so "did not re-run" is corroborated out of band. It reads
## NO file of its own — the library is the entire discovered input set,
## which is what makes the assertion below unambiguous.
const RunnerSource = """
#include <stdio.h>
int greet_value(void);
int main(int argc, char **argv) {
  if (argc != 2) return 64;
  FILE *log = fopen(argv[1], "a");
  if (!log) return 66;
  fprintf(log, "ran greet_value=%d\n", greet_value());
  fclose(log);
  return 0;
}
"""

type Fixture = object
  root: string
  workRoot: string
  cacheRoot: string
  libDir: string
  libPath: string
  runnerPath: string
  runLogPath: string

proc runCount(f: Fixture): int =
  if not fileExists(f.runLogPath):
    return 0
  f.runLogPath.readFile.splitLines.countIt(it.strip().len > 0)

proc compileLibrary(f: Fixture; greetValue: int) =
  ## Rebuild `libgreet.so` in place with a different `greet_value`. The
  ## runner binary is NOT relinked, so the only thing that changed
  ## between runs is a file the loader maps.
  let cc = ccPath()
  let res = execProcess(cc, args = [
    "-shared", "-fPIC",
    "-DGREET_VALUE=" & $greetValue,
    "-o", f.libPath,
    f.workRoot / "libgreet.c"
  ], options = {poStdErrToStdOut, poUsePath})
  if not fileExists(f.libPath):
    raise newException(OSError, "libgreet.so was not produced: " & res)

proc makeFixture(): Fixture =
  let root = createTempDir("repro-library-load-", "")
  let workRoot = root / "work"
  createDir(workRoot)
  # The library lives in a MUTABLE directory, not a content-addressed
  # store. On NixOS every DSO a normal process loads is an immutable
  # store path, which is exactly what masks this hole in day-to-day use.
  let libDir = workRoot / "lib"
  createDir(libDir)
  createDir(workRoot / "out")
  writeFile(workRoot / "libgreet.c", LibrarySource)
  writeFile(workRoot / "runner.c", RunnerSource)
  result = Fixture(
    root: root,
    workRoot: workRoot,
    cacheRoot: root / "cache",
    libDir: libDir,
    libPath: libDir / "libgreet.so",
    runnerPath: workRoot / "runner",
    runLogPath: workRoot / "out" / "runs.log")
  result.compileLibrary(1)
  # `-Wl,-rpath` makes this a DT_NEEDED dependency resolved by the
  # loader at startup, before the preloaded shim's hooks exist. That is
  # the shape the hole lives in; a runtime `dlopen` would go through the
  # interposed `open` and prove nothing.
  let cc = ccPath()
  let res = execProcess(cc, args = [
    "-o", result.runnerPath,
    result.workRoot / "runner.c",
    "-L", result.libDir, "-lgreet",
    "-Wl,-rpath," & result.libDir
  ], options = {poStdErrToStdOut, poUsePath})
  if not fileExists(result.runnerPath):
    raise newException(OSError, "runner was not produced: " & res)

proc monitoredRunEdge(f: Fixture): BuildAction =
  ## NOTE what is NOT here: `lib/libgreet.so` is not in `inputs`. The
  ## only declared input is the runner binary. Under `dgAutomaticMonitor`
  ## — the policy a real test-execute edge uses — the library has to come
  ## from the monitor or from nowhere.
  action("libload/run",
    ["./runner", "out/runs.log"],
    cwd = f.workRoot,
    inputs = ["runner"],
    outputs = [],
    cacheable = true,
    weakFingerprint = weak("libload/run"),
    actionCachePolicy = ffpHybrid,
    dependencyPolicy = automaticMonitorGatheringPolicy(),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc monitoredConfig(repoRoot, cacheRoot: string): BuildEngineConfig =
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
  var cache = openActionCache(f.cacheRoot / "action-cache")
  let hot = cache.readHotRecord(f.monitoredRunEdge().weakFingerprint)
  if not hot.found:
    return @[]
  hot.record.inputs

suite "a loaded shared library is a recorded input":

  test "changing a DT_NEEDED library re-runs the edge":
    if ccPath().len == 0:
      skip()
    else:
      let repoRoot = findRepoRoot()
      let f = makeFixture()
      defer: removeDir(f.root)
      let g = graph([f.monitoredRunEdge()])
      let config = monitoredConfig(repoRoot, f.cacheRoot)

      let first = runBuild(g, config)
      let r0 = first.byId("libload/run")
      checkpoint("first: status=" & $r0.status & " stderr=" & r0.stderr &
        " monitorReads=" & $r0.evidence.monitorReads.len)
      check r0.status == asSucceeded
      check r0.launched
      check f.runCount() == 1
      check f.runLogPath.readFile.contains("greet_value=1")

      # Denominator, and the whole point: the library must be IN the
      # recorded input set. Without this the invalidation below could
      # pass for an unrelated reason (e.g. a probe of the directory).
      let inputs = f.recordedInputs()
      let libRecorded = inputs.anyIt(it.path.endsWith("libgreet.so"))
      checkpoint("recorded inputs: " & $inputs.len &
        "; 'libgreet.so' among them: " & $libRecorded)
      check inputs.len > 0
      check libRecorded

      # Warm, nothing touched: reusable.
      let warm = runBuild(g, config)
      checkpoint("warm: decision=" & $warm.byId("libload/run").cacheDecision)
      check warm.byId("libload/run").cacheDecision in ReuseDecisions
      check not warm.byId("libload/run").launched
      check f.runCount() == 1

      # Change ONLY the library. The runner binary is untouched, and it
      # reads no file, so nothing the edge previously READ has changed —
      # only something it LOADED.
      f.compileLibrary(2)

      let after = runBuild(g, config)
      let r = after.byId("libload/run")
      checkpoint("after rebuilding the library: status=" & $r.status &
        " cacheDecision=" & $r.cacheDecision & " launched=" & $r.launched &
        " reason=" & r.reason)
      check r.cacheDecision notin ReuseDecisions
      check r.launched
      check f.runCount() == 2
      check f.runLogPath.readFile.contains("greet_value=2")

      # ... and the new state is itself reusable, so the fix did not
      # simply turn every such edge into a permanent miss.
      let settled = runBuild(g, config)
      checkpoint("settled: decision=" & $settled.byId("libload/run").cacheDecision)
      check settled.byId("libload/run").cacheDecision in ReuseDecisions
      check not settled.byId("libload/run").launched
      check f.runCount() == 2
