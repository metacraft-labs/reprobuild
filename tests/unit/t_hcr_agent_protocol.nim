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
