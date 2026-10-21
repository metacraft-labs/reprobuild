## Distributed-Execution M7, threat model G17 (CRED-2: "a revocation that
## takes effect in minutes"): revoking a host, or removing its CA from the
## trust anchors, takes effect on its NEXT FRAME — not at a restart.
##
## Before the fix `AuthorizationPolicy.revoked` was never filled, the trust
## anchors were loaded once at start, and a grants file that failed to parse
## dropped every peer's cache-peer role until the daemon restarted. Now a node
## re-reads `<tls dir>/revoked` and its anchor directory on change (within a
## store-scan interval):
##
##   * B, connected and fetching (positive control), is revoked by A: B's
##     next frame is refused `revoked` and the connection closed; the refusal
##     reaches the off-host sink as a `frame-refused` detection; A's own
##     client drops its connection to B, will not dial it, and refuses B's
##     memo attestations;
##   * B un-revoked: it reconnects and fetches again;
##   * B's CA removed from A's anchors: B's next frame on its open
##     connection is refused, and a new handshake fails; restored, it works;
##   * a revocation list that does not parse refuses EVERY caller (fail
##     closed) and says so to the sink; fixed, callers are admitted again;
##   * a grants file that does not parse drops the default role — and when
##     it parses again the default role comes back (it used to stay gone).
##
## MOCK POLICY — none: production hosts over real TLS, the real sink binary.

import std/[asyncdispatch, options, os, sets, strutils, tempfiles, times,
            unittest]

import repro_cas_store
import repro_peer_cache
import repro_cli_support/peer_cache_wiring

import ../../repro_peer_cache/tests/m7_test_pki

proc pumpFor(ms: int) =
  let deadline = epochTime() + ms.float / 1000.0
  while epochTime() < deadline:
    try: poll(20) except ValueError: sleep(20)

proc tickFor(hosts: openArray[PeerCacheHost]; ms: int) =
  let deadline = epochTime() + ms.float / 1000.0
  while epochTime() < deadline:
    for h in hosts: h.tick(10)

proc blob(host: PeerCacheHost; text: string): BlobDigest =
  var bytes = newSeq[byte](text.len)
  for i, ch in text: bytes[i] = byte(ord(ch))
  var cas = openCasStore(host.storages[0].root)
  defer: cas.close()
  blobDigestFromBytes(bytes(cas.casPut(bytes)))

proc fetchOk(client: PeerCacheClient; peer: PeerId; d: BlobDigest): bool =
  client.fetchTimeoutMs = 1_500
  (waitFor client.requestFetchFrom(peer, d)).isSome

suite "Distributed-Execution M7: revocation takes effect on the next frame (G17)":

  test "revocation, anchor removal, and fail-closed lists":
    let base = createTempDir("m7-g17-", "")
    var a = newTestNode(base, "a")
    var b = newTestNode(base, "b")
    mutualTrust([a, b])
    var sink = prepareEvidenceSink(base)
    sink.acceptsFrom(a)
    sink.acceptsFrom(b)
    sink.startEvidenceSink()
    var hostA, hostB: PeerCacheHost
    defer:
      if not hostB.isNil: hostB.stop()
      if not hostA.isNil: hostA.stop()
      stopEvidenceSink(sink)
      removeDir(base)
    hostA = startPeerCacheHost(tlsConfig(a, evidence = sink.endpoint,
      heartbeatMs = 300), a.identity.hostId, cacheRoot = base / "a-cache",
      stateDir = base / "a-state")
    hostB = startPeerCacheHost(tlsConfig(b, seeds = @[initEndpoint("127.0.0.1",
      hostA.actualPort)], evidence = sink.endpoint), b.identity.hostId,
      cacheRoot = base / "b-cache")
    # A also dials B, so A's own client holds a connection to B.
    discard waitFor hostA.client.connectKnownPeers()
    let aId = a.identity.hostId
    let bId = b.identity.hostId
    let d = blob(hostA, "revocable")
    check hostB.client.fetchOk(aId, d)          # positive control
    check hostA.client.isConnected(bId)

    # -- Revoke B ---------------------------------------------------------
    writeFile(a.tlsDir / "revoked", "# revoked hosts\n" & $bId & "\n")
    tickFor([hostA], 600)
    check hostA.revocationVersion >= 1
    check not hostB.client.fetchOk(aId, d)      # next frame refused
    tickFor([hostA, hostB], 400)
    check hostA.server.gate.refusedCount[rcRevoked] >= 1
    check not hostB.client.isConnected(aId)     # closed by A
    check not hostA.client.isConnected(bId)     # A dropped its own to B
    check bId in hostA.client.revokedIssuers    # B's attestations refused
    discard waitFor hostA.client.connectKnownPeers()
    check not hostA.client.isConnected(bId)     # and does not re-dial B
    var sawRevoked = false
    for e in sink.waitForDetection("frame-refused", pump = proc() =
        tickFor([hostA], 50)):
      if e.record.field("refusal") == "revoked" and
          e.record.field("peer") == $bId and e.senderHostId == aId:
        sawRevoked = true
    check sawRevoked

    # -- Un-revoke: B reconnects and fetches --------------------------------
    writeFile(a.tlsDir / "revoked", "")
    tickFor([hostA], 600)
    discard waitFor hostB.client.connectKnownPeers()
    check hostB.client.fetchOk(aId, d)

    # -- Remove B's CA from A's anchors -------------------------------------
    let anchor = a.anchorsDir / "b.crt"
    let saved = readFile(anchor)
    removeFile(anchor)
    tickFor([hostA], 600)
    check hostA.anchorsVersion >= 1
    check not hostB.client.fetchOk(aId, d)      # open connection: refused
    tickFor([hostA, hostB], 300)
    discard waitFor hostB.client.connectKnownPeers()
    check not hostB.client.isConnected(aId)     # new handshake: refused
    writeFile(anchor, saved)
    tickFor([hostA], 600)
    discard waitFor hostB.client.connectKnownPeers()
    check hostB.client.isConnected(aId)
    check hostB.client.fetchOk(aId, d)

    # -- An unreadable revocation list refuses everyone (fail closed) -------
    writeFile(a.tlsDir / "revoked", "this is not a host id\n")
    tickFor([hostA], 600)
    check hostA.server.gate.policy.revocationUnknown
    check not hostB.client.fetchOk(aId, d)
    check sink.waitForDetection("revocation-list-invalid", pump = proc() =
      tickFor([hostA], 50)).len >= 1
    writeFile(a.tlsDir / "revoked", "")
    tickFor([hostA], 600)
    check not hostA.server.gate.policy.revocationUnknown
    discard waitFor hostB.client.connectKnownPeers()
    check hostB.client.fetchOk(aId, d)

    # -- A broken grants file drops the default role, a fixed one restores it
    writeFile(a.tlsDir / "grants", "garbage\n")
    tickFor([hostA], 600)
    check hostA.server.gate.policy.authenticatedDefault == {}
    check not hostB.client.fetchOk(aId, d)      # unauthorized now
    writeFile(a.tlsDir / "grants", "")
    tickFor([hostA], 600)
    check hostA.server.gate.policy.authenticatedDefault == {brCachePeer}
    discard waitFor hostB.client.connectKnownPeers()
    check hostB.client.fetchOk(aId, d)
