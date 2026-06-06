## Peer-Cache-Scale M3 verification: signed `AdvertiseV2` round trip.
##
## Peer A signs an `AdvertiseV2`; peer B verifies (both keys live in
## the same shared trust anchor file). Then A sends a tampered frame
## (one byte flipped in `filterBytes`) — B rejects the signature,
## `signatureRejectedCount` increments to 1, and further tampered
## frames within the dedup window keep the counter at 1.

import std/[asyncdispatch, os, unittest]

import repro_peer_cache

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

suite "peer-cache signed advertisement round trip":
  test "valid sig accepted; tampered sig rejected; counter de-duped":
    let tmpDir = getTempDir() / "t_peer_cache_signed_ad"
    createDir(tmpDir)
    defer:
      try: removeDir(tmpDir) except CatchableError: discard

    let kpA = generateKeypair()
    let kpB = generateKeypair()
    let anchorPath = tmpDir / "shared.anchor"
    writeTrustAnchors(anchorPath, [kpA, kpB])
    let anchors = loadTrustAnchors(anchorPath)

    let peers = spawnLoopbackMtlsPeers(@[
      MtlsPeerSpec(keypair: kpA, anchors: anchors),
      MtlsPeerSpec(keypair: kpB, anchors: anchors)])
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

      # 1) Send a well-formed signed advertise from A's client to B's
      # registered peer ID (which is A's selfPeerId from B's POV).
      # Since the client.connections key is the *remote* peer ID,
      # A's client uses peers[1].peerId as the target.
      waitFor peers[0].client.sendAdvertiseV2(peers[1].peerId, baseAd)
      # Pump the dispatcher so B's server-side reader processes the
      # frame.
      var waited = 0
      while waited < 500:
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
        waited += PollIntervalMs

      # B's server should have applied the advertise — no signature
      # rejections yet.
      check peers[1].server.signatureRejectedCount == 0

      # 2) Build a tampered advertise. Flip the first byte of
      # filterBytes; sign with A's key so the signature is correctly
      # computed over the *original* canonical bytes — the receiver
      # will see a mismatch between the signed message and the
      # received message. We do this by hand-encoding: sign over the
      # canonical of `baseAd`, then send the tampered frame with that
      # signature. The signed canonical bytes don't match the
      # tampered filterBytes → verify fails.
      var tamperedAd = baseAd
      tamperedAd.sequence = 2'u64
      tamperedAd.filterBytes = baseAd.filterBytes
      tamperedAd.filterBytes[0] = byte(int(tamperedAd.filterBytes[0]) xor 0xff)
      # Sign over the ORIGINAL (untampered) bytes — to forge a frame
      # whose signature looks valid but covers different content.
      let canonicalOriginal = canonicaliseAdvertiseForSigning(
        peers[0].peerId,
        AdvertiseV2(
          sequence: tamperedAd.sequence,
          mode: tamperedAd.mode,
          filterCapacity: tamperedAd.filterCapacity,
          filterCount: tamperedAd.filterCount,
          filterBytes: baseAd.filterBytes))
      let forgedSig = signMessage(kpA, canonicalOriginal)
      tamperedAd.signature = newSeq[byte](64)
      for i in 0 ..< 64:
        tamperedAd.signature[i] = forgedSig[i]
      # Send the tampered frame raw via the client's connection
      # (sendAdvertiseV2 would re-sign; we want the forged sig to
      # cover the WRONG message).
      waitFor peers[0].client.sendRawFrameForTesting(
        peers[1].peerId, mkAdvertiseV2, encodeAdvertiseV2(tamperedAd))
      check waitForReject(peers[1].server, 1, MaxWaitMs)
      check peers[1].server.signatureRejectedCount == 1

      # 3) Send a second tampered frame — counter stays at 1 because
      # the dedup index already records peer A.
      var tamperedAd2 = tamperedAd
      tamperedAd2.sequence = 3'u64
      tamperedAd2.filterBytes[0] = byte(int(tamperedAd2.filterBytes[0]) xor 0x01)
      waitFor peers[0].client.sendRawFrameForTesting(
        peers[1].peerId, mkAdvertiseV2, encodeAdvertiseV2(tamperedAd2))
      # Give the dispatcher a chance to process.
      waited = 0
      while waited < 500:
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
        waited += PollIntervalMs
      check peers[1].server.signatureRejectedCount == 1
    finally:
      waitFor shutdownLoopbackPeers(peers)
