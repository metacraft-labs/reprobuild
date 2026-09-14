## M9.R.73.2, continued — the session-scoped Level 1 invalidation has to
## reach EVERY way a downstream action can avoid re-running, not just the
## one path it was wired into.
##
## `reprobuild-specs/Monitor-Loss-Path-Invalidation.md` §"Consequences For
## The Engine" states the downstream test against the action's
## **`cacheInputPaths`** — the set the action-cache record is actually
## KEYED on, which is declared inputs PLUS the depfile / monitor-read /
## monitor-probe channels. The scheduler's pre-lookup predicate tests
## `action.inputs`, the DECLARED inputs alone. On an engine whose entire
## premise is that observed reads are the truth and declarations are a
## partial hint, those two sets come apart for exactly the edge this memo
## is about: a downstream action that CONSUMES a Level 1 action's output
## without declaring it. Measured before the fix, `loss-undeclared` below
## was served `cdHit`.
##
## Two escapes are pinned here. Between them they grade three separate
## changes, and each suite goes red if ANY of the three it depends on is
## removed — measured by reverting them one at a time:
##
##   1. LOOKUP.  The record's keyed input set intersects the invalidated
##      set but the action's declared inputs do not. Refused at the
##      `unservableCacheRecordReason` seam, which is the one point every
##      record crosses — local, peer-installed, or binary-cache — on its
##      way to being served.
##   2. REGISTRATION, AND WHAT THE REFUSAL HAS TO SET. The "outputs are
##      present, call it up to date" shortcut collects evidence and never
##      folded it into the session accumulator, so a Level 1 (and, worse,
##      a Level 2) loss observed on an action the engine called up to date
##      invalidated nothing at all for the rest of the session. Folding it
##      is only half: the pre-lookup refusal also has to set
##      `cacheInvalidatedByPolicy`, or that same shortcut re-declares the
##      NEXT action up to date and the refusal produces no re-execution.
##      `--soft-rebuild` guards against exactly this, one branch above the
##      monitor-loss branch, and says so at length; the monitor-loss
##      branch did not.
##
## WHAT IS DELIBERATELY NOT A SEPARATE CASE, because measuring said so: a
## consumer wired to a producer that LAUNCHED never reaches the
## outputs-present shortcut at all — `dependencyLaunched` excludes it —
## and a consumer that DECLARES the invalidated path gets an implicit
## dependency on the producer that wrote it, so it is in that class too. A
## fixture built to isolate `cacheInvalidatedByPolicy` through a cached
## intermediate edge measured `dependencyLaunched = true` anyway and
## graded nothing; it was removed rather than kept as a case whose
## comment described a state it never reached. Case 2 is where the flag
## is actually load-bearing, because there the invalidating action is
## itself the one that did not launch.
##
## MOCK POLICY — one stand-in, the same one `t_zero_evidence_edge_is_not_
## cacheable` justifies at length: the `.iomon` capture is written with
## io-mon's OWN canonical encoder and prefixed with this host's real
## backend profile from io-mon's OWN
## `profileRecords(defaultHooksMonitorProfile())`, then read back by the
## production reader. The FILE is real; its CONTENT is chosen rather than
## observed, because no portable process reliably produces a
## kill-before-flush record on demand. The scheduler, the evidence
## collector, the per-edge `ActionCache`, the CAS and the fingerprinting
## are all the production ones.
##
## EVERY CASE IS PAIRED WITH A NO-LOSS CONTROL. Without them this file
## would also pass against an engine that had simply stopped caching, and
## the one thing a cache-invalidation test must never do is read green
## because nothing is reused any more.

import std/[os, unittest]

import repro_build_engine
import repro_core
import repro_hash
import repro_local_store
import io_mon/[types, writer, capabilities]

const TmpDir = "build/test-tmp/t_m9r73_session_invalidation_reaches_every_consumer"
const ReuseDecisions = {cdHit, cdHybridCutoff}

proc weak(name: string): ContentDigest =
  weakFingerprintFromText("m9r73-session-invalidation." & name)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

proc writeRmdf(path: string; records: seq[MonitorRecord]) =
  ## Written through `writeBuffer` rather than `writeFile` deliberately:
  ## measured on Windows, `writeFile` of a `cast[string]` capture produced
  ## a file LONGER than the encoded blob for some payloads, and the
  ## production reader then failed the edge with "iomon body
  ## length/trailer mismatch" — a fixture defect that reads exactly like
  ## the guard under test firing.
  createDir(path.parentDir)
  var all = profileRecords(defaultHooksMonitorProfile())
  for record in records:
    all.add(record)
  let encoded = encodeCanonical(all)
  var handle: File
  doAssert open(handle, path, fmWrite)
  discard handle.writeBuffer(addr encoded[0], encoded.len)
  handle.close()

proc iomonPolicy(reportPath: string): DependencyGatheringPolicy =
  ## The edge PRODUCES its own capture and the engine consumes it as the
  ## edge's evidence (`IomonFormatName`). Spelled out here rather than
  ## imported because the constructor that builds it is private to
  ## `repro_cli_support`; `IomonFormatName` is the constant the engine
  ## routes on.
  DependencyGatheringPolicy(
    kind: dgRecognizedFormat,
    completeness: decComplete,
    recognizedReports: @[
      RecognizedDependencyReportSpec(
        formatName: DependencyFormatName(IomonFormatName),
        outputs: @[ExpectedDependencyFile(
          logicalName: "iomon", path: reportPath, required: true)],
        completeness: decComplete)])

proc readRecord(path: string): MonitorRecord =
  MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
    osPid: 4242, threadId: 4242, path: path)

proc killBeforeFlush(): MonitorRecord =
  ## The ONE loss class `Monitor-Loss-Path-Invalidation.md` grades Level 1,
  ## spelled with the exact prefix `classifyEventLossDetail` routes on.
  MonitorRecord(kind: mrEventLoss, observationKind: moEventLoss,
    osPid: 4242, threadId: 8484,
    detail: "process killed with an un-flushed read batch (kill-before-flush)")

type Fixture = object
  root: string
  workRoot: string
  seedPath: string
  producedPath: string
  consumerReport: string

proc resetDir(path: string) =
  ## `removeDir` against a tree the previous run of this binary left behind
  ## fails with "the directory is not empty" on Windows while a handle the
  ## kernel has not finished closing still names a file in it. Retried
  ## rather than ignored: a fixture that silently reuses a stale action
  ## cache grades the wrong build.
  if not dirExists(path):
    return
  for attempt in 0 .. 19:
    try:
      removeDir(path)
      return
    except OSError:
      sleep(100)
  removeDir(path)

proc makeFixture(name: string): Fixture =
  let root = absolutePath(TmpDir / name)
  resetDir(root)
  let workRoot = root / "work"
  createDir(workRoot / "src")
  result = Fixture(
    root: root,
    workRoot: workRoot,
    seedPath: workRoot / "src" / "seed.txt",
    producedPath: workRoot / "generated" / "stable.txt",
    consumerReport: workRoot / "consumer.iomon")
  writeFile(result.seedPath, "stable input\n")

proc producerReport(f: Fixture; run: int): string =
  ## A capture per run, as a real monitored edge produces: re-writing one
  ## path in place is not what the engine sees in production.
  f.workRoot / ("producer-run" & $run & ".iomon")

proc testConfig(f: Fixture): BuildEngineConfig =
  result = defaultBuildEngineConfig(f.root / "cache")
  result.rebuildMissingOutputsOnCacheHit = true
  result.bypassRunQuota = true
  result.maxParallelism = 1'u32

proc producer(f: Fixture; run: int): BuildAction =
  result = builtinAction(bakCopyFile, "producer",
    cwd = f.workRoot,
    inputs = ["src/seed.txt"],
    outputs = ["generated/stable.txt"],
    cacheable = true,
    weakFingerprint = weak("producer"),
    actionCachePolicy = ffpChecksum,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  result.dependencyPolicy = iomonPolicy(f.producerReport(run))

proc consumer(f: Fixture; deps: openArray[string];
              declaresProducedPath: bool): BuildAction =
  ## `declaresProducedPath = false` is the shape the memo is about: the
  ## action READS the producer's output — the capture says so, and that is
  ## what puts the path in `cacheInputPaths` and therefore in the published
  ## record's keyed input set — while declaring nothing.
  result = builtinAction(bakWriteText, "consumer",
    cwd = f.workRoot,
    deps = deps,
    inputs = (if declaresProducedPath: @["generated/stable.txt"]
              else: newSeq[string]()),
    outputs = ["out/consumer.txt"],
    cacheable = true,
    weakFingerprint = weak("consumer"),
    actionCachePolicy = ffpChecksum,
    text = "derived\n",
    governingLockIdentity = lockIdentityOutsideSolvedGraph())
  result.dependencyPolicy = iomonPolicy(f.consumerReport)

suite "M9.R.73.2 session invalidation reaches every consumer":

  test "an undeclared consumer of a Level 1 action's output is refused a hit":
    ## ESCAPE 1. The producer genuinely EXECUTES in run 2 (its output is
    ## removed first, so the outputs-present shortcut cannot claim it), hits
    ## a kill-before-flush, and writes byte-identical bytes back. The
    ## consumer's declared input set is EMPTY, so the pre-lookup predicate
    ## sees no intersection; its cache RECORD is keyed on the path anyway,
    ## because the capture observed the read.
    ##
    ## Byte-identical output is the whole point: with changed bytes the
    ## consumer would miss on its input fingerprint and this file would
    ## grade nothing. The hit is legitimate on every axis the lookup can
    ## check, and must still be refused, because the evidence the producer
    ## published alongside those bytes is known to be incomplete.
    let f = makeFixture("loss-undeclared")
    var config = f.testConfig()

    writeRmdf(f.producerReport(1), @[readRecord(f.seedPath)])
    writeRmdf(f.consumerReport, @[readRecord(f.producedPath)])
    let first = runBuild(graph([f.producer(1),
      f.consumer(["producer"], declaresProducedPath = false)]), config)
    check first.byId("producer").status == asSucceeded
    check first.byId("consumer").status == asSucceeded
    # The property the whole case rests on: the path IS in the record's
    # keyed input set, and is NOT in the declared input set.
    check f.producedPath in first.byId("consumer").evidence.monitorReads
    check first.byId("consumer").evidence.declaredInputs.len == 0

    writeRmdf(f.producerReport(2),
      @[readRecord(f.seedPath), killBeforeFlush()])
    removeFile(f.producedPath)
    let second = runBuild(graph([f.producer(2),
      f.consumer(["producer"], declaresProducedPath = false)]), config)
    check second.byId("producer").status == asSucceeded
    check second.byId("producer").launched
    check readFile(f.producedPath) == "stable input\n"
    check second.byId("consumer").cacheDecision notin ReuseDecisions

  test "and the same consumer IS served when nothing was lost":
    ## THE NARROWNESS CONTROL for the case above, and it is not optional:
    ## every assertion above also holds against an engine that stopped
    ## reusing anything. The only difference here is the absence of the
    ## loss record.
    let f = makeFixture("noloss-undeclared")
    var config = f.testConfig()

    writeRmdf(f.producerReport(1), @[readRecord(f.seedPath)])
    writeRmdf(f.consumerReport, @[readRecord(f.producedPath)])
    let first = runBuild(graph([f.producer(1),
      f.consumer(["producer"], declaresProducedPath = false)]), config)
    check first.byId("consumer").status == asSucceeded

    writeRmdf(f.producerReport(2), @[readRecord(f.seedPath)])
    removeFile(f.producedPath)
    let second = runBuild(graph([f.producer(2),
      f.consumer(["producer"], declaresProducedPath = false)]), config)
    check second.byId("producer").launched
    check second.byId("consumer").cacheDecision in ReuseDecisions
    check not second.byId("consumer").launched

  test "a loss seen on an up-to-date-by-outputs action still invalidates downstream":
    ## ESCAPE 2, and the one with the widest blast radius: the
    ## outputs-present shortcut COLLECTS evidence and did not fold it into
    ## the session accumulator, so the loss recorded in that capture
    ## invalidated nothing for the rest of the build. Level 1 loses its
    ## narrowed path set; Level 2 loses the session-wide hit disable
    ## entirely.
    ##
    ## The producer reaches the shortcut because its run-1 capture
    ## observed NOTHING, so the zero-evidence guard withheld its publish:
    ## in run 2 it has no record to hit, its output is present, and
    ## nothing it depends on launched. That is not a contrived state — it
    ## is what any edge whose capture the engine declines to trust looks
    ## like on the next build.
    let f = makeFixture("loss-on-uptodate")
    var config = f.testConfig()

    writeRmdf(f.producerReport(1), @[])
    writeRmdf(f.consumerReport, @[readRecord(f.producedPath)])
    let first = runBuild(graph([f.producer(1),
      f.consumer(["producer"], declaresProducedPath = true)]), config)
    check first.byId("producer").status == asSucceeded
    check first.byId("consumer").status == asSucceeded

    writeRmdf(f.producerReport(2), @[killBeforeFlush()])
    let second = runBuild(graph([f.producer(2),
      f.consumer(["producer"], declaresProducedPath = true)]), config)
    # The producer was NOT launched — it was declared up to date because
    # its outputs are present — and its capture still said Level 1.
    check not second.byId("producer").launched
    check second.byId("producer").status == asUpToDate
    check second.byId("consumer").cacheDecision notin ReuseDecisions
    check second.byId("consumer").launched

  test "and nothing is invalidated when that action's capture is clean":
    ## Narrowness control for escape 2.
    let f = makeFixture("noloss-on-uptodate")
    var config = f.testConfig()

    writeRmdf(f.producerReport(1), @[])
    writeRmdf(f.consumerReport, @[readRecord(f.producedPath)])
    let first = runBuild(graph([f.producer(1),
      f.consumer(["producer"], declaresProducedPath = true)]), config)
    check first.byId("consumer").status == asSucceeded

    writeRmdf(f.producerReport(2), @[])
    let second = runBuild(graph([f.producer(2),
      f.consumer(["producer"], declaresProducedPath = true)]), config)
    check not second.byId("producer").launched
    check not second.byId("consumer").launched
