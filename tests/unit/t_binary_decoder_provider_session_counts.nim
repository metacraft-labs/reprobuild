## Malformed counts exercise real provider_session readers; no mocks.
include binary_decoder_count_support
include "../../libs/repro_provider_runtime/src/repro_provider_runtime/session.nim"
import std/unittest

suite "provider_session bounded count decoding":
  test "nested counts in BoxedValueSeq":
    var value: seq[BoxedValue]
    populateCountFixture(value)
    var encoded: seq[byte]
    encoded.writeBoxedValueSeq(value)
    checkCountMutations(encoded, proc(data: seq[byte]) =
      var pos = 0
      discard readBoxedValueSeq(data, pos), expectedCounts = 1)
  test "nested counts in EvaluationInput":
    var value: GraphEvaluationInput
    populateCountFixture(value)
    var encoded: seq[byte]
    encoded.writeEvalInput(value)
    checkCountMutations(encoded, proc(data: seq[byte]) =
      var pos = 0
      discard readEvalInput(data, pos), expectedCounts = 1)
  test "message collections in EngineHello":
    var value: EngineHello
    populateCountFixture(value)
    checkCountMutations(encodeEngineHello(value), proc(data: seq[byte]) =
      discard decodeEngineHello(data), expectedCounts = 1)
  test "message collections in ProviderManifestMsg":
    var value: ProviderManifest
    populateCountFixture(value)
    checkCountMutations(encodeProviderManifestMsg(value), proc(data: seq[byte]) =
      discard decodeProviderManifestMsg(data), expectedCounts = 1)
  test "message collections in InvokeEntryPoint":
    var value: InvokeEntryPoint
    populateCountFixture(value)
    checkCountMutations(encodeInvokeEntryPoint(value), proc(data: seq[byte]) =
      discard decodeInvokeEntryPoint(data), expectedCounts = 2)
  test "message collections in EntryPointResult":
    var value: EntryPointResult
    populateCountFixture(value)
    checkCountMutations(encodeEntryPointResult(value), proc(data: seq[byte]) =
      discard decodeEntryPointResult(data), expectedCounts = 3)
  test "message collections in BindDependencies":
    var value: BindDependencies
    populateCountFixture(value)
    checkCountMutations(encodeBindDependencies(value), proc(data: seq[byte]) =
      discard decodeBindDependencies(data), expectedCounts = 3)
