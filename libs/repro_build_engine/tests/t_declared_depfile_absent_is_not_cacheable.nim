## An action that DECLARED a dependency report and produced none of the
## files it declared must not publish an action-cache record.
##
## THE HOLE THIS CLOSES. ``depfilePolicyMulti`` (repro_cli_support.nim)
## lowers every declared depfile path with ``required = false``, so a
## depfile that is never written reaches ``collectEvidence`` and falls
## through a bare ``continue``: no diagnostic, no ``publishable = false``,
## a fully publishable record keyed on an EMPTY observed-input set. "This
## edge produced no dependency information" was therefore indistinguishable
## from "this edge has no dependencies". The `required = false` lowering is
## right — a GLOB entry may legitimately match zero files (cargo declares
## both ``target/debug/deps/*.d`` and ``target/release/deps/*.d`` and only
## one profile dir exists per build) — so the refusal belongs at the
## AGGREGATE level: none of the report's paths resolved at all.
##
## LIVE, NOT LATENT — and the belief that it was latent is what let it sit.
## ``compileDependencyPolicy`` (repro_dsl_stdlib .../nim.nim) reaches
## ``makeDepfilePolicy(cacheDir / "nim-compile.d")`` only on its UNCACHEABLE
## branch, which reads like a guarantee that every such edge is uncacheable.
## It is not one: the proc short-circuits first on
## ``if policy.kind != bdpDefault: return policy``, so a recipe that passes
## the depfile policy EXPLICITLY skips the cacheable test entirely and keeps
## ``nim.c``'s ``cacheable = true`` default. ``repro.nim`` does exactly that
## for the monitor-shim edges.
##
## Measured on this tree (``reprobuild graph --json``, 1743 actions):
## exactly one action carries a ``dgRecognizedFormat`` policy —
## ``reprobuild.test_fixtures.monitor_shim`` — it is ``cacheable: true``, its
## sole declared report is ``build/nimcache/repro_monitor_shim/nim-compile.d``,
## and nothing in this repository or in the Nim fork writes a file by that
## name. The third suite below is therefore NOT a description of that edge;
## it is the boundary of the guard, kept so that the uncacheable class stays
## silent and a future scope change fails a test that names it.
##
## MOCK POLICY — NONE. The scheduler (``runBuild``), the evidence collector
## (``collectEvidence``), the per-edge ``ActionCache``, the CAS, the
## fingerprinting and the subprocesses are all the production ones. The
## edges run a real ``/bin/sh`` and the depfile in the second suite is a
## real make-format file written by that shell and parsed by the production
## ``readRecognizedDependencyReport``. Nothing about the decision under test
## is faked; only the choice of WHICH edges to build is the test's.
##
## Governing spec text:
##
## * Compiles-Are-Normal-Edges.md §"Status" — the depfile fallback is the
##   part that is NOT implemented; M5 retires it. This is a tripwire until
##   then, not the fix.
## * Compiles-Are-Normal-Edges.md:269-273 — "An edge with no dependency
##   evidence that is also cacheable is worse than an uncached one: it
##   would publish and serve entries keyed on inputs it never observed,
##   and fail by returning a stale binary rather than by erroring".
## * Failure-Semantics.md:11-12 — "Ambiguous correctness failures MUST
##   fail closed: reject cache reuse, rerun, or require review rather
##   than silently accepting stale state."
##
## The three properties, and why all three are needed together:
##
##   1. declared-and-absent on a CACHEABLE edge => no publish, and the
##      engine SAYS SO, naming the edge and the path it expected.
##   2. declared-and-PRESENT => the edge publishes and is reused. Without
##      this the suite would also pass against an engine that refused to
##      cache anything, and every real depfile edge in the tree (gcc -MD,
##      rustc, zig, gfortran, ...) lives on this arm.
##   3. declared-and-absent on a NON-cacheable edge => nothing changes and
##      nothing is said. This pins the guard's SCOPE: an uncacheable edge
##      always re-runs, so there is nothing to protect and saying so on
##      every one of them is noise an operator learns to ignore.
##
## The action still SUCCEEDS in (1). Aborting the build would turn a silent
## issue into an outage, which is why the refusal is ``disableCacheHits``
## (publication withheld, action succeeds, ``traceCacheIneligibility``
## records why) rather than ``publishable = false`` (which the scheduler
## turns into ``asFailed``).

import std/[os, strutils, unittest]

import repro_build_engine
import repro_core
import repro_depfile
import repro_hash
import repro_local_store

const TmpDir = "build/test-tmp/t_declared_depfile_absent_is_not_cacheable"
const ReuseDecisions = {cdHit, cdHybridCutoff}
const RootImage = "/bin/sh"

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("declared-depfile-absent." & name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

type Fixture = object
  root: string
  workRoot: string
  cacheRoot: string
  runLogPath: string
  observedPath: string
  depfilePath: string

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
  createDir(workRoot)
  result = Fixture(
    root: root,
    workRoot: workRoot,
    cacheRoot: root / "cache",
    runLogPath: workRoot / "runs.log",
    observedPath: workRoot / "observed.txt",
    depfilePath: workRoot / "nim-compile.d")
  writeFile(result.observedPath, "generation-1\n")

proc depfileReportPolicy(path: string): DependencyGatheringPolicy =
  ## The shape ``depfilePolicyMulti`` (private to ``repro_cli_support``)
  ## produces for ``makeDepfilePolicy(path)`` — ``required = false`` and
  ## all. Spelled out here rather than imported precisely BECAUSE the
  ## ``required = false`` is the thing under test: a copy that drifted
  ## would stop grading it.
  DependencyGatheringPolicy(
    kind: dgRecognizedFormat,
    completeness: decComplete,
    recognizedReports: @[
      RecognizedDependencyReportSpec(
        formatName: DependencyFormatName(MakeDepfileFormatName),
        outputs: @[ExpectedDependencyFile(
          logicalName: "deps", path: path, required: false)],
        completeness: decComplete)])

proc depfileEdge(f: Fixture; id: string; cacheable: bool;
                 writesDepfile: bool): BuildAction =
  ## An edge that DECLARES ``f.depfilePath`` as its make-format dependency
  ## report. ``writesDepfile`` decides whether the command actually
  ## produces it — the single variable the first two suites differ on.
  ##
  ## The written report names ``f.observedPath`` as a prerequisite, so the
  ## publishing arm has a real recorded input rather than an empty one: a
  ## depfile with a target and no prerequisites would resolve but
  ## contribute nothing, and that is a different case from the one the
  ## reuse assertions are about.
  let command =
    if writesDepfile:
      "echo ran >> " & f.runLogPath & "; printf 'out: " & f.observedPath &
        "\\n' > " & f.depfilePath
    else:
      "echo ran >> " & f.runLogPath
  action(id,
    [RootImage, "-c", command],
    cwd = f.workRoot,
    inputs = [],
    outputs = [],
    cacheable = cacheable,
    weakFingerprint = weak(id),
    actionCachePolicy = ffpHybrid,
    dependencyPolicy = depfileReportPolicy(f.depfilePath),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc testConfig(cacheRoot: string): BuildEngineConfig =
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.fallbackToRunQuotaBypass = true
  result.maxParallelism = 1'u32

proc hasRecord(f: Fixture; act: BuildAction): bool =
  var cache = openActionCache(f.cacheRoot / "action-cache")
  cache.readHotRecord(act.weakFingerprint).found

proc ineligibilityTrace(res: BuildRunResult; id: string): string =
  for event in res.trace:
    if event.actionId == id and event.event.startsWith("cache-skip"):
      return event.event & " " & event.detail
  ""

suite "a declared-but-absent depfile makes the edge non-cacheable":

  test "absent depfile: the edge does not publish and re-runs":
    let f = makeFixture("absent")
    defer: removeDir(f.root)
    let act = f.depfileEdge("depfile-absent/run",
      cacheable = true, writesDepfile = false)
    let g = graph([act])
    let config = testConfig(f.cacheRoot)

    let first = runBuild(g, config)
    let r0 = first.byId(act.id)
    checkpoint("first: status=" & $r0.status &
      " depfileInputs=" & $r0.evidence.depfileInputs.len)
    # The action SUCCEEDS. Absent evidence on a cacheable edge does not
    # warrant killing the build; it warrants refusing to bank an entry
    # whose key cannot be trusted.
    check r0.status == asSucceeded
    check r0.launched
    check f.runCount() == 1

    # Denominator: the report really produced nothing, or the assertions
    # below would be about something else entirely.
    check not fileExists(f.depfilePath)
    check r0.evidence.depfileInputs.len == 0

    # The diagnostic has to name BOTH the edge and the path it expected,
    # because the next person to hit this must not have to rediscover that
    # nothing writes it.
    let diagnosed = r0.evidence.diagnostics.join(" ")
    checkpoint("diagnostics: " & diagnosed)
    check diagnosed.contains(act.id)
    check diagnosed.contains(f.depfilePath)
    check diagnosed.contains("produced none of its declared paths")

    # The structured reason reaches the scheduler trace, which is where
    # `repro why` reads it from.
    let traced = first.ineligibilityTrace(act.id)
    checkpoint("trace: " & traced)
    check traced.contains("missing-dependency-report")

    # Nothing was published, so there is nothing to be reused.
    check not f.hasRecord(act)

    let warm = runBuild(g, config)
    let r1 = warm.byId(act.id)
    checkpoint("warm: decision=" & $r1.cacheDecision &
      " launched=" & $r1.launched)
    check r1.cacheDecision notin ReuseDecisions
    check r1.launched
    check f.runCount() == 2

  test "present depfile: the edge publishes and is reused":
    # The narrowness guard, and the arm every real depfile edge in the
    # tree lives on. Without it this file would also pass against an
    # engine that had stopped caching depfile edges altogether.
    let f = makeFixture("present")
    defer: removeDir(f.root)
    let act = f.depfileEdge("depfile-present/run",
      cacheable = true, writesDepfile = true)
    let g = graph([act])
    let config = testConfig(f.cacheRoot)

    let first = runBuild(g, config)
    let r0 = first.byId(act.id)
    checkpoint("first: status=" & $r0.status &
      " depfileInputs=" & $r0.evidence.depfileInputs)
    check r0.status == asSucceeded
    check f.runCount() == 1
    check fileExists(f.depfilePath)
    # The prerequisite the depfile named is what the record is keyed on.
    check r0.evidence.depfileInputs == @[f.observedPath]

    # No refusal fired, and nothing was said. A guard that also fired here
    # would be indistinguishable from one that never discriminated.
    let diagnosed = r0.evidence.diagnostics.join(" ")
    checkpoint("diagnostics: " & diagnosed)
    check not diagnosed.contains("produced none of its declared paths")
    check first.ineligibilityTrace(act.id).len == 0

    check f.hasRecord(act)

    let warm = runBuild(g, config)
    let r1 = warm.byId(act.id)
    checkpoint("warm: decision=" & $r1.cacheDecision &
      " launched=" & $r1.launched)
    check not r1.launched
    check f.runCount() == 1

suite "the guard stops at the edge of its scope":

  test "absent depfile on a NON-cacheable edge changes nothing":
    ## THE SCOPE ARM. An uncacheable edge always re-runs, so absent
    ## evidence there cannot serve a stale result: there is nothing to
    ## protect, and a diagnostic on every one of them is noise an operator
    ## learns to ignore. ``repro.nim:2322-2327`` describes the intent for
    ## the monitor-shim edges in exactly those terms ("keep the edge
    ## non-cacheable and avoid monitor wrapping").
    ##
    ## WHAT THIS TEST DOES NOT SAY: that the shipped ``nim-compile.d``
    ## edges are in this class. They are not — see the header. The comment
    ## says non-cacheable; the graph says ``cacheable: true``. This arm
    ## pins the guard's SCOPE, not the tree's conformance to it.
    ##
    ## If this test ever goes red, the guard has started deciding
    ## something on a class where it was never meant to, and the first
    ## thing to check is whether the ``action.cacheable`` scope moved.
    let f = makeFixture("uncacheable")
    defer: removeDir(f.root)
    let act = f.depfileEdge("depfile-absent-uncacheable/run",
      cacheable = false, writesDepfile = false)
    let g = graph([act])
    let config = testConfig(f.cacheRoot)

    let first = runBuild(g, config)
    let r0 = first.byId(act.id)
    checkpoint("first: status=" & $r0.status)
    check r0.status == asSucceeded
    check r0.launched
    check f.runCount() == 1
    check not fileExists(f.depfilePath)

    # Silent: no diagnostic, no ineligibility trace. The edge was already
    # not publishing, and saying so on every one of them would be noise an
    # operator has to learn to ignore.
    let diagnosed = r0.evidence.diagnostics.join(" ")
    checkpoint("diagnostics: " & diagnosed)
    check not diagnosed.contains("produced none of its declared paths")
    check first.ineligibilityTrace(act.id).len == 0
    check not f.hasRecord(act)

    # And it re-runs, which is the property that made the absence
    # survivable in the first place.
    let warm = runBuild(g, config)
    check warm.byId(act.id).launched
    check f.runCount() == 2
