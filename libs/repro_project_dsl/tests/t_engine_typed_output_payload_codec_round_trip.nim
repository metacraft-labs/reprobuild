## Typed-Outputs M1 verification: a ``BuildActionDef`` with multiple
## typed outputs round-trips through ``encodeBuildActionPayload`` /
## ``decodeBuildActionPayload`` losslessly. An older-version payload
## (v11) decodes with an empty typed-output list.
##
## Pure codec test — no provider mode required. Builds a synthetic
## ``BuildActionDef`` in-line, encodes it, decodes it, and asserts on
## every field.

import std/[options, unittest]

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
      publishToBinaryCache: true,
      cacheEntryIdentity: some(newCacheEntryIdentity(
        packageName = "foo",
        packageVersion = "1.0",
        platform = publicInterfaceTriple(),
        toolchain = publicInterfaceToolchain("meson"),
        providerRevision = "test-revision")),
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
    check decoded.publishToBinaryCache
    check decoded.cacheEntryIdentity.isSome
    check deriveCacheEntryKeyHex(decoded.cacheEntryIdentity.get()) ==
      deriveCacheEntryKeyHex(action.cacheEntryIdentity.get())
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
    # A GENUINE v11 image, produced by the real encoder running at v11
    # (``encodeBuildActionPayloadAtVersion``), not a v26 image with its
    # tail chopped off.
    #
    # The trimming forgery this replaces was wrong, and wrong in a way
    # that reported itself as a decoder regression. It assumed every
    # version bump appends at the END OF THE PAYLOAD, so patching the
    # version word and dropping N trailing bytes would yield the older
    # wire shape. v25 broke that assumption: it appended
    # ``suppressMonitorShimSeed`` at the end of the DEPENDENCY POLICY
    # record, a dozen fields from the tail. The forged payload kept that
    # byte, no v11 reader consumes it, every field after the policy was
    # read one byte off, and the decode died on a garbage string length
    # ("truncated string in build action payload"). Nothing was wrong
    # with the decoder or with real v11 artefacts.
    let action = BuildActionDef(
      id: "legacy",
      call: publicCliCall("pkg", "exe", "build",
        "pkg.exe.build", @[]),
      cacheable: true,
      commandStatsId: "legacy",
      dependencyPolicy: defaultDependencyPolicy(),
      actionCachePolicy: defaultActionCachePolicy(),
      targetNames: @["legacy-target"])

    let payload = encodeBuildActionPayloadAtVersion(action, 11'u16)
    # The image really is stamped v11 (magic 0..3, version 4..5 LE).
    check payload[4] == 11'u8
    check payload[5] == 0'u8

    let decoded = decodeBuildActionPayload(payload)
    check decoded.id == "legacy"
    check decoded.targetNames == @["legacy-target"]
    # Backward-compatibility contract: v11 payloads decode with an
    # empty typed-output list and an empty outputTag.
    check decoded.typedOutputs.len == 0
    check decoded.outputTag == ""

  test "older v16 payload decodes with empty toolIdentityRefs (M9.N Batch B)":
    # Same construction as the v11 case above, at v16. v16-and-earlier
    # payloads MUST decode with all newer fields at their inert defaults
    # so legacy artefacts keep working.
    let action = BuildActionDef(
      id: "v16-legacy",
      call: publicCliCall("pkg", "exe", "build",
        "pkg.exe.build", @[]),
      cacheable: true,
      commandStatsId: "v16-legacy",
      dependencyPolicy: defaultDependencyPolicy(),
      actionCachePolicy: defaultActionCachePolicy())

    let payload = encodeBuildActionPayloadAtVersion(action, 16'u16)
    check payload[4] == 16'u8
    check payload[5] == 0'u8

    let decoded = decodeBuildActionPayload(payload)
    check decoded.id == "v16-legacy"
    # v16-and-earlier payloads decode with an empty toolIdentityRefs
    # slice — the engine's resolver block is a no-op for them.
    check decoded.toolIdentityRefs.len == 0
    # Windows-System-Resources Phase E: v18-and-earlier payloads
    # decode with ``requiresElevation = false`` so the engine's
    # exec lowering keeps every legacy edge on the direct-fork path.
    check decoded.requiresElevation == false
    # M9.R.34: v19-and-earlier payloads predate per-recipe
    # invalidation; legacy artefacts decode with an empty
    # ``recipeRevisionFingerprint`` so the engine reverts to the
    # pre-M9.R.34 fingerprint composition for them.
    check decoded.recipeRevisionFingerprint == ""

  test "every payload version from 1 to the current one decodes":
    ## The decoder claims a RANGE — ``version < 1 or version >
    ## BuildActionPayloadVersion`` is the only rejection — and the two cases
    ## above only spot-check two points in it. This walks the whole range, so
    ## a version whose write-side and read-side gates disagree is caught at
    ## the version where they diverge rather than whenever someone next
    ## happens to write a spot check for it.
    ##
    ## This is what replaces the hand-maintained trailing-byte counts. Those
    ## had to be updated by hand on every bump, were documented as such, and
    ## still went stale — and when they did the failure named the decoder
    ## rather than the count.
    let action = BuildActionDef(
      id: "range",
      call: publicCliCall("pkg", "exe", "build", "pkg.exe.build", @[
        inputArg("source", "src/foo.nim"),
        outputArg("binary", "build/test-bin/foo")
      ]),
      deps: @["dep-1"],
      inputs: @["src/foo.nim"],
      outputs: @["build/test-bin/foo"],
      poolUnits: 1'u32,
      cacheable: true,
      commandStatsId: "range",
      dependencyPolicy: defaultDependencyPolicy(),
      actionCachePolicy: defaultActionCachePolicy(),
      targetNames: @["foo"])

    for version in 1'u16 .. BuildActionPayloadVersion:
      let payload = encodeBuildActionPayloadAtVersion(action, version)
      check payload[4] == byte(version and 0xff'u16)
      check payload[5] == byte((version shr 8) and 0xff'u16)
      # Decoding must not raise for ANY version in the supported range.
      let decoded = decodeBuildActionPayload(payload)
      # ``id`` precedes every version gate, so it is the one field that
      # must survive at every version; a cursor that went out of step
      # anywhere later shows up as a decode failure above.
      check decoded.id == "range"
      check decoded.deps == @["dep-1"]
      check decoded.inputs == @["src/foo.nim"]
      check decoded.outputs == @["build/test-bin/foo"]
      check decoded.commandStatsId == "range"
