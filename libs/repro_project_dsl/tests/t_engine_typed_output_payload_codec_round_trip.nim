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
    # Forge a v11 payload by encoding a v12 action with no typed
    # outputs, then patching the version field down to 11 and
    # truncating the trailing typed-output u32-length prefix.
    # ``writeStringSeq`` would emit a u32 of 0 for an empty seq — at
    # v11 that suffix doesn't exist, so trimming the last 4 bytes
    # produces a byte-accurate v11 payload.
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
    # Truncate the trailing 4-byte u32 (the empty typedOutputs count).
    let oldLen = int(uint32(payload[6]) or
      (uint32(payload[7]) shl 8) or
      (uint32(payload[8]) shl 16) or
      (uint32(payload[9]) shl 24))
    payload.setLen(payload.len - 4)
    let newLen = uint32(oldLen - 4)
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
    # empty typed-output list.
    check decoded.typedOutputs.len == 0
