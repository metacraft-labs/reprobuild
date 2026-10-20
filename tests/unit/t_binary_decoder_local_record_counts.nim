## Count tracing uses the real record writer and decoder, including path interning.
include ./binary_decoder_count_support
include ../../libs/repro_local_store/src/repro_local_store


import std/unittest

suite "local record collection bounds":
  test "populated records roundtrip and every count is bounded":
    var record: ActionResultRecord
    populateCountFixture(record)
    let encoded = encodeRecord(record)
    let valid = decodeRecordImpl(encoded)
    check valid.inputs.len == 1
    check valid.envInputs.len == 1
    check valid.outputs.len == 1
    checkCountMutations(encoded, proc(data: seq[byte]) =
      discard decodeRecordImpl(data), 4)
