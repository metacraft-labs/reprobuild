## Peer-Cache M2 verification test: a simulated off-CIDR announcement
## is dropped by the multicast receiver. The warning is logged
## exactly once per peer ID per session.
##
## Implementation note (matching the milestone's "spoofing source IPs
## is impractical on loopback" caveat): we configure the server's
## allowlist to ``192.168.99.0/24`` — which deliberately excludes
## loopback — and then send a multicast announcement from
## ``127.0.0.1``. The receiver sees the source as ``127.0.0.1``
## (outside the allowlist), drops the announcement, and increments
## both the dropped-announce counter and the warning-emit counter
## (the latter capped at 1 per peer ID).
##
## The test also sends a second announcement from the same peer ID
## and asserts the warning counter does NOT increment (dedup).

import std/[asyncdispatch, asyncnet, nativesockets, os, unittest]

import repro_peer_cache

const
  MulticastAddress = "239.255.42.43"
    ## Distinct from the discovery test's group so concurrent test
    ## runs (e.g., parallel test runner) don't cross-talk.
  MulticastPort = 17655
  PollIntervalMs = 50
  MaxWaitMs = 3_000

proc makePeerId(seed: byte): PeerId =
  var raw: array[32, byte]
  raw[0] = byte(ord('O'))  ## ``O`` for "off-network".
  raw[1] = seed
  peerIdFromBytes(raw)

suite "peer-cache multicast CIDR allowlist":
  test "off-CIDR announcement dropped, warning logged once per peer":
    # Server with a CIDR allowlist that EXCLUDES loopback.
    let serverPeerId = makePeerId(0x10)
    let endpoint = initEndpoint("127.0.0.1", Port(0))
    let registry = newPeerRegistry(serverPeerId, endpoint)
    let restrictiveAllowlist = @[parseCidrV4("192.168.99.0/24")]
    let server = newPeerCacheServer(
      selfPeerId = serverPeerId,
      listenAddr = "127.0.0.1",
      listenPort = Port(0),
      registry = registry,
      cidrAllowlist = restrictiveAllowlist)
    server.start()
    let group = loopbackMulticastGroup(MulticastAddress,
                                       Port(MulticastPort))
    server.multicastListen(group)

    # A simulated off-network peer: a bare client (no
    # `PeerCacheClient` wrapping) that just sends a Hello on the
    # multicast group. Its source IP is `127.0.0.1` (loopback) so
    # the server's CIDR check will reject it.
    let attackerPeerId = makePeerId(0x20)
    let attackerHello = Hello(
      peerId: attackerPeerId,
      listenPort: 0'u16,
      capabilities: 0'u32)
    let packet = encodeHelloPacket(attackerHello)
    let attackerSock = newMulticastSenderSocket(group)
    try:
      sendMulticastPacket(attackerSock, group, packet)

      # Poll until the dropped-announce counter has incremented.
      var waited = 0
      while waited < MaxWaitMs and server.droppedAnnounceCount == 0:
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
        waited += PollIntervalMs

      check server.droppedAnnounceCount >= 1
      check server.warningEmitCount == 1
      # Registry stays empty — the off-CIDR peer never dialed back.
      check not registry.hasPeer(attackerPeerId)

      # Send a second announcement from the same peer ID. The
      # dropped-announce counter increments, but the warning
      # counter does NOT (dedup by peer ID).
      let dropsBefore = server.droppedAnnounceCount
      let warningsBefore = server.warningEmitCount
      sendMulticastPacket(attackerSock, group, packet)
      waited = 0
      while waited < MaxWaitMs and
          server.droppedAnnounceCount == dropsBefore:
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
        waited += PollIntervalMs
      check server.droppedAnnounceCount > dropsBefore
      check server.warningEmitCount == warningsBefore

      # Send a third announcement from a DIFFERENT peer ID. The
      # warning counter DOES increment (different peer => new
      # warning emission, still bounded once per peer per session).
      let otherAttackerPeerId = makePeerId(0x21)
      let otherHello = Hello(
        peerId: otherAttackerPeerId,
        listenPort: 0'u16,
        capabilities: 0'u32)
      let otherPacket = encodeHelloPacket(otherHello)
      let warnsAfterSecond = server.warningEmitCount
      sendMulticastPacket(attackerSock, group, otherPacket)
      waited = 0
      while waited < MaxWaitMs and
          server.warningEmitCount == warnsAfterSecond:
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
        waited += PollIntervalMs
      check server.warningEmitCount == warnsAfterSecond + 1
    finally:
      try: attackerSock.close() except CatchableError: discard
      server.stop()
