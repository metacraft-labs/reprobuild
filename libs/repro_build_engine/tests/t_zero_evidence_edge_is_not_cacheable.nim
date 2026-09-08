## An action whose monitor reported success while recording NO
## observation of any kind must not publish an action-cache record.
##
## MOCK POLICY — ONE justified stand-in, named and bounded below.
## The scheduler (`runBuild`), the evidence collector (`collectEvidence`,
## `foldMonitorDepFileEvidence`), the per-edge `ActionCache`, the CAS,
## the fingerprinting in `repro_local_store`, the subprocess and the
## files are all the production ones. What is supplied here is the iomon
## the action is fingerprinted against: it is written with io-mon's OWN
## canonical encoder (`io_mon/writer.encodeCanonical`), prefixed with this
## host's real backend profile from io-mon's OWN
## `profileRecords(defaultHooksMonitorProfile())`, and read back by
## the production reader, so the FILE is real — it is its CONTENT that
## is chosen rather than observed. See `writeRmdf` for why the profile
## records are not optional: without them the edge fails closed on the
## entropy-observability policy instead, and this suite grades a decision
## it did not make.
##
## That is unavoidable, and the reason is itself a finding. Measured on
## this host with the real monitor:
##
##   * `env true` (touches no file of its own): 33 records, 18 of them
##     `mrLibraryLoad` covering 14 distinct paths, `mesComplete`, and —
##     once library loads are folded as reads — 14 recorded inputs.
##     Not zero.
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
## produce the state would assert nothing, forever.
##
## THAT IS A PROPERTY OF THE PLATFORM, NOT OF THE GUARD, and it does not
## hold everywhere: Windows' shim emits no library-load records at all
## (measured by emission-site count in the io-mon sibling —
## `shim/linux_preload.nim` 2, `shim/macos_interpose.nim` 2,
## `shim/windows_interpose.nim` 0), so there an ordinary monitored action
## that performs no interposed read, probe or write reaches the guard for
## real and stops publishing permanently. The behaviour is still the
## fail-closed one; what changes is that it becomes reachable, so it has
## to say so. `MonitorHasLibraryLoadFloor` makes that condition explicit
## instead of an accident of which shim is compiled in, and the
## diagnostic suite below grades BOTH regimes on whatever host runs it —
## the no-floor message is the one that matters operationally and is
## exactly the one a `when`-guarded literal would ship untested.
##
## The state is still worth guarding — it is what a backend that reports success while
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
##
## (2) EARNED ITS KEEP, and the way it did is worth recording. When a
## LATER, unrelated policy — M6's entropy-observability gate — began
## refusing the publish for every capture whose backend profile was
## missing, this fixture had no profile record, so (1) went on passing
## while the guard it names had stopped deciding anything. (2) is what
## went red: an edge with one recorded read stopped being reused. Any
## global fail-closed rule that swallows this suite's subject shows up
## there first, which is why the narrowness arm is not optional.

import std/[os, strutils, unittest]

import repro_build_engine
import repro_core
import repro_core/paths as corepaths
import repro_depfile
import repro_hash
import repro_local_store
import io_mon/[types, writer, capabilities]

const TmpDir = "build/test-tmp/t_zero_evidence_edge_is_not_cacheable"
const ReuseDecisions = {cdHit, cdHybridCutoff}

const RootImage = "/bin/sh"
  ## `runEdge`'s `argv[0]`, and therefore the path the LAUNCHER contributes
  ## through `foldLauncherRootImage` — the action's own root image, which no
  ## monitor record can supply. It is in `monitorReads` of every edge here and
  ## is named rather than counted, so that a change to what the engine folds
  ## from its own bookkeeping fails on the IDENTITY of the extra entry instead
  ## of being absorbed by moving a number. What must NOT change silently is
  ## that this contribution cannot answer "did the monitor observe anything?";
  ## the first test below is what holds that.

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
  makeDepfilePath: string
  pathSetPath: string

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
    rmdfPath: workRoot / "observed.iomon",
    runLogPath: workRoot / "runs.log",
    observedPath: workRoot / "observed.txt",
    makeDepfilePath: workRoot / "deps.d",
    pathSetPath: workRoot / "converted.pathset")
  writeFile(result.observedPath, "generation-1\n")

proc writeRmdf(f: Fixture; records: seq[MonitorRecord]) =
  ## io-mon's own canonical encoder, so the production reader validates
  ## magic, version, framing, sequence numbers and trailer checksum
  ## exactly as it does for a monitor-written file.
  ##
  ## The capture is PREFIXED with this host's real backend profile, taken from
  ## io-mon's own `profileRecords(defaultHooksMonitorProfile())` — the same
  ## call the monitor makes — because every capture the monitor writes carries
  ## one and the engine reads it.
  ##
  ## Without it the edge never reaches the guard under test. A capture with no
  ## `mrBackendProfile` record leaves `entropyObservability` at `entUnknown`,
  ## and `applyEntropyBlessingPolicy` (Windows-Build-Correctness M6) refuses
  ## the publish on THAT ground — "absence of evidence is not evidence of
  ## absence" — before the zero-evidence question is ever asked. The suite then
  ## reads green on a fixture that is failing closed for an unrelated reason:
  ## the "does not publish" assertions hold no matter what this guard does, and
  ## the "one observation publishes" assertion cannot hold at all. Supplying
  ## the profile is what makes the entropy policy say nothing here, so the only
  ## thing left deciding the publish is the property this file is about.
  ##
  ## These records are META and add no observation: `mrBackendProfile` and
  ## `mrCapabilityGap` carry capability ids in `path`, not paths, and
  ## `foldOneMonitorRecord` routes them to `entropyObservability` only. The
  ## zero case below stays genuinely zero — its checked denominators say so.
  var all = profileRecords(defaultHooksMonitorProfile())
  for record in records:
    all.add(record)
  writeFile(f.rmdfPath, cast[string](encodeCanonical(all)))

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
  ## actions that produce iomon evidence themselves"), so the fixture iomon
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

proc iomonReportEdge(f: Fixture; id: string): BuildAction =
  ## THE OTHER PRODUCER OF MONITOR EVIDENCE, and the reason it is here.
  ##
  ## `collectEvidence` reaches `applyMonitorEvidenceStatus` from TWO places,
  ## not one: the wrapped/hosted monitor arm that `runEdge` above exercises,
  ## and this one — an edge whose own command PRODUCES an `.iomon` capture
  ## which the engine consumes as the edge's evidence
  ## (`IomonFormatName` / `iomonReportPolicy`), instead of monitoring the
  ## orchestrator process. Both arms fold through `foldMonitorDepFileEvidence`
  ## and both ask the zero-evidence question, so the guard has to hold on
  ## both.
  ##
  ## MEASURED, and this is why the case exists rather than being assumed
  ## covered: deleting `applyMonitorEvidenceStatus` from the recognized-report
  ## arm outright left this whole file GREEN. Nothing in the tree drives an
  ## `IomonFormatName` report end to end — `iomonReportPolicy` has call sites
  ## in the DSL and none in any test that builds — so that arm's Level 0-3
  ## handling, the zero-evidence guard included, was graded by nothing at all.
  ## The claim that the launcher's root-image fold runs after "every"
  ## `applyMonitorEvidenceStatus` call was therefore only half checkable.
  ##
  ## The policy is spelled out here rather than imported because the
  ## constructor that builds it (`iomonReportGatheringPolicy`) is private to
  ## `repro_cli_support`; the shape is its shape, and `IomonFormatName` is the
  ## same constant the engine routes on.
  ##
  ## Note also what this edge does NOT get: its policy is not in
  ## `MonitorPolicyKinds`, so `foldLauncherRootImage` contributes nothing to
  ## it. Its `monitorReads` is exactly what the capture said, which is what
  ## makes the assertions below able to name the whole set.
  result = action(id,
    ["/bin/sh", "-c", "echo ran >> " & f.runLogPath],
    cwd = f.workRoot,
    inputs = [],
    outputs = [],
    cacheable = true,
    weakFingerprint = weak(id),
    actionCachePolicy = ffpHybrid,
    dependencyPolicy = DependencyGatheringPolicy(
      kind: dgRecognizedFormat,
      completeness: decComplete,
      recognizedReports: @[
        RecognizedDependencyReportSpec(
          formatName: DependencyFormatName(IomonFormatName),
          outputs: @[ExpectedDependencyFile(
            logicalName: "iomon", path: f.rmdfPath, required: true)],
          completeness: decComplete)]),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc reportValidatedByMonitorEdge(f: Fixture; id: string): BuildAction =
  ## `dgRecognizedFormatValidatedByMonitor` — the SECOND member of
  ## `MonitorPolicyKinds`, and until this case existed the guard was graded on
  ## the first member only.
  ##
  ## WHY THAT GAP WAS LOAD-BEARING RATHER THAN COSMETIC. `runEdge` above is
  ## `dgAutomaticMonitor`; the recognized-report suite is `dgRecognizedFormat`,
  ## which is NOT in `MonitorPolicyKinds` at all, so `foldLauncherRootImage`
  ## contributes nothing to it. Between them they left both "validated by
  ## monitor" kinds — the two policies that carry a monitor capture AND an
  ## author-declared report — with the launcher fold ACTIVE and the guard
  ## UNGRADED. Measured: re-seeding `monitorReads` with the root image before
  ## `applyMonitorEvidenceStatus` for exactly these two kinds reopens the
  ## defect this file is about for two thirds of the monitored policy set, and
  ## every case in this file stayed green.
  ##
  ## The declared report is a make depfile naming a target and NO
  ## prerequisites, so `depfileInputs` stays empty and the only thing that can
  ## answer "did the monitor observe anything?" is the capture. The action
  ## writes it, because `required: true` means a missing report is a different
  ## failure than the one under test.
  result = action(id,
    ["/bin/sh", "-c", "echo ran >> " & f.runLogPath &
      "; printf 'out:\\n' > " & f.makeDepfilePath],
    cwd = f.workRoot,
    inputs = [],
    outputs = [],
    cacheable = true,
    weakFingerprint = weak(id),
    actionCachePolicy = ffpHybrid,
    dependencyPolicy = DependencyGatheringPolicy(
      kind: dgRecognizedFormatValidatedByMonitor,
      completeness: decComplete,
      recognizedReports: @[
        RecognizedDependencyReportSpec(
          formatName: DependencyFormatName(MakeDepfileFormatName),
          outputs: @[ExpectedDependencyFile(
            logicalName: "deps", path: f.makeDepfilePath, required: true)],
          completeness: decComplete)]),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  result.monitorDepfile = f.rmdfPath

proc converterValidatedByMonitorEdge(f: Fixture; id: string;
                                     converterReports = ""): BuildAction =
  ## `dgPostBuildConverterValidatedByMonitor` — the THIRD and last member of
  ## `MonitorPolicyKinds`, graded for the same reason as the one above.
  ##
  ## `converterReports` is the body the converter appends to its
  ## `repro-pathset-v1` output. Empty is the zero case; an `input\t<path>`
  ## line is the narrowness case — and note WHICH channel that line lands in:
  ## `addPathSet(recognized = false)` folds a converter's declared inputs into
  ## `monitorReads`, the same seq the monitor's own observations use. So this
  ## arm also pins that a converter-reported path is accepted as evidence,
  ## which is a deliberate, spec'd decision ("an action with one recorded
  ## probe has said something about the world") and not the accident this file
  ## exists to prevent. Recording it here means a future change to that
  ## decision fails a test that names it.
  result = action(id,
    ["/bin/sh", "-c", "echo ran >> " & f.runLogPath],
    cwd = f.workRoot,
    inputs = [],
    outputs = [],
    cacheable = true,
    weakFingerprint = weak(id),
    actionCachePolicy = ffpHybrid,
    dependencyPolicy = DependencyGatheringPolicy(
      kind: dgPostBuildConverterValidatedByMonitor,
      completeness: decComplete,
      postBuildConverters: @[
        PostBuildDependencyConverterSpec(
          converterProcess: directProcess(
            corepaths.normalizedPath("/bin/sh"),
            ["-c", "printf 'repro-pathset-v1\\n" & converterReports & "' > " &
              f.pathSetPath],
            corepaths.normalizedPath(f.workRoot)),
          outputs: @[ExpectedDependencyFile(
            logicalName: "path-set", path: f.pathSetPath, required: true)],
          outputKind: dcoReproPathSet,
          outputFormatName: DependencyFormatName(ReproPathSetFormatName),
          completeness: decComplete)]),
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

    # Denominator: the OBSERVED evidence really is empty, or the
    # assertions below would be about something else entirely.
    #
    # `monitorReads` is not empty and must not be: it carries the one path
    # the LAUNCHER contributes, the action's own root image. That entry is a
    # reconstruction from `argv[0]`, not something the monitor saw, and it is
    # present for every action whose image resolves — so it is named here,
    # exactly, rather than budgeted for by a bumped count. If the engine ever
    # answers "the monitor observed something" with an entry of its own again,
    # this equality fails on the identity of the entry, and the publish
    # assertions below fail with it.
    check r0.evidence.monitorReads == @[RootImage]
    check r0.evidence.monitorWrites.len == 0
    check r0.evidence.monitorProbes.len == 0

    # The diagnostic has to name the reason, because `repro why` is how
    # an operator finds out why this edge never caches.
    let diagnosed = r0.evidence.diagnostics.join(" ")
    checkpoint("diagnostics: " & diagnosed)
    check diagnosed.contains("no observation of any kind")
    # It must also name the ACTION, because a build with hundreds of
    # edges gives an operator nothing to act on otherwise.
    check diagnosed.contains(act.id)

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
    # The one observed read PLUS the launcher's root image, named in both
    # positions: what makes this edge publish has to be the OBSERVATION, and
    # an assertion that only counted would keep passing if the observation
    # were dropped and a second engine-side entry took its place.
    #
    # The image is LAST, and that is the visible half of the fix: it is
    # contributed after the evidence question is asked, so moving it back in
    # front of `applyMonitorEvidenceStatus` reorders this seq and fails here
    # as well as in the zero case above.
    check r0.evidence.monitorReads == @[f.observedPath, RootImage]
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

suite "the same guard holds on the recognized-report evidence arm":
  ## `collectEvidence` has a second `applyMonitorEvidenceStatus` call site and
  ## it decides the same thing for a different class of edge. Graded here so
  ## that "the guard is armed" is a statement about the engine rather than
  ## about one launch path.

  test "zero observations in a produced .iomon: the edge does not publish":
    let f = makeFixture("report-zero")
    defer: removeDir(f.root)
    f.writeRmdf(@[processRecord()])
    let act = f.iomonReportEdge("report-zero-evidence/run")
    let g = graph([act])
    let config = testConfig(f.cacheRoot)

    let first = runBuild(g, config)
    let r0 = first.byId(act.id)
    checkpoint("first: status=" & $r0.status &
      " reads=" & $r0.evidence.monitorReads.len &
      " diagnostics=" & r0.evidence.diagnostics.join(" | "))
    check r0.status == asSucceeded
    check f.runCount() == 1
    # Genuinely empty, and on this arm there is no launcher contribution to
    # subtract: the whole observed set is what the capture carried.
    check r0.evidence.monitorReads.len == 0
    check r0.evidence.monitorWrites.len == 0
    check r0.evidence.monitorProbes.len == 0
    check r0.evidence.depfileInputs.len == 0

    let diagnosed = r0.evidence.diagnostics.join(" ")
    check diagnosed.contains("no observation of any kind")
    check diagnosed.contains(act.id)
    check not f.hasRecord(act)

    let warm = runBuild(g, config)
    let r1 = warm.byId(act.id)
    checkpoint("warm: decision=" & $r1.cacheDecision &
      " launched=" & $r1.launched)
    check r1.cacheDecision notin ReuseDecisions
    check r1.launched
    check f.runCount() == 2

  test "one observation in a produced .iomon: the edge publishes and is reused":
    # The narrowness arm again, on this arm. Without it, "does not publish"
    # would also be satisfied by an engine that refused every edge of this
    # class for some unrelated reason.
    let f = makeFixture("report-one")
    defer: removeDir(f.root)
    f.writeRmdf(@[processRecord(), readRecord(f.observedPath)])
    let act = f.iomonReportEdge("report-one-observation/run")
    let g = graph([act])
    let config = testConfig(f.cacheRoot)

    let first = runBuild(g, config)
    let r0 = first.byId(act.id)
    checkpoint("first: status=" & $r0.status &
      " reads=" & $r0.evidence.monitorReads)
    check r0.status == asSucceeded
    check r0.evidence.monitorReads == @[f.observedPath]
    check f.runCount() == 1
    check f.hasRecord(act)

    let warm = runBuild(g, config)
    let r1 = warm.byId(act.id)
    checkpoint("warm: decision=" & $r1.cacheDecision &
      " launched=" & $r1.launched)
    check r1.cacheDecision in ReuseDecisions
    check f.runCount() == 1

suite "the guard holds for every monitored policy kind, not just the first":
  ## `foldLauncherRootImage` is scoped to `MonitorPolicyKinds`, which has
  ## THREE members. The suites above grade `dgAutomaticMonitor` (where the
  ## fold is active) and `dgRecognizedFormat` (where it is not). These two
  ## cases are the remaining members — the ones that carry BOTH a monitor
  ## capture and an author-declared report — so "the launcher's contribution
  ## cannot answer the monitor's question" is a statement about the scope of
  ## the fold rather than about one policy that happens to be tested.
  ##
  ## MEASURED, which is why they exist: re-seeding `monitorReads` before
  ## `applyMonitorEvidenceStatus` for exactly `{dgRecognizedFormat` &
  ## `ValidatedByMonitor, dgPostBuildConverterValidatedByMonitor}` — the
  ## original defect, narrowed to the two kinds nothing covered — left every
  ## other case in this file green.

  test "recognized-format-validated-by-monitor: zero observations do not publish":
    let f = makeFixture("validated-report-zero")
    defer: removeDir(f.root)
    f.writeRmdf(@[processRecord()])
    let act = f.reportValidatedByMonitorEdge("validated-report-zero/run")
    let g = graph([act])
    let config = testConfig(f.cacheRoot)

    let first = runBuild(g, config)
    let r0 = first.byId(act.id)
    checkpoint("first: status=" & $r0.status &
      " reads=" & $r0.evidence.monitorReads &
      " depfileInputs=" & $r0.evidence.depfileInputs &
      " diagnostics=" & r0.evidence.diagnostics.join(" | "))
    check r0.status == asSucceeded
    check f.runCount() == 1
    # The declared report contributed no prerequisite, so the launcher's
    # root image is again the whole of `monitorReads` and nothing else has
    # said anything about the world.
    check r0.evidence.monitorReads == @[RootImage]
    check r0.evidence.depfileInputs.len == 0
    check r0.evidence.monitorWrites.len == 0
    check r0.evidence.monitorProbes.len == 0

    let diagnosed = r0.evidence.diagnostics.join(" ")
    check diagnosed.contains("no observation of any kind")
    check diagnosed.contains(act.id)
    check not f.hasRecord(act)

    let warm = runBuild(g, config)
    let r1 = warm.byId(act.id)
    checkpoint("warm: decision=" & $r1.cacheDecision)
    check r1.cacheDecision notin ReuseDecisions
    check r1.launched
    check f.runCount() == 2

  test "recognized-format-validated-by-monitor: one observation publishes":
    let f = makeFixture("validated-report-one")
    defer: removeDir(f.root)
    f.writeRmdf(@[processRecord(), readRecord(f.observedPath)])
    let act = f.reportValidatedByMonitorEdge("validated-report-one/run")
    let g = graph([act])
    let config = testConfig(f.cacheRoot)

    let first = runBuild(g, config)
    let r0 = first.byId(act.id)
    checkpoint("first: reads=" & $r0.evidence.monitorReads)
    check r0.status == asSucceeded
    # Observation first, launcher reconstruction last — the same ordering the
    # `dgAutomaticMonitor` case pins, asserted again on the policy kind where
    # BOTH `applyMonitorEvidenceStatus` producers can run.
    check r0.evidence.monitorReads == @[f.observedPath, RootImage]
    check f.hasRecord(act)
    check f.runCount() == 1

    let warm = runBuild(g, config)
    check warm.byId(act.id).cacheDecision in ReuseDecisions
    check f.runCount() == 1

  test "converter-validated-by-monitor: zero observations do not publish":
    let f = makeFixture("validated-converter-zero")
    defer: removeDir(f.root)
    f.writeRmdf(@[processRecord()])
    let act = f.converterValidatedByMonitorEdge("validated-converter-zero/run")
    let g = graph([act])
    let config = testConfig(f.cacheRoot)

    let first = runBuild(g, config)
    let r0 = first.byId(act.id)
    checkpoint("first: status=" & $r0.status &
      " reads=" & $r0.evidence.monitorReads &
      " diagnostics=" & r0.evidence.diagnostics.join(" | "))
    check r0.status == asSucceeded
    check f.runCount() == 1
    check r0.evidence.monitorReads == @[RootImage]
    check r0.evidence.depfileInputs.len == 0
    check r0.evidence.monitorWrites.len == 0
    check r0.evidence.monitorProbes.len == 0

    let diagnosed = r0.evidence.diagnostics.join(" ")
    check diagnosed.contains("no observation of any kind")
    check diagnosed.contains(act.id)
    check not f.hasRecord(act)

    let warm = runBuild(g, config)
    let r1 = warm.byId(act.id)
    check r1.cacheDecision notin ReuseDecisions
    check r1.launched
    check f.runCount() == 2

  test "converter-validated-by-monitor: one converted input publishes":
    let f = makeFixture("validated-converter-one")
    defer: removeDir(f.root)
    f.writeRmdf(@[processRecord()])
    let act = f.converterValidatedByMonitorEdge("validated-converter-one/run",
      converterReports = "input\\t" & f.observedPath & "\\n")
    let g = graph([act])
    let config = testConfig(f.cacheRoot)

    let first = runBuild(g, config)
    let r0 = first.byId(act.id)
    checkpoint("first: status=" & $r0.status &
      " reads=" & $r0.evidence.monitorReads &
      " diagnostics=" & r0.evidence.diagnostics.join(" | "))
    check r0.status == asSucceeded
    # The converter's declared input lands in `monitorReads` BEFORE the
    # launcher's reconstruction, and it is what makes this edge publish while
    # the case above does not.
    check r0.evidence.monitorReads == @[f.observedPath, RootImage]
    check f.hasRecord(act)
    check f.runCount() == 1

    let warm = runBuild(g, config)
    check warm.byId(act.id).cacheDecision in ReuseDecisions
    check f.runCount() == 1

suite "the zero-evidence diagnostic names the platform's floor regime":
  ## Both regimes are graded here, on whatever host runs the suite. The
  ## no-floor branch is the operationally important one and is NOT
  ## reachable on Linux or macOS, so if it were a `when`-guarded literal
  ## it would ship untested — which is how the "every process reports the
  ## loader closure" argument came to be applied to a platform where it
  ## is false.

  test "every platform's floor answer is pinned, on any host":
    # io-mon emits `mrLibraryLoad` from `shim/linux_preload.nim` and
    # `shim/macos_interpose.nim`; `shim/windows_interpose.nim` has no
    # emission site.
    #
    # Asserted as DATA, per platform, rather than as `when defined(...)`
    # against the host constant. The `when` form does not work and this
    # is not a stylistic preference: on Linux `defined(linux) or
    # defined(macosx)` and a bare `true` are the same value, so a
    # mutation claiming a floor on EVERY platform — the exact mistake
    # under review — passed a host-conditional assertion. Verified: that
    # mutation survived the `when` form and is caught by this one.
    check monitorShimHasLibraryLoadFloor(mspLinux)
    check monitorShimHasLibraryLoadFloor(mspMacos)
    check not monitorShimHasLibraryLoadFloor(mspWindows)
    # An unknown platform must default to "no floor": claiming a floor we
    # have not verified is the direction that produces a silent permanent
    # non-publish with no diagnostic.
    check not monitorShimHasLibraryLoadFloor(mspUnsupported)
    # ... and the host constant is that function, not a separate literal
    # that could drift from it.
    check MonitorHasLibraryLoadFloor ==
      monitorShimHasLibraryLoadFloor(HostMonitorShimPlatform)

  test "with a library-load floor: the message points at the backend":
    let msg = zeroEvidenceDiagnostic("pkg.some_edge", true)
    checkpoint(msg)
    check msg.contains("pkg.some_edge")
    check msg.contains("no observation of any kind")
    check msg.contains("HAS a library-load floor")
    check msg.contains("suspect the monitor backend")
    # It must NOT tell an operator on a floored platform that the edge
    # will re-run forever; there the state means the backend is lying.
    check not msg.contains("re-run on EVERY build")

  test "without a library-load floor: the message says it is permanent":
    # This is the Windows regime. A silent permanent non-publish is the
    # failure mode under review; the whole point is that it announces
    # itself, names the edge, says the consequence, and says where the
    # real fix belongs.
    let msg = zeroEvidenceDiagnostic("pkg.some_edge", false)
    checkpoint(msg)
    check msg.contains("pkg.some_edge")
    check msg.contains("NO library-load floor")
    check msg.contains("re-run on EVERY build")
    check msg.contains("permanently")
    check msg.contains("cacheable = false")
    # The remedy must point at the shim, not at weakening this guard —
    # scoping the guard off a platform with no floor would hand that
    # platform the original soundness hole with no signal.
    check msg.contains("not a weaker guard here")
    check not msg.contains("suspect the monitor backend")
