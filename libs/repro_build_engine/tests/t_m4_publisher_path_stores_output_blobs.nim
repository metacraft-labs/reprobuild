## Local-CAS-Hardlink-Materialization M4 — the PUBLISHER-configured path.
##
## M4's deliverable names a route: "configure a publisher, confirm blobs
## land in ``cas/``, delete a materialized output, and assert the next
## build restores it from the CAS instead of re-running the action — with
## ``rebuildMissingOutputsOnCacheHit`` off".
##
## S5 and S7 between them proved the second half of that sentence through
## a different door: S5 at the ``runBuild`` level under
## ``defaultBuildEngineConfig``, S7 through the real CLI behind
## ``--restore-cached-outputs``. Neither of them touches a publisher. That
## matters because "restore works via the flag" and "the publisher path
## works" are different claims about different code: the flag clears
## ``deferLocalOutputBlobs``, while a publisher leaves it set and reaches
## blob storage through a SEPARATE clause of ``storeOutputBlobsFor``.
##
## Measured before this file existed: deleting that clause entirely —
##
##     let wanted = (not config.deferLocalOutputBlobs)
##
## — left all 57 store-touching ``repro_build_engine`` cases green, and
## left ``t_m5_peer_cache_build_wiring`` green too, because that file sets
## ``deferLocalOutputBlobs = false`` by hand and so never asks the
## question.
##
## *Which clause matters, and which one does not.* The disjunction has a
## peer arm and a binary-cache arm, and they are not in the same
## position. The BINARY-CACHE arm is the one every ``repro build``
## depends on: ``engineConfig.binaryCachePublisher =
## mkBinaryCachePublisher()`` is assigned unconditionally at BOTH build
## engine configs (``repro_cli_support.nim:7383`` and ``:8691``),
## ``mkBinaryCachePublisher`` has a single ``result =`` and never returns
## nil, and the ordinary path at ``:8647`` hard-codes
## ``deferLocalOutputBlobs: true`` — so that arm is the ONLY thing that
## stores a payload for an action carrying ``publishToBinaryCache`` or for
## any action under an INTERMEDIATE-scope cache. The PEER arm has no CLI
## caller that can reach it: ``peerCacheActionPublisher`` is assigned at
## exactly one non-test site (``:7366``), inside the same constructor
## whose ``:7355`` writes ``deferLocalOutputBlobs: peerCachePublisher ==
## nil`` — so whenever the field is non-nil the flag is already false and
## the FIRST disjunct fires. ``repro build --peer-cache=…`` therefore
## stores blobs without the peer clause being consulted; the peer clause
## is reachable only from a library caller that builds a config by hand,
## which is what the second case below does.
##
## What this file also pins is the HONEST shape of the publisher route as
## shipped, which is not what M4's sentence assumed. A publisher gives you
## the blobs and NOT the restore: ``runLoweredGraphBuild`` sets
## ``deferLocalOutputBlobs: peerCachePublisher == nil`` but still sets
## ``rebuildMissingOutputsOnCacheHit: true``, so a publisher-configured
## build stores every payload and then rebuilds a deleted output anyway.
## The two knobs are independent and only ``enableCachedOutputRestore``
## moves the second one. That is not new here — ``Windows-Cacheable-
## Builds-Session-Residuals`` S5 and S7 both already record it against the
## same construction; what is new is that both halves are ASSERTED here,
## in that order, so the file states the limitation rather than only the
## win.

import std/[options, os, strutils, unittest]

import repro_binary_cache_client/cache_key
import repro_binary_cache_server/types as bcsTypes
import repro_build_engine
import repro_hash
import repro_local_store

from repro_cas_store import openCasStore, casGet, close, CasStore,
  toContentHash

from repro_core/paths import extendedPath

# Every case gets its OWN root, under this run's pid-scoped directory in
# the build tree, and every removal goes through ``extendedPath``.
#
# The isolation is load-bearing and so is the path spelling, and both were
# measured here rather than copied.
#
# *Isolation.* A shared directory wiped at startup does not work: the
# engine keeps a warm ``ActionCache`` handle per cache root for the life of
# the process, so a case cannot reliably delete a root it built, and the
# NEXT run then meets a warm cache. Every case in this file fails at once
# in that state, with ``asUpToDate`` and no publisher invocation — a
# stale-state failure that looks exactly like the feature being broken.
# Pid scoping plus a sweep of earlier runs bounds the residue at one run's
# trees, and puts them in ``build/`` rather than ``%TEMP%``.
#
# *``extendedPath``.* Without it this file leaves a tree behind on every
# run, and the reason is neither a handle nor a scanner: the action cache's
# own record path is
# ``<root>/cache/action-cache/hot-records/0-1-<64 hex>.rbar/<64 hex>.rec``,
# which is 174 characters of tail on its own. Add a test-tmp root and it
# crosses MAX_PATH, at which point ``removeDir`` reports
# ``The directory is not empty`` against a directory whose only child it
# has just listed — and retries never help, while ``rm -rf`` succeeds.
# Measured: 30 retries over 6 seconds failed, and the same tree went in one
# call through ``extendedPath``. That is also why the first version of this
# file, rooted in ``%TEMP%``, leaked only the case with the LONGEST tag
# name and cleaned up the other six.

const TmpRoot = "build/test-tmp/m4pub"
let RunRoot = absolutePath(TmpRoot / $getCurrentProcessId())

proc dropTree(path: string) =
  ## Best-effort removal, always through ``extendedPath``. Never fatal:
  ## failing a case on its cleanup would report a caching defect that is
  ## not one. What survives is NAMED by the teardown suite rather than
  ## silently left.
  for _ in 0 .. 4:
    if not dirExists(extendedPath(path)):
      return
    try:
      removeDir(extendedPath(path))
    except CatchableError:
      sleep(100)

proc sweepPreviousRuns() =
  ## A sibling belongs to a process that is gone, so this is the removal
  ## that can actually succeed. It cannot affect this run either way — the
  ## pid scope is what isolates them.
  if not dirExists(TmpRoot):
    return
  for kind, path in walkDir(absolutePath(TmpRoot)):
    if kind == pcDir and path != RunRoot:
      dropTree(path)

sweepPreviousRuns()
createDir(extendedPath(RunRoot))

var caseRoots: seq[string] = @[]

proc newCaseRoot(tag: string): string =
  result = RunRoot / tag
  dropTree(result)
  createDir(extendedPath(result))
  caseRoots.add(result)

# ---------------------------------------------------------------------------
# Fixtures. The action is ``bakWriteText`` — hermetic, no toolchain, no
# monitor — so the only variable between cases is the engine config.
# ---------------------------------------------------------------------------

proc fingerprintForPayload(payload: string): ContentDigest =
  casDigest(payload.toOpenArrayByte(0, payload.high),
            domain = hdActionFingerprint)

proc stubIdentity(revision: string): CacheEntryIdentity =
  newCacheEntryIdentity(
    packageName = "m4-pkg",
    packageVersion = "1.0.0",
    platform = bcsTypes.PlatformTriple(
      cpu: "x86_64", os: "linux", abi: "gnu", libcVariant: "glibc"),
    toolchain = bcsTypes.ToolchainIdentity(
      name: "stub", version: "1", hostLdSoAbi: "", extraFingerprint: ""),
    providerRevision = revision)

type Fixture = object
  cacheRoot: string
  outputPath: string
  payload: string
  graph: BuildGraph

proc makeFixture(root: string;
                 tag: string;
                 publish = false;
                 identity = none(CacheEntryIdentity)): Fixture =
  # ``tag`` distinguishes the FINGERPRINT, not the directory: the root is
  # already per-case, and a second copy of a long tag in the path is what
  # pushed the action cache's own record past MAX_PATH.
  let cacheRoot = absolutePath(root / "cache")
  let outputPath = absolutePath(root / "out" / "artifact.txt")
  createDir(cacheRoot)
  createDir(splitPath(outputPath).head)
  let payload = "m4 publisher payload " & tag & "\n"
  let act = BuildAction(
    governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    kind: bakWriteText,
    id: "m4-publisher-write",
    outputs: @[outputPath],
    cacheable: true,
    actionCachePolicy: ffpChecksum,
    weakFingerprint: fingerprintForPayload(payload & "|" & tag),
    builtinText: payload,
    publishToBinaryCache: publish,
    cacheEntryIdentity: identity)
  Fixture(cacheRoot: cacheRoot, outputPath: outputPath, payload: payload,
          graph: graph(@[act], newSeq[BuildPool]()))

proc cliShapedConfig(cacheRoot: string): BuildEngineConfig =
  ## The configuration an ordinary ``repro build <target>`` constructs —
  ## ``repro_cli_support.nim:8647``, where both are literals: blobs
  ## deferred, and a missing output on a hit rebuilt rather than restored.
  ## (``--restore-cached-outputs`` moves the second, and ``--peer-cache``
  ## moves the first on the OTHER construction at ``:7341``; neither is
  ## the baseline this file measures against.) Both literals are spelled
  ## out because this file's whole subject is what a publisher does and
  ## does not change about them.
  result = defaultBuildEngineConfig(cacheRoot)
  result.maxParallelism = 1
  result.deferLocalOutputBlobs = true
  result.rebuildMissingOutputsOnCacheHit = true

type Recorder = ref object
  peerPublishes: int
  binaryPublishes: int

proc peerPublisher(rec: Recorder): PeerCacheActionPublisher =
  result = proc(weakFingerprint: ContentDigest;
                bundleBytes: seq[byte]) {.gcsafe, closure.} =
    rec.peerPublishes.inc

proc binaryPublisher(rec: Recorder): BinaryCachePublisher =
  result = proc(req: BinaryCachePublishRequest):
      BinaryCachePublishResult {.gcsafe, closure.} =
    rec.binaryPublishes.inc
    BinaryCachePublishResult(ok: true, statusCode: 200, bytesUploaded: 1)

proc readRecord(path: string): ActionResultRecord =
  let raw = readFile(path)
  var bytes = newSeq[byte](raw.len)
  if raw.len > 0:
    copyMem(addr bytes[0], unsafeAddr raw[0], raw.len)
  decodeActionResultRecord(bytes)

proc casBlobCount(cacheRoot: string): int =
  ## Files under ``<cache-root>/cas/blake3``. M4 asks for "blobs land in
  ## ``cas/``", and a record field saying ``opkCasBlobs`` is a different
  ## statement from a file existing, so both are checked.
  let blobs = cacheRoot / "cas" / "blake3"
  if not dirExists(blobs):
    return 0
  for _ in walkDirRec(blobs, yieldFilter = {pcFile}):
    inc result

proc recordFor(fx: Fixture): ActionResultRecord =
  readRecord(dependencyEvidencePath(fx.cacheRoot, fx.graph.actions[0].id))

# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------

suite "M4 the publisher-configured path stores output blobs":

  test "the CLI's own configuration stores nothing — the control":
    ## Without this case the ones below prove only that blobs can exist,
    ## not that a publisher is what put them there. This is also the
    ## measured state of all 181 records on the reference host.
    let root = newCaseRoot("control")
    defer: dropTree(root)
    let fx = makeFixture(root, "control")
    let res = runBuild(fx.graph, cliShapedConfig(fx.cacheRoot))
    check res.results[0].status == asSucceeded
    check fileExists(fx.outputPath)
    check fx.recordFor.outputPayloadKind == opkMetadataOnly
    check casBlobCount(fx.cacheRoot) == 0

  test "a peer-cache publisher stores blobs despite deferLocalOutputBlobs":
    ## The clause a mutant could delete with every existing case still
    ## green. ``deferLocalOutputBlobs`` is left TRUE here, exactly as
    ## ``runLoweredGraphBuild`` leaves it; the publisher is the only
    ## difference from the control above.
    let root = newCaseRoot("peer")
    defer: dropTree(root)
    let fx = makeFixture(root, "peer")
    let rec = Recorder()
    var cfg = cliShapedConfig(fx.cacheRoot)
    check cfg.deferLocalOutputBlobs
    cfg.peerCacheActionPublisher = peerPublisher(rec)
    let res = runBuild(fx.graph, cfg)
    check res.results[0].status == asSucceeded
    check rec.peerPublishes == 1
    check fx.recordFor.outputPayloadKind == opkCasBlobs
    check casBlobCount(fx.cacheRoot) > 0

  test "the stored blob is the output's own bytes, retrievable by digest":
    ## "Blobs land in ``cas/``" is only worth anything if what landed is
    ## the payload. The record's own ``CasBlobRef`` is resolved against
    ## the store and compared with the file on disk.
    let root = newCaseRoot("bytes")
    defer: dropTree(root)
    let fx = makeFixture(root, "bytes")
    let rec = Recorder()
    var cfg = cliShapedConfig(fx.cacheRoot)
    cfg.peerCacheActionPublisher = peerPublisher(rec)
    discard runBuild(fx.graph, cfg)
    let record = fx.recordFor
    check record.outputPayloadKind == opkCasBlobs
    check record.outputs.len == 1
    check record.outputs[0].blob.sizeBytes == uint64(fx.payload.len)
    var cas = openCasStore(fx.cacheRoot)
    try:
      let blob = cas.casGet(toContentHash(record.outputs[0].blob.digest.bytes))
      var text = newString(blob.len)
      if blob.len > 0:
        copyMem(addr text[0], unsafeAddr blob[0], blob.len)
      check text == fx.payload
      check text == readFile(fx.outputPath)
    finally:
      cas.close()

  test "a binary-cache publisher stores blobs only for a tagged action":
    ## The second clause, and it is narrower than the peer one: an
    ## untagged action under a RELEASE-scope binary cache is not published
    ## and must not pay for a blob either.
    let root = newCaseRoot("bc")
    defer: dropTree(root)
    let untagged = makeFixture(root / "u", "bc-untagged", publish = false,
      identity = some(stubIdentity("rev-untagged")))
    let rec = Recorder()
    var cfg = cliShapedConfig(untagged.cacheRoot)
    cfg.binaryCachePublisher = binaryPublisher(rec)
    discard runBuild(untagged.graph, cfg)
    check rec.binaryPublishes == 0
    check untagged.recordFor.outputPayloadKind == opkMetadataOnly
    check casBlobCount(untagged.cacheRoot) == 0

    let tagged = makeFixture(root / "t", "bc-tagged", publish = true,
      identity = some(stubIdentity("rev-tagged")))
    var taggedCfg = cliShapedConfig(tagged.cacheRoot)
    taggedCfg.binaryCachePublisher = binaryPublisher(rec)
    discard runBuild(tagged.graph, taggedCfg)
    check rec.binaryPublishes == 1
    check tagged.recordFor.outputPayloadKind == opkCasBlobs
    check casBlobCount(tagged.cacheRoot) > 0

  test "an INTERMEDIATE-scope binary cache stores an untagged action too":
    ## The third clause. Scope is a property of the CACHE, not of the
    ## action, so the same untagged action that stored nothing above must
    ## store here — otherwise an intermediate cache has nothing to
    ## publish.
    let root = newCaseRoot("bc-intermediate")
    defer: dropTree(root)
    let fx = makeFixture(root, "bc-intermediate", publish = false)
    let rec = Recorder()
    var cfg = cliShapedConfig(fx.cacheRoot)
    cfg.binaryCachePublisher = binaryPublisher(rec)
    cfg.binaryCacheIntermediateScope = true
    discard runBuild(fx.graph, cfg)
    check fx.recordFor.outputPayloadKind == opkCasBlobs
    check casBlobCount(fx.cacheRoot) > 0

  test "a publisher alone stores the blob and still RE-RUNS a deletion":
    ## The limitation, asserted rather than described. This is the exact
    ## configuration ``repro build --peer-cache=…`` produces today: blobs
    ## in ``cas/``, and ``rebuildMissingOutputsOnCacheHit`` still true, so
    ## the payload that could have been restored is paid for and not used.
    ## M4's sentence assumed configuring a publisher would deliver the
    ## restore; it delivers half of it.
    let root = newCaseRoot("publisher-only")
    defer: dropTree(root)
    let fx = makeFixture(root, "publisher-only")
    let rec = Recorder()
    var cfg = cliShapedConfig(fx.cacheRoot)
    cfg.peerCacheActionPublisher = peerPublisher(rec)
    discard runBuild(fx.graph, cfg)
    check casBlobCount(fx.cacheRoot) > 0

    removeFile(fx.outputPath)
    check not fileExists(fx.outputPath)

    let second = runBuild(fx.graph, cfg)
    check second.results[0].launched
    check second.results[0].reason != "restored"
    check fileExists(fx.outputPath)
    # The blob was there the whole time and the engine declined to use it.
    check casBlobCount(fx.cacheRoot) > 0

  test "publisher plus the restore opt-in: the deleted output IS restored":
    ## M4's deliverable, on M4's own route, with
    ## ``rebuildMissingOutputsOnCacheHit`` off as the milestone demands.
    ## The knob comes from the production helper rather than being set
    ## here, so a helper that stopped clearing it fails this case.
    let root = newCaseRoot("publisher-restore")
    defer: dropTree(root)
    let fx = makeFixture(root, "publisher-restore")
    let rec = Recorder()
    var cfg = cliShapedConfig(fx.cacheRoot)
    cfg.peerCacheActionPublisher = peerPublisher(rec)
    cfg.enableCachedOutputRestore()
    check not cfg.rebuildMissingOutputsOnCacheHit
    discard runBuild(fx.graph, cfg)
    check fx.recordFor.outputPayloadKind == opkCasBlobs
    check casBlobCount(fx.cacheRoot) > 0

    removeFile(fx.outputPath)
    check not fileExists(fx.outputPath)

    let second = runBuild(fx.graph, cfg)
    check second.results[0].cacheDecision == cdHit
    check second.results[0].status == asCacheHit
    check not second.results[0].launched
    check second.results[0].reason == "restored"
    # A status flag is not a restore. The bytes are.
    check fileExists(fx.outputPath)
    check readFile(fx.outputPath) == fx.payload


suite "M4 the publisher-configured path — teardown":

  test "every root this run created is removed, and any survivor is NAMED":
    ## Counting is not enough — M3 made that point about its own teardown
    ## and it applies here: a survivor has to be identifiable, because the
    ## only interesting question about one is WHICH case left it.
    var surviving: seq[string] = @[]
    for root in caseRoots:
      dropTree(root)
      if dirExists(extendedPath(root)):
        surviving.add(root)
    if surviving.len > 0:
      echo "    surviving: ", surviving.join(", ")
    check surviving.len == 0
    dropTree(RunRoot)
