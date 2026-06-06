## Peer-Cache M0 verification test: a frame with `version != 1` is
## rejected by `decodeFrame` with a `PeerCacheCodecError` whose
## message cites the observed version.

import std/[strutils, unittest]

import repro_peer_cache

proc buildFrameWithVersion(version: uint16): seq[byte] =
  ## Builds a wire-shaped frame with the version override + a Hello
  ## payload (the payload kind doesn't matter for the test; the
  ## version check runs before payload decoding).
  let payload = encodeHello(Hello(
    peerId: peerIdFromBytes(default(array[32, byte])),
    listenPort: 0,
    capabilities: 0))
  result = @[]
  # version (little-endian uint16)
  result.add(byte(version and 0xff'u16))
  result.add(byte((version shr 8) and 0xff'u16))
  # messageKind: mkHello
  result.add(byte(ord(mkHello)))
  result.add(0'u8)
  # payloadLen (little-endian uint32)
  result.add(byte(payload.len and 0xff))
  result.add(byte((payload.len shr 8) and 0xff))
  result.add(byte((payload.len shr 16) and 0xff))
  result.add(byte((payload.len shr 24) and 0xff))
  for b in payload:
    result.add(b)

suite "peer-cache codec version mismatch":
  test "version=2 frame is rejected with the observed version in the message":
    let bad = buildFrameWithVersion(2'u16)
    expect PeerCacheCodecError:
      try:
        discard decodeFrame(bad)
      except PeerCacheCodecError as err:
        # Message must cite the observed version "2".
        check err.msg.contains("2")
        # And it must specifically describe a version mismatch so the
        # operator/log reader knows what failed.
        check err.msg.toLowerAscii().contains("version")
        raise

  test "version=0 frame is rejected":
    let bad = buildFrameWithVersion(0'u16)
    expect PeerCacheCodecError:
      try:
        discard decodeFrame(bad)
      except PeerCacheCodecError as err:
        check err.msg.toLowerAscii().contains("version")
        raise

  test "version=42 frame is rejected with the value in the message":
    let bad = buildFrameWithVersion(42'u16)
    expect PeerCacheCodecError:
      try:
        discard decodeFrame(bad)
      except PeerCacheCodecError as err:
        check err.msg.contains("42")
        raise

  test "version=1 frame parses cleanly (sanity check)":
    let good = buildFrameWithVersion(1'u16)
    let frame = decodeFrame(good)
    check frame.version == 1'u16
    check frame.messageKind == mkHello
