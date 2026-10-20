## Actual nested interface records, encoded and decoded without mocks.
include binary_decoder_count_support
include "../../libs/repro_interface_artifacts/src/repro_interface_artifacts.nim"
import std/unittest

suite "interface bounded count decoding":
  test "populated public interface and nested provisioning collections":
    var value: ProjectInterface
    populateCountFixture(value)
    checkCountMutations(encodeInterfacePayload(value), proc(data: seq[byte]) =
      discard decodeInterfacePayload(data), expectedCounts = 58)
  test "file stamp sequence":
    var values: seq[FileStamp]
    populateCountFixture(values)
    var encoded: seq[byte]
    writeFileStamps(encoded, values)
    checkCountMutations(encoded, proc(data: seq[byte]) =
      var pos = 0
      discard readFileStamps(data, pos), expectedCounts = 1)
