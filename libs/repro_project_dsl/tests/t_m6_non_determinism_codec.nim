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
    ## The v23 payload comes out of the REAL encoder running at v23
    ## (`encodeBuildActionPayloadAtVersion`) rather than a hand-rolled one: a
    ## hand-rolled encoder would stop resembling the real format the moment
    ## either changed, and would then test nothing.
    ##
    ## It used to be derived instead, by taking a current-version image,
    ## removing the bytes the blessing appended and rewriting the header. That
    ## is only sound while every intervening bump appends AT THE TAIL, and v25
    ## does not: it appended `suppressMonitorShimSeed` at the end of the
    ## dependency-policy record, which sits a dozen fields earlier. The derived
    ## image kept a byte no v23 reader consumes, so it failed the decoder's
    ## trailing-bytes check — as a forgery, not as a legacy artefact, though
    ## the error named the decoder either way.
    let action = BuildActionDef(
      id: "compile",
      call: inlineExecCall(@["nim", "c"]),
      nonDeterminism: ndpEntropyBlessed,
      nonDeterminismJustification: "j")
    let v23 = encodeBuildActionPayloadAtVersion(action, 23'u16)
    # Envelope: magic(4) | version u16 LE | payloadLen u32 LE | payload
    check v23[4] == 23'u8
    check v23[5] == 0'u8
    # The blessing the action carries is genuinely ABSENT from the image, not
    # merely ignored on the way in. The v26 encoding is longer by the blessing
    # byte + its length-prefixed one-character justification (1 + 4 + 1) AND
    # by v25's `suppressMonitorShimSeed` byte — the mid-payload one. Spelling
    # both out is the assertion that would have caught the old forgery: it
    # accounted for the first group and not for the second.
    check encodeBuildActionPayload(action).len - v23.len == (1 + 4 + 1) + 1

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
