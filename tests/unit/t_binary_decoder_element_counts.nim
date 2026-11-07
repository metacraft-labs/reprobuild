## Exercise real codec entry points with hostile element counts. No mocks.
## A moderate count gives the old code a measurable allocation without risking
## the host. The maximum integer count is covered directly by the shared bound.
import std/unittest
import repro_peer_cache/[codec, types]
import repro_core/codec as coreCodec

proc rejectCount(encoded: seq[byte]; offset: int; expectedMessage: string;
                 decode: proc(data: seq[byte]) {.closure.}) =
  let before = getMaxMem()
  for count in [65536'u32]:
    var malformed = encoded
    for i in 0 ..< 4:
      malformed[offset + i] = byte((count shr (i * 8)) and 255)
    var rejected = false
    try:
      decode(malformed)
    except PeerCacheCodecError as error:
      check error.msg == expectedMessage
      rejected = true
    check rejected
  check getMaxMem() - before < 1_000_000

suite "binary decoder element counts":
  test "peer want rejects before allocating digest sequence":
    let before = getMaxMem()
    expect PeerCacheCodecError:
      discard decodeWant(@[0'u8, 0, 0, 1, 0]) # 65536, zero digest bytes
    check getMaxMem() - before < 1_000_000
  test "advertisement added and removed counts reject at the bound":
    let encoded = encodeAdvertise(Advertise())
    rejectCount(encoded, 9, "added digest count exceeds payload",
      proc(data: seq[byte]) = discard decodeAdvertise(data))
    rejectCount(encoded, 13, "removed digest count exceeds payload",
      proc(data: seq[byte]) = discard decodeAdvertise(data))
  test "want and gossip counts reject at the bound":
    rejectCount(encodeWant(Want()), 1, "element count exceeds payload",
      proc(data: seq[byte]) = discard decodeWant(data))
    let encoded = encodeSwimProbe(SwimProbe())
    rejectCount(encoded, encoded.len - 4, "element count exceeds payload",
      proc(data: seq[byte]) = discard decodeSwimProbe(data))
  test "shared bound handles exact fits empty and invalid sizes":
    check coreCodec.elementCountFits(0, 0, 4)
    check coreCodec.elementCountFits(2, 8, 4)
    check not coreCodec.elementCountFits(3, 8, 4)
    check not coreCodec.elementCountFits(high(uint32), 8, 4)
    check not coreCodec.elementCountFits(0, -1, 4)
    check not coreCodec.elementCountFits(0, 0, 0)
    check coreCodec.elementCountFits(1, high(int), high(int))
    check not coreCodec.elementCountFits(2, high(int), high(int))
  test "smallest gossip member still decodes at the exact bound":
    # A SwimMember with an empty host is the 47-byte minimum the bound uses,
    # and the gossip list is the last field of a probe.
    let probe = SwimProbe(gossip: @[SwimMember()])
    check decodeSwimProbe(encodeSwimProbe(probe)).gossip.len == 1
