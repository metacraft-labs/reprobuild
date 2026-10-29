## Distributed-Execution M7: `t_poisoned_cache_record_is_rejected_and_reported`.
##
## A peer serving (a) a blob whose BLAKE3 does not match its digest, and (b)
## a memo record published for a StrongFingerprint it did not compute, is
## REJECTED, REPORTED OFF-HOST, and MARKED SUSPECT — DET-2's two halves: the
## refusal and the report. The positive control: an honest peer's record is
## accepted and no suspicion is recorded, so the gate is not satisfied by a
## client that distrusts everyone.
##
## Case (c), G15 end to end: M serves A's genuine record attested with a
## leaf that has expired (through the server's `memoEntryReader`
## field — an honest node never serves another host's stale entry). The
## consumer refuses it at its own clock and the `memo-attestation-expired`
## detection reaches the sink, without marking M suspect.
##
## Nodes (all in this process, each a full `PeerCacheHost` on its own real
## TCP port with its own disk stores and its own host CA; every node pins
## every other — the malicious one is a TRUSTED host that has been
## compromised, which is the adversary that matters):
##
##   A  honest producer: builds `hello` from config v1 and publishes an
##      ATTESTED memo entry (`memo_attestation.nim`) for strong S1.
##   M  malicious: serves A's cache root (so it holds the real blobs) plus a
##      memo store of its own, and corrupts content-plane replies.
##   C  consumers (fresh clients), each connected to one peer only.
##
## The evidence sink runs as a separate process (`repro-evidence-sink`);
## every assertion about "reported" reads ITS store.
##
## Poisoning case (b) is the relabel: M takes A's genuine record (computed
## for S1 from config v1) and publishes it under S2 — the strong fingerprint
## a consumer whose `config.h` says v2 actually computes. Before M7 the
## consumer accepted it (fingerprints and digests are self-consistent) and
## installed a v1 binary for v2 inputs. Now the attestation, signed by A over
## S1, does not cover S2: rejected, reported, M suspect, and the consumer
## rebuilds a correct v2 binary.
##
## TRUST PROFILES (2026-10-20). Poisoned-record handling is kept in BOTH
## profiles. The first case runs HARDENED nodes (reports asserted at the
## off-host sink). The second runs TRUSTED nodes — the default profile,
## pinned long-lived host keys, no sink: the same blob and relabel
## poisonings are rejected and the peer marked suspect, and the reports go
## to the consumer's LOCAL detection log (`<state>/peer-cache-detections.log`),
## which is where a trusted node records them (not off-host); the honest
## peer is never suspected there either.
##
## Case (d), `selector-validation-failed` and `memo-selector-mismatch`
## (threat model G23, closed — no longer deferred to M2): M answers a v1
## consumer's request for A's selector with bytes that are not a memo
## entry, with an entry M attests ITSELF (M is pinned and may publish, so
## the attestation verifies) whose record disagrees with its own output
## digests, and (hardened) with an entry describing another selector. Each
## is rejected, reported — at the sink with the served bytes captured
## (hardened), in the consumer's local log (trusted) — and M marked
## suspect; the consumer rebuilds the correct binary.
##
## Cases (d4) and (d5), trusted profile (Distributed-Execution M1): a memo
## entry, or the record inside one, in a NEWER format than this build reads
## — what an honest node of a later version serves in a mixed-version
## fleet — is a plain miss with no detection and no suspicion, while (d1)'s
## malformed bytes keep both. The boundary on both sides of "newer" (M1
## review fix, 2026-10-22): (d6) a memo entry with the right magic and the
## CURRENT version whose body is garbage, and (d7) a properly attested entry
## whose record has the record magic and a version this build KNOWS and
## refuses (the no-evidence epoch) — both malformed, not newer: rejected,
## reported and suspected.
##
## Campaign M17: the edge is built under `ffpChecksum` (it was
## `ffpTimestamp`, whose records a peer-cache producer no longer publishes),
## and the hardened case checks that the same edge under `ffpTimestamp` is
## not published.
##
## MOCK POLICY — none: real sockets, real TLS with host-CA leaves, the real
## build engine and a real C compiler, real disk stores, the real sink
## binary. The "malicious" behaviour uses the server's production
## `responseInterceptor` seam (content corruption) and a memo entry written
## to M's real on-disk store — exactly what a compromised host can do.

import std/[asyncdispatch, options, os, osproc, strutils, tables, times,
            unittest]

import repro_build_engine
import repro_hash
import repro_local_store
import repro_peer_cache
import repro_cli_support/peer_cache_wiring

import ./m7_test_pki

const
  ConfigV1 = "#define GREETING \"hello from config v1\"\n"
  ConfigV2 = "#define GREETING \"hello from config v2\"\n"
  MainSource = """
#include <stdio.h>
#include "config.h"
int main(void) {
  printf("%s\n", GREETING);
  return 0;
}
"""
  ActionId = "m7-poison-hello"
  HeartbeatMs = 300

proc ccPath(): string =
  result = findExe("cc")
  if result.len == 0:
    result = findExe("clang")

proc writeWorkspace(ws, config: string) =
  createDir(ws / "out")
  writeFile(ws / "main.c", MainSource)
  writeFile(ws / "config.h", config)

proc helloGraph(ws: string; policy = ffpChecksum;
                weakText = "t-m7-poisoned-record.hello"): BuildGraph =
  let output = ws / "out" / "hello"
  graph([action(ActionId,
    [ccPath(), "-O1", "-MD", "-MF", "out/hello.d", "-o", output, "main.c"],
    cwd = ws, inputs = ["main.c"], outputs = [output],
    depfile = "out/hello.d", cacheable = true,
    weakFingerprint = weakFingerprintFromText(weakText),
    actionCachePolicy = policy,
    governingLockIdentity = lockIdentityOutsideSolvedGraph())])

proc engineConfig(cacheRoot, ws: string;
                  hooks: PeerCacheEngineHooks): BuildEngineConfig =
  result = defaultBuildEngineConfig(cacheRoot)
  result.rebuildMissingOutputsOnCacheHit = true
  result.deferLocalOutputBlobs = true
  result.bypassRunQuota = true
  result.maxParallelism = 1'u32
  result.portableRoots = @[LogicalRoot(label: "project", path: ws,
    kind: lrkTracked)]
  wireEngineConfig(result, hooks, ws)

proc byId(res: BuildRunResult; id: string): ActionResult =
  for item in res.results:
    if item.id == id:
      return item
  raise newException(ValueError, "missing result " & id)

proc pumpFor(ms: int) =
  let deadline = epochTime() + ms.float / 1000.0
  while epochTime() < deadline:
    try: poll(20) except ValueError: sleep(20)

proc pumpOnce() =
  try: poll(50) except ValueError: sleep(50)

proc awaitHandshakeToken() =
  ## Every per-case consumer below is host `c` dialling M from 127.0.0.1,
  ## and M's receiver gate budgets the connection-establishing frames PER
  ## CALLER: the identity proof per address (`a:127.0.0.1`), the Hello per
  ## host (`h:<c>`), each `Vocabulary` 2/s with a burst of 4. The trusted
  ## case opens eight such connections within about two seconds, so without
  ## pacing the last dial is refused for rate whenever the cases run a
  ## little faster than usual (M1 landing, 2026-10-25: d5's consumer never
  ## connected, and d5 read as "no peer holds a selector"). Waiting one
  ## refill interval before each dial guarantees the dial a token in both
  ## buckets, whatever happened before it.
  let rate = min(Vocabulary[bmIdentityProof].ratePerSecond,
                 Vocabulary[bmHello].ratePerSecond)
  pumpFor(int(1000.0 / rate) + 50)

proc fromPeer(entries: seq[EvidenceEntry]; field, value: string):
    seq[EvidenceEntry] =
  for e in entries:
    if e.record.field(field) == value:
      result.add(e)

suite "Distributed-Execution M7: poisoned cache records":

  test "t_poisoned_cache_record_is_rejected_and_reported":
    if ccPath().len == 0:
      checkpoint("no C compiler on PATH; the test needs a real build")
      fail()
    else:
      let base = normalizedPath(absolutePath(getTempDir() /
        ("repro-m7-poison-" & $getCurrentProcessId())))
      removeDir(base)
      createDir(base)
      var a = newTestNode(base, "a")
      var m = newTestNode(base, "m")
      var c = newTestNode(base, "c")
      mutualTrust([a, m, c])
      var sink = prepareEvidenceSink(base)
      for n in [a, m, c]:
        sink.acceptsFrom(n)
      sink.startEvidenceSink()
      var hosts: seq[PeerCacheHost] = @[]
      defer:
        for h in hosts:
          h.stop()
        stopEvidenceSink(sink)
        removeDir(base)

      let wsA = base / "ws-a"
      writeWorkspace(wsA, ConfigV1)
      let cacheA = base / "cache-a"
      let hostA = startPeerCacheHost(tlsConfig(a, evidence = sink.endpoint,
        heartbeatMs = HeartbeatMs), a.identity.hostId, cacheRoot = cacheA)
      hosts.add(hostA)
      # -- A builds and publishes an attested entry --------------------------
      let hooksA = newPeerCacheEngineHooks(hostA.client,
        openPeerCacheStorage(cacheA), hostA.registry, hostA.attestorFor())
      let built = runBuild(helloGraph(wsA), engineConfig(cacheA, wsA, hooksA))
      check built.byId(ActionId).status == asSucceeded
      check hooksA.stats.publishes == 1
      let storageA = openPeerCacheStorage(cacheA)
      let weaks = storageA.memo.weakFingerprints()
      check weaks.len == 1
      let weak = weaks[0]
      let selA = storageA.memo.listSelectors(weak)[0]
      let entryA = storageA.memo.readMemoEntry(weak,
        selA.strongFingerprint).get()
      check entryA.issuerHostId == a.identity.hostId
      check entryA.issuerSignature.len == 64
      # Campaign M17 (Edge-Derived-Identities.md §3.3a, §3.6): the build runs
      # under ffpChecksum, because a timestamp-policy record is never
      # published. The same edge under ffpTimestamp leaves A's memo store as
      # it was, and the trace names the policy.
      let wsAT = base / "ws-a-timestamp"
      writeWorkspace(wsAT, ConfigV1)
      let tsBuilt = runBuild(helloGraph(wsAT, ffpTimestamp,
        "t-m7-poisoned-record.timestamp"), engineConfig(cacheA, wsAT, hooksA))
      check tsBuilt.byId(ActionId).status == asSucceeded
      check hooksA.stats.publishes == 1
      check storageA.memo.weakFingerprints() == @[weak]
      var tsRefused = false
      for event in tsBuilt.trace:
        if event.event == "peer-cache-publish-refused" and
            "ffpTimestamp input-check policy" in event.detail:
          tsRefused = true
      check tsRefused

      # -- Positive control: an honest peer's record is accepted -------------
      let wsC1 = base / "ws-c1"
      writeWorkspace(wsC1, ConfigV1)
      let cacheC1 = base / "cache-c1"
      let hostC1 = startPeerCacheHost(tlsConfig(c,
        seeds = @[initEndpoint("127.0.0.1", hostA.actualPort)],
        evidence = sink.endpoint, heartbeatMs = HeartbeatMs),
        c.identity.hostId, cacheRoot = cacheC1)
      hosts.add(hostC1)
      check hostC1.client.connectedPeers() == @[a.identity.hostId]
      let hooksC1 = newPeerCacheEngineHooks(hostC1.client,
        openPeerCacheStorage(cacheC1), hostC1.registry, hostC1.attestorFor())
      let honest = runBuild(helloGraph(wsC1),
        engineConfig(cacheC1, wsC1, hooksC1))
      checkpoint("honest fetch: " & hooksC1.stats.lastFetchReason &
        " install: " & hooksC1.stats.lastInstallReason)
      check hooksC1.stats.hits == 1
      check not honest.byId(ActionId).launched
      check execProcess(wsC1 / "out" / "hello").strip() ==
        "hello from config v1"
      check hostC1.client.suspectMarks == 0
      check not hostC1.registry.entries[a.identity.hostId].suspect

      # -- M: serves A's blobs and its own (forged) memo store ---------------
      let cacheM = base / "cache-m"
      createDir(cacheM)
      let hostM = startPeerCacheHost(tlsConfig(m, evidence = sink.endpoint,
        heartbeatMs = HeartbeatMs), m.identity.hostId, cacheRoot = cacheM)
      hosts.add(hostM)
      hostM.addStorage(cacheA)

      # (a) blob BLAKE3 mismatch ---------------------------------------------
      hostM.server.responseInterceptor = proc(p: seq[byte]): seq[byte]
          {.gcsafe.} =
        result = p
        if result.len > 0:
          result[0] = result[0] xor 0xff'u8
      let probe = startPeerCacheHost(tlsConfig(c,
        seeds = @[initEndpoint("127.0.0.1", hostM.actualPort)],
        evidence = sink.endpoint, heartbeatMs = HeartbeatMs),
        c.identity.hostId, cacheRoot = base / "cache-m")
      hosts.add(probe)
      check probe.client.connectedPeers() == @[m.identity.hostId]
      let corrupted = waitFor probe.client.requestFetchFrom(m.identity.hostId,
        entryA.outputDigests[0])
      check corrupted.isNone                         # rejected
      check probe.client.suspectMarks >= 1           # marked suspect
      check probe.registry.entries[m.identity.hostId].suspect
      let mismatch = sink.waitForDetection("blob-digest-mismatch",
        pump = pumpOnce)
      check mismatch.fromPeer("peer", $m.identity.hostId).len >= 1
      # The worker that DETECTED it is the sender the sink stamped — never a
      # field the worker wrote.
      for e in mismatch:
        check e.senderHostId == c.identity.hostId
        # A blob may be source: its bytes are never captured (EVID-6).
        check e.record.payload.len == 0
        check e.record.payloadSize > 0'u64
      check sink.waitForDetection("mark-suspect", pump = pumpOnce).fromPeer(
        "peer", $m.identity.hostId).len >= 1
      hostM.server.responseInterceptor = nil

      # (b) a record published for a strong fingerprint M did not compute ---
      let wsC2 = base / "ws-c2"
      writeWorkspace(wsC2, ConfigV2)
      # The strong fingerprint a v2 consumer computes for A's PathSet.
      let ctxC2 = TwoPhaseContext(peerKey: weak, cwd: wsC2,
        workspaceRoot: wsC2, portable: true)
      let pathSet = decodePeerPathSet(storageA.readBlob(
        selA.pathSetDigest).get())
      let strongV2 = twoPhaseStrongFingerprint(weak, selA.pathSetDigest,
        identitiesFor(pathSet, ctxC2))
      check strongV2 != selA.strongFingerprint
      var forged = entryA                  # A's genuine record and signature
      forged.strongFingerprint = strongV2  # relabelled to the popular key
      let storageM = openPeerCacheStorage(cacheM)
      check storageM.memo.writeMemoEntry(forged)
      discard advertiseStorage(hostM.registry, storageM)
      let cacheC2 = base / "cache-c2"
      let hostC2 = startPeerCacheHost(tlsConfig(c,
        seeds = @[initEndpoint("127.0.0.1", hostM.actualPort)],
        evidence = sink.endpoint, heartbeatMs = HeartbeatMs),
        c.identity.hostId, cacheRoot = cacheC2)
      hosts.add(hostC2)
      let hooksC2 = newPeerCacheEngineHooks(hostC2.client,
        openPeerCacheStorage(cacheC2), hostC2.registry, hostC2.attestorFor())
      let poisoned = runBuild(helloGraph(wsC2),
        engineConfig(cacheC2, wsC2, hooksC2))
      checkpoint("poisoned fetch: " & hooksC2.stats.lastFetchReason)
      check hooksC2.stats.hits == 0                     # rejected
      check poisoned.byId(ActionId).launched            # rebuilt locally
      check execProcess(wsC2 / "out" / "hello").strip() ==
        "hello from config v2"                          # not A's v1 binary
      check hostC2.client.suspectMarks >= 1             # marked suspect
      check hostC2.registry.entries[m.identity.hostId].suspect
      let unbound = sink.waitForDetection("memo-issuer-unbound",
        pump = pumpOnce)
      let fromM = unbound.fromPeer("peer", $m.identity.hostId)
      checkpoint("consumer evidence appender: appended=" &
        $hostC2.appender.appended & " dropped=" & $hostC2.appender.dropped &
        " lastError=" & hostC2.appender.lastError & " detections=" &
        $hostC2.client.detectionsReported)
      for e in unbound:
        checkpoint("memo-issuer-unbound from " & $e.senderHostId & ": " &
          describe(e.record))
      check fromM.len >= 1                              # reported off-host
      for e in fromM:
        check e.senderHostId == c.identity.hostId
        check e.record.field("strongFingerprint") == $strongV2
        # The forged entry itself is captured (metadata, EVID-1).
        check e.record.payload.len > 0
        check decodeMemoEntry(e.record.payload).strongFingerprint == strongV2

      # An UNATTESTED entry (the pre-M7 shape) is refused the same way.
      var bare = entryA
      bare.strongFingerprint = strongV2
      bare.issuerLeafDer = @[]
      bare.issuerSignature = @[]
      check verifyAttestation(bare, hostC2.client.trustAnchorSet,
        hostC2.client.revokedIssuers).ok == false
      check verifyAttestation(entryA, hostC2.client.trustAnchorSet,
        hostC2.client.revokedIssuers).ok

      # (c) an entry whose issuer's leaf expired an hour ago (G15) ----------
      # A's genuine record for S1, attested with a real, minimum-lifetime
      # (60 s) leaf A minted as early as its host CA allows; the test waits
      # until that leaf is past its expiry plus the clock-skew allowance.
      # (The issuing CA must be valid at the attestation's own time, or the
      # verdict is "forged", not "expired" — so the leaf cannot simply be
      # dated hours back.) An honest server drops such an entry
      # (`entryReaderFor` serves another host's entry only while its
      # attestation is fresh); a compromised M answers with it anyway,
      # through the server's production `memoEntryReader` field. The
      # consumer judges it at ITS clock: refused, reported off-host as
      # `memo-attestation-expired` — and NOT marked suspect (a stale entry
      # is not a forgery).
      let longAgo = a.identity.ca.notBefore + 1
      var stale = entryA
      attest(stale, mintLeaf(a.identity, lrDaemon, ttlSeconds = 60,
        now = longAgo), now = longAgo)
      let expiredFrom = longAgo + 60 + LeafClockSkewSeconds + 2
      while getTime().toUnix < expiredFrom:
        pumpFor(500)
      check not attestationFresh(stale)
      let staleBytes = encodeMemoEntry(stale)
      let staleStrong = stale.strongFingerprint
      hostM.server.memoEntryReader = proc(w, st: BlobDigest):
          Option[seq[byte]] {.gcsafe.} =
        if st == staleStrong: some(staleBytes) else: none(seq[byte])
      let wsC3 = base / "ws-c3"
      writeWorkspace(wsC3, ConfigV1)
      let cacheC3 = base / "cache-c3"
      let hostC3 = startPeerCacheHost(tlsConfig(c,
        seeds = @[initEndpoint("127.0.0.1", hostM.actualPort)],
        evidence = sink.endpoint, heartbeatMs = HeartbeatMs),
        c.identity.hostId, cacheRoot = cacheC3)
      hosts.add(hostC3)
      check hostC3.client.connectedPeers() == @[m.identity.hostId]
      let hooksC3 = newPeerCacheEngineHooks(hostC3.client,
        openPeerCacheStorage(cacheC3), hostC3.registry, hostC3.attestorFor())
      let expiredRun = runBuild(helloGraph(wsC3),
        engineConfig(cacheC3, wsC3, hooksC3))
      checkpoint("expired fetch: " & hooksC3.stats.lastFetchReason)
      check hooksC3.stats.hits == 0                     # refused
      check expiredRun.byId(ActionId).launched          # rebuilt locally
      check execProcess(wsC3 / "out" / "hello").strip() ==
        "hello from config v1"
      let expired = sink.waitForDetection("memo-attestation-expired",
        pump = pumpOnce).fromPeer("peer", $m.identity.hostId)
      check expired.len >= 1                            # reached the sink
      for e in expired:
        check e.senderHostId == c.identity.hostId
        check e.record.field("strongFingerprint") == $staleStrong
        check e.record.field("issuer") == $a.identity.hostId
        check decodeMemoEntry(e.record.payload).issuedAtUnix == longAgo
      # Expired is not forged: no suspicion from this consumer.
      check hostC3.client.suspectMarks == 0
      check not hostC3.registry.entries[m.identity.hostId].suspect

      # (d) `selector-validation-failed` and `memo-selector-mismatch` (G23,
      # closed: the positive control M2 was going to build is this one). The
      # compromised M answers a v1 consumer's request for A's selector S1
      # with: (d1) bytes that are not a memo entry; (d2) an entry M attests
      # ITSELF — M is a pinned, publishing host, so the attestation verifies
      # — whose record disagrees with the entry's own output digests; (d3)
      # an entry that describes another selector. Each is rejected, reported
      # at the sink with the served bytes captured (metadata, EVID-1), and M
      # marked suspect; the consumer rebuilds a correct v1 binary.
      let s1 = selA.strongFingerprint
      proc fromMWith(trigger, needle: string): seq[EvidenceEntry] =
        let deadline = epochTime() + 10.0
        while epochTime() < deadline:
          result = @[]
          for e in sink.detections(trigger).fromPeer("peer",
              $m.identity.hostId):
            if needle in e.record.field("reason"):
              result.add(e)
          if result.len > 0:
            return
          pumpOnce()
      proc consumeFromM(tag: string; served: seq[byte]) =
        let bytes = served
        hostM.server.memoEntryReader = proc(w, st: BlobDigest):
            Option[seq[byte]] {.gcsafe.} =
          if st == s1: some(bytes) else: none(seq[byte])
        let ws = base / ("ws-" & tag)
        writeWorkspace(ws, ConfigV1)
        let cache = base / ("cache-" & tag)
        let host = startPeerCacheHost(tlsConfig(c,
          seeds = @[initEndpoint("127.0.0.1", hostM.actualPort)],
          evidence = sink.endpoint, heartbeatMs = HeartbeatMs),
          c.identity.hostId, cacheRoot = cache)
        hosts.add(host)
        check host.client.connectedPeers() == @[m.identity.hostId]
        let hooks = newPeerCacheEngineHooks(host.client,
          openPeerCacheStorage(cache), host.registry, host.attestorFor())
        let run = runBuild(helloGraph(ws), engineConfig(cache, ws, hooks))
        checkpoint(tag & " fetch: " & hooks.stats.lastFetchReason)
        check hooks.stats.hits == 0                     # rejected
        check run.byId(ActionId).launched               # rebuilt locally
        check execProcess(ws / "out" / "hello").strip() ==
          "hello from config v1"
        check host.client.suspectMarks >= 1             # marked suspect
        check host.registry.entries[m.identity.hostId].suspect
      # (d1) not a memo entry at all.
      let garbage = @[byte 0x52, 0x45, 0x50, 0x52, 0x00, 0xff, 0x13, 0x37]
      consumeFromM("d1", garbage)
      let malformed = fromMWith("selector-validation-failed",
        "malformed memo entry")
      check malformed.len >= 1
      for e in malformed:
        check e.senderHostId == c.identity.hostId
        check e.record.payload == garbage               # captured
      # (d2) attested by M itself, inconsistent with its own record.
      var inconsistent = entryA
      inconsistent.outputDigests[0] = entryA.pathSetDigest
      attest(inconsistent, mintLeaf(m.identity, lrDaemon))
      check verifyAttestation(inconsistent, hostC1.client.trustAnchorSet,
        hostC1.client.revokedIssuers).ok      # the issuer binding holds
      consumeFromM("d2", encodeMemoEntry(inconsistent))
      let disagreeing = fromMWith("selector-validation-failed",
        "output digests disagree")
      check disagreeing.len >= 1
      for e in disagreeing:
        check e.senderHostId == c.identity.hostId
        check e.record.field("issuer") == $m.identity.hostId
        check decodeMemoEntry(e.record.payload).outputDigests ==
          inconsistent.outputDigests
      # (d3) an entry for another selector.
      var elsewhere = entryA
      elsewhere.strongFingerprint = strongV2
      consumeFromM("d3", encodeMemoEntry(elsewhere))
      let mismatched = fromMWith("memo-selector-mismatch",
        "does not describe the requested selector")
      check mismatched.len >= 1
      for e in mismatched:
        check e.senderHostId == c.identity.hostId
        check e.record.field("strongFingerprint") == $s1
        check decodeMemoEntry(e.record.payload).strongFingerprint == strongV2
      hostM.server.memoEntryReader = nil

      # -- No suspicion was ever recorded against the honest peer -------------
      pumpFor(500)
      let suspicion = sink.detections("mark-suspect")
      check suspicion.fromPeer("peer", $a.identity.hostId).len == 0
      check sink.detections("memo-issuer-unbound").fromPeer(
        "peer", $a.identity.hostId).len == 0
      # The sink's own chain verifies.
      check verifyEvidenceStore(sink.dir, sinkCheckpointKey(sink),
        allowUnanchoredTail = true).ok

  test "trusted profile: poisoned records are rejected, suspected and logged locally":
    if ccPath().len == 0:
      checkpoint("no C compiler on PATH; the test needs a real build")
      fail()
    else:
      let base = normalizedPath(absolutePath(getTempDir() /
        ("repro-m7-poison-trusted-" & $getCurrentProcessId())))
      removeDir(base)
      createDir(base)
      var a = newTestNode(base, "a")
      var m = newTestNode(base, "m")
      var c = newTestNode(base, "c")
      mutualTrust([a, m, c])
      var hosts: seq[PeerCacheHost] = @[]
      defer:
        for h in hosts:
          h.stop()
        removeDir(base)
      proc trusted(n: TestNode; seeds: seq[Endpoint] = @[]): PeerCacheConfig =
        tlsConfig(n, seeds = seeds, profile = tpTrusted)
      proc localLog(stateDir: string): string =
        let p = stateDir / "peer-cache-detections.log"
        if fileExists(p): readFile(p) else: ""

      let wsA = base / "ws-a"
      writeWorkspace(wsA, ConfigV1)
      let cacheA = base / "cache-a"
      let hostA = startPeerCacheHost(trusted(a), a.identity.hostId,
        cacheRoot = cacheA, stateDir = base / "state-a")
      hosts.add(hostA)
      check hostA.appender.isNil                      # trusted: no sink
      let hooksA = newPeerCacheEngineHooks(hostA.client,
        openPeerCacheStorage(cacheA), hostA.registry, hostA.attestorFor())
      let built = runBuild(helloGraph(wsA), engineConfig(cacheA, wsA, hooksA))
      check built.byId(ActionId).status == asSucceeded
      check hooksA.stats.publishes == 1
      let storageA = openPeerCacheStorage(cacheA)
      let weaks = storageA.memo.weakFingerprints()
      check weaks.len == 1
      let weak = weaks[0]
      let selA = storageA.memo.listSelectors(weak)[0]
      let entryA = storageA.memo.readMemoEntry(weak,
        selA.strongFingerprint).get()
      check entryA.issuerHostId == a.identity.hostId

      # -- Positive control: the honest peer's record is accepted -------------
      let wsC1 = base / "ws-c1"
      writeWorkspace(wsC1, ConfigV1)
      let cacheC1 = base / "cache-c1"
      let stateC1 = base / "state-c1"
      let hostC1 = startPeerCacheHost(trusted(c,
        @[initEndpoint("127.0.0.1", hostA.actualPort)]), c.identity.hostId,
        cacheRoot = cacheC1, stateDir = stateC1)
      hosts.add(hostC1)
      check hostC1.client.connectedPeers() == @[a.identity.hostId]
      let hooksC1 = newPeerCacheEngineHooks(hostC1.client,
        openPeerCacheStorage(cacheC1), hostC1.registry, hostC1.attestorFor())
      let honest = runBuild(helloGraph(wsC1),
        engineConfig(cacheC1, wsC1, hooksC1))
      check hooksC1.stats.hits == 1
      check not honest.byId(ActionId).launched
      check execProcess(wsC1 / "out" / "hello").strip() ==
        "hello from config v1"
      check hostC1.client.suspectMarks == 0
      check "mark-suspect" notin localLog(stateC1)

      # -- M: serves A's blobs and its own forged memo store -----------------
      let cacheM = base / "cache-m"
      createDir(cacheM)
      let hostM = startPeerCacheHost(trusted(m), m.identity.hostId,
        cacheRoot = cacheM, stateDir = base / "state-m")
      hosts.add(hostM)
      hostM.addStorage(cacheA)

      # (a) blob BLAKE3 mismatch: rejected, suspected, logged locally.
      hostM.server.responseInterceptor = proc(p: seq[byte]): seq[byte]
          {.gcsafe.} =
        result = p
        if result.len > 0:
          result[0] = result[0] xor 0xff'u8
      let stateProbe = base / "state-probe"
      let probe = startPeerCacheHost(trusted(c,
        @[initEndpoint("127.0.0.1", hostM.actualPort)]), c.identity.hostId,
        cacheRoot = base / "cache-probe", stateDir = stateProbe)
      hosts.add(probe)
      check probe.client.connectedPeers() == @[m.identity.hostId]
      let corrupted = waitFor probe.client.requestFetchFrom(m.identity.hostId,
        entryA.outputDigests[0])
      check corrupted.isNone                         # rejected
      check probe.client.suspectMarks >= 1           # marked suspect
      check probe.registry.entries[m.identity.hostId].suspect
      let probeLog = localLog(stateProbe)
      checkpoint("probe's local detection log:\n" & probeLog)
      check "blob-digest-mismatch" in probeLog       # reported (locally)
      check "mark-suspect" in probeLog
      check $m.identity.hostId in probeLog
      hostM.server.responseInterceptor = nil

      # (b) a record relabelled to a strong fingerprint M did not compute.
      let wsC2 = base / "ws-c2"
      writeWorkspace(wsC2, ConfigV2)
      let ctxC2 = TwoPhaseContext(peerKey: weak, cwd: wsC2,
        workspaceRoot: wsC2, portable: true)
      let pathSet = decodePeerPathSet(storageA.readBlob(
        selA.pathSetDigest).get())
      let strongV2 = twoPhaseStrongFingerprint(weak, selA.pathSetDigest,
        identitiesFor(pathSet, ctxC2))
      check strongV2 != selA.strongFingerprint
      var forged = entryA
      forged.strongFingerprint = strongV2
      let storageM = openPeerCacheStorage(cacheM)
      check storageM.memo.writeMemoEntry(forged)
      discard advertiseStorage(hostM.registry, storageM)
      let cacheC2 = base / "cache-c2"
      let stateC2 = base / "state-c2"
      let hostC2 = startPeerCacheHost(trusted(c,
        @[initEndpoint("127.0.0.1", hostM.actualPort)]), c.identity.hostId,
        cacheRoot = cacheC2, stateDir = stateC2)
      hosts.add(hostC2)
      let hooksC2 = newPeerCacheEngineHooks(hostC2.client,
        openPeerCacheStorage(cacheC2), hostC2.registry, hostC2.attestorFor())
      let poisoned = runBuild(helloGraph(wsC2),
        engineConfig(cacheC2, wsC2, hooksC2))
      checkpoint("poisoned fetch: " & hooksC2.stats.lastFetchReason)
      check hooksC2.stats.hits == 0                     # rejected
      check poisoned.byId(ActionId).launched            # rebuilt locally
      check execProcess(wsC2 / "out" / "hello").strip() ==
        "hello from config v2"                          # not A's v1 binary
      check hostC2.client.suspectMarks >= 1             # marked suspect
      check hostC2.registry.entries[m.identity.hostId].suspect
      let c2Log = localLog(stateC2)
      checkpoint("consumer's local detection log:\n" & c2Log)
      check "memo-issuer-unbound" in c2Log              # reported (locally)
      check $strongV2 in c2Log
      check "mark-suspect" in c2Log

      # (d) `selector-validation-failed` (G23 closed) in the trusted
      # profile: M answers a v1 consumer's request for S1 with bytes that
      # are not a memo entry, then with an entry it attests itself (its
      # pinned long-lived key) whose record disagrees with the entry's
      # output digests. Rejected, M suspected, and the report in the
      # consumer's local detection log.
      let s1 = selA.strongFingerprint
      proc consumeFromM(tag: string; served: seq[byte]): string =
        let bytes = served
        hostM.server.memoEntryReader = proc(w, st: BlobDigest):
            Option[seq[byte]] {.gcsafe.} =
          if st == s1: some(bytes) else: none(seq[byte])
        let ws = base / ("ws-" & tag)
        writeWorkspace(ws, ConfigV1)
        let cache = base / ("cache-" & tag)
        let state = base / ("state-" & tag)
        awaitHandshakeToken()
        let host = startPeerCacheHost(trusted(c,
          @[initEndpoint("127.0.0.1", hostM.actualPort)]), c.identity.hostId,
          cacheRoot = cache, stateDir = state)
        hosts.add(host)
        check host.client.connectedPeers() == @[m.identity.hostId]
        let hooks = newPeerCacheEngineHooks(host.client,
          openPeerCacheStorage(cache), host.registry, host.attestorFor())
        let run = runBuild(helloGraph(ws), engineConfig(cache, ws, hooks))
        checkpoint(tag & " fetch: " & hooks.stats.lastFetchReason)
        check hooks.stats.hits == 0                     # rejected
        check run.byId(ActionId).launched               # rebuilt locally
        check execProcess(ws / "out" / "hello").strip() ==
          "hello from config v1"
        check host.client.suspectMarks >= 1             # marked suspect
        check host.registry.entries[m.identity.hostId].suspect
        result = localLog(state)
        checkpoint(tag & " consumer's local detection log:\n" & result)
      let d1Log = consumeFromM("d1",
        @[byte 0x52, 0x45, 0x50, 0x52, 0x00, 0xff, 0x13, 0x37])
      check "selector-validation-failed" in d1Log       # reported (locally)
      check "malformed memo entry" in d1Log
      check "mark-suspect" in d1Log
      var inconsistent = entryA
      inconsistent.outputDigests[0] = entryA.pathSetDigest
      attest(inconsistent, mintNodeCredential(m.identity, lrDaemon,
        ipPinnedHostKey))
      let d2Log = consumeFromM("d2", encodeMemoEntry(inconsistent))
      check "selector-validation-failed" in d2Log
      check "output digests disagree" in d2Log
      check ("issuer=" & $m.identity.hostId) in d2Log
      # (d6) The current memo-entry version with a garbage body: not a newer
      # format (the version is this build's own), so malformed.
      let current = encodeMemoEntry(entryA)
      var garbled = current[0 ..< 6]
      garbled.add(@[byte 0xde, 0xad, 0xbe, 0xef, 0x13, 0x37, 0x00, 0xff])
      check not memoEntryIsNewerFormat(garbled).newer
      let d6Log = consumeFromM("d6", garbled)
      check "selector-validation-failed" in d6Log       # reported (locally)
      check "malformed memo entry" in d6Log
      check "mark-suspect" in d6Log
      check "newer format" notin d6Log
      # (d7) An attested entry whose record carries the record magic and a
      # version this build knows and REFUSES (a trust decision, not a
      # newer writer): malformed.
      let refusedVersions = actionRecordVersionsThisBuildRefuses()
      checkpoint("record versions this build refuses: " & $refusedVersions)
      check refusedVersions.len > 0 and max(refusedVersions) >= 1
      let refusedVersion = max(refusedVersions)
      var refusedRecord = entryA
      refusedRecord.recordBytes[4] = byte(refusedVersion and 0xff)
      refusedRecord.recordBytes[5] = byte(refusedVersion shr 8)
      attest(refusedRecord, mintNodeCredential(m.identity, lrDaemon,
        ipPinnedHostKey))
      check not actionRecordIsNewerFormat(refusedRecord.recordBytes).newer
      let d7Log = consumeFromM("d7", encodeMemoEntry(refusedRecord))
      check "selector-validation-failed" in d7Log
      check "mark-suspect" in d7Log
      check "newer format" notin d7Log

      # (d4, d5) A mixed-version fleet (Distributed-Execution M1,
      # landing-review carry-over): an honest NEWER node serves a memo entry
      # in a newer format (d4), or a current entry whose record is in a
      # newer format (d5). Neither is malformed or forged — this build just
      # cannot read it — so it is a plain miss: the consumer rebuilds,
      # reports NO detection and does NOT suspect the peer. (d1) above,
      # bytes that are not a memo entry at all, still is rejected, reported
      # and suspected.
      var newerEntry = encodeMemoEntry(entryA)
      let entryVersion = uint16(newerEntry[4]) or (uint16(newerEntry[5]) shl 8)
      newerEntry[4] = byte((entryVersion + 1) and 0xff)
      newerEntry[5] = byte((entryVersion + 1) shr 8)
      check memoEntryIsNewerFormat(newerEntry).newer
      var newerRecord = entryA
      let unknownRecord = firstUnknownActionRecordVersion()
      newerRecord.recordBytes[4] = byte(unknownRecord and 0xff)
      newerRecord.recordBytes[5] = byte(unknownRecord shr 8)
      attest(newerRecord, mintNodeCredential(m.identity, lrDaemon,
        ipPinnedHostKey))
      check actionRecordIsNewerFormat(newerRecord.recordBytes).newer
      proc serveNewerFromM(tag: string; served: seq[byte]):
          tuple[hooks: PeerCacheEngineHooks; host: PeerCacheHost;
                launched: bool; output, log: string] =
        let bytes = served
        hostM.server.memoEntryReader = proc(w, st: BlobDigest):
            Option[seq[byte]] {.gcsafe.} =
          if st == s1: some(bytes) else: none(seq[byte])
        let ws = base / ("ws-" & tag)
        writeWorkspace(ws, ConfigV1)
        let cache = base / ("cache-" & tag)
        let state = base / ("state-" & tag)
        awaitHandshakeToken()
        result.host = startPeerCacheHost(trusted(c,
          @[initEndpoint("127.0.0.1", hostM.actualPort)]), c.identity.hostId,
          cacheRoot = cache, stateDir = state)
        hosts.add(result.host)
        # The precondition of a meaningful miss: the consumer IS connected
        # to M (a refused dial would make "a miss" vacuous).
        check result.host.client.connectedPeers() == @[m.identity.hostId]
        result.hooks = newPeerCacheEngineHooks(result.host.client,
          openPeerCacheStorage(cache), result.host.registry,
          result.host.attestorFor())
        let run = runBuild(helloGraph(ws), engineConfig(cache, ws,
          result.hooks))
        result.launched = run.byId(ActionId).launched
        result.output = execProcess(ws / "out" / "hello").strip()
        result.log = localLog(state)
      for (tag, served) in [("d4", newerEntry),
                            ("d5", encodeMemoEntry(newerRecord))]:
        let got = serveNewerFromM(tag, served)
        checkpoint(tag & " fetch: " & got.hooks.stats.lastFetchReason &
          "\n" & tag & " consumer's local detection log:\n" & got.log)
        check got.host.client.connectedPeers() == @[m.identity.hostId]
        check got.hooks.stats.hits == 0                 # a miss
        check got.launched                              # rebuilt locally
        check got.output == "hello from config v1"
        check "newer format" in got.hooks.stats.lastFetchReason
        check got.host.client.suspectMarks == 0         # NOT suspected
        check not got.host.registry.entries[m.identity.hostId].suspect
        check "mark-suspect" notin got.log              # nothing reported
        check "selector-validation-failed" notin got.log
      hostM.server.memoEntryReader = nil

      # -- The honest peer was never suspected --------------------------------
      for log in [localLog(stateC1), probeLog, c2Log, d1Log, d2Log, d6Log,
                  d7Log]:
        for line in log.splitLines:
          if "mark-suspect" in line:
            check $a.identity.hostId notin line
