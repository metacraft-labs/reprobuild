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

proc pathClosedCycle(path: openArray[string]): bool =
  ## True once some object type occurs twice on the current path, i.e. the
  ## walk has already gone once around a cycle in the type graph.
  for i in 0 ..< path.len:
    for j in i + 1 ..< path.len:
      if path[i] == path[j]:
        return true

proc populateCountFixture[T](value: var T; path: var seq[string]) =
  ## Fill every ``seq`` with one element and every ``Option`` with a value,
  ## recursing into each object field, so the encoder writes every element
  ## count reachable from ``T``.
  ##
  ## The type graph may be cyclic: ``InterfaceTarballProvisioning.gemBuildUses``
  ## holds ``InterfaceToolUse``, which holds ``InterfaceTarballProvisioning``.
  ## A plain structural walk then never terminates. ``path`` names the object
  ## types currently being populated; a ``seq`` whose element type is already
  ## on the path is expanded only while no cycle has been closed yet, so each
  ## cycle is walked around exactly once (one level of ``gemBuildUses``) and
  ## every collection on it still gets a populated, encoded count. Past that
  ## point the ``seq`` stays empty, which writes a zero count the recorder
  ## does not capture.
  when T is string:
    discard
  elif T is seq:
    when typeof(value[0]) is object:
      let elementType = $typeof(value[0])
      if elementType in path and pathClosedCycle(path):
        return
    value.setLen(1)
    populateCountFixture(value[0], path)
  elif T is Option:
    var inner: typeof(value.get())
    populateCountFixture(inner, path)
    value = some(inner)
  elif T is ref:
    discard
  elif T is object:
    path.add($T)
    for field in fields(value):
      populateCountFixture(field, path)
    path.setLen(path.len - 1)
  elif T is tuple:
    for field in fields(value):
      populateCountFixture(field, path)

proc populateCountFixture[T](value: var T) =
  var path: seq[string]
  populateCountFixture(value, path)

proc checkCountMutations(encoded: seq[byte]; decode: proc (data: seq[byte]) {.closure.}; expectedCounts: int; offsetAdjustment: int = 0) =
  ## Every recorded collection count must return the structured envelope error
  ## before allocating. One aggregate budget prevents later allocations from
  ## hiding behind an earlier iteration's memory high-water mark.
  decode(encoded) # Nonempty valid control, including nested collections.
  # Take the recorded offsets and clear the shared recorder before asserting,
  # so one failing case cannot leak its offsets into the next case's count.
  let offsets = encodedCountOffsets
  encodedCountOffsets = @[]
  doAssert offsets.len == expectedCounts,
    "fixture must reach all expected collections: recorded " &
    $offsets.len & ", expected " & $expectedCounts
  echo "  checked count fields: ", offsets.len
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
