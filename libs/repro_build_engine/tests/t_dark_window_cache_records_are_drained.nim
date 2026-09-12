## Records published while the no-evidence publish guard was dark are not
## servable, and a record that is keyed on nothing is never servable.
##
## MOCK POLICY — NO MOCKS, DOUBLES OR FAKES ARE USED IN THIS FILE, AND NONE
## MAY BE ADDED. Every assertion drives the real `runBuild` scheduler, the
## real per-edge `ActionCache` and CAS in `repro_local_store`, the real
## on-disk codec, a real `/bin/sh` subprocess and real files. The one thing
## that is CONSTRUCTED rather than observed is the byte content of a
## pre-epoch record file — and it is constructed by taking the container the
## production encoder just wrote and rewriting the two version bytes of each
## frame with the production tail checksum recomputed, which is exactly what
## an older binary's file looks like. There is no other way to obtain one:
## this binary cannot write a version it refuses to read.
##
## WHY THIS FILE EXISTS
## ---------------------------------------------------------------------
## Between 2026-09-02 03:44 and 2026-09-08 18:32 — 6 days 15 hours — the
## engine contributed a path to an OBSERVED evidence channel from its own
## bookkeeping before asking whether the monitor had observed anything. The
## guard that refuses to publish an action-cache record for an action that
## observed nothing could not fire in that window. `832f5fa2` fixed the
## ordering; it did NOT reach the entries already published, and measurement
## confirmed it could not:
##
##   pre-fix engine  publish zero-observation edge -> record present,
##                   recordInputs = ["/bin/sh"], no diagnostic
##   post-fix engine consume the same cache root   -> cdHit, launched=false
##
## Lookup is by weak fingerprint, happens BEFORE the action runs (so there is
## no evidence to gate on), and re-derives the strong fingerprint from the
## record's OWN input list — so a record's internal consistency is all that
## is ever checked and an old record keeps validating against itself.
##
## THE TWO REMEDIATIONS, AND WHY IT TAKES TWO
## ---------------------------------------------------------------------
## 1. AN EPOCH (`ActionRecordVersionEvidenceEpoch` = 6, the first version
##    written by a binary whose guard fires; 2, 3, 4 and 5 are all refused).
##    Temporal, total.
##    It is the only sound way to reach the already-published entries,
##    because there is no predicate that recognises them: what identifies one
##    — "the monitor observed nothing" — was never written into the record.
##    The reconstruction and the observation were merged into a single input
##    list at publish time, and Dependency-Observation-Attribution.md rule 6
##    is exactly that once merged nothing downstream can separate them. A
##    record whose inputs are `["/bin/sh"]` because the engine reconstructed
##    it is byte-identical to one whose inputs are `["/bin/sh"]` because a
##    process really read it. So the discriminator has to be WHEN, and the
##    version is the record's only durable "when".
##
## 2. A LOOKUP-TIME REFUSAL (`unservableCacheRecordReason`). Positional, and
##    narrow: a record with no input fingerprints AND no environment inputs
##    is keyed on the weak fingerprint alone, has nothing to revalidate, and
##    would be served on every future build no matter what changed. The epoch
##    cannot see such a record if a FUTURE publisher writes one; this can,
##    and it also grades records arriving from a LAN peer or a binary cache,
##    which never pass the publish-side guard at all.
##
## Neither subsumes the other. (1) reaches the past and cannot reach the
## future; (2) reaches the future and cannot recognise the past.
##
## Governing spec text:
##
## * Failure-Semantics.md:11-12 — "Ambiguous correctness failures MUST fail
##   closed: reject cache reuse, rerun, or require review rather than
##   silently accepting stale state."
## * Reprobuild-Development.milestones.org:719-724 (M17) — an action with no
##   monitorable evidence "is NEVER marked complete-on-declared-inputs".
## * Compiles-Are-Normal-Edges.md:269-273 — such an edge "would publish and
##   serve entries keyed on inputs it never observed, and fail by returning a
##   stale binary rather than by erroring".

import std/[os, strutils, unittest]

import repro_build_engine
import repro_core
import repro_depfile
import repro_hash
import repro_local_store
import io_mon/[types, writer, capabilities]

const TmpDir = "build/test-tmp/t_dark_window_cache_records_are_drained"
const ReuseDecisions = {cdHit, cdHybridCutoff}

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("dark-window." & name)

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
  createDir(workRoot)
  result = Fixture(
    root: root,
    workRoot: workRoot,
    cacheRoot: root / "cache",
    runLogPath: workRoot / "runs.log",
    observedPath: workRoot / "observed.txt",
    depfilePath: workRoot / "deps.d",
    rmdfPath: workRoot / "observed.iomon")
  writeFile(result.observedPath, "generation-1\n")

proc testConfig(cacheRoot: string): BuildEngineConfig =
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.fallbackToRunQuotaBypass = true
  result.maxParallelism = 1'u32

proc reportingEdge(f: Fixture; id: string): BuildAction =
  ## An edge that publishes a REAL record through the ordinary path, with no
  ## monitor wired.
  ##
  ## `dgRecognizedFormat` with an author-declared make depfile, rather than
  ## the monitored policy the rest of this campaign is about, and that is
  ## deliberate on two counts. It keeps the epoch cases about the RECORD
  ## FORMAT — the drain has to hold for every edge in the tree, not only for
  ## monitored ones — and it needs no io-monitor driver, which a cacheable
  ## `dgAutomaticMonitor` edge would fail without. There is intentionally no
  ## "declared-only" gathering kind to reach for here; see the note in
  ## `repro_core/dependency_gathering.nim` for why.
  result = action(id,
    ["/bin/sh", "-c", "echo ran >> " & f.runLogPath &
      "; printf 'out: " & f.observedPath & "\\n' > " & f.depfilePath],
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
          formatName: DependencyFormatName(MakeDepfileFormatName),
          outputs: @[ExpectedDependencyFile(
            logicalName: "deps", path: f.depfilePath, required: true)],
          completeness: decComplete)]),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc monitoredEdge(f: Fixture; id: string): BuildAction =
  ## A MONITORED cacheable edge, with the capture prewired so `monitoredAction`
  ## leaves the argv alone and folds the fixture iomon (the same technique
  ## `t_zero_evidence_edge_is_not_cacheable` uses, and for the same reason: a
  ## cacheable `dgAutomaticMonitor` edge with no io-monitor driver configured
  ## fails outright, which would decide the case before the predicate did).
  ## The capture carries the host's real backend profile plus one observed
  ## read, so the edge publishes through the ordinary path and the case can
  ## then substitute the record it is about.
  result = action(id,
    ["/bin/sh", "-c", "echo ran >> " & f.runLogPath],
    cwd = f.workRoot,
    inputs = [],
    outputs = [],
    cacheable = true,
    weakFingerprint = weak(id),
    actionCachePolicy = ffpHybrid,
    dependencyPolicy = automaticMonitorGatheringPolicy(),
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  result.monitorDepfile = f.rmdfPath

proc writeRmdf(f: Fixture) =
  ## io-mon's own canonical encoder, prefixed with this host's real backend
  ## profile from io-mon's own `profileRecords(defaultHooksMonitorProfile())`.
  ## The profile is not optional: without an `mrBackendProfile` record the
  ## entropy-observability policy refuses the publish on its own ground and
  ## the edge never reaches the decision under test.
  var all = profileRecords(defaultHooksMonitorProfile())
  all.add(MonitorRecord(kind: mrProcessStart, observationKind: moProcessStart,
    osPid: 4242, threadId: 4242))
  all.add(MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
    osPid: 4242, threadId: 4242, path: f.observedPath))
  writeFile(f.rmdfPath, cast[string](encodeCanonical(all)))

proc recFiles(f: Fixture): seq[string] =
  let hot = f.cacheRoot / "action-cache" / "hot-records"
  if not dirExists(hot):
    return @[]
  for path in walkDirRec(hot):
    if path.endsWith(".rec"):
      result.add(path)

proc rewriteFrameVersions(path: string; newVersion: uint16) =
  ## Rewrite every RBAR frame's version field inside a per-edge container and
  ## recompute the frame's tail checksum, leaving a byte-complete file that a
  ## reader accepting `newVersion` would decode normally.
  ##
  ## The tail MUST be recomputed. `decodePerEdgeFileWithSeq` checks it before
  ## it ever calls the record codec, so a naive two-byte patch stops the read
  ## at the checksum and the case would pass for the wrong reason — it would
  ## be measuring "a torn file is not served", which was never in doubt.
  ##
  ## Container layout (`encodePerEdgeFile`): "RBPE", u16 version, u32 record
  ## count, then per record { u32 length, length bytes of RBAR frame, u32 tail
  ## }, then an optional 8-byte write-sequence trailer. The RBAR frame is
  ## "RBAR" followed by its own u16 version, which is the field rewritten
  ## here.
  var raw = cast[seq[byte]](readFile(path))
  doAssert raw.len > 10
  doAssert raw[0 .. 3] == cast[seq[byte]]("RBPE")
  var pos = 4
  pos += 2                                    # container version
  let count = int(raw[pos].uint32 or (raw[pos + 1].uint32 shl 8) or
    (raw[pos + 2].uint32 shl 16) or (raw[pos + 3].uint32 shl 24))
  pos += 4
  doAssert count > 0, "fixture wrote a container with no records"
  for _ in 0 ..< count:
    let length = int(raw[pos].uint32 or (raw[pos + 1].uint32 shl 8) or
      (raw[pos + 2].uint32 shl 16) or (raw[pos + 3].uint32 shl 24))
    pos += 4
    let frameStart = pos
    doAssert raw[frameStart .. frameStart + 3] == cast[seq[byte]]("RBAR")
    raw[frameStart + 4] = byte(newVersion and 0xff'u16)
    raw[frameStart + 5] = byte((newVersion shr 8) and 0xff'u16)
    pos += length
    let tail = uint32(localHash(raw[frameStart ..< frameStart + length]).value and
      0xffff_ffff'u64)
    raw[pos] = byte(tail and 0xff'u32)
    raw[pos + 1] = byte((tail shr 8) and 0xff'u32)
    raw[pos + 2] = byte((tail shr 16) and 0xff'u32)
    raw[pos + 3] = byte((tail shr 24) and 0xff'u32)
    pos += 4
  writeFile(path, cast[string](raw))

suite "the record epoch makes pre-epoch frames unreadable":

  test "the codec accepts this binary's own frames and refuses every older one":
    # The denominator first: a record this binary writes round-trips. Without
    # it, "the old versions raise" would also hold for a codec that raised on
    # everything.
    let record = ActionResultRecord(
      weakFingerprint: weak("codec"),
      policy: ffpHybrid,
      inputs: @[],
      outputs: @[])
    let encoded = encodeActionResultRecord(record)
    check decodeActionResultRecord(encoded).weakFingerprint == weak("codec")

    # The frame's version is the u16 immediately after the 4-byte magic.
    check encoded[0 .. 3] == cast[seq[byte]]("RBAR")
    # 5 is in this list and is the one that matters: it is what a binary built
    # from mainline writes today, and it was written by a binary whose guard
    # was dead just as surely as 2, 3 and 4 were. An epoch drawn at 5 would
    # have drained the old records and left the recent ones.
    for stale in [2'u16, 3'u16, 4'u16, 5'u16]:
      var patched = encoded
      patched[4] = byte(stale and 0xff'u16)
      patched[5] = byte((stale shr 8) and 0xff'u16)
      expect EnvelopeError:
        discard decodeActionResultRecord(patched)

  test "a pre-epoch record file is a clean MISS, not an error, and the edge re-runs":
    # END TO END, through the real scheduler and the real cache. The record is
    # written by this binary, so the ONLY difference from a servable entry is
    # the frame version — which is precisely the claim the epoch makes.
    let f = makeFixture("epoch-miss")
    defer: removeDir(f.root)
    let act = f.reportingEdge("epoch-miss/run")
    let g = graph([act])
    let config = testConfig(f.cacheRoot)

    check runBuild(g, config).byId(act.id).status == asSucceeded
    check f.runCount() == 1

    # Control: unmodified, this record IS served. If it were not, the
    # assertion after the rewrite would say nothing about the version.
    let warm = runBuild(g, config)
    checkpoint("warm before the rewrite: decision=" &
      $warm.byId(act.id).cacheDecision)
    check warm.byId(act.id).cacheDecision in ReuseDecisions
    check not warm.byId(act.id).launched
    check f.runCount() == 1

    let files = f.recFiles()
    checkpoint("per-edge record files: " & $files.len)
    check files.len == 1
    for path in files:
      # Rewritten to 5, the version mainline writes today, so this case is the
      # realistic upgrade: a cache warmed by the CURRENT binary must drain.
      rewriteFrameVersions(path, 5'u16)

    # The file is still byte-complete and its checksums still match — it is
    # simply a version this binary refuses. The reader must turn that into a
    # miss and the edge must re-execute, not fail.
    let after = runBuild(g, config)
    let r = after.byId(act.id)
    checkpoint("after the rewrite: status=" & $r.status &
      " decision=" & $r.cacheDecision & " launched=" & $r.launched)
    check r.status == asSucceeded
    check r.cacheDecision notin ReuseDecisions
    check r.launched
    check f.runCount() == 2

    # ... and the edge is reusable again once it has republished at the
    # current version, so the epoch is a drain and not a permanent miss.
    let settled = runBuild(g, config)
    checkpoint("settled: decision=" & $settled.byId(act.id).cacheDecision)
    check settled.byId(act.id).cacheDecision in ReuseDecisions
    check f.runCount() == 2

  test "a pre-epoch file is not readable through the cache API either":
    # The scheduler is one consumer. `readHotRecord` is what `repro why`, the
    # shm warm path and the peer-cache installer go through, so the drain has
    # to hold there too rather than being a property of one call path.
    let f = makeFixture("epoch-api")
    defer: removeDir(f.root)
    let act = f.reportingEdge("epoch-api/run")
    check runBuild(graph([act]), testConfig(f.cacheRoot)).byId(act.id).status ==
      asSucceeded

    block:
      var cache = openActionCache(f.cacheRoot / "action-cache")
      check cache.readHotRecord(act.weakFingerprint).found

    for path in f.recFiles():
      rewriteFrameVersions(path, 4'u16)

    block:
      var cache = openActionCache(f.cacheRoot / "action-cache")
      check not cache.readHotRecord(act.weakFingerprint).found
      check cache.loadPerEdgeRecords(act.weakFingerprint).len == 0

suite "a record keyed on nothing is refused at lookup":
  ## `unservableCacheRecordReason`. Scoped to monitored cacheable process
  ## edges, and each of the three scope conditions gets a case, because the
  ## scope is what a later contributor edits and a predicate that is too
  ## broad here turns legitimate built-in and declared-input edges into
  ## permanent misses.

  test "the reason names the edge and says what is wrong with the record":
    let monitored = action("pkg.monitored",
      ["/bin/sh", "-c", "true"],
      cacheable = true,
      dependencyPolicy = automaticMonitorGatheringPolicy(),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    let empty = ActionResultRecord(
      weakFingerprint: weak("empty"), policy: ffpHybrid)
    let reason = monitored.unservableCacheRecordReason(empty)
    checkpoint(reason)
    check reason.contains("pkg.monitored")
    check reason.contains("no recorded inputs")
    check reason.contains("weak fingerprint alone")
    check reason.contains("Re-running")

  test "one recorded input, or one recorded env input, is enough to serve":
    # The narrowness arm. Without it "refuses the empty record" would also
    # hold for a predicate that refused every record, which would disable the
    # action cache for every monitored edge in the tree.
    let monitored = action("pkg.monitored",
      ["/bin/sh", "-c", "true"],
      cacheable = true,
      dependencyPolicy = automaticMonitorGatheringPolicy(),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    let withInput = ActionResultRecord(
      weakFingerprint: weak("one"), policy: ffpHybrid,
      inputs: @[FileFingerprint(path: "/some/observed/file",
        policy: ffpHybrid)])
    check monitored.unservableCacheRecordReason(withInput).len == 0
    let withEnv = ActionResultRecord(
      weakFingerprint: weak("env"), policy: ffpHybrid,
      envInputs: @[EnvFingerprint(name: "LANG", present: true, value: "C")])
    check monitored.unservableCacheRecordReason(withEnv).len == 0

  test "a non-cacheable edge, a built-in edge and a declared-input edge are all exempt":
    # The three scope conditions, one assertion each.
    let empty = ActionResultRecord(
      weakFingerprint: weak("empty"), policy: ffpHybrid)

    let nonCacheable = action("pkg.non_cacheable",
      ["/bin/sh", "-c", "true"],
      cacheable = false,
      dependencyPolicy = automaticMonitorGatheringPolicy(),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    check nonCacheable.unservableCacheRecordReason(empty).len == 0

    # A built-in action legitimately has no file inputs: it is keyed on text
    # its caller mixed into the weak fingerprint. Refusing it would make
    # write-text, copy-file and stamp edges permanent misses.
    let builtin = builtinAction(bakWriteText, "pkg.write_text",
      outputs = ["out.txt"], text = "hello",
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    check builtin.unservableCacheRecordReason(empty).len == 0

    # An edge whose evidence comes from a report its AUTHOR declared owns that
    # set; `dgRecognizedFormat` is not in `MonitorPolicyKinds`, the engine
    # never promised to discover its inputs, and an empty set there is the
    # author's statement rather than the engine's failure to observe.
    let reported = action("pkg.reported",
      ["/bin/sh", "-c", "true"],
      cacheable = true,
      dependencyPolicy = DependencyGatheringPolicy(
        kind: dgRecognizedFormat, completeness: decComplete),
      governingLockIdentity = lockIdentityOutsideSolvedGraph())
    check reported.unservableCacheRecordReason(empty).len == 0

  test "every monitored policy kind is graded, not just the first":
    # Rule 8: the predicate is scoped to `MonitorPolicyKinds`, which has three
    # members, and the member list is what a later contributor edits.
    let empty = ActionResultRecord(
      weakFingerprint: weak("empty"), policy: ffpHybrid)
    for kind in [dgAutomaticMonitor, dgRecognizedFormatValidatedByMonitor,
                 dgPostBuildConverterValidatedByMonitor]:
      let act = action("pkg.kind_" & $kind,
        ["/bin/sh", "-c", "true"],
        cacheable = true,
        dependencyPolicy = DependencyGatheringPolicy(
          kind: kind, completeness: decComplete),
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      checkpoint($kind & ": " & act.unservableCacheRecordReason(empty))
      check act.unservableCacheRecordReason(empty).len > 0

suite "the lookup-time refusal is wired into the scheduler, not only defined":
  ## THE PREDICATE ABOVE IS A PURE FUNCTION AND A PURE FUNCTION NOTHING CALLS
  ## DECIDES NOTHING. That is the shape of defect this whole campaign is
  ## about — a guard that existed and could not fire — so the wiring gets its
  ## own end-to-end case rather than being assumed from the definition.
  ##
  ## The record substituted here is the shape an OLDER binary or a LAN peer
  ## can still hand this engine: a monitored cacheable edge's record with an
  ## empty input set. The current engine will not publish one
  ## (`gradeKeyedInputSet` refuses), which is exactly why the case has to
  ## write it directly through the cache API rather than provoke it.

  test "a substituted no-input record is refused and the edge re-executes":
    let f = makeFixture("lookup-refusal")
    defer: removeDir(f.root)
    f.writeRmdf()
    let act = f.monitoredEdge("lookup-refusal/run")
    let g = graph([act])
    let config = testConfig(f.cacheRoot)

    check runBuild(g, config).byId(act.id).status == asSucceeded
    check f.runCount() == 1

    # CONTROL. The edge publishes and is reused. Without this, the assertion
    # after the substitution would also pass against an engine that never
    # cached this edge at all.
    let warm = runBuild(g, config)
    checkpoint("warm before the substitution: decision=" &
      $warm.byId(act.id).cacheDecision)
    check warm.byId(act.id).cacheDecision in ReuseDecisions
    check not warm.byId(act.id).launched
    check f.runCount() == 1

    # Substitute a record with NO inputs under the same weak fingerprint.
    block:
      var cas = openLocalCas(f.cacheRoot / "cas")
      var cache = openActionCache(f.cacheRoot / "action-cache")
      let poisoned = cache.recordActionResult(cas, act.weakFingerprint,
        act.actionCachePolicy, [], [], act.cwd)
      cache.writePerEdgeRecords(act.weakFingerprint, @[poisoned])
    block:
      var cache = openActionCache(f.cacheRoot / "action-cache")
      let hot = cache.readHotRecord(act.weakFingerprint)
      # The denominator: the record IS present and IS internally consistent,
      # so nothing but the refusal can stop it being served.
      check hot.found
      check hot.record.inputs.len == 0
      check hot.record.envInputs.len == 0

    let after = runBuild(g, config)
    let r = after.byId(act.id)
    checkpoint("after the substitution: status=" & $r.status &
      " decision=" & $r.cacheDecision & " launched=" & $r.launched)
    check r.status == asSucceeded
    check r.cacheDecision notin ReuseDecisions
    check r.launched
    check f.runCount() == 2

  test "the whole-graph shortcut refuses it too, on its evidence-skipping arm":
    ## TWO ARMS, AND THE ONE THE CLI ACTUALLY USES IS THE SECOND CASE HERE.
    ##
    ## `tryFastNoopCacheHits` decides "nothing in this graph needs to run"
    ## without ever entering the scheduler, so the per-edge refusal at the
    ## `lookupActionResult` seam is not on that path at all. It has two arms:
    ## one that loads each record (`skipCacheHitEvidence = false`, exercised
    ## by the case above, which falls back to the scheduler) and one that
    ## batches the whole graph into `scanHotIndexMetadataInputsUnchanged`
    ## (`skipCacheHitEvidence = true`).
    ##
    ## The second is the DEFAULT on the main CLI path
    ## (`repro_cli_support`'s engine config passes `skipCacheHitEvidence =
    ## true`), so a guard graded only by the case above would be a guard
    ## production does not execute — which is the exact shape of defect this
    ## file exists about. Measured while writing it: with the refusal wired
    ## only at the lookup seam, the substituted record was served as `cdHit`,
    ## `launched = false`.
    let f = makeFixture("lookup-refusal-fast")
    defer: removeDir(f.root)
    f.writeRmdf()
    let act = f.monitoredEdge("lookup-refusal-fast/run")
    let g = graph([act])
    var config = testConfig(f.cacheRoot)
    config.skipCacheHitEvidence = true

    check runBuild(g, config).byId(act.id).status == asSucceeded
    check f.runCount() == 1

    let warm = runBuild(g, config)
    checkpoint("warm on the fast arm: decision=" &
      $warm.byId(act.id).cacheDecision & " reason=" & warm.byId(act.id).reason)
    check warm.byId(act.id).cacheDecision in ReuseDecisions
    check not warm.byId(act.id).launched
    check f.runCount() == 1

    block:
      var cas = openLocalCas(f.cacheRoot / "cas")
      var cache = openActionCache(f.cacheRoot / "action-cache")
      let poisoned = cache.recordActionResult(cas, act.weakFingerprint,
        act.actionCachePolicy, [], [], act.cwd)
      cache.writePerEdgeRecords(act.weakFingerprint, @[poisoned])

    let after = runBuild(g, config)
    let r = after.byId(act.id)
    checkpoint("fast arm after the substitution: status=" & $r.status &
      " decision=" & $r.cacheDecision & " launched=" & $r.launched)
    check r.cacheDecision notin ReuseDecisions
    check r.launched
    check f.runCount() == 2
