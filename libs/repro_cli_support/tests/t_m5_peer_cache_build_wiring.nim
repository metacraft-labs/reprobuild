## Linux-Distro-Recipe-Validation M5 — peer-cache build wiring.
##
## Verifies that `BuildEngineConfig.peerCacheActionFetcher` +
## `peerCacheActionInstaller` cause an action-cache miss against a
## fresh local store to be satisfied from a peer-cache action bundle
## without recompiling, AND that running the same engine against a
## DIFFERENT recipe (different input bytes ⇒ different weak
## fingerprint) correctly MISSES the peer cache and falls through to
## the local builtin path.
##
## We exercise the engine seam directly (no DSL workspace, no daemon)
## so the test stays fast and deterministic. Two stores are wired:
##
##   - ``sourceCache`` / ``sourceCas`` — built by running `runBuild`
##     with `peerCacheActionPublisher` set. After the run, the
##     publisher closure has stored the action-bundle bytes into the
##     in-process peer table keyed by the action's weak fingerprint.
##
## MOCK JUSTIFICATION: the in-process table stands in for the network on
## purpose — this file pins the ENGINE seam (miss -> fetcher -> installer
## -> retry hit, and a weak-fingerprint miss falling through to a build).
## The real wire path, two-phase selectors and BLAKE3-verified blob fetches
## over TCP between distinct workspace roots, is covered end to end by
## `libs/repro_peer_cache/tests/t_peer_cache_two_phase_lan_roundtrip.nim`.
##
##   - ``targetCache`` / ``targetCas`` — built by running `runBuild`
##     with `peerCacheActionFetcher` + `peerCacheActionInstaller` set.
##     On action-cache miss the fetcher reads from the same peer
##     table; the installer decodes the bundle and writes it into the
##     target's local CAS + ActionCache. The retry lookup hits, and
##     the build is reported as a cache hit instead of a fresh
##     compile.
##
## See `Linux-Distro-Recipe-Validation.milestones.org` §M5
## "Cross-Campaign Dependency" / "What M5 actually needs".
##
## Campaign M17 (Edge-Derived-Identities.md §3.3a, §3.4 item 1, §3.6): the
## engine offers a peer-cache publisher only a checksum- or hybrid-policy,
## Level-0 record that names at least one observed input. The write action
## below therefore reads one declared input and is recorded under
## `ffpChecksum` (it was an input-less `ffpTimestamp` record, which the
## engine now keeps local), and "a timestamp-policy record is not offered to
## the publisher" pins the refusal on this seam.
##
## Owner decision 2026-10-29 (Edge-Derived-Identities.md §3.4 item 1 rider):
## only a monitored or builtin record crosses hosts, so the shell action of
## "peer bundles restore conditional presence ..." is a MONITORED edge. Its
## monitor evidence is an io-mon capture the test writes (in io-mon's own
## encoding, with the backend profile io-mon writes first) and hands the
## action as a prewired `monitorDepfile`, the seam a direct engine caller
## uses, so the case runs wherever this file does; until then the edge was
## evidenced by a make depfile it wrote, which the engine now keeps local.

import std/[options, os, strutils, tables, unittest]

import repro_build_engine
import repro_cas_store
import repro_hash
import repro_local_store
import repro_peer_cache
import io_mon/[capabilities, types, writer]
from repro_test_support import testCaseScratchSlug

let TmpDir = "build/test-tmp/t_m5_peer_cache_build_wiring" /
  testCaseScratchSlug()

proc resetTmp() =
  if dirExists(TmpDir):
    removeDir(TmpDir)
  createDir(TmpDir)

# ---------------------------------------------------------------------------
# Engine-graph helpers. The action is a `bakWriteText` so the build is
# hermetic: the engine writes a fixed text payload to a declared
# output, no external tool / no PATH dep. The action's
# `weakFingerprint` is computed via the same `casDigest` path the
# engine uses for cache-input hashes; here we derive it from the
# action's payload so the producer + consumer (same payload bytes)
# share a fingerprint and the cross-build cache hit lands cleanly.
# ---------------------------------------------------------------------------

proc fingerprintForPayload(payload: string): ContentDigest =
  ## Derives a stable weak-fingerprint from the payload bytes. We use
  ## `casDigest` with the `hdActionFingerprint` domain so the producer
  ## and consumer agree byte-for-byte without re-running the engine's
  ## `actionFingerprintFor` (which would need a tool-profiles
  ## environment we don't bring up here). The domain framing in
  ## `casDigest` keeps this from colliding with a regular CAS content
  ## digest of the same payload.
  casDigest(payload.toOpenArrayByte(0, payload.high),
            domain = hdActionFingerprint)

proc recipeInput(): string =
  ## The one input every write action below declares: the same path and
  ## bytes for producer and consumer, so it keys nothing apart.
  result = absolutePath(TmpDir / "inputs" / "recipe.txt")
  createDir(result.parentDir)
  writeFile(result, "recipe\n")

proc buildOneAction(outputPath, payload, fingerprintToken: string;
                    policy = ffpChecksum): BuildGraph =
  ## Produces a one-action graph that writes `payload` to `outputPath`.
  ## `fingerprintToken` discriminates the action's weak fingerprint so
  ## the negative test can re-use the same harness with a distinct
  ## fingerprint AND a distinct payload (so a cross-recipe peer cache
  ## hit would be a real bug).
  let action = BuildAction(
    governingLockIdentity: lockIdentityOutsideSolvedGraph(),
    kind: bakWriteText,
    id: "t-m5-write",
    deps: @[],
    inputs: @[recipeInput()],
    outputs: @[outputPath],
    cacheable: true,
    actionCachePolicy: policy,
    weakFingerprint: fingerprintForPayload(payload & "|" & fingerprintToken),
    builtinText: payload)
  graph(@[action], newSeq[BuildPool]())

# ---------------------------------------------------------------------------
# Peer-table fixture. A single `TableRef` plays the part of the
# remote LAN peer cache: the publisher closure writes into it on the
# producer side, the fetcher closure reads out of it on the consumer
# side. Real ``--peer-cache=lan://…`` uses the multicast discovery
# plane + the BLAKE3-verified TCP fetch round; we elide both here so
# the test runs in <1 second with no kernel timer involvement.
# ---------------------------------------------------------------------------

type
  PeerTable = TableRef[string, seq[byte]]

proc keyHex(digest: ContentDigest): string =
  result = ""
  for b in digest.bytes:
    result.add(toHex(int(b), 2))

proc newPublisher(peer: PeerTable): PeerCacheActionPublisher =
  result = proc(query: PeerCacheActionQuery; record: ActionResultRecord;
                cas: var CasStore) {.gcsafe, closure.} =
    # The engine hands the publisher the record and its own CAS; the
    # bundle (record + output payloads) is materialised from there, the
    # way a real publisher reads the blobs it is about to serve.
    peer[][keyHex(query.weakFingerprint)] =
      encodeActionBundle(materializeActionBundle(cas, record))

proc newFetcher(peer: PeerTable): PeerCacheActionFetcher =
  result = proc(query: PeerCacheActionQuery):
      Option[seq[byte]] {.gcsafe, closure.} =
    let key = keyHex(query.weakFingerprint)
    if peer[].hasKey(key):
      some(peer[][key])
    else:
      none(seq[byte])

proc newInstaller(): PeerCacheActionBundleInstaller =
  result = proc(query: PeerCacheActionQuery;
                bundleBytes: seq[byte];
                cas: var CasStore;
                cache: ptr ActionCache):
                tuple[ok: bool; reason: string] {.gcsafe, closure.} =
    let bundle =
      try:
        decodeActionBundle(bundleBytes)
      except CatchableError as exc:
        return (false, "decode failed: " & exc.msg)
    installActionBundle(cas, cache[], bundle)

# ---------------------------------------------------------------------------
# Engine config factories.
# ---------------------------------------------------------------------------

proc producerConfig(cacheRoot: string;
                    peer: PeerTable): BuildEngineConfig =
  result = defaultBuildEngineConfig(cacheRoot)
  result.maxParallelism = 1
  result.deferLocalOutputBlobs = false
  result.peerCacheActionPublisher = newPublisher(peer)

proc consumerConfig(cacheRoot: string;
                    peer: PeerTable): BuildEngineConfig =
  result = defaultBuildEngineConfig(cacheRoot)
  result.maxParallelism = 1
  result.peerCacheActionFetcher = newFetcher(peer)
  result.peerCacheActionInstaller = newInstaller()

# ---------------------------------------------------------------------------
# Tests.
# ---------------------------------------------------------------------------

suite "LDRV-M5 peer-cache action-bundle build wiring":

  test "peer bundles restore conditional presence and remove recorded absence":
    # Keep the existing justified in-process network seam; the producer,
    # action cache, CAS and filesystem process are real. A fresh consumer
    # store proves these results came through peer installation, not a local hit.
    resetTmp()
    defer: removeDir(TmpDir)
    let work = absolutePath(TmpDir / "work")
    createDir(work)
    createDir(work / "out")
    writeFile(work / "input.txt", "peer product\n")
    let sh = findExe("sh")
    require sh.len > 0
    for present in [false, true]:
      let mode = if present: "exported" else: "no-exports"
      let peer: PeerTable = newTable[string, seq[byte]]()
      let command = "cat input.txt > out/module.dll" &
        (if present: "; cp out/module.dll out/module.lib" else: "")
      var link = action("conditional-" & mode, @[sh, "-c", command],
        cwd = work, inputs = @["input.txt"], outputs = @["out/module.dll"],
        optionalOutputs = @["out/module.lib"],
        cacheable = true, actionCachePolicy = ffpHybrid,
        weakFingerprint = fingerprintForPayload(mode),
        governingLockIdentity = lockIdentityOutsideSolvedGraph())
      # The monitor's account of the run: it read its input.
      let capture = TmpDir / ("capture-" & mode & ".iomon")
      let raw = encodeCanonical(profileRecords(defaultHooksMonitorProfile()) &
        @[MonitorRecord(kind: mrFileRead, observationKind: moFileRead,
          osPid: 4242, threadId: 4242, path: work / "input.txt",
          detail: "")])
      var text = newString(raw.len)
      if raw.len > 0:
        copyMem(addr text[0], unsafeAddr raw[0], raw.len)
      writeFile(capture, text)
      link.monitorDepfile = capture
      var sourceConfig = producerConfig(TmpDir / ("source-" & mode), peer)
      sourceConfig.bypassRunQuota = true
      sourceConfig.enableCachedOutputRestore()
      let source = runBuild(graph([link]), sourceConfig)
      checkpoint source.results[0].stderr
      require source.results[0].status == asSucceeded
      require peer[].len == 1
      removeFile(work / "out/module.dll")
      if present:
        removeFile(work / "out/module.lib")
      else:
        writeFile(work / "out/module.lib", "stale export\n")
      var targetConfig = consumerConfig(TmpDir / ("target-" & mode), peer)
      targetConfig.bypassRunQuota = true
      targetConfig.enableCachedOutputRestore()
      let restored = runBuild(graph([link]), targetConfig)
      checkpoint restored.results[0].stderr
      check restored.results[0].status == asCacheHit
      check restored.results[0].cacheDecision == cdHit
      check not restored.results[0].launched
      check readFile(work / "out/module.dll") == "peer product\n"
      if present:
        check readFile(work / "out/module.lib") == "peer product\n"
      else:
        check not fileExists(work / "out/module.lib")

  test "consumer build hits peer cache after producer publishes bundle":
    resetTmp()
    let sourceRoot = TmpDir / "source"
    let targetRoot = TmpDir / "target"
    # ``ActionResultRecord.outputs[i].path`` is recorded byte-for-byte
    # and the R11 materialization helper restores to that exact path
    # (it doesn't rebase to a per-host root). For the test to demonstrate a peer-
    # cache hit on the consumer side, producer + consumer must share
    # the same declared output path; we put the file in a shared
    # ``outputs/`` sub-dir under TmpDir and delete the producer's
    # output before the consumer runs so we can observe the consumer
    # re-creating it from the peer-cache bundle.
    let sharedOutput = absolutePath(TmpDir / "outputs" / "hello.txt")
    createDir(sourceRoot)
    createDir(targetRoot)
    createDir(splitPath(sharedOutput).head)

    let peer: PeerTable = newTable[string, seq[byte]]()
    let payload = "hello peer cache\n"
    let fingerprintToken = "m5-hit"

    # Producer: builds against an empty source cache, builds the
    # action, and publishes the bundle into the peer table.
    let sourceGraph = buildOneAction(
      sharedOutput, payload, fingerprintToken)
    let sourceResult = runBuild(sourceGraph, producerConfig(sourceRoot, peer))
    check sourceResult.results.len == 1
    check sourceResult.results[0].status == asSucceeded
    check fileExists(sharedOutput)
    check readFile(sharedOutput) == payload
    check peer[].len == 1  # exactly one action got published

    # Wipe the produced output so the consumer-side restore is
    # observable. The consumer's local action-cache + CAS are
    # already empty (separate ``targetRoot``); only the peer table
    # carries the producer's bundle bytes across.
    removeFile(sharedOutput)
    check not fileExists(sharedOutput)

    # Consumer: builds the SAME action against an empty target cache,
    # consults the peer, hits, installs the bundle, re-runs the
    # lookup which now hits locally.
    let targetGraph = buildOneAction(
      sharedOutput, payload, fingerprintToken)
    let targetResult = runBuild(targetGraph, consumerConfig(targetRoot, peer))
    check targetResult.results.len == 1
    let targetEntry = targetResult.results[0]
    check targetEntry.status == asCacheHit  # cache hit, NOT a fresh compile
    check targetEntry.cacheDecision == cdHit
    check fileExists(sharedOutput)
    check readFile(sharedOutput) == payload

  test "consumer with mismatching inputs MISSES peer cache and compiles":
    resetTmp()
    let sourceRoot = TmpDir / "source"
    let targetRoot = TmpDir / "target"
    let sourceOutput = absolutePath(TmpDir / "outputs" / "producer.txt")
    let targetOutput = absolutePath(TmpDir / "outputs" / "consumer.txt")
    createDir(sourceRoot)
    createDir(targetRoot)
    createDir(splitPath(sourceOutput).head)

    let peer: PeerTable = newTable[string, seq[byte]]()
    let producerPayload = "producer-side payload\n"
    let producerToken = "m5-miss-source"
    let consumerPayload = "consumer-side payload\n"  # different bytes
    let consumerToken = "m5-miss-target"           # different fingerprint

    # Producer publishes its bundle keyed by its weak fingerprint.
    let sourceGraph = buildOneAction(
      sourceOutput, producerPayload, producerToken)
    let sourceResult = runBuild(
      sourceGraph, producerConfig(sourceRoot, peer))
    check sourceResult.results[0].status == asSucceeded
    check peer[].len == 1

    # Consumer asks for a DIFFERENT action whose weak fingerprint
    # doesn't match the producer's bundle. The peer-cache fetcher
    # returns `none`, the installer is never called, and the engine
    # falls through to its builtin write path.
    let targetGraph = buildOneAction(
      targetOutput, consumerPayload, consumerToken)
    let targetResult = runBuild(
      targetGraph, consumerConfig(targetRoot, peer))
    check targetResult.results.len == 1
    let targetEntry = targetResult.results[0]
    check targetEntry.status == asSucceeded  # fresh compile
    check targetEntry.cacheDecision == cdMiss
    check fileExists(targetOutput)
    check readFile(targetOutput) == consumerPayload
    # `consumerConfig` has only fetcher + installer (no publisher), so
    # the peer table should still hold exactly the one entry the
    # producer published. A second entry would indicate the consumer
    # accidentally republished — that would be a regression in the
    # wiring path under test.
    check peer[].len == 1

  test "a timestamp-policy record is not offered to the publisher":
    # Campaign M17 (Edge-Derived-Identities.md §3.3a, §3.6): the same action
    # recorded under `ffpTimestamp` stays local. The engine does not hand it
    # to the publisher, says why in the trace, and still serves it locally.
    resetTmp()
    let sourceRoot = TmpDir / "source"
    let output = absolutePath(TmpDir / "outputs" / "timestamp.txt")
    createDir(sourceRoot)
    createDir(splitPath(output).head)
    let peer: PeerTable = newTable[string, seq[byte]]()
    let tsGraph = buildOneAction(output, "timestamp payload\n", "m5-timestamp",
      policy = ffpTimestamp)
    let built = runBuild(tsGraph, producerConfig(sourceRoot, peer))
    check built.results[0].status == asSucceeded
    check peer[].len == 0
    var refused: seq[string] = @[]
    for event in built.trace:
      if event.event == "peer-cache-publish-refused":
        refused.add(event.detail)
    check refused.len == 1
    check refused.len == 1 and "ffpTimestamp input-check policy" in refused[0]
    let again = runBuild(tsGraph, producerConfig(sourceRoot, peer))
    check not again.results[0].launched
    check peer[].len == 0
