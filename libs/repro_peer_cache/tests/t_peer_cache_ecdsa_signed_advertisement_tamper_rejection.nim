## Peer-Cache-BearSSL M1 verification (M3-migrated): signed
## `AdvertiseV2` round trip using real ECDSA-P256.
##
## Originally landed in M1 against the M3-era `spawnLoopbackMtlsPeers`
## fixture. M3's hard cutover deleted the synthetic-handshake fixture
## and replaced it with `spawnLoopbackTlsPeers`; this test now exercises
## the same per-message signature behaviour over the BearSSL TLS
## tunnel:
##
##   - A well-formed signed advertise is accepted.
##   - A tampered advertise (signature covers different bytes than the
##     ones on the wire) is rejected at verification.
##   - `signatureRejectedCount` increments once per peer per session
##     (the dedup window prevents a single misbehaving peer from
##     bumping the counter every frame).

import std/[asyncdispatch, os, times, unittest]

import repro_peer_cache

{.used.}

const
  PollIntervalMs = 50
  MaxWaitMs = 3_000

proc waitFor1Peer(reg: PeerRegistry; budgetMs: int): bool =
  var waited = 0
  while waited < budgetMs:
    if reg.peerCount() >= 1:
      return true
    try: poll(0) except ValueError: discard
    sleep(PollIntervalMs)
    waited += PollIntervalMs
  reg.peerCount() >= 1

proc waitForReject(server: PeerCacheServer;
                   atLeast: int; budgetMs: int): bool =
  var waited = 0
  while waited < budgetMs:
    if server.signatureRejectedCount >= atLeast:
      return true
    try: poll(0) except ValueError: discard
    sleep(PollIntervalMs)
    waited += PollIntervalMs
  server.signatureRejectedCount >= atLeast

suite "peer-cache ECDSA-P256 signed advertisement tamper rejection":
  test "valid sig accepted; tampered sig rejected; counter de-duped":
    let peers = waitFor spawnLoopbackTlsPeers(2,
      fleetTag = "ecdsa_tamper_" & $epochTime())
    try:
      waitFor dialAllLoopbackClients(peers)
      check waitFor1Peer(peers[0].registry, MaxWaitMs)
      check waitFor1Peer(peers[1].registry, MaxWaitMs)

      # Build a tiny cuckoo filter A wants to advertise to B.
      var rawDigest: array[32, byte]
      for i in 0 ..< 32:
        rawDigest[i] = byte(i + 1)
      let cf = newCuckooFilter(capacity = 64'u32)
      check cf.insert(rawDigest)
      let baseAd = AdvertiseV2(
        sequence: 1'u64,
        mode: amSnapshot,
        filterCapacity: 64'u32,
        filterCount: cf.count,
        filterBytes: cf.serialize())

      # 1) Send a well-formed signed advertise from A to B.
      waitFor peers[0].client.sendAdvertiseV2(peers[1].peerId, baseAd)
      var waited = 0
      while waited < 500:
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
        waited += PollIntervalMs
      check peers[1].server.signatureRejectedCount == 0

      # 2) Build a tampered advertise. Compute the signature over the
      # ORIGINAL filterBytes, then mutate the on-wire filterBytes —
      # so the canonicalised bytes on the wire no longer match the
      # signed input.
      var tamperedAd = baseAd
      tamperedAd.sequence = 2'u64
      tamperedAd.filterBytes = baseAd.filterBytes
      tamperedAd.filterBytes[0] = byte(int(tamperedAd.filterBytes[0]) xor 0xff)
      let canonicalOriginal = canonicaliseAdvertiseForSigning(
        peers[0].peerId,
        AdvertiseV2(
          sequence: tamperedAd.sequence,
          mode: tamperedAd.mode,
          filterCapacity: tamperedAd.filterCapacity,
          filterCount: tamperedAd.filterCount,
          filterBytes: baseAd.filterBytes))
      let forgedSig = signMessage(peers[0].client.ourCert.keypair,
                                  canonicalOriginal)
      tamperedAd.signature = newSeq[byte](64)
      for i in 0 ..< 64:
        tamperedAd.signature[i] = forgedSig[i]
      waitFor peers[0].client.sendRawFrameForTesting(
        peers[1].peerId, mkAdvertiseV2, encodeAdvertiseV2(tamperedAd))
      check waitForReject(peers[1].server, 1, MaxWaitMs)
      check peers[1].server.signatureRejectedCount == 1

      # 3) Second tampered frame: counter stays at 1 (dedup window).
      var tamperedAd2 = tamperedAd
      tamperedAd2.sequence = 3'u64
      tamperedAd2.filterBytes[0] = byte(int(tamperedAd2.filterBytes[0]) xor 0x01)
      waitFor peers[0].client.sendRawFrameForTesting(
        peers[1].peerId, mkAdvertiseV2, encodeAdvertiseV2(tamperedAd2))
      waited = 0
      while waited < 500:
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
        waited += PollIntervalMs
      check peers[1].server.signatureRejectedCount == 1
    finally:
      waitFor shutdownLoopbackPeers(peers)
