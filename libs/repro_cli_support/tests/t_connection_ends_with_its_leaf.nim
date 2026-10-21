## Distributed-Execution M7, threat model G15: a connection does not outlive
## the short-lived leaf that opened it, on either end.
##
## Leaves live at most an hour (CRED-1), but the leaf was checked once, at
## the handshake, so a connection opened inside a leaf's hour stayed
## authenticated after it — a stolen leaf kept its hour's connections for as
## long as it liked. Now:
##
##   * the RECEIVER judges the caller's leaf on every frame (`boundary`
##     credential check): once the leaf has expired (beyond the clock-skew
##     allowance) the next frame is refused `unauthenticated` and the
##     connection is closed;
##   * the CALLER judges the server's leaf on every frame it receives on its
##     own connection (the outbound gate), the same way;
##   * an honest node never hits either: `rotateExpiringConnections` closes
##     and re-dials, with its current leaf, any connection whose leaf (its
##     own or the peer's) is about to expire.
##
## Clocks: each side's gate takes the time from a clock seam
## (`server.clock`, `client.clock`); the test moves one side's clock past the
## leaf's expiry instead of waiting an hour. Justified per the mock policy:
## the property is a function of the receiver's clock, and the seam is the
## only way to evaluate it inside a test's time budget.
##
## MOCK POLICY — the clock seam above; everything else is production: two
## `PeerCacheHost`s over real TLS with host-CA leaves.

import std/[asyncdispatch, options, os, tempfiles, times, unittest]

import repro_cas_store
import repro_peer_cache
import repro_cli_support/peer_cache_wiring

import ../../repro_peer_cache/tests/m7_test_pki

proc pumpFor(ms: int) =
  let deadline = epochTime() + ms.float / 1000.0
  while epochTime() < deadline:
    try: poll(20) except ValueError: sleep(20)

proc blob(host: PeerCacheHost; text: string): BlobDigest =
  var bytes = newSeq[byte](text.len)
  for i, ch in text: bytes[i] = byte(ord(ch))
  let storage = host.storages[0]
  var cas = openCasStore(storage.root)
  defer: cas.close()
  blobDigestFromBytes(bytes(cas.casPut(bytes)))

suite "Distributed-Execution M7: a connection ends with its leaf (G15)":

  test "the receiver refuses a frame once the caller's leaf has expired":
    let base = createTempDir("m7-g15-", "")
    defer: removeDir(base)
    var a = newTestNode(base, "a")
    var b = newTestNode(base, "b")
    mutualTrust([a, b])
    let hostA = startPeerCacheHost(tlsConfig(a), a.identity.hostId,
      cacheRoot = base / "a-cache")
    defer: hostA.stop()
    let hostB = startPeerCacheHost(tlsConfig(b, seeds = @[initEndpoint(
      "127.0.0.1", hostA.actualPort)]), b.identity.hostId,
      cacheRoot = base / "b-cache")
    defer: hostB.stop()
    check hostB.client.isConnected(a.identity.hostId)
    let digest = blob(hostA, "leaf-bound connection")
    # Positive control: inside the leaf's hour the frame is answered.
    check (waitFor hostB.client.requestFetchFrom(a.identity.hostId,
      digest)).isSome
    let refusedBefore = hostA.server.gate.refusedCount[rcUnauthenticated]
    # A's clock moves past B's leaf (an hour, plus the skew allowance).
    let bLeafEnd = hostB.leaf.cert.notAfter
    hostA.server.clock = proc(): int64 {.gcsafe, closure.} =
      (bLeafEnd + LeafClockSkewSeconds + 5) * 1000
    hostB.client.fetchTimeoutMs = 1_500
    check (waitFor hostB.client.requestFetchFrom(a.identity.hostId,
      digest)).isNone
    pumpFor(300)
    check hostA.server.gate.refusedCount[rcUnauthenticated] == refusedBefore + 1
    check not hostB.client.isConnected(a.identity.hostId)   # closed

  test "the caller refuses a reply once the server's leaf has expired":
    let base = createTempDir("m7-g15-out-", "")
    defer: removeDir(base)
    var a = newTestNode(base, "a")
    var b = newTestNode(base, "b")
    mutualTrust([a, b])
    let hostA = startPeerCacheHost(tlsConfig(a), a.identity.hostId,
      cacheRoot = base / "a-cache")
    defer: hostA.stop()
    let hostB = startPeerCacheHost(tlsConfig(b, seeds = @[initEndpoint(
      "127.0.0.1", hostA.actualPort)]), b.identity.hostId,
      cacheRoot = base / "b-cache")
    defer: hostB.stop()
    let digest = blob(hostA, "outbound leaf check")
    check (waitFor hostB.client.requestFetchFrom(a.identity.hostId,
      digest)).isSome
    let aLeafEnd = hostA.leaf.cert.notAfter
    hostB.client.clock = proc(): int64 {.gcsafe, closure.} =
      (aLeafEnd + LeafClockSkewSeconds + 5) * 1000
    hostB.client.fetchTimeoutMs = 1_500
    check (waitFor hostB.client.requestFetchFrom(a.identity.hostId,
      digest)).isNone
    pumpFor(300)
    check hostB.client.gate.refusedCount[rcUnauthenticated] >= 1
    check not hostB.client.isConnected(a.identity.hostId)

  test "an honest node re-dials before either leaf expires":
    let base = createTempDir("m7-g15-rot-", "")
    defer: removeDir(base)
    var a = newTestNode(base, "a")
    var b = newTestNode(base, "b")
    mutualTrust([a, b])
    let hostA = startPeerCacheHost(tlsConfig(a), a.identity.hostId,
      cacheRoot = base / "a-cache")
    defer: hostA.stop()
    let hostB = startPeerCacheHost(tlsConfig(b, seeds = @[initEndpoint(
      "127.0.0.1", hostA.actualPort)]), b.identity.hostId,
      cacheRoot = base / "b-cache")
    defer: hostB.stop()
    check hostB.client.isConnected(a.identity.hostId)
    # Nothing is close to expiry: nothing rotates.
    check (waitFor hostB.client.rotateExpiringConnections()) == 0
    # Four minutes before the end of A's leaf: B closes, and re-dials.
    let aLeafEnd = hostA.leaf.cert.notAfter
    hostB.client.clock = proc(): int64 {.gcsafe, closure.} =
      (aLeafEnd - 240) * 1000
    check (waitFor hostB.client.rotateExpiringConnections()) == 1
    check not hostB.client.isConnected(a.identity.hostId)
    hostB.client.clock = nil
    discard waitFor hostB.client.connectKnownPeers()
    check hostB.client.isConnected(a.identity.hostId)
    let digest = blob(hostA, "after rotation")
    check (waitFor hostB.client.requestFetchFrom(a.identity.hostId,
      digest)).isSome
