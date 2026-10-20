## Malformed counts exercise real domain readers; no mocks.
include binary_decoder_count_support
include "../../libs/repro_domain_types/src/repro_domain_types/codec.nim"
import std/unittest

suite "domain bounded count decoding":
  test "nested counts in Env":
    var value: seq[EnvVar]
    populateCountFixture(value)
    var encoded: seq[byte]
    encoded.writeEnv(value)
    checkCountMutations(encoded, proc(data: seq[byte]) =
      var pos = 0
      discard readEnv(data, pos), expectedCounts = 1)
  test "nested counts in Process":
    var value: ProcessSpec
    populateCountFixture(value)
    var encoded: seq[byte]
    encoded.writeProcess(value)
    checkCountMutations(encoded, proc(data: seq[byte]) =
      var pos = 0
      discard readProcess(data, pos), expectedCounts = 2)
  test "nested counts in DependencyPolicy":
    var value: DependencyGatheringPolicy
    populateCountFixture(value)
    var encoded: seq[byte]
    encoded.writeDependencyPolicy(value)
    checkCountMutations(encoded, proc(data: seq[byte]) =
      var pos = 0
      discard readDependencyPolicy(data, pos), expectedCounts = 7)
