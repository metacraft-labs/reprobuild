## A cacheable edge that declares NO outputs must still be skipped when
## nothing it reads has changed.
##
## MOCK POLICY — NO MOCKS ARE USED IN THIS FILE, AND NONE MAY BE ADDED.
## Every assertion drives the real `runBuild` scheduler in
## `repro_build_engine`, the real per-edge `ActionCache` + CAS in
## `repro_local_store`, a real C compiler (`cc`), a real subprocess, and
## real files in a real temporary directory. A mocked store or a fake
## executor would make these tests vacuous: the defect under test lives
## in the interaction between the engine's "are the declared outputs
## present" pre-check and the `rebuildMissingOutputsOnCacheHit`
## reuse gate, so both halves must be the production ones.
##
## The engine config below mirrors what `repro build` actually sets —
## `rebuildMissingOutputsOnCacheHit = true` and
## `deferLocalOutputBlobs = true`
## (`libs/repro_cli_support/src/repro_cli_support.nim:8693`) — so these
## tests exercise the warm in-place local-build mode users get by
## default, not the CAS-restore mode. A second suite repeats the core
## property with `rebuildMissingOutputsOnCacheHit = false` so the fix
## cannot be a config-specific special case.
##
## The graph is the two-edge shape `ct_test_nim_unittest` emits for
## every reprobuild test: a `build` edge that compiles a test binary
## (declared output) and a `run` edge that executes it (NO declared
## output — running a test produces nothing the build graph consumes).
##
## Governing spec text:
##
## * Test-Edges-And-Parallel-Runner.milestones.org §Introduction,
##   initiative goal (1): "Make each reprobuild test program a
##   first-class build edge in the DSL so it benefits from action-cache
##   reuse, incremental invalidation, named selection, and watch."
## * Incremental-Invalidation.md §"Validation Criteria": "a warm re-run
##   of an unchanged graph still executes zero actions".
## * Incremental-Invalidation.md §"Validation Criteria": "changing a read
##   input invalidates the action".
##
## The three properties, and why all three are required together:
##
## 1. unchanged inputs  => the run edge is NOT re-launched (cache hit).
## 2. changed fixture   => the run edge IS re-launched.
## 3. changed binary    => the run edge IS re-launched.
##
## (1) alone would also pass against an engine that never runs anything;
## (2) and (3) are what make (1) mean something. Each direction is
## corroborated by an out-of-band execution counter (a log the child
## process appends to), so "not launched" is not merely the engine's
## own bookkeeping agreeing with itself.

import std/[os, osproc, strutils, tempfiles, unittest]

import repro_build_engine
import repro_hash
import repro_local_store

## Both decisions mean "the recorded result is still valid, do not
## re-execute". `cdHybridCutoff` is the hybrid policy's form of a hit:
## input metadata moved but the content hash matched
## (Incremental-Invalidation.md §"File Fingerprint Policies").
const ReuseDecisions = {cdHit, cdHybridCutoff}

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("zero-output-edge-cacheable." & name)

proc ccPath(): string =
  result = findExe("cc")
  if result.len == 0:
    result = findExe("gcc")

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

## The "test binary": reads a fixture file, appends one line to a run
## log (the out-of-band execution counter) and writes a Make depfile so
## the run edge can use the recognized-format dependency policy instead
## of requiring the io-monitor. Nothing it writes is a DECLARED OUTPUT
## of the run edge — that is the whole point of the shape under test.
const TestProgramSource = """
#include <stdio.h>
#ifndef PROGRAM_REVISION
#define PROGRAM_REVISION "rev-a"
#endif
int main(int argc, char **argv) {
  if (argc != 4) return 64;
  FILE *fixture = fopen(argv[1], "r");
  if (!fixture) return 65;
  char buf[512];
  if (!fgets(buf, sizeof buf, fixture)) buf[0] = '\0';
  fclose(fixture);
  FILE *log = fopen(argv[2], "a");
  if (!log) return 66;
  fprintf(log, "%s %s\n", PROGRAM_REVISION, buf);
  fclose(log);
  FILE *dep = fopen(argv[3], "w");
  if (!dep) return 67;
  fprintf(dep, "run.stamp: %s\n", argv[1]);
  fclose(dep);
  return 0;
}
"""

type Fixture = object
  root: string
  workRoot: string
  cacheRoot: string
  fixturePath: string
  runLogPath: string
  compileAction: BuildAction
  runAction: BuildAction

proc runCount(f: Fixture): int =
  ## Out-of-band evidence: how many times the child process actually ran.
  if not fileExists(f.runLogPath):
    return 0
  for line in readFile(f.runLogPath).splitLines():
    if line.strip().len > 0:
      inc result

proc compileEdge(cc, workRoot, revision: string): BuildAction =
  action("testbin/compile",
    [cc, "-O0", "-DPROGRAM_REVISION=\"" & revision & "\"",
     "-MD", "-MF", "out/testbin.d", "-o", "out/testbin", "src/prog.c"],
    cwd = workRoot,
    inputs = ["src/prog.c"],
    outputs = ["out/testbin"],
    depfile = "out/testbin.d",
    cacheable = true,
    weakFingerprint = weak("testbin/compile"),
    actionCachePolicy = ffpHybrid,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc runEdge(workRoot: string): BuildAction =
  # The edge under test. `outputs = []` is deliberate and load-bearing:
  # `ct_test_nim_unittest.run` declares no outputs either.
  action("testbin/run",
    ["out/testbin", "src/fixture.txt", "out/runs.log", "out/run.d"],
    cwd = workRoot,
    deps = ["testbin/compile"],
    inputs = ["out/testbin", "src/fixture.txt"],
    outputs = [],
    depfile = "out/run.d",
    cacheable = true,
    weakFingerprint = weak("testbin/run"),
    actionCachePolicy = ffpHybrid,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc makeFixture(cc: string; revision = "rev-a"): Fixture =
  let root = createTempDir("repro-zero-output-edge-", "")
  let workRoot = root / "work"
  createDir(workRoot / "src")
  createDir(workRoot / "out")
  writeFile(workRoot / "src" / "prog.c", TestProgramSource)
  let fixturePath = workRoot / "src" / "fixture.txt"
  writeFile(fixturePath, "fixture-generation-1\n")
  Fixture(
    root: root,
    workRoot: workRoot,
    cacheRoot: root / "cache",
    fixturePath: fixturePath,
    runLogPath: workRoot / "out" / "runs.log",
    compileAction: compileEdge(cc, workRoot, revision),
    runAction: runEdge(workRoot))

proc buildGraphOf(f: Fixture): BuildGraph =
  graph([f.compileAction, f.runAction])

proc warmConfig(cacheRoot: string): BuildEngineConfig =
  ## Exactly the mode `repro build` runs in.
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.maxParallelism = 2'u32

proc restoreConfig(cacheRoot: string): BuildEngineConfig =
  ## The CAS-restore mode (`rebuildMissingOutputsOnCacheHit = false`).
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = false
  result.bypassRunQuota = true
  result.maxParallelism = 2'u32

suite "zero-output edge is cacheable on its inputs alone":

  test "1. unchanged inputs: the run edge is not re-launched":
    let cc = ccPath()
    if cc.len == 0:
      skip()
    else:
      let f = makeFixture(cc)
      defer: removeDir(f.root)
      let g = f.buildGraphOf()
      let config = warmConfig(f.cacheRoot)

      let first = runBuild(g, config)
      check first.byId("testbin/compile").status == asSucceeded
      check first.byId("testbin/run").status == asSucceeded
      check first.byId("testbin/run").launched
      check f.runCount() == 1

      let second = runBuild(g, config)
      let r = second.byId("testbin/run")
      checkpoint("second run: status=" & $r.status &
        " cacheDecision=" & $r.cacheDecision &
        " launched=" & $r.launched & " reason=" & r.reason)
      check r.cacheDecision in ReuseDecisions
      check r.status in {asCacheHit, asUpToDate}
      check not r.launched
      # Out-of-band corroboration: the child process did not run again.
      check f.runCount() == 1

      # A third warm pass must stay a hit — the hit must not depend on
      # the record having been written by the immediately preceding run.
      let third = runBuild(g, config)
      check third.byId("testbin/run").cacheDecision in ReuseDecisions
      check not third.byId("testbin/run").launched
      check f.runCount() == 1

  test "2. changed input: the run edge is re-launched":
    let cc = ccPath()
    if cc.len == 0:
      skip()
    else:
      let f = makeFixture(cc)
      defer: removeDir(f.root)
      let g = f.buildGraphOf()
      let config = warmConfig(f.cacheRoot)

      check runBuild(g, config).byId("testbin/run").launched
      check f.runCount() == 1
      check not runBuild(g, config).byId("testbin/run").launched
      check f.runCount() == 1

      # Change what the test reads. The binary is untouched.
      writeFile(f.fixturePath, "fixture-generation-2-with-more-bytes\n")

      let after = runBuild(g, config)
      let r = after.byId("testbin/run")
      checkpoint("after fixture change: status=" & $r.status &
        " cacheDecision=" & $r.cacheDecision &
        " launched=" & $r.launched & " reason=" & r.reason)
      check r.cacheDecision notin ReuseDecisions
      check r.launched
      check f.runCount() == 2
      check readFile(f.runLogPath).contains("fixture-generation-2")
      # The compile edge reads none of that, so it must still be a hit.
      check not after.byId("testbin/compile").launched

      # ... and the new state is itself cacheable.
      check not runBuild(g, config).byId("testbin/run").launched
      check f.runCount() == 2

  test "3. changed test binary: the run edge is re-launched":
    let cc = ccPath()
    if cc.len == 0:
      skip()
    else:
      let f = makeFixture(cc)
      defer: removeDir(f.root)
      let config = warmConfig(f.cacheRoot)

      check runBuild(f.buildGraphOf(), config).byId("testbin/run").launched
      check f.runCount() == 1
      check not runBuild(f.buildGraphOf(), config).byId("testbin/run").launched
      check f.runCount() == 1
      check readFile(f.runLogPath).contains("rev-a")

      # Change the test program's source so the compile edge produces a
      # different binary. Nothing else moves.
      writeFile(f.workRoot / "src" / "prog.c",
        TestProgramSource.replace("\"rev-a\"", "\"rev-b\""))
      var rebuilt = f
      rebuilt.compileAction = compileEdge(cc, f.workRoot, "rev-b")

      let after = runBuild(rebuilt.buildGraphOf(), config)
      check after.byId("testbin/compile").launched
      let r = after.byId("testbin/run")
      checkpoint("after binary change: status=" & $r.status &
        " cacheDecision=" & $r.cacheDecision &
        " launched=" & $r.launched & " reason=" & r.reason)
      check r.cacheDecision notin ReuseDecisions
      check r.launched
      check f.runCount() == 2
      check readFile(f.runLogPath).contains("rev-b")

  test "4. a zero-output edge that has never run is still executed":
    # The counterpart to (1): "no declared outputs" must not be read as
    # "the declared outputs are present", which would let a never-executed
    # edge report itself up to date.
    #
    # The edge here has NO dependency on purpose. With a dependency that
    # launched in the same pass, `dependencyLaunched` suppresses the
    # "outputs are present, call it up to date" shortcut and the test would
    # pass even against an engine that answers `allOutputsExist = true` for
    # an empty output set. A dependency-free edge removes that cover, so
    # this case fails if the two questions are ever collapsed into one.
    let sh = findExe("sh")
    if sh.len == 0:
      skip()
    else:
      let root = createTempDir("repro-zero-output-first-run-", "")
      defer: removeDir(root)
      let workRoot = root / "work"
      createDir(workRoot / "src")
      createDir(workRoot / "out")
      writeFile(workRoot / "src" / "fixture.txt", "solo\n")
      let logPath = workRoot / "out" / "solo.log"
      let solo = action("solo/run",
        [sh, "-c",
         "printf 'ran\\n' >> out/solo.log; " &
         "printf 'solo.stamp: src/fixture.txt\\n' > out/solo.d"],
        cwd = workRoot,
        inputs = ["src/fixture.txt"],
        outputs = [],
        depfile = "out/solo.d",
        cacheable = true,
        weakFingerprint = weak("solo/run"),
        actionCachePolicy = ffpHybrid,
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      let g = graph([solo])
      let config = warmConfig(root / "cache")

      let first = runBuild(g, config)
      let r = first.byId("solo/run")
      checkpoint("first run: status=" & $r.status &
        " cacheDecision=" & $r.cacheDecision &
        " launched=" & $r.launched & " reason=" & r.reason)
      check r.launched
      check r.status == asSucceeded
      check r.status != asUpToDate
      check fileExists(logPath)
      check readFile(logPath) == "ran\n"

      # ... and once it HAS run, the same edge is reusable.
      let second = runBuild(g, config)
      check second.byId("solo/run").cacheDecision in ReuseDecisions
      check not second.byId("solo/run").launched
      check readFile(logPath) == "ran\n"

suite "zero-output edge is cacheable in CAS-restore mode too":

  test "unchanged inputs hit with rebuildMissingOutputsOnCacheHit = false":
    let cc = ccPath()
    if cc.len == 0:
      skip()
    else:
      let f = makeFixture(cc)
      defer: removeDir(f.root)
      let g = f.buildGraphOf()
      let config = restoreConfig(f.cacheRoot)

      check runBuild(g, config).byId("testbin/run").launched
      check f.runCount() == 1

      let second = runBuild(g, config)
      let r = second.byId("testbin/run")
      checkpoint("restore-mode second run: status=" & $r.status &
        " cacheDecision=" & $r.cacheDecision &
        " launched=" & $r.launched & " reason=" & r.reason)
      check r.cacheDecision in ReuseDecisions
      check not r.launched
      check f.runCount() == 1

      writeFile(f.fixturePath, "fixture-generation-2-with-more-bytes\n")
      check runBuild(g, config).byId("testbin/run").launched
      check f.runCount() == 2
