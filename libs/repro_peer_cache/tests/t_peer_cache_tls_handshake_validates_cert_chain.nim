## Peer-Cache-BearSSL M4 verification: TLS handshake validates a
## cert chain rooted in a shared mini-CA.
##
## Two peers each present a peer cert signed by a shared mini-CA.
## The trust anchor is the CA cert (with `isCa = true`); peer leaf
## certs are NOT in the anchor set. The TLS handshake completes
## because BearSSL's X.509 verifier walks the chain from the leaf to
## the CA and accepts.
##
## A third peer presenting a cert signed by a *different* CA is
## rejected at chain validation when it tries to dial peer A; A's
## `tlsHandshakeRejectedCount` increments.

import std/[asyncdispatch, os, strutils, tables, times, unittest]

import repro_peer_cache

{.used.}

const
  LoopbackCidrLocal = "127.0.0.0/8"
  PollIntervalMs = 50
  MaxWaitMs = 5_000

proc waitForCount(reg: PeerRegistry; n: int; budgetMs: int): bool =
  var waited = 0
  while waited < budgetMs:
    if reg.peerCount() >= n:
      return true
    try: poll(0) except ValueError: discard
    sleep(PollIntervalMs)
    waited += PollIntervalMs
  reg.peerCount() >= n

type
  CaTrustPeer = object
    peerId: PeerId
    cert: CertAndKey
    server: PeerCacheServer
    client: PeerCacheClient
    registry: PeerRegistry

proc mintCaSignedPeer(caCert: CertAndKey; subjectCn: string): CertAndKey =
  let peerKp = generateKeypair()
  result = generateCaSignedCert(
    peerKeypair = peerKp,
    subjectCn = subjectCn,
    caCertDer = caCert.certDer,
    caKeypair = caCert.keypair,
    validityDays = 365)

proc setupCaAnchorDir(tmp: string; tag: string; caCert: CertAndKey): TrustAnchorSet =
  let anchorDir = tmp / ("anchors_" & tag)
  createDir(anchorDir)
  writeFile(anchorDir / "ca.crt", caCert.certPem)
  loadTrustAnchorDir(anchorDir)

proc spawnCaTrustPeer(caCert: CertAndKey; tmp: string;
                      idx: int): CaTrustPeer =
  let peerCnHex = "peer-" & $idx & "-" & $epochTime()
  let cert = mintCaSignedPeer(caCert, peerCnHex)
  let peerId = derivePeerIdFromPublicKey(cert.keypair.publicKey)
  let anchors = setupCaAnchorDir(tmp, "p" & $idx, caCert)
  let allowlist = @[parseCidrV4(LoopbackCidrLocal)]
  let endpoint = initEndpoint("127.0.0.1", Port(0))
  let registry = newPeerRegistry(peerId, endpoint)
  let server = newPeerCacheServer(
    selfPeerId = peerId,
    listenAddr = "127.0.0.1",
    listenPort = Port(0),
    registry = registry,
    cidrAllowlist = allowlist,
    trustMode = tmTls,
    ourCert = cert,
    trustAnchorSet = anchors)
  server.start()
  result = CaTrustPeer(
    peerId: peerId,
    cert: cert,
    server: server,
    client: nil,
    registry: registry)

suite "peer-cache TLS handshake validates cert chain (M4)":
  test "two peers signed by shared mini-CA complete handshake":
    let tmp = getTempDir() / "peer_cache_m4_chain_" & $epochTime()
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    try:
      # Shared mini-CA.
      let caKp = generateKeypair()
      let caCert = generateCaCert(caKp, subjectCn = "shared-ca",
                                  validityDays = 365)

      # Two peers signed by the shared CA, each with the CA cert as
      # the sole anchor.
      var peerA = spawnCaTrustPeer(caCert, tmp, 0)
      var peerB = spawnCaTrustPeer(caCert, tmp, 1)
      let peers = [addr peerA, addr peerB]

      # All-to-all client wiring.
      let allowlist = @[parseCidrV4(LoopbackCidrLocal)]
      for i in 0 ..< 2:
        let other = peers[1 - i]
        let anchors = setupCaAnchorDir(tmp,
          "client_" & $i, caCert)
        let cli = newPeerCacheClient(
          selfPeerId = peers[i].peerId,
          listenPort = uint16(peers[i].server.actualPort),
          registry = peers[i].registry,
          seedPeers = @[initEndpoint("127.0.0.1",
                                     other.server.actualPort)],
          cidrAllowlist = allowlist,
          trustMode = tmTls,
          ourCert = peers[i].cert,
          trustAnchorSet = anchors)
        peers[i].client = cli

      try:
        waitFor peerA.client.start()
        waitFor peerB.client.start()
        check waitForCount(peerA.registry, 1, MaxWaitMs)
        check waitForCount(peerB.registry, 1, MaxWaitMs)
        check peerA.registry.hasPeer(peerB.peerId)
        check peerB.registry.hasPeer(peerA.peerId)
        # No TLS handshake rejections — chain validation passed.
        check peerA.server.tlsHandshakeRejectedCount == 0
        check peerB.server.tlsHandshakeRejectedCount == 0
      finally:
        waitFor peerA.client.stop()
        waitFor peerB.client.stop()
        peerA.server.stop()
        peerB.server.stop()
    finally:
      removeDir(tmp)

  test "peer with cert from different CA is rejected at chain validation":
    let tmp = getTempDir() / "peer_cache_m4_chain_rej_" & $epochTime()
    if dirExists(tmp): removeDir(tmp)
    createDir(tmp)
    try:
      let caKp = generateKeypair()
      let caCert = generateCaCert(caKp, subjectCn = "good-ca",
                                  validityDays = 365)
      let badCaKp = generateKeypair()
      let badCaCert = generateCaCert(badCaKp, subjectCn = "bad-ca",
                                     validityDays = 365)

      # Peer A trusts only "good-ca"; peer C presents a cert signed by
      # "bad-ca". A's handshake should reject C.
      var peerA = spawnCaTrustPeer(caCert, tmp, 0)
      var peerC = spawnCaTrustPeer(badCaCert, tmp, 1)
      let allowlist = @[parseCidrV4(LoopbackCidrLocal)]

      # C dials A. C's anchor set is its own bad-ca; A's anchor set is
      # the good-ca only.
      let cAnchors = setupCaAnchorDir(tmp, "c_client", badCaCert)
      let cClient = newPeerCacheClient(
        selfPeerId = peerC.peerId,
        listenPort = uint16(peerC.server.actualPort),
        registry = peerC.registry,
        seedPeers = @[initEndpoint("127.0.0.1",
                                   peerA.server.actualPort)],
        cidrAllowlist = allowlist,
        trustMode = tmTls,
        ourCert = peerC.cert,
        trustAnchorSet = cAnchors)
      peerC.client = cClient
      # A also needs a (no-op) client so we can clean it up uniformly.
      let aAnchors = setupCaAnchorDir(tmp, "a_client", caCert)
      let aClient = newPeerCacheClient(
        selfPeerId = peerA.peerId,
        listenPort = uint16(peerA.server.actualPort),
        registry = peerA.registry,
        seedPeers = @[],
        cidrAllowlist = allowlist,
        trustMode = tmTls,
        ourCert = peerA.cert,
        trustAnchorSet = aAnchors)
      peerA.client = aClient

      try:
        waitFor peerA.client.start()
        waitFor peerC.client.start()
        # Wait a bit and assert no membership gained on either side.
        var waited = 0
        let budget = MaxWaitMs
        while waited < budget:
          try: poll(0) except ValueError: discard
          sleep(PollIntervalMs)
          waited += PollIntervalMs
        # The handshake from C to A must fail — A rejected C's cert,
        # and C couldn't dial A successfully.
        check peerA.registry.peerCount() == 0
        check peerC.registry.peerCount() == 0
        # A or C must record at least one TLS handshake rejection on
        # either side (BearSSL fails the chain validation either at
        # the server's verifier or the client's verifier).
        check (peerA.server.tlsHandshakeRejectedCount +
               peerC.client.tlsHandshakeRejectedCount) >= 1
      finally:
        waitFor peerA.client.stop()
        waitFor peerC.client.stop()
        peerA.server.stop()
        peerC.server.stop()
    finally:
      removeDir(tmp)
