## Distributed-Execution M0: the two-phase memoization messages round-trip
## through the frame codec, and malformed payloads are rejected.
##
## No mocks: pure codec over byte strings.

import std/unittest

import repro_peer_cache

proc digestN(seed: byte): BlobDigest =
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = byte((int(seed) * 7 + i) and 0xff)
  blobDigestFromBytes(raw)

proc reframe(kind: MessageKind; payload: seq[byte]): Frame =
  decodeFrame(encodeFrame(kind, payload))

suite "peer-cache memo codec":

  test "GetSelectorsRequest round-trips on protocol version 1":
    let msg = GetSelectorsRequest(weakFingerprint: digestN(1))
    let frame = reframe(mkGetSelectorsRequest, encodeGetSelectorsRequest(msg))
    check frame.version == PeerCacheProtocolVersion
    check frame.messageKind == mkGetSelectorsRequest
    check decodeGetSelectorsRequest(frame.payload) == msg

  test "GetSelectorsResponse round-trips with 0, 1 and many selectors":
    for count in [0, 1, 5]:
      var sels: seq[MemoSelector] = @[]
      for i in 0 ..< count:
        sels.add(MemoSelector(pathSetDigest: digestN(byte(10 + i)),
          strongFingerprint: digestN(byte(100 + i))))
      let msg = GetSelectorsResponse(weakFingerprint: digestN(2),
        selectors: sels)
      let frame = reframe(mkGetSelectorsResponse,
        encodeGetSelectorsResponse(msg))
      let decoded = decodeGetSelectorsResponse(frame.payload)
      check decoded.weakFingerprint == msg.weakFingerprint
      check decoded.selectors == sels

  test "GetActionRecordRequest / Response round-trip, found and not found":
    let req = GetActionRecordRequest(weakFingerprint: digestN(3),
      strongFingerprint: digestN(4))
    check decodeGetActionRecordRequest(reframe(mkGetActionRecordRequest,
      encodeGetActionRecordRequest(req)).payload) == req
    let found = GetActionRecordResponse(weakFingerprint: digestN(3),
      strongFingerprint: digestN(4), found: true, entry: @[1'u8, 2, 3, 250])
    check decodeGetActionRecordResponse(reframe(mkGetActionRecordResponse,
      encodeGetActionRecordResponse(found)).payload) == found
    let missing = GetActionRecordResponse(weakFingerprint: digestN(3),
      strongFingerprint: digestN(4), found: false, entry: @[])
    check decodeGetActionRecordResponse(encodeGetActionRecordResponse(
      missing)) == missing

  test "dispatch routes every memo kind to its handler":
    var seen: seq[MessageKind] = @[]
    let frames = @[
      reframe(mkGetSelectorsRequest, encodeGetSelectorsRequest(
        GetSelectorsRequest(weakFingerprint: digestN(5)))),
      reframe(mkGetSelectorsResponse, encodeGetSelectorsResponse(
        GetSelectorsResponse(weakFingerprint: digestN(5)))),
      reframe(mkGetActionRecordRequest, encodeGetActionRecordRequest(
        GetActionRecordRequest(weakFingerprint: digestN(5),
          strongFingerprint: digestN(6)))),
      reframe(mkGetActionRecordResponse, encodeGetActionRecordResponse(
        GetActionRecordResponse(weakFingerprint: digestN(5),
          strongFingerprint: digestN(6))))]
    for frame in frames:
      dispatch(frame,
        onGetSelectorsRequest = proc (m: GetSelectorsRequest) =
          seen.add(mkGetSelectorsRequest),
        onGetSelectorsResponse = proc (m: GetSelectorsResponse) =
          seen.add(mkGetSelectorsResponse),
        onGetActionRecordRequest = proc (m: GetActionRecordRequest) =
          seen.add(mkGetActionRecordRequest),
        onGetActionRecordResponse = proc (m: GetActionRecordResponse) =
          seen.add(mkGetActionRecordResponse))
    check seen == @[mkGetSelectorsRequest, mkGetSelectorsResponse,
                    mkGetActionRecordRequest, mkGetActionRecordResponse]

  test "malformed memo payloads are rejected":
    # Truncated weak fingerprint.
    expect PeerCacheCodecError:
      discard decodeGetSelectorsRequest(@[1'u8, 2, 3])
    # Trailing garbage.
    var withTrailer = encodeGetSelectorsRequest(
      GetSelectorsRequest(weakFingerprint: digestN(7)))
    withTrailer.add(0'u8)
    expect PeerCacheCodecError:
      discard decodeGetSelectorsRequest(withTrailer)
    # A selector count far beyond the payload / the hard cap.
    var huge = encodeGetSelectorsResponse(
      GetSelectorsResponse(weakFingerprint: digestN(8)))
    huge[32] = 0xff'u8
    huge[33] = 0xff'u8
    expect PeerCacheCodecError:
      discard decodeGetSelectorsResponse(huge)
    # found = false must not carry entry bytes.
    var bogus = encodeGetActionRecordResponse(GetActionRecordResponse(
      weakFingerprint: digestN(9), strongFingerprint: digestN(9),
      found: true, entry: @[42'u8]))
    bogus[64] = 0'u8  # flip `found` to false, keep the entry byte
    expect PeerCacheCodecError:
      discard decodeGetActionRecordResponse(bogus)
