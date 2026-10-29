## Campaign M17 (ReproOS-Campaign-Completion.milestones.org),
## `t_peer_cache_refuses_timestamp_records_across_hosts`:
## Edge-Derived-Identities.md §3.3a and §3.6 with their 2026-10-27 riders
## (§10 decision 11, conflict C2), and §3.4 item 1 (decision 13, C3), applied
## to the two-phase LAN peer cache of Distributed-Execution M0 at BOTH ends.
##
## PRODUCER. A record made under `ffpTimestamp` is not published: the engine
## does not offer it to the publisher hook, and `publishTwoPhase` itself
## refuses it before re-observing or hashing a single input. The refusal names
## the policy. A Level-1, unstated-level or zero-evidence record is refused the
## same way, naming the level. A checksum or a hybrid Level-0 record IS
## published, and its memo entry states Level 0 under the issuer's signature
## (memo entry v3): stripping or changing the level breaks the attestation.
##
## CONSUMER. A peer response carrying a record that may not cross hosts -- a
## timestamp-policy record from a non-conforming producer that claims Level 0,
## a legacy (v2) entry that states no level, a Level-1 record -- is refused by
## `installTwoPhaseBundle` with the policy or level named, and the engine
## treats it as a miss: the action runs, and nothing it names is materialised
## (the forged output bytes never reach the consumer's CAS or its output
## path). A checksum Level-0 control built the same way IS installed and
## served, which is what makes the refusals the rule's doing.
##
## The same assertions over real TLS between two processes are in the
## changed M0 gate, `t_peer_cache_two_phase_lan_roundtrip` (which also covers
## the lookup's own refusal in `fetchTwoPhase`).
##
## MOCK POLICY. Everything here is real -- the build engine, the CLI's
## `newPeerCacheEngineHooks` publisher and installer, the on-disk CAS, action
## cache and memo store, ECDSA attestations by a CA-signed leaf -- except two
## things, each justified:
##   * the network transport. The consumer's FETCHER is a closure that hands
##     the engine the bundle a lookup would have produced (the entry, the
##     PathSet blob, the identities observed on the consumer's files and the
##     output blobs), because what is under test is what the consumer does
##     with a response, and a forged or legacy response cannot be obtained
##     from a conforming producer at all. The wire path is the M0 gate's.
##   * the host identity is minted in memory rather than through
##     `loadOrCreateHostIdentity`, whose key-file write is POSIX-only, so the
##     test runs on every platform. The CA certificate is written to disk and
##     loaded as the consumer's trust anchor exactly as a pinned one is.
## "Another host" is a second cache root over the same workspace path, so the
## producer's records are not rebased; rebasing is the M0 gate's subject.

import std/[options, os, sets, strutils, times, unittest]

from repro_test_support import testCaseScratchSlug

import repro_build_engine
import repro_cas_store
import repro_core/paths
import repro_hash
import repro_local_store
import repro_peer_cache
import repro_cli_support/peer_cache_wiring

let TmpDir = absolutePath("build/test-tmp/m17pc-" & testCaseScratchSlug())
  ## Short: a memo entry's temp file is two 64-hex directory levels deep
  ## under the cache root, and `writeMemoEntry` does not use extended-length
  ## paths, so a long scratch root runs past MAX_PATH on Windows.

const
  ActionId = "m17-peer-publication"
  ProducerText = "from the producer\n"
  ConsumerText = "built by the consumer\n"

let Weak = weakFingerprintFromText("t-m17-peer-cache-publication")

# ---------------------------------------------------------------------------
# Identity.
# ---------------------------------------------------------------------------

proc inMemoryHostIdentity(dir: string):
    tuple[identity: HostIdentity; caPath: string] =
  ## A host CA as `loadOrCreateHostIdentity` mints one, minus the key file.
  var keypair = generateKeypair()
  let hostId = derivePeerIdFromPublicKey(keypair.publicKey)
  let now = getTime().toUnix
  var ca = generateCaCertWithWindow(keypair, subjectCn = $hostId,
    notBefore = now - LeafClockSkewSeconds, notAfter = now + 86_400)
  ca.keypair.privateKey = default(PrivateKeyBytes)
  createDir(dir)
  result.caPath = dir / "host-ca.crt"
  writeFile(result.caPath, ca.certPem)
  result.identity = HostIdentity(ca: ca, caKey: newSecretKey(keypair),
    hostId: hostId)

var producerIdentity: HostIdentity
var producerCaPath = ""
var producerLeaf: LeafCredential

proc attestor(): LeafProvider =
  result = proc(): LeafCredential {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      producerLeaf

# ---------------------------------------------------------------------------
# Builds.
# ---------------------------------------------------------------------------

proc newWorkspace(name: string): string =
  result = TmpDir / name / "ws"
  createDir(result / "src")
  createDir(result / "out")
  writeFile(result / "src" / "main.c", "int main;\n")

proc theAction(ws: string; policy: FileFingerprintPolicy;
               text: string): BuildAction =
  ## One action, keyed by the same weak fingerprint on every host. Its
  ## builtin text is NOT in the key, so the producer's bytes and the
  ## consumer's own differ, and which one ends up on disk says where it came
  ## from.
  builtinAction(bakWriteText, ActionId, cwd = ws,
    inputs = [ws / "src" / "main.c"],
    outputs = [ws / "out" / "result.txt"],
    cacheable = true,
    weakFingerprint = Weak,
    actionCachePolicy = policy,
    text = text,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())

proc engineConfig(cacheRoot: string): BuildEngineConfig =
  result = defaultBuildEngineConfig(cacheRoot)
  result.maxParallelism = 1'u32
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true

type Ran = object
  result: ActionResult
  trace: string

proc run(action: BuildAction; config: BuildEngineConfig): Ran =
  let res = runBuild(graph(@[action], newSeq[BuildPool]()), config)
  require res.results.len == 1
  result.result = res.results[0]
  for event in res.trace:
    result.trace.add(event.event & ": " & event.detail & "\n")
  checkpoint(result.trace)
  require result.result.status in {asSucceeded, asCacheHit, asUpToDate}

proc events(trace, event: string): seq[string] =
  for line in trace.splitLines():
    if line.startsWith(event & ": "):
      result.add(line)

proc readRecordFile(path: string): ActionResultRecord =
  let raw = readFile(path)
  var bytes = newSeq[byte](raw.len)
  if raw.len > 0:
    copyMem(addr bytes[0], unsafeAddr raw[0], raw.len)
  decodeActionResultRecord(bytes)

proc producerRecord(ws, cacheRoot: string;
                    policy: FileFingerprintPolicy): ActionResultRecord =
  ## The producer's LOCAL record of one execution, with its output blob kept
  ## in the CAS (as a peer publisher's build keeps it), published nowhere.
  var config = engineConfig(cacheRoot)
  config.deferLocalOutputBlobs = false
  discard run(theAction(ws, policy, ProducerText), config)
  readRecordFile(dependencyEvidencePath(cacheRoot, ActionId))

proc contextFor(ws: string): TwoPhaseContext =
  TwoPhaseContext(peerKey: blobDigestFromBytes(Weak.bytes), cwd: ws,
    workspaceRoot: ws, portable: false)

proc forgedBundle(record: ActionResultRecord; level: EvidenceLevel;
                  producerCacheRoot: string; ctx: TwoPhaseContext):
    seq[byte] =
  ## What a producer that does not apply the M17 rule (one built before it,
  ## or a non-conforming one) publishes for `record` -- `publishTwoPhase` as
  ## it was at `0ab157f1e`, stating `level` -- handed over as the lookup
  ## would hand it to the installer: the identities are the CONSUMER's,
  ## observed on its own files, so everything but the rule says "install".
  let normalized = normalizeRecord(record, ctx)
  let pathSet = pathSetOf(normalized)
  let pathSetBytes = encodePeerPathSet(pathSet)
  let pathSetDigest = digestOf(pathSetBytes)
  let identities = identitiesFor(pathSet, ctx)
  var cas = openCasStore(producerCacheRoot)
  defer: cas.close()
  var outputDigests: seq[BlobDigest] = @[]
  var blobs: seq[seq[byte]] = @[]
  for output in record.outputs:
    outputDigests.add(blobDigestFromBytes(output.blob.digest.bytes))
    blobs.add(cas.casGet(toContentHash(output.blob.digest.bytes)))
  let entry = MemoEntry(weakFingerprint: ctx.peerKey,
    pathSetDigest: pathSetDigest,
    strongFingerprint: twoPhaseStrongFingerprint(ctx.peerKey, pathSetDigest,
      identities),
    recordBytes: encodeActionResultRecord(normalized),
    outputDigests: outputDigests,
    evidenceLevel: level)
  encodeTwoPhaseBundle(TwoPhaseBundle(entryBytes: encodeMemoEntry(entry),
    pathSetBytes: pathSetBytes, identities: identities, blobs: blobs))

proc publishedBundle(storage: PeerCacheStorage; ctx: TwoPhaseContext):
    seq[byte] =
  ## The bundle a lookup builds from a producer's published memo entry
  ## (Steps 1-4 of `fetchTwoPhase` without the wire).
  # The key the producer's engine published under: its own weak fingerprint
  # for the action, which folds more than the caller-supplied one in.
  let weaks = storage.memo.weakFingerprints()
  doAssert weaks.len == 1
  let selectors = storage.memo.listSelectors(weaks[0])
  doAssert selectors.len == 1
  let entryBytes = storage.memo.readMemoEntryBytes(weaks[0],
    selectors[0].strongFingerprint).get()
  let entry = decodeMemoEntry(entryBytes)
  let pathSetBytes = storage.readBlob(entry.pathSetDigest).get()
  var blobs: seq[seq[byte]] = @[]
  for d in entry.outputDigests:
    blobs.add(storage.readBlob(d).get())
  encodeTwoPhaseBundle(TwoPhaseBundle(entryBytes: entryBytes,
    pathSetBytes: pathSetBytes,
    identities: identitiesFor(decodePeerPathSet(pathSetBytes), ctx),
    blobs: blobs))

proc outputBlobIn(cacheRoot: string; record: ActionResultRecord): bool =
  var cas = openCasStore(cacheRoot)
  defer: cas.close()
  cas.casExists(toContentHash(record.outputs[0].blob.digest.bytes))

suite "M17: the peer-cache PRODUCER publishes only checksum/hybrid Level-0 records":

  setup:
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
    createDir(TmpDir)
    let minted = inMemoryHostIdentity(TmpDir / "producer-identity")
    producerIdentity = minted.identity
    producerCaPath = minted.caPath
    producerLeaf = mintLeaf(producerIdentity, lrDaemon)

  test "a timestamp-policy record is not published, and the refusal names the policy":
    let ws = newWorkspace("producer-ts")
    let cacheRoot = TmpDir / "producer-ts" / "cache"
    let storage = openPeerCacheStorage(cacheRoot)
    let hooks = newPeerCacheEngineHooks(nil, storage, nil, attestor())
    var config = engineConfig(cacheRoot)
    wireEngineConfig(config, hooks, ws)
    let built = run(theAction(ws, ffpTimestamp, ProducerText), config)
    check built.result.launched
    let refused = events(built.trace, "peer-cache-publish-refused")
    check refused.len == 1
    check refused.len == 1 and "ffpTimestamp input-check policy" in refused[0]
    # Not handed to the publisher at all, so nothing was written for peers.
    check hooks.stats.publishes == 0
    check hooks.stats.publishSkips == 0
    check storage.memo.weakFingerprints().len == 0
    # The local record is unaffected: it serves this host.
    let again = run(theAction(ws, ffpTimestamp, ProducerText), config)
    check not again.result.launched

  test "checksum and hybrid Level-0 records are published, signed as Level 0":
    for policy in [ffpChecksum, ffpHybrid]:
      let name = (if policy == ffpChecksum: "p-cs" else: "p-hy")
      let ws = newWorkspace(name)
      let cacheRoot = TmpDir / name / "cache"
      let storage = openPeerCacheStorage(cacheRoot)
      let hooks = newPeerCacheEngineHooks(nil, storage, nil, attestor())
      var config = engineConfig(cacheRoot)
      wireEngineConfig(config, hooks, ws)
      let built = run(theAction(ws, policy, ProducerText), config)
      check built.result.launched
      checkpoint($policy & " publish: " & hooks.stats.lastPublishReason)
      check events(built.trace, "peer-cache-publish-refused").len == 0
      check hooks.stats.publishes == 1
      let weaks = storage.memo.weakFingerprints()
      require weaks.len == 1
      let selectors = storage.memo.listSelectors(weaks[0])
      require selectors.len == 1
      let entry = storage.memo.readMemoEntry(weaks[0],
        selectors[0].strongFingerprint).get()
      check entry.evidenceLevel == elComplete
      check decodeActionResultRecord(entry.recordBytes).policy == policy
      # The level is part of what the issuer signed.
      let anchors = loadTrustAnchorFile(producerCaPath)
      let revoked = initHashSet[PeerId]()
      let verdict = verifyAttestation(entry, anchors, revoked)
      checkpoint(verdict.reason)
      check verdict.ok
      var stripped = entry
      stripped.evidenceLevel = elUnstated
      check not verifyAttestation(stripped, anchors, revoked).ok
      var relabelled = entry
      relabelled.evidenceLevel = elKnownScopeLoss
      check not verifyAttestation(relabelled, anchors, revoked).ok
      # The entry round-trips as v3 and still says Level 0.
      check decodeMemoEntry(encodeMemoEntry(entry)).evidenceLevel ==
        elComplete

  test "publishTwoPhase refuses before observing an input, naming policy or level":
    let ws = newWorkspace("library")
    let tsCache = TmpDir / "library" / "ts-cache"
    let tsRecord = producerRecord(ws, tsCache, ffpTimestamp)
    let csCache = TmpDir / "library" / "cs-cache"
    let csRecord = producerRecord(ws, csCache, ffpChecksum)
    let ctx = contextFor(ws)
    let store = openPeerMemoStore(TmpDir / "library" / "memo")
    var cas = openCasStore(csCache)
    defer: cas.close()
    var tsStore = openCasStore(tsCache)
    defer: tsStore.close()
    var zero = csRecord
    zero.inputs = @[]
    zero.envInputs = @[]
    var unhashed = csRecord
    for input in unhashed.inputs.mitems:
      if input.metadata.kind == ffkRegular:
        input.hasLocalHash = false
    # A timestamp record whose only input is a directory: no regular file
    # whose missing hash could refuse it, so only the policy rule does.
    var tsDirectoryOnly = tsRecord
    var directory = observeFile(ws / "src", ffpTimestamp)
    directory.path = ws / "src"
    tsDirectoryOnly.inputs = @[directory]
    let cases = [
      ("timestamp policy", tsRecord, elComplete, "ffpTimestamp input-check policy"),
      ("timestamp policy, no regular file", tsDirectoryOnly, elComplete,
       "ffpTimestamp input-check policy"),
      ("Level 1", csRecord, elKnownScopeLoss, "Level 1"),
      ("unstated level", csRecord, elUnstated, "unstated"),
      ("no observed input", zero, elComplete, "names no observed input"),
      ("missing content hash", unhashed, elComplete, "no content hash")]
    for (label, record, level, named) in cases:
      let outcome =
        if record.policy == ffpTimestamp:
          publishTwoPhase(store, tsStore, record, ctx, attestor(), level)
        else:
          publishTwoPhase(store, cas, record, ctx, attestor(), level)
      checkpoint(label & ": " & outcome.reason)
      check not outcome.published
      check named in outcome.reason
    # Nothing was written: no entry, and no PathSet blob (the first thing a
    # publish that got as far as identities would have stored).
    check store.weakFingerprints().len == 0
    let pathSetBlob = digestOf(encodePeerPathSet(
      pathSetOf(normalizeRecord(tsRecord, ctx))))
    check not tsStore.casExists(toContentHash(bytes(pathSetBlob)))
    # Control: the checksum record at Level 0 is published.
    let published = publishTwoPhase(store, cas, csRecord, ctx, attestor(),
      elComplete)
    checkpoint(published.reason)
    check published.published
    check published.entry.evidenceLevel == elComplete

  test "the producer does not serve a non-conforming entry already in its memo store":
    # Found by the independent verification of M17 chunk 1. A memo store
    # outlives the build that wrote it: entries a pre-M17 build of this host
    # published (timestamp-policy, no stated level), or that an older build
    # sharing the cache root still publishes, are on disk when this build's
    # node serves the root. Serving one -- and re-attesting it with this
    # host's current leaf when its attestation is stale -- publishes it
    # again, to every consumer, including an older one that applies no rule.
    # The node's entry reader applies the same rule as the publisher.
    let ws = newWorkspace("served")
    let tsRecord = producerRecord(ws, TmpDir / "served" / "ts-cache",
      ffpTimestamp)
    let csRecord = producerRecord(ws, TmpDir / "served" / "cs-cache",
      ffpChecksum)
    let ctx = contextFor(ws)
    let storage = openPeerCacheStorage(TmpDir / "served" / "node")
    proc stored(record: ActionResultRecord; level: EvidenceLevel;
                leaf: LeafCredential): MemoEntry =
      let normalized = normalizeRecord(record, ctx)
      let pathSetDigest = digestOf(encodePeerPathSet(pathSetOf(normalized)))
      var outputs: seq[BlobDigest] = @[]
      for output in record.outputs:
        outputs.add(blobDigestFromBytes(output.blob.digest.bytes))
      # A distinct strong per case, so each is its own selector.
      let identities = @[$level, $record.policy]
      result = MemoEntry(weakFingerprint: ctx.peerKey,
        pathSetDigest: pathSetDigest,
        strongFingerprint: twoPhaseStrongFingerprint(ctx.peerKey,
          pathSetDigest, identities),
        recordBytes: encodeActionResultRecord(normalized),
        outputDigests: outputs, evidenceLevel: level)
      attest(result, leaf)
      discard storage.memo.writeMemoEntry(result)
    # Leaves close to expiry, so the reader would re-attest what it serves.
    let stale = mintLeaf(producerIdentity, lrDaemon, ttlSeconds = 600)
    let legacyTimestamp = stored(tsRecord, elUnstated, stale)
    let legacyChecksum = stored(csRecord, elUnstated, stale)
    let level1 = stored(csRecord, elKnownScopeLoss, stale)
    let conforming = stored(csRecord, elComplete, stale)
    let node = PeerCacheHost(
      config: PeerCacheConfig(trustMode: tmTls, trustProfile: tpHardened),
      selfPeerId: producerIdentity.hostId, storages: @[storage],
      identity: producerIdentity, leaf: producerLeaf)
    let reader = entryReaderFor(node)
    for (label, entry) in [("legacy timestamp entry", legacyTimestamp),
                           ("legacy entry stating no level", legacyChecksum),
                           ("Level-1 entry", level1)]:
      checkpoint(label)
      check reader(entry.weakFingerprint, entry.strongFingerprint).isNone
      # Not re-attested either: the stored entry keeps its old signature.
      check storage.memo.readMemoEntry(entry.weakFingerprint,
        entry.strongFingerprint).get().issuerSignature ==
        entry.issuerSignature
    # Control: the conforming entry is served, re-attested with the
    # node's current leaf.
    let served = reader(conforming.weakFingerprint,
      conforming.strongFingerprint)
    require served.isSome
    let fresh = decodeMemoEntry(served.get())
    check fresh.evidenceLevel == elComplete
    check fresh.issuerSignature != conforming.issuerSignature
    check verifyAttestation(fresh, loadTrustAnchorFile(producerCaPath),
      initHashSet[PeerId]()).ok

suite "M17: the peer-cache CONSUMER refuses records that may not cross hosts":

  setup:
    if dirExists(TmpDir):
      removeDir(extendedPath(TmpDir))
    createDir(TmpDir)
    let minted = inMemoryHostIdentity(TmpDir / "producer-identity")
    producerIdentity = minted.identity
    producerCaPath = minted.caPath
    producerLeaf = mintLeaf(producerIdentity, lrDaemon)

  test "installTwoPhaseBundle refuses a timestamp, Level-1 or legacy entry":
    let ws = newWorkspace("install")
    let tsCache = TmpDir / "install" / "ts-cache"
    let tsRecord = producerRecord(ws, tsCache, ffpTimestamp)
    let csCache = TmpDir / "install" / "cs-cache"
    let csRecord = producerRecord(ws, csCache, ffpChecksum)
    let ctx = contextFor(ws)
    let cases = [
      ("timestamp record claiming Level 0", tsRecord, tsCache, elComplete,
       "ffpTimestamp input-check policy"),
      ("Level-1 record", csRecord, csCache, elKnownScopeLoss, "Level 1"),
      ("legacy entry stating no level", csRecord, csCache, elUnstated,
       "unstated")]
    for i, (label, record, producerCache, level, named) in cases:
      let consumerCache = TmpDir / "install" / ("consumer-" & $i)
      var cas = openCasStore(consumerCache)
      var cache = openActionCache(consumerCache / "action-cache",
        attachShm = false)
      let bundle = decodeTwoPhaseBundle(
        forgedBundle(record, level, producerCache, ctx))
      let installed = installTwoPhaseBundle(cas, cache, bundle, Weak,
        ffpChecksum, ctx)
      checkpoint(label & ": " & installed.reason)
      check not installed.ok
      check named in installed.reason
      # Nothing was materialised from it.
      check not cas.casExists(toContentHash(record.outputs[0].blob.digest.bytes))
      let lookup = cache.lookupActionResult(cas.inner, Weak, ffpChecksum,
        outputRoot = ws)
      check lookup.status notin {aclHit, aclHybridCutoff}
      cas.close()
    # Control: the same construction for a checksum Level-0 record installs,
    # so what refused the cases above is the rule, not the bundle.
    let consumerCache = TmpDir / "install" / "consumer-control"
    var cas = openCasStore(consumerCache)
    defer: cas.close()
    var cache = openActionCache(consumerCache / "action-cache",
      attachShm = false)
    let bundle = decodeTwoPhaseBundle(
      forgedBundle(csRecord, elComplete, csCache, ctx))
    let installed = installTwoPhaseBundle(cas, cache, bundle, Weak,
      ffpChecksum, ctx)
    checkpoint(installed.reason)
    check installed.ok
    check cas.casExists(toContentHash(csRecord.outputs[0].blob.digest.bytes))

  test "a forged timestamp response is a miss: the action runs, nothing is materialised":
    let ws = newWorkspace("engine-forged")
    let producerCache = TmpDir / "engine-forged" / "producer"
    let record = producerRecord(ws, producerCache, ffpTimestamp)
    let ctx = contextFor(ws)
    let forged = forgedBundle(record, elComplete, producerCache, ctx)
    # The consumer: another cache root, its own output.
    removeFile(ws / "out" / "result.txt")
    let consumerCache = TmpDir / "engine-forged" / "consumer"
    let hooks = newPeerCacheEngineHooks(nil,
      openPeerCacheStorage(consumerCache), nil, attestor())
    var config = engineConfig(consumerCache)
    wireEngineConfig(config, hooks, ws)
    var served = 0
    config.peerCacheActionFetcher = proc(query: PeerCacheActionQuery):
        Option[seq[byte]] {.gcsafe, closure.} =
      {.cast(gcsafe).}:
        inc served
        some(forged)
    let built = run(theAction(ws, ffpChecksum, ConsumerText), config)
    check served == 1
    check built.result.launched
    check readFile(ws / "out" / "result.txt") == ConsumerText
    check hooks.stats.installs == 0
    check hooks.stats.installFailures == 1
    check "ffpTimestamp input-check policy" in hooks.stats.lastInstallReason
    let failed = events(built.trace, "peer-cache-install-failed")
    check failed.len == 1
    check failed.len == 1 and "ffpTimestamp input-check policy" in failed[0]
    check not outputBlobIn(consumerCache, record)

  test "control: a published checksum Level-0 record is installed and served":
    let ws = newWorkspace("engine-honest")
    let producerCache = TmpDir / "engine-honest" / "producer"
    let producerStorage = openPeerCacheStorage(producerCache)
    let producerHooks = newPeerCacheEngineHooks(nil, producerStorage, nil,
      attestor())
    var producerConfig = engineConfig(producerCache)
    wireEngineConfig(producerConfig, producerHooks, ws)
    discard run(theAction(ws, ffpChecksum, ProducerText), producerConfig)
    require producerHooks.stats.publishes == 1
    let bundle = publishedBundle(producerStorage, contextFor(ws))
    removeFile(ws / "out" / "result.txt")
    let consumerCache = TmpDir / "engine-honest" / "consumer"
    let hooks = newPeerCacheEngineHooks(nil,
      openPeerCacheStorage(consumerCache), nil, attestor())
    var config = engineConfig(consumerCache)
    wireEngineConfig(config, hooks, ws)
    config.peerCacheActionFetcher = proc(query: PeerCacheActionQuery):
        Option[seq[byte]] {.gcsafe, closure.} =
      {.cast(gcsafe).}:
        some(bundle)
    let served = run(theAction(ws, ffpChecksum, ConsumerText), config)
    checkpoint(hooks.stats.lastInstallReason)
    check hooks.stats.installs == 1
    check not served.result.launched
    check readFile(ws / "out" / "result.txt") == ProducerText
