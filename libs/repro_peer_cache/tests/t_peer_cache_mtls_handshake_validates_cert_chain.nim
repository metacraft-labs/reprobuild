## Peer-Cache-Scale M3 verification: mTLS auth-handshake validates the
## peer's "cert chain" (i.e. the peer's pubkey appears in our trust
## anchor file), and rejects peers whose key is not in the anchor.
##
## The test exercises three peers configured for `tmMtls`:
##
##   - A and B have keypairs whose pubkeys are in a shared trust
##     anchor file. Their handshake completes and they enter each
##     other's membership.
##   - C has a keypair whose pubkey is NOT in the shared trust anchor.
##     A's accept loop rejects C at handshake time; B's accept loop
##     rejects C at handshake time. C's registry stays empty of A + B.
##
## All in-process via `127.0.0.1:0` loopback. The shared anchor file
## lives under a per-test temp directory so the assertions are
## independent of any other test's state.

import std/[asyncdispatch, os, unittest]

import repro_peer_cache

const
  PollIntervalMs = 50
  MaxWaitMs = 3_000

proc allMembershipsAtLeast(peers: seq[LoopbackPeer]; n: int): bool =
  for peer in peers:
    if peer.registry.peerCount() < n:
      return false
  true

suite "peer-cache mTLS handshake validates cert chain":
  test "trusted peers handshake; untrusted peer rejected":
    # Per-test temp dir for the anchor file.
    let tmpDir = getTempDir() / "t_peer_cache_mtls_handshake"
    createDir(tmpDir)
    defer:
      try: removeDir(tmpDir) except CatchableError: discard

    # A + B share the same anchor; C has a separate keypair NOT in the
    # shared anchor.
    let kpA = generateKeypair()
    let kpB = generateKeypair()
    let kpC = generateKeypair()
    let sharedAnchorPath = tmpDir / "shared.anchor"
    writeTrustAnchors(sharedAnchorPath, [kpA, kpB])
    let sharedAnchors = loadTrustAnchors(sharedAnchorPath)

    # C also has an anchor file (so it can run as `tmMtls`), but it
    # only knows itself — so when C dials A or B it doesn't know A/B
    # are trustworthy either, and vice versa.
    let cOnlyAnchorPath = tmpDir / "c_only.anchor"
    writeTrustAnchors(cOnlyAnchorPath, [kpC])
    let cOnlyAnchors = loadTrustAnchors(cOnlyAnchorPath)

    let specs = @[
      MtlsPeerSpec(keypair: kpA, anchors: sharedAnchors),
      MtlsPeerSpec(keypair: kpB, anchors: sharedAnchors),
      MtlsPeerSpec(keypair: kpC, anchors: cOnlyAnchors)]
    let peers = spawnLoopbackMtlsPeers(specs, seedAll = true)
    try:
      waitFor dialAllLoopbackClients(peers)
      # Poll until A and B see each other (membership count = 1),
      # but C remains alone (membership count = 0). C's dials to A
      # and B fail at the auth handshake.
      var waited = 0
      while waited < MaxWaitMs and
            not (peers[0].registry.peerCount() >= 1 and
                 peers[1].registry.peerCount() >= 1):
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
        waited += PollIntervalMs

      # A sees B (and only B).
      check peers[0].registry.peerCount() == 1
      check peers[0].registry.hasPeer(peers[1].peerId)
      # B sees A (and only A).
      check peers[1].registry.peerCount() == 1
      check peers[1].registry.hasPeer(peers[0].peerId)
      # C sees nobody.
      check peers[2].registry.peerCount() == 0

      # Handshake-rejection counters fire on at least one of:
      #   - C dialing A or B (C rejects A/B at the challenge step
      #     because A/B's pubkeys aren't in C's anchor; A/B reject C
      #     at the challenge step because C's pubkey isn't in their
      #     anchor).
      #   - A or B dialing C (mirror).
      # The exact split varies with the order of accept/dial, so we
      # only require the *aggregate* failed-handshake count exceeds
      # zero on either side of the C-quarantine.
      let totalRejections =
        peers[0].server.handshakeRejectedCount +
        peers[1].server.handshakeRejectedCount +
        peers[2].server.handshakeRejectedCount +
        peers[0].client.handshakeRejectedCount +
        peers[1].client.handshakeRejectedCount +
        peers[2].client.handshakeRejectedCount
      check totalRejections >= 1
    finally:
      waitFor shutdownLoopbackPeers(peers)
