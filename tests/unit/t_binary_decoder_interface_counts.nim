## Actual nested interface records, encoded and decoded without mocks.
include binary_decoder_count_support
include "../../libs/repro_interface_artifacts/src/repro_interface_artifacts.nim"
import std/unittest

suite "interface bounded count decoding":
  test "populated public interface and nested provisioning collections":
    var value: ProjectInterface
    populateCountFixture(value)
    # ``gemBuildUses`` closes the cycle InterfaceToolUse ->
    # InterfaceTarballProvisioning -> InterfaceToolUse. The fixture must walk
    # it once, so the gem tool-use counts are corrupted and checked below
    # like every other count, and must stop there instead of recursing
    # without end.
    let gemUses = value.toolUses[0].tarballProvisioning[0].gemBuildUses
    doAssert gemUses.len == 1,
      "fixture must populate one level of gemBuildUses"
    doAssert gemUses[0].policyPath.len == 1 and
      gemUses[0].nixProvisioning.len == 1,
      "the nested gem tool use must carry its own collections"
    doAssert gemUses[0].tarballProvisioning.len == 0,
      "fixture must not expand the tool-use cycle a second time"
    let contributionGemUses = value.provisioningContributions[0]
      .tarballProvisioning[0].gemBuildUses
    doAssert contributionGemUses.len == 1 and
      contributionGemUses[0].tarballProvisioning.len == 1 and
      contributionGemUses[0].tarballProvisioning[0].gemBuildUses.len == 0,
      "a contribution's gem tool uses are walked once around the cycle"
    checkCountMutations(encodeInterfacePayload(value), proc(data: seq[byte]) =
      discard decodeInterfacePayload(data), expectedCounts = 139)
  test "file stamp sequence":
    var values: seq[FileStamp]
    populateCountFixture(values)
    var encoded: seq[byte]
    writeFileStamps(encoded, values)
    checkCountMutations(encoded, proc(data: seq[byte]) =
      var pos = 0
      discard readFileStamps(data, pos), expectedCounts = 1)
