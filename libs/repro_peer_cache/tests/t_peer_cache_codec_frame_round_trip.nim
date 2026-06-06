## Peer-Cache M0 verification test: every `MessageKind` payload round-
## trips through encode → frame → decode losslessly. Spot-checks the
## bytes of the encoded frame for the framing invariant
## (`version=1` + kind tag + payloadLen) and asserts that the decoded
## payload byte-equals the source bytes.

import std/[random, sequtils, unittest]

import repro_peer_cache

proc digestN(seed: byte): BlobDigest =
  ## Deterministic 32-byte digest used as a payload fixture.
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = byte((int(seed) + i) and 0xff)
  blobDigestFromBytes(raw)

proc peerIdN(seed: byte): PeerId =
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = byte((int(seed) + 7 * i) and 0xff)
  peerIdFromBytes(raw)

suite "peer-cache codec frame round trip":
  test "Hello round-trips":
    let msg = Hello(peerId: peerIdN(0x10),
                    listenPort: 7654,
                    capabilities: 0xfeed_beef'u32)
    let payload = encodeHello(msg)
    let framed = encodeFrame(mkHello, payload)
    let frame = decodeFrame(framed)
    check frame.version == 1'u16
    check frame.messageKind == mkHello
    check frame.payloadLen == uint32(payload.len)
    check frame.payload == payload
    let decoded = decodeHello(frame.payload)
    check decoded == msg

  test "HelloOk round-trips":
    let msg = HelloOk(peerId: peerIdN(0x20),
                      protocolVersion: 1'u16,
                      maxBlobBytes: 100_000_000'u64)
    let frame = decodeFrame(encodeFrame(mkHelloOk, encodeHelloOk(msg)))
    check decodeHelloOk(frame.payload) == msg

  test "Advertise round-trips with randomised added/removed lengths":
    var rng = initRand(0xc0ffee)
    for trial in 0 ..< 8:
      let addedLen = rng.rand(0 .. 7)
      let removedLen = rng.rand(0 .. 5)
      let added = toSeq(0 ..< addedLen).mapIt(digestN(byte((trial * 17 + it) and 0xff)))
      let removed = toSeq(0 ..< removedLen).mapIt(digestN(byte((trial * 31 + it + 128) and 0xff)))
      let mode = if (trial and 1) == 0: amSnapshot else: amDelta
      let msg = Advertise(sequence: uint64(trial) * 100'u64,
                          mode: mode,
                          added: added,
                          removed: removed)
      let payload = encodeAdvertise(msg)
      let framed = encodeFrame(mkAdvertise, payload)
      let frame = decodeFrame(framed)
      check frame.messageKind == mkAdvertise
      check frame.payload == payload
      let decoded = decodeAdvertise(frame.payload)
      check decoded.sequence == msg.sequence
      check decoded.mode == msg.mode
      check decoded.added.len == msg.added.len
      check decoded.removed.len == msg.removed.len
      for i, d in decoded.added:
        check d == msg.added[i]
      for i, d in decoded.removed:
        check d == msg.removed[i]

  test "Want round-trips":
    for kind in [wkBlobs, wkSnapshotRequest]:
      let msg = Want(kind: kind,
                     digests: @[digestN(0x40), digestN(0x41), digestN(0x42)])
      let frame = decodeFrame(encodeFrame(mkWant, encodeWant(msg)))
      let decoded = decodeWant(frame.payload)
      check decoded.kind == msg.kind
      check decoded.digests.len == msg.digests.len
      for i, d in decoded.digests:
        check d == msg.digests[i]

  test "FetchRequest round-trips":
    let msg = FetchRequest(digest: digestN(0x55))
    let frame = decodeFrame(encodeFrame(mkFetchRequest,
      encodeFetchRequest(msg)))
    check decodeFetchRequest(frame.payload) == msg

  test "FetchResponse round-trips (empty + populated + truncated)":
    let cases = @[
      FetchResponse(digest: digestN(0x60), truncated: false, payload: @[]),
      FetchResponse(digest: digestN(0x61), truncated: false,
                    payload: @[byte(0xaa), 0xbb, 0xcc, 0xdd, 0x00, 0xff]),
      FetchResponse(digest: digestN(0x62), truncated: true, payload: @[]),
    ]
    for msg in cases:
      let frame = decodeFrame(encodeFrame(mkFetchResponse,
        encodeFetchResponse(msg)))
      let decoded = decodeFetchResponse(frame.payload)
      check decoded.digest == msg.digest
      check decoded.truncated == msg.truncated
      check decoded.payload == msg.payload

  test "Ping / Pong / Goodbye round-trip with empty payloads":
    block:
      let frame = decodeFrame(encodeFrame(mkPing, encodePing(Ping())))
      check frame.messageKind == mkPing
      check frame.payloadLen == 0'u32
      check frame.payload.len == 0
      discard decodePing(frame.payload)
    block:
      let frame = decodeFrame(encodeFrame(mkPong, encodePong(Pong())))
      check frame.messageKind == mkPong
      check frame.payloadLen == 0'u32
      discard decodePong(frame.payload)
    block:
      let frame = decodeFrame(encodeFrame(mkGoodbye, encodeGoodbye(Goodbye())))
      check frame.messageKind == mkGoodbye
      check frame.payloadLen == 0'u32
      discard decodeGoodbye(frame.payload)
