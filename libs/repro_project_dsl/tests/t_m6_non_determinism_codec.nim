## Windows-Build-Correctness M6 — the entropy blessing must survive the
## payload codec, and a payload that predates it must decode as UNBLESSED.
##
## The blessing is declared in a package spec, encoded into the build-action
## payload by the provider, and decoded by the CLI on the way to the engine.
## Every one of those hops is a place a boolean can go missing, and this one
## goes missing in the dangerous direction if the decoder guesses: a v23
## payload has no blessing byte, and answering "blessed" for it would restore
## cache publication for every legacy artefact on the strength of a byte that
## was never written.
##
## The round-trip below is not ceremony. Neither the DSL test
## (`t_nim_entropy_blessing`) nor the engine test (`test_m6_entropy_blessing`)
## crosses this boundary — the first reads the registered `BuildActionDef`
## directly and the second sets the field on a hand-built `BuildAction` — so
## without this file a codec that dropped the field entirely would pass both.

import std/unittest

import repro_project_dsl

suite "M6 the entropy blessing round-trips through the action payload":
  setup:
    resetBuildActionRegistry()

  test "a blessing and its justification survive encode/decode":
    let action = BuildActionDef(
      id: "compile",
      call: inlineExecCall(@["nim", "c"]),
      nonDeterminism: ndpEntropyBlessed,
      nonDeterminismJustification: "temp names only; never reaches output")
    let decoded = decodeBuildActionPayload(encodeBuildActionPayload(action))
    check decoded.nonDeterminism == ndpEntropyBlessed
    check decoded.nonDeterminismJustification ==
      "temp names only; never reaches output"

  test "the absence of a blessing round-trips as an absence":
    ## The distinguishing direction. A codec that wrote a constant, or that
    ## read the wrong offset and happened to land on a non-zero byte, would
    ## pass the case above and fail this one.
    let action = BuildActionDef(
      id: "compile",
      call: inlineExecCall(@["gcc", "-c"]))
    let decoded = decodeBuildActionPayload(encodeBuildActionPayload(action))
    check decoded.nonDeterminism == ndpUnblessed
    check decoded.nonDeterminismJustification == ""

  test "the blessing does not disturb the fields encoded beside it":
    ## It is appended after the v23 tool-identity roles, so an off-by-one in
    ## either direction corrupts a neighbour rather than failing loudly.
    let action = BuildActionDef(
      id: "compile",
      call: inlineExecCall(@["ninja"]),
      toolIdentityRefs: @["ninja", "libdrm"],
      toolIdentityRefKinds: @[tirkNative, tirkBuild],
      declaredOutputs: @["build/out"],
      readOnlyRoots: @["src"],
      nonDeterminism: ndpEntropyBlessed,
      nonDeterminismJustification: "vouched for")
    let decoded = decodeBuildActionPayload(encodeBuildActionPayload(action))
    check decoded.toolIdentityRefs == action.toolIdentityRefs
    check decoded.toolIdentityRefKinds == action.toolIdentityRefKinds
    check decoded.declaredOutputs == action.declaredOutputs
    check decoded.readOnlyRoots == action.readOnlyRoots
    check decoded.nonDeterminism == ndpEntropyBlessed
    check decoded.nonDeterminismJustification == "vouched for"

  test "a v23 payload decodes as UNBLESSED, never as blessed":
    ## The legacy-artefact path, and the one that fails in the dangerous
    ## direction if the decoder guesses. A v23 payload has no blessing byte,
    ## so the decoder must supply `ndpUnblessed` — answering "blessed" would
    ## restore cache publication for every artefact written before this
    ## milestone, on the strength of a byte that was never written.
    ##
    ## The v23 payload is derived from a real v24 one by removing exactly the
    ## bytes v24 appended and rewriting the header, rather than hand-rolling
    ## an encoder: a hand-rolled one would stop resembling the real format the
    ## moment either changed, and would then test nothing.
    let action = BuildActionDef(
      id: "compile",
      call: inlineExecCall(@["nim", "c"]),
      nonDeterminism: ndpEntropyBlessed,
      nonDeterminismJustification: "j")
    let v24 = encodeBuildActionPayload(action)
    # Trailer appended by v24: one blessing byte + a u32-length-prefixed
    # one-character justification.
    let appended = 1 + 4 + 1
    var v23 = v24[0 ..< v24.len - appended]
    # Envelope: magic(4) | version u16 LE | payloadLen u32 LE | payload
    v23[4] = 23'u8
    v23[5] = 0'u8
    let shortened = uint32(v23.len - 10)
    v23[6] = byte(shortened and 0xFF'u32)
    v23[7] = byte((shortened shr 8) and 0xFF'u32)
    v23[8] = byte((shortened shr 16) and 0xFF'u32)
    v23[9] = byte((shortened shr 24) and 0xFF'u32)

    let decoded = decodeBuildActionPayload(v23)
    # The surrounding fields must still decode, or this would be testing a
    # rejected payload rather than a legacy one.
    check decoded.id == "compile"
    check decoded.nonDeterminism == ndpUnblessed
    check decoded.nonDeterminismJustification == ""

  test "a corrupted blessing byte is refused, not rounded to a blessing":
    ## Same strictness the v19 `requiresElevation` and v21 `cwdKind`
    ## sentinels use, and it earns it here more than there: one of the two
    ## ordinals SUPPRESSES a cache-publication guard, so a payload byte that
    ## decoded to whatever it happened to hold would be a way to bless a tool
    ## by corruption.
    let action = BuildActionDef(
      id: "compile",
      call: inlineExecCall(@["nim", "c"]),
      nonDeterminism: ndpEntropyBlessed,
      nonDeterminismJustification: "j")
    var bytes = encodeBuildActionPayload(action)
    # The blessing byte is followed by the length-prefixed justification, so
    # it sits 5 bytes before the single justification character at the tail.
    let blessingIndex = bytes.len - 6
    check bytes[blessingIndex] == byte(ord(ndpEntropyBlessed))
    bytes[blessingIndex] = 200'u8
    expect BuildActionPayloadError:
      discard decodeBuildActionPayload(bytes)
