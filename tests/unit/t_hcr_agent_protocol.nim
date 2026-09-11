import std/[json, strutils, unittest]

import repro_hcr_agent

const SupportProfile = "macos-arm64-direct-hcr-in-codetracer-v1"

proc samplePatchRequest(): HcrPatchRequest =
  HcrPatchRequest(
    schemaId: HcrPatchRequestSchemaId,
    patchId: "patch-0001",
    supportProfile: SupportProfile,
    mode: hpmDirect,
    changedFunctions: @["reprobuild_hcr_patchable_value"],
    targetSymbols: @["_reprobuild_hcr_patchable_value"],
    directPatchPayload: payload([byte 0x20, 0x00, 0x80, 0xd2]),
    debugObjectPayload: payload([byte 0x7f, 0x45, 0x4c, 0x46]),
    unwindMetadataPayload: payload([byte 0x10, 0x00, 0x00, 0x00]),
    sourceGenerationMap: @[
      HcrSourceGenerationEntry(
        sourcePath: "src/patchable.c",
        generation: 1,
        snapshotDigest: "blake3-256:source-generation-1",
        lineTableDigest: "blake3-256:line-table-1")
    ])

proc agentHello(): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: "msg-hello",
    kind: hmkHello,
    hello: HcrHello(
      supportProfile: SupportProfile,
      agentPid: 1234,
      capabilities: @[
        "hcr-agent-protocol",
        "direct-patch-injection",
        "debug-object-payloads",
        "unwind-metadata-payloads"
      ]))

proc coordinatorHelloAck(): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: "msg-hello-ack",
    kind: hmkHelloAck,
    hello: HcrHello(
      supportProfile: SupportProfile,
      agentPid: 0,
      capabilities: @["hcr-agent-protocol"]))

proc patchRequestMessage(): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: "msg-patch-request",
    kind: hmkPatchRequest,
    patchRequest: samplePatchRequest())

proc lifecycleMessage(patchId: string; event: string): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: "msg-lifecycle",
    kind: hmkLifecycleEvent,
    lifecycleEvent: HcrLifecycleEvent(
      patchId: patchId,
      event: event,
      sequence: 1))

proc patchAppliedMessage(sharedLibraryPositivePath = false): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: "msg-patch-applied",
    kind: hmkPatchApplied,
    patchApplied: HcrPatchApplied(
      patchId: "patch-0001",
      changedFunctions: @["reprobuild_hcr_patchable_value"],
      symbolGeneration: 1,
      debugObjectDigest: "blake3-256:debug-object",
      unwindMetadataDigest: "blake3-256:unwind",
      sourceGenerationMapDigest: "blake3-256:source-map",
      oldCodeRetained: true,
      sharedLibraryPositivePath: sharedLibraryPositivePath))

suite "HCR agent protocol":
  test "patch request frames round-trip with payload digests":
    let request = samplePatchRequest()
    let message = HcrAgentMessage(
      schemaId: HcrAgentProtocolSchemaId,
      transportScope: HcrAgentTransportScope,
      protocolVersion: HcrAgentProtocolVersion,
      messageId: "msg-0001",
      kind: hmkPatchRequest,
      patchRequest: request)

    let frame = frameAgentMessage(message)
    check frame.startsWith("Content-Length: ")
    let decoded = parseFramedAgentMessage(frame)

    check decoded.schemaId == HcrAgentProtocolSchemaId
    check decoded.transportScope == HcrAgentTransportScope
    check decoded.protocolVersion == HcrAgentProtocolVersion
    check decoded.kind == hmkPatchRequest
    check decoded.patchRequest.schemaId == HcrPatchRequestSchemaId
    check decoded.patchRequest.patchId == "patch-0001"
    check decoded.patchRequest.supportProfile == SupportProfile
    check decoded.patchRequest.mode == hpmDirect
    check decoded.patchRequest.changedFunctions ==
      @["reprobuild_hcr_patchable_value"]
    check decoded.patchRequest.directPatchPayload.bytes ==
      @[byte 0x20, 0x00, 0x80, 0xd2]
    check decoded.patchRequest.debugObjectPayload.digest ==
      payload([byte 0x7f, 0x45, 0x4c, 0x46]).digest
    check decoded.patchRequest.sourceGenerationMap[0].generation == 1'u32

  test "patch applied event carries debugger and replay evidence handles":
    let message = HcrAgentMessage(
      schemaId: HcrAgentProtocolSchemaId,
      transportScope: HcrAgentTransportScope,
      protocolVersion: HcrAgentProtocolVersion,
      messageId: "msg-0002",
      kind: hmkPatchApplied,
      patchApplied: HcrPatchApplied(
        patchId: "patch-0001",
        changedFunctions: @["reprobuild_hcr_patchable_value"],
        symbolGeneration: 1,
        debugObjectDigest: "blake3-256:debug-object",
        unwindMetadataDigest: "blake3-256:unwind",
        sourceGenerationMapDigest: "blake3-256:source-map",
        entryAddress: "0x10403c000",
        dispatchAddress: "0x104078000",
        oldCodeRetained: true,
        sharedLibraryPositivePath: false))

    let decoded = parseFramedAgentMessage(frameAgentMessage(message))

    check decoded.kind == hmkPatchApplied
    check decoded.patchApplied.patchId == "patch-0001"
    check decoded.patchApplied.symbolGeneration == 1'u64
    check decoded.patchApplied.entryAddress == "0x10403c000"
    check decoded.patchApplied.dispatchAddress == "0x104078000"
    check decoded.patchApplied.oldCodeRetained
    check not decoded.patchApplied.sharedLibraryPositivePath

  test "payload digest mismatches fail closed":
    let request = patchRequestJson(samplePatchRequest())
    request["directPatchPayload"]["digest"] =
      newJString("blake3-256:not-the-payload")

    expect ValueError:
      discard parsePatchRequest(request)

  test "unsupported patch modes are rejected by the direct profile codec":
    let request = patchRequestJson(samplePatchRequest())
    request["mode"] = newJString("shared-library")

    expect ValueError:
      discard parsePatchRequest(request)

  test "session accepts the negotiated direct patch lifecycle":
    var session = initHcrAgentSession(SupportProfile)

    session.observeAgentProtocolMessage(hmdAgentToCoordinator, agentHello())
    check session.state == hssAgentHelloReceived
    session.observeAgentProtocolMessage(
      hmdCoordinatorToAgent, coordinatorHelloAck())
    check session.state == hssNegotiated
    session.observeAgentProtocolMessage(
      hmdCoordinatorToAgent, patchRequestMessage())
    check session.state == hssPatchRequested
    session.observeAgentProtocolMessage(
      hmdAgentToCoordinator,
      lifecycleMessage("patch-0001", "hcr/patchApplied"))
    session.observeAgentProtocolMessage(
      hmdAgentToCoordinator, patchAppliedMessage())

    check session.state == hssPatchFinished
    check session.activePatchId == "patch-0001"
    check session.lifecycleEvents == @["hcr/patchApplied"]

  test "session rejects patch requests before capability negotiation":
    var session = initHcrAgentSession(SupportProfile)

    expect ValueError:
      session.observeAgentProtocolMessage(
        hmdCoordinatorToAgent, patchRequestMessage())

  test "session rejects empty patch ids":
    var session = initHcrAgentSession(SupportProfile)
    session.observeAgentProtocolMessage(hmdAgentToCoordinator, agentHello())
    session.observeAgentProtocolMessage(
      hmdCoordinatorToAgent, coordinatorHelloAck())

    var message = patchRequestMessage()
    message.patchRequest.patchId = ""
    expect ValueError:
      session.observeAgentProtocolMessage(hmdCoordinatorToAgent, message)

  test "session rejects mismatched patch ids and shared-library success":
    var session = initHcrAgentSession(SupportProfile)
    session.observeAgentProtocolMessage(hmdAgentToCoordinator, agentHello())
    session.observeAgentProtocolMessage(
      hmdCoordinatorToAgent, coordinatorHelloAck())
    session.observeAgentProtocolMessage(
      hmdCoordinatorToAgent, patchRequestMessage())

    expect ValueError:
      session.observeAgentProtocolMessage(
        hmdAgentToCoordinator,
        lifecycleMessage("patch-9999", "hcr/patchApplied"))

    session.observeAgentProtocolMessage(
      hmdAgentToCoordinator,
      lifecycleMessage("patch-0001", "hcr/patchApplied"))
    expect ValueError:
      session.observeAgentProtocolMessage(
        hmdAgentToCoordinator,
        patchAppliedMessage(sharedLibraryPositivePath = true))

  # --- HLX-M7 -------------------------------------------------------------
  # Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §10.3; protocol
  # `Hot-Code-Reloading-High-Level-Interfaces.md` §7.2 / §7.3.
  #
  # `allowed_mocks: none`. These drive the production codec and the production
  # session rules; nothing is stubbed.

  test "replay refuses a patch bundle whose supportProfile is not this host's":
    # §7.3 applies a stored bundle to a REPLAY process. The bundle's wire format
    # carries no architecture or ABI tag, so on a foreign host it would be
    # applied blindly — a linux-x86_64 `E9 rel32` published into an arm64
    # process is not a wrong patch, it is arbitrary code. `observeHello`
    # already refuses a mismatch during a live session; replay reads its profile
    # out of the recorded CodePatchEvent instead of off a socket, so the check
    # has to be callable without one.
    verifyBundleSupportProfile(HcrLinuxX86_64DirectSupportProfile,
                               HcrLinuxX86_64DirectSupportProfile)

    expect ValueError:
      verifyBundleSupportProfile(HcrMacosArm64DirectSupportProfile,
                                 HcrLinuxX86_64DirectSupportProfile)
    expect ValueError:
      verifyBundleSupportProfile(HcrLinuxX86_64DirectSupportProfile,
                                 HcrMacosArm64DirectSupportProfile)

  test "a bundle that names no supportProfile is refused, not waved through":
    # "Cannot be shown to match this host" must not be spelled "matches". An
    # empty profile is the shape a trace recorded by an agent that never
    # reported one would have, and applying its bundle would be the §7.3
    # equivalent of patching on faith.
    expect ValueError:
      verifyBundleSupportProfile("", HcrLinuxX86_64DirectSupportProfile)
    expect ValueError:
      verifyBundleSupportProfile(HcrLinuxX86_64DirectSupportProfile, "")

  test "the codePatchEvent report survives a protocol round trip":
    # The agent's report of what it recorded has to reach the coordinator
    # intact: it is the client's only way to learn whether the recording it is
    # inside carries the code-version boundary, and it is a gate's second,
    # independently transported copy of the digests.
    var applied = HcrPatchApplied(
      patchId: "patch-0001",
      changedFunctions: @["hcr_target"],
      symbolGeneration: 3'u64,
      debugObjectDigest: "blake3-256:debug",
      unwindMetadataDigest: "blake3-256:unwind",
      sourceGenerationMapDigest: "blake3-256:map",
      entryAddress: "0x1000",
      dispatchAddress: "0x2000",
      oldCodeRetained: true,
      sharedLibraryPositivePath: false)
    applied.codePatchEvent = HcrCodePatchEvent(
      present: true,
      recorded: true,
      bridgePresent: true,
      bridgeResult: 1,
      hashSelfTest: true,
      publicationTier: 1'u32,
      codeHashBefore: "sha256:" & repeat('a', 64),
      codeHashAfter: "sha256:" & repeat('b', 64),
      patchBundle: "sha256:" & repeat('c', 64),
      claimHeld: true)

    let message = HcrAgentMessage(
      schemaId: HcrAgentProtocolSchemaId,
      transportScope: HcrAgentTransportScope,
      protocolVersion: HcrAgentProtocolVersion,
      messageId: "agent-patch-applied-1",
      kind: hmkPatchApplied,
      patchApplied: applied)
    let restored = parseFramedAgentMessage(frameAgentMessage(message))
    check restored.patchApplied.codePatchEvent == applied.codePatchEvent
    check restored.patchApplied.symbolGeneration == 3'u64

  test "a claim conflict is reported as a named skipped function":
    # §10.1: the claim map's rule ends "never to a silent skip". A refusal that
    # reached the client as a bare message string would satisfy the letter and
    # not the point — the client could not tell a contested function from a
    # broken one without parsing prose.
    var failed = HcrPatchFailed(
      patchId: "patch-0001",
      stage: "applyDirectPatchRequest",
      message: "direct patch refused: claimed-by-recorder")
    failed.skippedFunctions = @[HcrSkippedFunction(
      function: "hcr_target",
      reason: "claimed-by-recorder",
      holder: 1'u32,
      windowAddress: "0x7f0000001000")]

    let message = HcrAgentMessage(
      schemaId: HcrAgentProtocolSchemaId,
      transportScope: HcrAgentTransportScope,
      protocolVersion: HcrAgentProtocolVersion,
      messageId: "agent-patch-failed-1",
      kind: hmkPatchFailed,
      patchFailed: failed)
    let restored = parseFramedAgentMessage(frameAgentMessage(message))
    check restored.patchFailed.skippedFunctions.len == 1
    check restored.patchFailed.skippedFunctions[0].reason ==
      "claimed-by-recorder"
    check restored.patchFailed.skippedFunctions[0].holder == 1'u32

  test "an absent codePatchEvent is not the same as an unrecorded one":
    # A non-Linux agent emits no `codePatchEvent` at all, and that must decode
    # to "not attempted" rather than to "attempted and not recorded". Only the
    # second is ever a defect, and collapsing them would hide it.
    let applied = HcrPatchApplied(
      patchId: "patch-0001",
      changedFunctions: @["hcr_target"],
      symbolGeneration: 1'u64,
      debugObjectDigest: "d",
      unwindMetadataDigest: "u",
      sourceGenerationMapDigest: "m",
      oldCodeRetained: true,
      sharedLibraryPositivePath: false)
    let message = HcrAgentMessage(
      schemaId: HcrAgentProtocolSchemaId,
      transportScope: HcrAgentTransportScope,
      protocolVersion: HcrAgentProtocolVersion,
      messageId: "agent-patch-applied-1",
      kind: hmkPatchApplied,
      patchApplied: applied)
    let restored = parseFramedAgentMessage(frameAgentMessage(message))
    check not restored.patchApplied.codePatchEvent.present
    check not restored.patchApplied.codePatchEvent.recorded

# ---------------------------------------------------------------------------
# GDH-M4 — the `sourceChanged` / `sourceReloadResult` pair (design §4.3/§4.4).
# ---------------------------------------------------------------------------

const
  GdhPath = "res://gdh4/probe.gd"
  GdhV2 = "extends Node\n\nfunc tick() -> int:\n\treturn 2\n"
  GdhV3 = "extends Node\n\nfunc tick() -> int:\n\treturn 3\n"

proc gdhSourceChanged(reloadId: string; generation: uint32;
                      text: string): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersionSourceReload,
    messageId: "coordinator-source-changed-1",
    kind: hmkSourceChanged,
    sourceChanged: HcrSourceChanged(
      reloadId: reloadId,
      language: "gdscript",
      changedFiles: @[
        sourceChangedFile(GdhPath, generation, bytesOfString(text))]))

proc gdhAppliedResult(reloadId: string;
                      generation: uint32): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersionSourceReload,
    messageId: "agent-source-reload-result-1",
    kind: hmkSourceReloadResult,
    sourceReloadResult: HcrSourceReloadResult(
      reloadId: reloadId,
      outcome: hsroApplied,
      appliedFiles: @[
        HcrSourceReloadAppliedFile(
          sourcePath: GdhPath,
          generation: generation,
          pathIndex: 7'u64,
          stepIndex: 481230'u64,
          appliedDigest: sourceSnapshotDigest(bytesOfString(GdhV2)),
          appliedLineCount: sourceLineCount(bytesOfString(GdhV2)))]))

suite "GDH-M4 source reload protocol":
  test "the digest both ends must agree on is SHA-256, pinned to FIPS 180-4":
    # The C agent recomputes these with `repro_hcr_sha256.h` and the
    # coordinator with `source_digest.nim`. Two independent implementations
    # agreeing is only evidence if both are pinned to the published vectors —
    # otherwise they could agree on being wrong together.
    check sha256Hex("") ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check sha256Hex("abc") ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256Hex(
      "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    check sourceSnapshotDigest(bytesOfString("abc")).startsWith("sha256:")
    check digestAlgorithmOf(sourceSnapshotDigest(bytesOfString("abc"))) ==
      "sha256"
    # An untagged digest must NOT be read as this algorithm. A host that
    # guessed would report a verification it did not perform.
    check digestAlgorithmOf("deadbeef") == ""

  test "the line table and the line count agree on the same convention":
    # They have to: a file could otherwise pass `lineCount` and fail
    # `lineTableDigest` for a reason no reader could act on.
    check sourceLineCount(bytesOfString("a\nb\nc\n")) == 3'u32
    check sourceLineCount(bytesOfString("a\nb\nc")) == 3'u32
    check sourceLineCount(bytesOfString("")) == 0'u32
    check sourceLineStartOffsets(bytesOfString("a\nb\nc\n")) == @[0'u32, 2'u32, 4'u32]
    check uint32(sourceLineStartOffsets(bytesOfString("a\nbb\nc")).len) ==
      sourceLineCount(bytesOfString("a\nbb\nc"))
    # Same line count, different bytes: the case §4.3 says `lineTableDigest`
    # exists for, where an index- or count-keyed scheme looks right.
    check sourceLineCount(bytesOfString(GdhV2)) ==
      sourceLineCount(bytesOfString(GdhV3))
    check sourceSnapshotDigest(bytesOfString(GdhV2)) !=
      sourceSnapshotDigest(bytesOfString(GdhV3))

  test "a sourceChanged frame round-trips with its content intact":
    let message = gdhSourceChanged("gdh4-r-0002", 2'u32, GdhV2)
    let restored = parseFramedAgentMessage(frameAgentMessage(message))
    check restored.kind == hmkSourceChanged
    check restored.protocolVersion == HcrAgentProtocolVersionSourceReload
    check restored.sourceChanged.reloadId == "gdh4-r-0002"
    check restored.sourceChanged.changedFiles.len == 1
    let file = restored.sourceChanged.changedFiles[0]
    check file.sourcePath == GdhPath
    check file.generation == 2'u32
    check file.contentEncoding == hsceInline
    check file.content == bytesOfString(GdhV2)
    check file.snapshotDigest == sourceSnapshotDigest(bytesOfString(GdhV2))
    check file.lineCount == sourceLineCount(bytesOfString(GdhV2))

  test "generation 1 is refused by name on BOTH directions of the wire":
    # §4.3 numbered generations so that 1 — the content the process started
    # with — is never a valid notification value. That is what turns the
    # shipping `symbolGeneration: 1` hardcode into a protocol error here
    # instead of a plausible one.
    expect ValueError:
      discard parseFramedAgentMessage(
        frameAgentMessage(gdhSourceChanged("gdh4-r-0002", 1'u32, GdhV2)))
    expect ValueError:
      discard parseFramedAgentMessage(
        frameAgentMessage(gdhAppliedResult("gdh4-r-0002", 1'u32)))
    # …and 2 is accepted, so the refusal above is about the value and not
    # about the shape of the message.
    let ok = parseFramedAgentMessage(
      frameAgentMessage(gdhAppliedResult("gdh4-r-0002", 2'u32)))
    check ok.sourceReloadResult.appliedFiles[0].generation == 2'u32

  test "the source-reload messages exist only on protocolVersion 2":
    var message = gdhSourceChanged("gdh4-r-0002", 2'u32, GdhV2)
    message.protocolVersion = HcrAgentProtocolVersion
    expect ValueError:
      discard parseFramedAgentMessage(frameAgentMessage(message))

  test "\"applied\" with nothing applied is refused":
    # Trap 2: a chain of `success: true` is not a result. The parser refuses
    # the shape so that no consumer has to remember to check it.
    var message = gdhAppliedResult("gdh4-r-0002", 2'u32)
    message.sourceReloadResult.appliedFiles = @[]
    expect ValueError:
      discard parseFramedAgentMessage(frameAgentMessage(message))
    # `reason` is non-empty iff the outcome is not applied — both halves.
    var withReason = gdhAppliedResult("gdh4-r-0002", 2'u32)
    withReason.sourceReloadResult.reason = "something"
    expect ValueError:
      discard parseFramedAgentMessage(frameAgentMessage(withReason))
    var refusedNoReason = gdhAppliedResult("gdh4-r-0002", 2'u32)
    refusedNoReason.sourceReloadResult.outcome = hsroFailed
    refusedNoReason.sourceReloadResult.appliedFiles = @[]
    refusedNoReason.sourceReloadResult.reason = ""
    expect ValueError:
      discard parseFramedAgentMessage(frameAgentMessage(refusedNoReason))

  test "an applied file with no recomputed digest is refused":
    # ADDED AT REVIEW. `appliedLineCount == 0` and `appliedFiles == []` were
    # already refused; an empty `appliedDigest` was not, which left one shape
    # representable: a host whose digest computation failed answering
    # `applied` with the evidence field blank and everything else intact.
    var noDigest = gdhAppliedResult("gdh4-r-0002", 2'u32)
    noDigest.sourceReloadResult.appliedFiles[0].appliedDigest = ""
    expect ValueError:
      discard parseFramedAgentMessage(frameAgentMessage(noDigest))
    # An UNTAGGED digest is refused too: a reader cannot recompute a bare hex
    # string without knowing the algorithm, so it is not a digest.
    var untagged = gdhAppliedResult("gdh4-r-0002", 2'u32)
    untagged.sourceReloadResult.appliedFiles[0].appliedDigest =
      sha256Hex(GdhV2)
    expect ValueError:
      discard parseFramedAgentMessage(frameAgentMessage(untagged))
    # …and the tagged one is accepted, so the refusals above are about the
    # field's content and not about the message's shape.
    let ok = parseFramedAgentMessage(
      frameAgentMessage(gdhAppliedResult("gdh4-r-0002", 2'u32)))
    check ok.sourceReloadResult.appliedFiles[0].appliedDigest ==
      sourceSnapshotDigest(bytesOfString(GdhV2))

  test "a mandatory lineCount of zero is refused":
    var message = gdhSourceChanged("gdh4-r-0002", 2'u32, GdhV2)
    message.sourceChanged.changedFiles[0].lineCount = 0'u32
    expect ValueError:
      discard parseFramedAgentMessage(frameAgentMessage(message))

  test "an empty changedFiles list is refused":
    var message = gdhSourceChanged("gdh4-r-0002", 2'u32, GdhV2)
    message.sourceChanged.changedFiles = @[]
    expect ValueError:
      discard parseFramedAgentMessage(frameAgentMessage(message))

  test "a refused file must carry a named reason":
    let message = HcrAgentMessage(
      schemaId: HcrAgentProtocolSchemaId,
      transportScope: HcrAgentTransportScope,
      protocolVersion: HcrAgentProtocolVersionSourceReload,
      messageId: "agent-source-reload-result-1",
      kind: hmkSourceReloadResult,
      sourceReloadResult: HcrSourceReloadResult(
        reloadId: "gdh4-r-0002",
        outcome: hsroFailed,
        reason: HcrReloadReasonCapabilityNotNegotiated,
        refusedFiles: @[
          HcrSourceReloadRefusedFile(
            sourcePath: GdhPath, generation: 2'u32, reason: "")]))
    expect ValueError:
      discard parseFramedAgentMessage(frameAgentMessage(message))

  test "a session refuses a reused reloadId and a mismatched acknowledgement":
    var session = initHcrAgentSession(SupportProfile)
    session.observeAgentProtocolMessage(hmdAgentToCoordinator,
      HcrAgentMessage(
        schemaId: HcrAgentProtocolSchemaId,
        transportScope: HcrAgentTransportScope,
        protocolVersion: HcrAgentProtocolVersion,
        messageId: "agent-hello-1",
        kind: hmkHello,
        hello: HcrHello(
          supportProfile: SupportProfile, agentPid: 1,
          capabilities: @["hcr-agent-protocol", HcrSourceReloadCapability])))
    check session.hostAdvertisedSourceReload()
    session.observeAgentProtocolMessage(hmdCoordinatorToAgent,
      HcrAgentMessage(
        schemaId: HcrAgentProtocolSchemaId,
        transportScope: HcrAgentTransportScope,
        protocolVersion: HcrAgentProtocolVersion,
        messageId: "coordinator-hello-ack-1",
        kind: hmkHelloAck,
        hello: HcrHello(supportProfile: SupportProfile, agentPid: 0,
          capabilities: @["hcr-agent-protocol"])))
    check session.state == hssNegotiated

    session.observeAgentProtocolMessage(hmdCoordinatorToAgent,
      gdhSourceChanged("gdh4-r-0002", 2'u32, GdhV2))
    check session.state == hssSourceReloadRequested
    # An acknowledgement for a different reload is refused: without this, two
    # notifications in flight could be answered once and counted twice.
    expect ValueError:
      session.observeAgentProtocolMessage(hmdAgentToCoordinator,
        gdhAppliedResult("gdh4-r-9999", 2'u32))
    session.observeAgentProtocolMessage(hmdAgentToCoordinator,
      gdhAppliedResult("gdh4-r-0002", 2'u32))
    check session.state == hssNegotiated
    check session.sourceReloadResults.len == 1
    # §4.3 requires the id to be unique per notification.
    expect ValueError:
      session.observeAgentProtocolMessage(hmdCoordinatorToAgent,
        gdhSourceChanged("gdh4-r-0002", 3'u32, GdhV3))
