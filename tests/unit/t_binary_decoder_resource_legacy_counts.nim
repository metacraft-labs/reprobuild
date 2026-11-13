## Real legacy records remain readable; impossible dependency/holder counts must
## fail at the count guard, before allocation or a later truncated field read.
include ../../libs/repro_resources/src/repro_resources/state_store

proc legacyFixture(): seq[byte] =
  for ch in StateRecordMagic: result.add(byte(ch))
  result.writeU32Le(StateRecordVersion)
  result.writeString("")
  result.writeString("")
  result.writeU32Le(0)
  result.writeString("")
  result.writeString("")
  result.writeU32Le(1)
  result.writeString("")
  result.writeString("")
  for i in 0 ..< 32: result.add(0)
  result.add(0)
  result.writeU32Le(1)
  result.writeString("")
  result.writeU64Le(0)
  result.add(0)
  result.writeU64Le(0)


import std/unittest

suite "resource legacy collection bounds":
  test "populated records roundtrip and every count is bounded":
    let fixture = legacyFixture()
    let valid = decodeRecordLegacy(fixture)
    check valid.dependsOn.len == 1
    check valid.holders.len == 1
    for offset in [28, 73]:
      var corrupt = fixture
      corrupt[offset] = 0
      corrupt[offset + 1] = 0
      corrupt[offset + 2] = 1
      corrupt[offset + 3] = 0
      let before = getMaxMem()
      var rejected = false
      try:
        discard decodeRecordLegacy(corrupt)
      except IOError as error:
        doAssert error.msg == "element count exceeds remaining bytes"
        rejected = true
      doAssert rejected
      doAssert getMaxMem() - before < 512 * 1024
