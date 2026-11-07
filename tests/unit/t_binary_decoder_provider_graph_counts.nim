## Malformed counts exercise real provider_graph readers; no mocks.
include binary_decoder_count_support
include "../../libs/repro_provider_runtime/src/repro_provider_runtime/codec.nim"
import std/unittest

suite "provider_graph bounded count decoding":
  test "nested counts in Manifest":
    var value: ProviderManifest
    populateCountFixture(value)
    var encoded: seq[byte]
    encoded.writeManifest(value)
    checkCountMutations(encoded, proc(data: seq[byte]) =
      var pos = 0
      discard readManifest(data, pos), expectedCounts = 1)
  test "nested counts in Fragment":
    var value: GraphFragment
    populateCountFixture(value)
    var encoded: seq[byte]
    encoded.writeFragmentPayload(value, true)
    checkCountMutations(encoded, proc(data: seq[byte]) =
      var pos = 0
      discard readFragment(data, pos), expectedCounts = 6)
  test "nested counts in DevEnvResult":
    var value: DevEnvResult
    populateCountFixture(value)
    var encoded: seq[byte]
    encoded.writeDevEnvResult(value)
    checkCountMutations(encoded, proc(data: seq[byte]) =
      var pos = 0
      discard readDevEnvResult(data, pos), expectedCounts = 29)
  test "nested counts in StoredFragment":
    var value: StoredGraphFragment
    populateCountFixture(value)
    var encoded: seq[byte]
    encoded.writeStoredFragment(value)
    checkCountMutations(encoded, proc(data: seq[byte]) =
      var pos = 0
      discard readStoredFragment(data, pos), expectedCounts = 6)
  test "snapshot fragment collection":
    var value: ProviderGraphSnapshot
    populateCountFixture(value)
    checkCountMutations(encodeProviderSnapshot(value), proc(data: seq[byte]) =
      discard decodeProviderSnapshot(data), expectedCounts = 8,
      offsetAdjustment = 12)
