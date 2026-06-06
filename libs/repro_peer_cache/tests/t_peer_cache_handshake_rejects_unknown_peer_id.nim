## Peer-Cache M0 verification test: a connection from outside the
## CIDR allowlist is rejected at accept time. The remote sees the
## connection close without an `mkHelloOk` ever being delivered AND
## the server's registry does not contain the rejected peer ID.
##
## Implementation note (matching the milestone's authenticity caveat):
## simulating an off-CIDR connection on a single loopback host is
## hard — the OS always reports the remote as `127.0.0.1`. We
## therefore configure the server with a more restrictive CIDR
## (`192.168.99.0/24`) that explicitly excludes `127.0.0.0/8` and
## connect from `127.0.0.1`; the server rejects the loopback
## connection, demonstrating the CIDR-check code path. This
## documents the deliberate restriction as the milestone spec
## requires.

import std/[asyncdispatch, asyncnet, nativesockets, os, unittest]

import repro_peer_cache
import repro_peer_cache/server
import repro_peer_cache/types
import repro_peer_cache/codec
import repro_peer_cache/registry

const
  PollIntervalMs = 50
  MaxWaitMs = 3_000

proc makePeerId(seed: byte): PeerId =
  var raw: array[32, byte]
  raw[0] = byte(ord('X'))
  raw[1] = seed
  peerIdFromBytes(raw)

proc clientAttempt(host: string; port: Port;
                   selfPeerId: PeerId;
                   listenPort: uint16;
                   sawHelloOk: ref bool;
                   connectionClosed: ref bool): Future[void] {.async.} =
  ## Opens a raw connection, sends a Hello, and waits for either a
  ## HelloOk reply (would indicate the allowlist did not reject us)
  ## or a clean EOF (the expected outcome).
  var sock = newAsyncSocket()
  try:
    await sock.connect(host, port)
    let hello = Hello(peerId: selfPeerId,
                      listenPort: listenPort,
                      capabilities: 0)
    let payload = encodeHello(hello)
    let frame = encodeFrame(mkHello, payload)
    var asString = newString(frame.len)
    for i, b in frame:
      asString[i] = char(b)
    await sock.send(asString)
    # Read up to one frame header (8 bytes) — if the server rejected
    # us, `recv` returns an empty string (clean EOF).
    let header = await sock.recv(8)
    if header.len == 0:
      connectionClosed[] = true
    else:
      # The server replied — decode and see if it was HelloOk.
      var bytes = newSeq[byte](header.len)
      for i in 0 ..< header.len:
        bytes[i] = byte(ord(header[i]))
      if bytes.len >= 4:
        var payloadLen: uint32 = 0
        for i in 0 ..< 4:
          payloadLen = payloadLen or (uint32(bytes[4 + i]) shl uint32(i * 8))
        if payloadLen > 0'u32:
          let body = await sock.recv(int(payloadLen))
          for i in 0 ..< body.len:
            bytes.add(byte(ord(body[i])))
      try:
        let f = decodeFrame(bytes)
        if f.messageKind == mkHelloOk:
          sawHelloOk[] = true
      except CatchableError:
        # Couldn't decode — count it as a connection-failure case
        # (also acceptable as a rejection signal).
        connectionClosed[] = true
  except CatchableError:
    # connect or send fault — count as a rejection signal.
    connectionClosed[] = true
  finally:
    try: sock.close() except CatchableError: discard

suite "peer-cache handshake CIDR rejection":
  test "off-CIDR connection is rejected; no HelloOk delivered, peer not registered":
    # Server configured with a CIDR that excludes loopback.
    let serverPeerId = makePeerId(0x01)
    let serverEndpoint = initEndpoint("127.0.0.1", Port(0))
    let registry = newPeerRegistry(serverPeerId, serverEndpoint)
    let restrictiveAllowlist = @[parseCidrV4("192.168.99.0/24")]
    let server = newPeerCacheServer(
      selfPeerId = serverPeerId,
      listenAddr = "127.0.0.1",
      listenPort = Port(0),
      registry = registry,
      cidrAllowlist = restrictiveAllowlist)
    server.start()

    var sawHelloOk = new bool
    var connectionClosed = new bool
    sawHelloOk[] = false
    connectionClosed[] = false

    let clientPeerId = makePeerId(0x02)
    try:
      # Attempt the connection. The acceptLoop will reject and close,
      # so the recv call should hit EOF.
      waitFor clientAttempt(
        host = "127.0.0.1",
        port = server.actualPort,
        selfPeerId = clientPeerId,
        listenPort = 0,
        sawHelloOk = sawHelloOk,
        connectionClosed = connectionClosed)

      # Poll briefly to give the acceptLoop time to settle (the
      # rejection is synchronous within the accept handler, so this is
      # belt-and-suspenders).
      var waited = 0
      while waited < MaxWaitMs and registry.hasPeer(clientPeerId):
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
        waited += PollIntervalMs

      check not sawHelloOk[]
      check connectionClosed[]
      check not registry.hasPeer(clientPeerId)
    finally:
      server.stop()

  test "explicit inAllowlist behaviour":
    # Sanity-check the helper directly so the test failure
    # localises if the policy ever drifts.
    let permissive = @[parseCidrV4("127.0.0.0/8")]
    check inAllowlist("127.0.0.1", permissive)
    check inAllowlist("127.0.0.42", permissive)
    check not inAllowlist("10.0.0.1", permissive)
    check not inAllowlist("192.168.1.1", permissive)
    let restrictive = @[parseCidrV4("192.168.99.0/24")]
    check not inAllowlist("127.0.0.1", restrictive)
    check inAllowlist("192.168.99.42", restrictive)
    check not inAllowlist("192.168.100.42", restrictive)
    let empty: seq[CidrV4] = @[]
    check not inAllowlist("127.0.0.1", empty)
