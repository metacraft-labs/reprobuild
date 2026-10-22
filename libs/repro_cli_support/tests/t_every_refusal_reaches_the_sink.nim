## Distributed-Execution M7, threat model G19, G23 and G29: every refusal
## class of the Boundary gate reaches the off-host sink WITH the refused
## frame captured, and the gate covers the frames a node receives on its OWN
## outbound connections too.
##
## Inbound (A refuses frames B and a raw TLS caller send it), each class a
## positive control of its trigger reaching the sink, with the payload as
## read (EVID-1 — refusals decided from the frame header used to capture
## nothing):
##   size, protocol, unauthenticated, unauthorized, rate, not-implemented
##   (a reserved message, and a `ReachGoal` to a node without the worker
##   role — which used to be answered `refused` but AUDITED AS ADMITTED),
##   schema. (`revoked` is in `t_revocation_takes_effect_on_the_next_frame`,
##   `edge-initiated` in `t_worker_hydrates_over_the_callers_connection`.)
##
## Outbound (G29: frames a node receives on a connection IT opened), driven
## by a hostile peer-cache server — a raw TLS listener holding a trusted
## host's genuine leaf, that completes the handshake and then sends what no
## request asked for:
##   * a fetch response while no fetch is outstanding (`protocol`);
##   * a `ReachGoal` request — a message never sent to the node that opened
##     the connection (`protocol`).
## Each is refused by the dialling node's outbound gate, the connection is
## dropped, and the refusal reaches the sink as `direction=outbound` with
## the frame captured. Positive control: the same server's handshake frames
## (identity proof, HelloOk) were admitted and the connection was up.
##
## MOCK POLICY — a raw TLS caller (`rawDial`) that skips protocol steps, as a
## misbehaving client does, and a raw TLS server (`hostileServer`) that
## sends unrequested frames, as a compromised peer does; everything else is
## production.

import std/[asyncdispatch, asyncnet, nativesockets, net, options, os, sets,
            strutils, tables, tempfiles, times, unittest]

import repro_cas_store
import repro_peer_cache
import repro_cli_support/peer_cache_wiring

import ../../repro_peer_cache/tests/m7_test_pki

proc tickFor(hosts: openArray[PeerCacheHost]; ms: int) =
  let deadline = epochTime() + ms.float / 1000.0
  while epochTime() < deadline:
    for h in hosts: h.tick(5)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, ch in s: result[i] = byte(ord(ch))

proc recvExactTls(conn: TlsConn; n: int): Future[seq[byte]] {.async.} =
  var got = ""
  while got.len < n:
    let chunk = await tls.recv(conn, n - got.len)
    if chunk.len == 0: break
    got.add(chunk)
  result = bytesOf(got)

proc readFrameTls(conn: TlsConn): Future[Option[Frame]] {.async.} =
  let header = await recvExactTls(conn, 8)
  if header.len != 8: return none(Frame)
  var n: uint32 = 0
  for i in 0 ..< 4: n = n or (uint32(header[4 + i]) shl uint32(8 * i))
  var bytes = header
  if n > 0:
    let body = await recvExactTls(conn, int(n))
    if body.len != int(n): return none(Frame)
    bytes.add(body)
  return some(decodeFrame(bytes))

proc sendTls(conn: TlsConn; kind: MessageKind; payload: seq[byte]) {.async.} =
  await tls.send(conn, encodeFrame(kind, payload))

proc rawDial(node: TestNode; port: Port; proveIdentity: bool):
    Future[TlsConn] {.async.} =
  ## A raw TLS connection as `node` (its own leaf), optionally sending the
  ## identity proof — a caller that does not follow the protocol.
  let leaf = mintLeaf(node.identity, lrDaemon)
  let sock = newAsyncSocket()
  await sock.connect("127.0.0.1", port)
  let conn = (await wrapClientSocket(sock, "127.0.0.1", leaf.cert.certDer,
    leaf.key, loadTrustAnchorDir(node.anchorsDir))).get()
  if proveIdentity:
    await conn.sendTls(mkIdentityProof, encodeIdentityProof(leaf.cert.certDer))
    discard await readFrameTls(conn)   # the server's proof
  return conn

proc refusalsAtSink(sink: SinkProcess; sender: PeerId; refusal: string;
                    direction = "inbound"): seq[EvidenceEntry] =
  for e in sink.detections("frame-refused"):
    if e.senderHostId == sender and e.record.field("refusal") == refusal and
        e.record.field("direction") == direction:
      result.add(e)

proc waitRefusal(sink: SinkProcess; sender: PeerId; refusal: string;
                 hosts: openArray[PeerCacheHost];
                 direction = "inbound"; want = 1): seq[EvidenceEntry] =
  # Drive the dispatchers AND the appender queue: under heavy parallel load
  # the audit record may still be in the appender when we first look.
  let deadline = epochTime() + 25.0
  while epochTime() < deadline:
    for h in hosts:
      if not h.appender.isNil: discard h.appender.drain(200)
    result = sink.refusalsAtSink(sender, refusal, direction)
    if result.len >= want: return
    tickFor(hosts, 100)

type
  HostileScript = ref object
    ## What the hostile server sends once its handshake is done and `go`
    ## is set; one frame per connection (the dialler drops it after).
    frames: seq[(MessageKind, seq[byte])]
    go: bool
    accepted: int
    handshakes: int
    dropped: int
      ## Connections the dialler closed after a scripted frame (seen as
      ## end-of-stream on the hostile side).

proc hostileServer(node: TestNode; listener: AsyncSocket;
                   script: HostileScript) {.async.} =
  ## A peer-cache server under `node`'s genuine identity that answers the
  ## handshake correctly (identity proof, HelloOk, an empty advertisement)
  ## and then, per accepted connection, sends the next scripted frame.
  let anchors = loadTrustAnchorDir(node.anchorsDir)
  while true:
    var sock: AsyncSocket
    try: sock = await listener.accept()
    except CatchableError: return
    inc script.accepted
    let leaf = mintLeaf(node.identity, lrDaemon)
    let connOpt = await wrapServerSocket(sock, leaf.cert.certDer, leaf.key,
      anchors)
    if connOpt.isNone:
      try: sock.close() except CatchableError: discard
      continue
    let conn = connOpt.get()
    try:
      discard await readFrameTls(conn)            # the dialler's proof
      discard await readFrameTls(conn)            # its Hello
      await conn.sendTls(mkIdentityProof, encodeIdentityProof(leaf.cert.certDer))
      await conn.sendTls(mkHelloOk, encodeHelloOk(HelloOk(
        peerId: node.identity.hostId, protocolVersion: PeerCacheProtocolVersion,
        maxBlobBytes: DefaultMaxBlobBytes)))
      await conn.sendTls(mkAdvertise, encodeAdvertise(Advertise()))
      inc script.handshakes
      while not script.go:
        await sleepAsync(20)
      if script.frames.len > 0:
        let (kind, payload) = script.frames[0]
        script.frames.delete(0)
        script.go = false
        await conn.sendTls(kind, payload)
        # Whatever the dialler still sends, it must end the connection.
        while (await readFrameTls(conn)).isSome:
          discard
        inc script.dropped
    except CatchableError:
      inc script.dropped

suite "Distributed-Execution M7: every refusal reaches the sink (G19, G23, G29)":

  test "inbound: each refusal class, with the frame captured":
    let base = createTempDir("m7-g19-in-", "")
    var a = newTestNode(base, "a")
    var b = newTestNode(base, "b")
    var raw = newTestNode(base, "raw")
    mutualTrust([a, b, raw])
    a.grantRoles(b, "cache-peer,orchestrator")
    var sink = prepareEvidenceSink(base)
    for n in [a, b, raw]: sink.acceptsFrom(n)
    sink.startEvidenceSink()
    var hostA, hostB: PeerCacheHost
    defer:
      if not hostB.isNil: hostB.stop()
      if not hostA.isNil: hostA.stop()
      stopEvidenceSink(sink)
      removeDir(base)
    hostA = startPeerCacheHost(tlsConfig(a, evidence = sink.endpoint,
      heartbeatMs = 1000), a.identity.hostId, cacheRoot = base / "a-cache")
    let aId = a.identity.hostId
    proc dialB() =
      if not hostB.isNil: hostB.stop()
      hostB = startPeerCacheHost(tlsConfig(b, seeds = @[initEndpoint(
        "127.0.0.1", hostA.actualPort)]), b.identity.hostId,
        cacheRoot = base / "b-cache")
    dialB()

    # unauthorized is not possible for B (granted orchestrator); not-
    # implemented: a reserved message, and ReachGoal to a non-worker node.
    let goal = bytesOf("RGRQ-not-a-real-goal-but-captured")
    waitFor hostB.client.sendRawFrameForTesting(aId, mkAttach, @[])
    waitFor hostB.client.sendRawFrameForTesting(aId, mkReachGoalRequest, goal)
    var ni = waitRefusal(sink, aId, "not-implemented", [hostA, hostB])
    check ni.len >= 1
    var goalCaptured = false
    for e in sink.refusalsAtSink(aId, "not-implemented"):
      if e.record.field("messageKind") == "reach-goal" and
          e.record.payload == goal:
        goalCaptured = true
    check goalCaptured                       # refused AND captured (G19)
    for e in sink.sinkEntries():             # never audited as admitted
      if e.kind == ekRecord and e.record.category == ecAudit and
          e.record.trigger == "reach-goal":
        check false

    # rate: advertisement-refresh requests past their burst
    for i in 0 ..< 40:
      waitFor hostB.client.sendRawFrameForTesting(aId, mkWant,
        encodeWant(Want(kind: wkSnapshotRequest, digests: @[])))
    let rate = waitRefusal(sink, aId, "rate", [hostA, hostB])
    check rate.len >= 1
    for e in rate:
      check e.record.payload.len > 0         # the frame, captured

    # The rate flood spent B's per-caller refusal-record budget (G18: later
    # refusals are folded into summaries); let it refill so the next class
    # is recorded one by one, frame and all.
    tickFor([hostA, hostB], 3_000)
    # schema: a fetch request whose payload does not decode
    let junk = @[byte 1, 2, 3, 4, 5, 6, 7]
    waitFor hostB.client.sendRawFrameForTesting(aId, mkFetchRequest, junk)
    let schema = waitRefusal(sink, aId, "schema", [hostA, hostB])
    check schema.len >= 1
    var junkCaptured = false
    for e in schema:
      if e.record.payload == junk: junkCaptured = true
    check junkCaptured

    # size: a fetch request over its 64-byte budget (the connection closes)
    dialB()
    let big = newSeq[byte](100)
    waitFor hostB.client.sendRawFrameForTesting(aId, mkFetchRequest, big)
    let size = waitRefusal(sink, aId, "size", [hostA, hostB])
    check size.len >= 1
    for e in size:
      check e.record.payload.len == 100       # captured despite the refusal

    # unauthenticated: a raw TLS caller that sends Hello without proving
    # its leaf
    let c1 = waitFor rawDial(raw, hostA.actualPort, proveIdentity = false)
    waitFor c1.sendTls(mkHello, encodeHello(Hello(peerId: raw.identity.hostId)))
    check (waitFor readFrameTls(c1)).isSome   # the refusal notice
    check waitRefusal(sink, aId, "unauthenticated", [hostA]).len >= 1

    # protocol: a proven caller that fetches before Hello
    let c2 = waitFor rawDial(raw, hostA.actualPort, proveIdentity = true)
    waitFor c2.sendTls(mkFetchRequest, encodeFetchRequest(FetchRequest()))
    check waitRefusal(sink, aId, "protocol", [hostA]).len >= 1

    # unauthorized: the raw caller (a cache peer only) after a full Hello
    let c3 = waitFor rawDial(raw, hostA.actualPort, proveIdentity = true)
    waitFor c3.sendTls(mkHello, encodeHello(Hello(peerId: raw.identity.hostId)))
    for _ in 0 ..< 2: discard waitFor readFrameTls(c3)   # HelloOk, Advertise
    waitFor c3.sendTls(mkReachGoalRequest, goal)
    let unauth = waitRefusal(sink, aId, "unauthorized", [hostA])
    check unauth.len >= 1
    for e in unauth:
      check e.record.field("peer") == $raw.identity.hostId
      check e.record.payload == goal

  test "outbound: a hostile server's unrequested frames are refused":
    let base = createTempDir("m7-g29-out-", "")
    var c = newTestNode(base, "c")
    var h = newTestNode(base, "hostile")
    mutualTrust([c, h])
    var sink = prepareEvidenceSink(base)
    sink.acceptsFrom(c)
    sink.startEvidenceSink()
    let listener = newAsyncSocket()
    listener.setSockOpt(OptReuseAddr, true)
    listener.bindAddr(Port(0), "127.0.0.1")
    listener.listen()
    let hostilePort = listener.getLocalAddr()[1]
    let fetchReply = bytesOf("FETCH-RESPONSE-NOBODY-ASKED-FOR")
    let goal = bytesOf("RGRQ-sent-to-the-node-that-dialled")
    let script = HostileScript(frames: @[(mkFetchResponse, fetchReply),
      (mkReachGoalRequest, goal)])
    asyncCheck hostileServer(h, listener, script)
    var hostC: PeerCacheHost
    defer:
      if not hostC.isNil: hostC.stop()
      try: listener.close() except CatchableError: discard
      stopEvidenceSink(sink)
      removeDir(base)
    hostC = startPeerCacheHost(tlsConfig(c, seeds = @[initEndpoint(
      "127.0.0.1", hostilePort)], evidence = sink.endpoint,
      heartbeatMs = 1000), c.identity.hostId, cacheRoot = base / "c-cache")
    let cId = c.identity.hostId
    let hId = h.identity.hostId
    var round = 0
    for (refusal, payload, kind) in [("protocol", fetchReply, "fetch-response"),
                                     ("protocol", goal, "unexpected")]:
      inc round
      # Positive control: the handshake was admitted; the connection is up.
      var up = false
      let upDeadline = epochTime() + 20.0
      while not up and epochTime() < upDeadline:
        tickFor([hostC], 100)
        up = hostC.client.isConnected(hId)
        if not up: discard waitFor hostC.client.connectKnownPeers()
      check up
      script.go = true
      var found = false
      let deadline = epochTime() + 25.0
      while not found and epochTime() < deadline:
        discard hostC.appender.drain(200)
        for e in sink.refusalsAtSink(cId, refusal, direction = "outbound"):
          if e.record.payload == payload:
            found = true
            check e.record.field("peer") == $hId
            check e.record.field("messageKind") == kind
        tickFor([hostC], 100)
      checkpoint("outbound " & kind & " refusal at the sink: " & $found)
      check found
      # Every outbound refusal ends the connection: the hostile side sees it
      # closed (the dialler may re-dial its seed afterwards).
      let downDeadline = epochTime() + 10.0
      while script.dropped < round and epochTime() < downDeadline:
        tickFor([hostC], 50)
      check script.dropped == round
    check hostC.server.gate.refusedCount[rcProtocol] == 0   # nothing inbound
    check hostC.client.gate.refusedCount[rcProtocol] >= 2
    check script.handshakes >= 2
