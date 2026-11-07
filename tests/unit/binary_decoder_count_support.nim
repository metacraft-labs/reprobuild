## Capture count positions while encoding real fixtures, without mocking reads.
import std/[options, tables]
import repro_core/codec as countCodec

var encodedCountOffsets: seq[int]

proc writeU32Le(outp: var seq[byte]; value: uint32) =
  ## Each populated collection has length one; all fixture scalar u32 values
  ## remain zero. Core writeString uses its own length writer, so empty string
  ## prefixes are excluded. Delegate the actual bytes to the production codec.
  if value == 1:
    encodedCountOffsets.add(outp.len)
  countCodec.writeU32Le(outp, value)

proc populateCountFixture[T](value: var T) =
  when T is string:
    discard
  elif T is seq:
    value.setLen(1)
    populateCountFixture(value[0])
  elif T is Option:
    var inner: typeof(value.get())
    populateCountFixture(inner)
    value = some(inner)
  elif T is ref:
    discard
  elif T is object or T is tuple:
    for field in fields(value):
      populateCountFixture(field)

proc checkCountMutations(encoded: seq[byte]; decode: proc (data: seq[byte]) {.closure.}; expectedCounts: int; offsetAdjustment: int = 0) =
  ## Every recorded collection count must return the structured envelope error
  ## before allocating. One aggregate budget prevents later allocations from
  ## hiding behind an earlier iteration's memory high-water mark.
  decode(encoded) # Nonempty valid control, including nested collections.
  doAssert encodedCountOffsets.len == expectedCounts,
    "fixture must reach all expected collections: recorded " &
    $encodedCountOffsets.len & ", expected " & $expectedCounts
  echo "  checked count fields: ", encodedCountOffsets.len
  let offsets = encodedCountOffsets
  encodedCountOffsets = @[]
  let before = getMaxMem()
  for rawOffset in offsets:
    let offset = rawOffset + offsetAdjustment
    var malformed = encoded
    malformed[offset] = 0
    malformed[offset + 1] = 0
    malformed[offset + 2] = 1
    malformed[offset + 3] = 0
    var rejected = false
    try:
      decode(malformed)
    except EnvelopeError as error:
      doAssert error.kind == eeMalformed
      doAssert error.msg == "element count exceeds remaining bytes",
        "count was rejected only after entering element decoding"
      rejected = true
    doAssert rejected, "count accepted at byte " & $offset
  doAssert getMaxMem() - before < 1_000_000,
    "decoder allocated from an untrusted element count"
