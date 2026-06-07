## Peer-Cache-BearSSL M4 verification: signed AdvertiseV2 round trip
## through the TLS tunnel.
##
## The M1 `t_peer_cache_ecdsa_signed_advertisement_tamper_rejection`
## test already runs under `tmTls` since M3's hard cutover; this M4
## test is the same scenario at its post-cutover name, so the M4
## campaign's verification table reads cleanly.
##
##   * AdvertiseV2 signed with real ECDSA-P256 by peer A is accepted
##     by peer B (the tunnel handles transport encryption; the
##     signed advertisement is a piggyback-safe record for SWIM
##     dissemination, so both layers must validate independently).
##   * A tampered AdvertiseV2 fails the per-message signature check
##     on peer B even though the TLS record decrypted cleanly.
##   * `signatureRejectedCount` increments once; the dedup window
##     prevents a single misbehaving peer from bumping the counter
##     every frame.

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

suite "peer-cache TLS signed advertisement round trip (M4)":
  test "valid sig accepted through TLS tunnel; tampered sig rejected":
    let peers = waitFor spawnLoopbackTlsPeers(2,
      fleetTag = "tls_signed_ad_" & $epochTime())
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

      # 1) Well-formed signed advertise — accepted over the TLS tunnel.
      waitFor peers[0].client.sendAdvertiseV2(peers[1].peerId, baseAd)
      var waited = 0
      while waited < 500:
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
        waited += PollIntervalMs
      check peers[1].server.signatureRejectedCount == 0

      # 2) Tampered advertise: signature covers the original bytes,
      # but on-wire bytes mutate. Even though TLS decrypts cleanly,
      # the per-message ECDSA-P256 verification fails.
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

      # 3) A second tampered frame doesn't double-count.
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
