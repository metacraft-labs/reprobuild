## An action whose monitor reported success while recording NO
## observation of any kind must not publish an action-cache record.
##
## MOCK POLICY — ONE justified stand-in, named and bounded below.
## The scheduler (`runBuild`), the evidence collector (`collectEvidence`,
## `foldMonitorDepFileEvidence`), the per-edge `ActionCache`, the CAS,
## the fingerprinting in `repro_local_store`, the subprocess and the
## files are all the production ones. What is supplied here is the RMDF
## the action is fingerprinted against: it is written with io-mon's OWN
## canonical encoder (`io_mon/writer.encodeCanonical`) and read back by
## the production reader, so the FILE is real — it is its CONTENT that
## is chosen rather than observed.
##
## That is unavoidable, and the reason is itself a finding. Measured on
## this host with the real monitor:
##
##   * `env true` (touches no file of its own): 33 records, 18 of them
##     `mrLibraryLoad`, `mesComplete`, and — once library loads are
##     folded as reads — 16 recorded inputs. Not zero.
##   * a `-nostdlib` dynamically-linked binary: 6 `mrLibraryLoad`
##     records (the loader plus the shim's own dependent DSOs).
##     Not zero.
##   * a `-nostdlib -static` binary, which `LD_PRELOAD` cannot reach at
##     all: io-mon emits `mrEventLoss`, the fold returns
##     `mesUnknownScopeLoss`, and the Level 2 arm already disables the
##     publish. Handled, and not by this guard.
##
## So on Linux today there is no process that reaches the guard: every
## injectable process observes something, and every non-injectable one
## fails closed earlier. A test that waited for a real process to
## produce the state would assert nothing, forever. The state is still
## worth guarding — it is what a backend that reports success while
## capturing nothing produces, which is the documented shape of io-mon's
## P0 "mcComplete with zero real inputs"
## (MacOS-Monitoring-Adversarial-Hardening.milestones.org:1360) — and a
## guard with no test is what let this hole exist for as long as it did.
## The stand-in is confined to the bytes of one input file; nothing about
## the decision under test is faked.
##
## Governing spec text:
##
## * Monitor-Hook-Shim.md:501 — "injection failure MUST fail the
##   monitored action or make it non-cacheable, depending on policy".
##   This suite takes the second arm.
## * Reprobuild-Development.milestones.org:719-724 (M17) — "An action
##   that genuinely has NO monitorable evidence and genuinely cannot be
##   monitored (e.g. a pure network fetch) is made NON-CACHEABLE (always
##   re-run) ... It is NEVER marked complete-on-declared-inputs."
## * Failure-Semantics.md:11-12 — "Ambiguous correctness failures MUST
##   fail closed: reject cache reuse, rerun, or require review rather
##   than silently accepting stale state."
## * Compiles-Are-Normal-Edges.md:269-273 — "An edge with no dependency
##   evidence that is also cacheable is worse than an uncached one: it
##   would publish and serve entries keyed on inputs it never observed,
##   and fail by returning a stale binary rather than by erroring".
##
## The three properties, and why all three are needed together:
##
##   1. zero observations   => the edge does NOT publish, so it re-runs.
##   2. one observation     => the edge DOES publish and is reused.
##   3. a non-cacheable edge is unaffected (it never published anyway).
##
## (1) alone would also pass against an engine that never caches
## anything; (2) is what makes it mean something, and is the regression
## guard for the whole class of edges that "make a zero-output edge
## cacheable" exists to serve.

import std/[os, strutils, unittest]

import repro_build_engine
import repro_core
import repro_hash
import repro_local_store
import io_mon/[types, writer]

const TmpDir = "build/test-tmp/t_zero_evidence_edge_is_not_cacheable"
const ReuseDecisions = {cdHit, cdHybridCutoff}

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("zero-evidence-edge." & name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

type Fixture = object
  root: string
  workRoot: string
  cacheRoot: string
  rmdfPath: string
  runLogPath: string
  observedPath: string

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
    rmdfPath: workRoot / "observed.rdep",
    runLogPath: workRoot / "runs.log",
    observedPath: workRoot / "observed.txt")
  writeFile(result.observedPath, "generation-1\n")

proc writeRmdf(f: Fixture; records: seq[MonitorRecord]) =
  ## io-mon's own canonical encoder, so the production reader validates
  ## magic, version, framing, sequence numbers and trailer checksum
  ## exactly as it does for a monitor-written file.
  writeFile(f.rmdfPath, cast[string](encodeCanonical(records)))

proc processRecord(): MonitorRecord =
  ## A record that carries no file observation. The real monitor emits
  ## these alongside the file ones; on their own they say "the monitored
  ## process started" and nothing about what it depends on.
  MonitorRecord(
    kind: mrProcessStart,
    observationKind: moProcessStart,
    osPid: 4242,
    threadId: 4242)

proc readRecord(path: string): MonitorRecord =
  MonitorRecord(
    kind: mrFileRead,
    observationKind: moFileRead,
    osPid: 4242,
    threadId: 4242,
    path: path)

proc runEdge(f: Fixture; id: string; cacheable = true): BuildAction =
  ## `monitoredAction` preserves a monitor depfile the caller already set
  ## ("direct engine callers may provide a monitor depfile path for
  ## actions that produce RMDF evidence themselves"), so the fixture RMDF
  ## is what `collectEvidence` folds instead of the engine wrapping the
  ## command in the monitor and overwriting it.
  result = action(id,
    ["/bin/sh", "-c", "echo ran >> " & f.runLogPath],
    cwd = f.workRoot,
    inputs = [],
    outputs = [],
    cacheable = cacheable,
    weakFingerprint = weak(id),
    actionCachePolicy = ffpHybrid,
    dependencyPolicy = automaticMonitorGatheringPolicy(),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  result.monitorDepfile = f.rmdfPath

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

suite "an edge that observed nothing is not cacheable":

  test "zero observations: the edge does not publish and re-runs":
    let f = makeFixture("zero")
    defer: removeDir(f.root)
    f.writeRmdf(@[processRecord()])
    let act = f.runEdge("zero-evidence/run")
    let g = graph([act])
    let config = testConfig(f.cacheRoot)

    let first = runBuild(g, config)
    let r0 = first.byId(act.id)
    checkpoint("first: status=" & $r0.status &
      " reads=" & $r0.evidence.monitorReads.len &
      " writes=" & $r0.evidence.monitorWrites.len &
      " probes=" & $r0.evidence.monitorProbes.len)
    # The action still SUCCEEDS. Failing a monitored exit-0 action to
    # punish its monitor is the arm of Monitor-Hook-Shim.md:501 this
    # deliberately does not take.
    check r0.status == asSucceeded
    check r0.launched
    check f.runCount() == 1

    # Denominator: the evidence really is empty, or the assertions below
    # would be about something else entirely.
    check r0.evidence.monitorReads.len == 0
    check r0.evidence.monitorWrites.len == 0
    check r0.evidence.monitorProbes.len == 0

    # The diagnostic has to name the reason, because `repro why` is how
    # an operator finds out why this edge never caches.
    let diagnosed = r0.evidence.diagnostics.join(" ")
    checkpoint("diagnostics: " & diagnosed)
    check diagnosed.contains("no observation of any kind")

    # Nothing was published, so there is nothing to be reused.
    check not f.hasRecord(act)

    let warm = runBuild(g, config)
    let r1 = warm.byId(act.id)
    checkpoint("warm: decision=" & $r1.cacheDecision &
      " launched=" & $r1.launched & " reason=" & r1.reason)
    check r1.cacheDecision notin ReuseDecisions
    check r1.launched
    check f.runCount() == 2

  test "one observation: the edge publishes and is reused":
    # The narrowness guard. A single recorded read is enough to make the
    # record mean something, and such an edge must keep the reuse that
    # making zero-output edges cacheable was for.
    let f = makeFixture("one")
    defer: removeDir(f.root)
    f.writeRmdf(@[processRecord(), readRecord(f.observedPath)])
    let act = f.runEdge("one-observation/run")
    let g = graph([act])
    let config = testConfig(f.cacheRoot)

    let first = runBuild(g, config)
    let r0 = first.byId(act.id)
    checkpoint("first: status=" & $r0.status &
      " reads=" & $r0.evidence.monitorReads.len)
    check r0.status == asSucceeded
    check r0.evidence.monitorReads.len == 1
    check f.runCount() == 1
    check f.hasRecord(act)

    let warm = runBuild(g, config)
    let r1 = warm.byId(act.id)
    checkpoint("warm: decision=" & $r1.cacheDecision &
      " launched=" & $r1.launched)
    check r1.cacheDecision in ReuseDecisions
    check not r1.launched
    check f.runCount() == 1

    # ... and it still invalidates on the observation it recorded, so the
    # reuse above is not reuse-of-anything.
    writeFile(f.observedPath, "generation-2-longer\n")
    let after = runBuild(g, config)
    let r2 = after.byId(act.id)
    checkpoint("after changing the observed file: decision=" &
      $r2.cacheDecision & " launched=" & $r2.launched)
    check r2.cacheDecision notin ReuseDecisions
    check r2.launched
    check f.runCount() == 2

  test "a non-cacheable edge is unaffected":
    # The guard must not turn a `cacheable = false` edge — the sanctioned
    # home for actions with no monitorable evidence — into a failure or a
    # new diagnostic. It never published, so there is nothing to skip.
    let f = makeFixture("noncacheable")
    defer: removeDir(f.root)
    f.writeRmdf(@[processRecord()])
    let act = f.runEdge("non-cacheable/run", cacheable = false)
    let g = graph([act])
    let config = testConfig(f.cacheRoot)

    let first = runBuild(g, config)
    let r0 = first.byId(act.id)
    checkpoint("first: status=" & $r0.status &
      " diagnostics=" & $r0.evidence.diagnostics.len)
    check r0.status == asSucceeded
    check r0.evidence.diagnostics.len == 0
    check f.runCount() == 1

    check runBuild(g, config).byId(act.id).status == asSucceeded
    check f.runCount() == 2
