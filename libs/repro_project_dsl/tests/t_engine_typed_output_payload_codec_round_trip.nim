## Typed-Outputs M1 verification: a ``BuildActionDef`` with multiple
## typed outputs round-trips through ``encodeBuildActionPayload`` /
## ``decodeBuildActionPayload`` losslessly. An older-version payload
## (v11) decodes with an empty typed-output list.
##
## Pure codec test — no provider mode required. Builds a synthetic
## ``BuildActionDef`` in-line, encodes it, decodes it, and asserts on
## every field.

import std/[unittest]

import repro_project_dsl

suite "t_engine_typed_output_payload_codec_round_trip":

  test "t_engine_typed_output_payload_codec_round_trip":
    # Construct a synthetic action with multiple typed outputs. The
    # call/inputs/outputs etc. fields don't need to be meaningful for
    # the codec test — we just want a fully-populated value so the
    # encoder serialises every section.
    let call = publicCliCall("pkg", "exe", "build",
      "pkg.exe.build", @[
        inputArg("source", "src/foo.nim"),
        outputArg("binary", "build/test-bin/foo")
      ])

    let action = BuildActionDef(
      id: "build-foo",
      call: call,
      deps: @["dep-1", "dep-2"],
      inputs: @["src/foo.nim"],
      outputs: @["build/test-bin/foo"],
      pool: "",
      poolUnits: 1'u32,
      depfile: "",
      cacheable: true,
      commandStatsId: "build-foo",
      dependencyPolicy: defaultDependencyPolicy(),
      actionCachePolicy: defaultActionCachePolicy(),
      targetNames: @["foo"],
      typedOutputs: @[
        BuildActionTypedOutput(
          fieldName: "testBinary",
          types: @["NimUnittestBinary", "TestBinary"],
          path: "build/test-bin/foo"),
        BuildActionTypedOutput(
          fieldName: "installer",
          types: @["InstallableExecutable"],
          path: "build/test-bin/foo-installer")
      ])

    let payload = encodeBuildActionPayload(action)
    let decoded = decodeBuildActionPayload(payload)

    # Every field round-trips, including the new typed-output list.
    check decoded.id == action.id
    check decoded.deps == action.deps
    check decoded.inputs == action.inputs
    check decoded.outputs == action.outputs
    check decoded.targetNames == action.targetNames
    check decoded.typedOutputs.len == 2
    check decoded.typedOutputs[0].fieldName == "testBinary"
    check decoded.typedOutputs[0].types ==
      @["NimUnittestBinary", "TestBinary"]
    check decoded.typedOutputs[0].path == "build/test-bin/foo"
    check decoded.typedOutputs[1].fieldName == "installer"
    check decoded.typedOutputs[1].types == @["InstallableExecutable"]
    check decoded.typedOutputs[1].path == "build/test-bin/foo-installer"

  test "older v11 payload decodes with empty typed-output list":
    # Forge a v11 payload by encoding the current-version action with
    # no typed outputs and no ``outputTag``, then patching the version
    # field down to 11 and truncating the trailing fields that
    # ``writeStringSeq`` / ``writeString`` for those empty defaults
    # emitted.
    # Recipe-Val M8 (v13) + MR10 (v14) + M9.L.4-refactor Step B (v16)
    # + M9.N Batch B (v17): the encoded payload now ends with the
    # u32 typedOutputs count + the u32 outputTag string length + the
    # u32 env count + the publishToBinaryCache sentinel byte + the
    # hasIdentity sentinel byte + the u32 toolIdentityRefs count
    # (all zero for an empty action), so 18 trailing bytes need
    # trimming to reach v11's wire shape.
    let action = BuildActionDef(
      id: "legacy",
      call: publicCliCall("pkg", "exe", "build",
        "pkg.exe.build", @[]),
      cacheable: true,
      commandStatsId: "legacy",
      dependencyPolicy: defaultDependencyPolicy(),
      actionCachePolicy: defaultActionCachePolicy(),
      targetNames: @["legacy-target"])

    var payload = encodeBuildActionPayload(action)
    # Patch the version word (offset 4..5, little-endian uint16) down
    # to 11 and re-encode the payload length so the framing self-
    # consistency check stays valid.
    # Magic is bytes 0..3; version is bytes 4..5; length is bytes 6..9.
    # Truncate 18 trailing bytes: 4 for the empty typedOutputs count
    # (the v12 addition) + 4 for the empty outputTag string length
    # (the v13 addition) + 4 for the empty env count (the v14
    # addition) + 1 for the publishToBinaryCache sentinel byte + 1
    # for the hasIdentity sentinel byte (the v16 addition; both
    # default-zero when the optional fields are inert) + 4 for the
    # empty toolIdentityRefs count (the v17 addition). All six
    # fields are absent at v11.
    let trimBytes = 18
    let oldLen = int(uint32(payload[6]) or
      (uint32(payload[7]) shl 8) or
      (uint32(payload[8]) shl 16) or
      (uint32(payload[9]) shl 24))
    payload.setLen(payload.len - trimBytes)
    let newLen = uint32(oldLen - trimBytes)
    payload[4] = 11'u8
    payload[5] = 0'u8
    payload[6] = byte(newLen and 0xff)
    payload[7] = byte((newLen shr 8) and 0xff)
    payload[8] = byte((newLen shr 16) and 0xff)
    payload[9] = byte((newLen shr 24) and 0xff)

    let decoded = decodeBuildActionPayload(payload)
    check decoded.id == "legacy"
    check decoded.targetNames == @["legacy-target"]
    # Backward-compatibility contract: v11 payloads decode with an
    # empty typed-output list and an empty outputTag.
    check decoded.typedOutputs.len == 0
    check decoded.outputTag == ""

  test "older v16 payload decodes with empty toolIdentityRefs (M9.N Batch B)":
    # Forge a v16 payload by encoding the current-version action with
    # no toolIdentityRefs, then patching the version field down to 16
    # and trimming the trailing 4 bytes (the v17 toolIdentityRefs
    # length-prefix). v16-and-earlier payloads MUST decode with an
    # empty ``toolIdentityRefs`` so legacy artefacts keep working.
    let action = BuildActionDef(
      id: "v16-legacy",
      call: publicCliCall("pkg", "exe", "build",
        "pkg.exe.build", @[]),
      cacheable: true,
      commandStatsId: "v16-legacy",
      dependencyPolicy: defaultDependencyPolicy(),
      actionCachePolicy: defaultActionCachePolicy())

    var payload = encodeBuildActionPayload(action)
    let trimBytes = 4
    let oldLen = int(uint32(payload[6]) or
      (uint32(payload[7]) shl 8) or
      (uint32(payload[8]) shl 16) or
      (uint32(payload[9]) shl 24))
    payload.setLen(payload.len - trimBytes)
    let newLen = uint32(oldLen - trimBytes)
    payload[4] = 16'u8
    payload[5] = 0'u8
    payload[6] = byte(newLen and 0xff)
    payload[7] = byte((newLen shr 8) and 0xff)
    payload[8] = byte((newLen shr 16) and 0xff)
    payload[9] = byte((newLen shr 24) and 0xff)

    let decoded = decodeBuildActionPayload(payload)
    check decoded.id == "v16-legacy"
    # v16-and-earlier payloads decode with an empty toolIdentityRefs
    # slice — the engine's resolver block is a no-op for them.
    check decoded.toolIdentityRefs.len == 0
