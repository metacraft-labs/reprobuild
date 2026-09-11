import std/[streams, unittest]

import repro_hcr_agent
import repro_hcr_test

const
  SupportProfile = "macos-arm64-direct-hcr-in-codetracer-v1"
  FunctionName = "_reprobuild_hcr_patchable_value"

proc resolveTargetSymbol(ctx: pointer; symbolName: string): uint64 =
  let target = cast[ptr FakeTarget](ctx)
  if symbolName == FunctionName:
    target[].entryAddress(symbolName)
  else:
    0

proc runtimeOps(target: var FakeTarget): HcrAgentRuntimeOps =
  HcrAgentRuntimeOps(
    ctx: addr target,
    targetEnv: target.targetOps(),
    resolveTargetSymbol: resolveTargetSymbol)

proc coordinatorHelloAck(): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: "coordinator-hello-ack-1",
    kind: hmkHelloAck,
    hello: HcrHello(
      supportProfile: SupportProfile,
      agentPid: 0,
      capabilities: @["hcr-agent-protocol"]))

proc patchRequest(patchBytes: seq[byte]): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: "coordinator-patch-request-1",
    kind: hmkPatchRequest,
    patchRequest: HcrPatchRequest(
      schemaId: HcrPatchRequestSchemaId,
      patchId: "patch-0001",
      supportProfile: SupportProfile,
      mode: hpmDirect,
      changedFunctions: @[FunctionName],
      targetSymbols: @[FunctionName],
      directPatchPayload: payload(patchBytes),
      debugObjectPayload: payload([byte 0x7f, 0x45, 0x4c, 0x46]),
      unwindMetadataPayload: payload([byte 0x10, 0x00, 0x00, 0x00]),
      sourceGenerationMap: @[
        HcrSourceGenerationEntry(
          sourcePath: "src/patchable.c",
          generation: 1,
          snapshotDigest: "blake3-256:source-generation-1",
          lineTableDigest: "blake3-256:line-table-1")
      ]))

proc collectMessages(stream: StringStream): seq[HcrAgentMessage] =
  stream.setPosition(0)
  while not stream.atEnd:
    result.add stream.readAgentMessage()

suite "HCR agent endpoint":
  test "framed transport carries multiple coordinator messages":
    let patchBytes = aarch64ReturnImmediateBytes(77)
    let stream = newStringStream()
    discard stream.writeAgentMessage(coordinatorHelloAck())
    discard stream.writeAgentMessage(patchRequest(patchBytes))

    let messages = collectMessages(stream)
    check messages.len == 2
    check messages[0].kind == hmkHelloAck
    check messages[1].kind == hmkPatchRequest
    check messages[1].patchRequest.directPatchPayload.bytes == patchBytes

  test "agent endpoint negotiates and applies direct patch request":
    var target = initFakeTarget(
      FunctionName, aarch64PatchableReturnBytes(11, sledNops = 4))
    let patchBytes = aarch64ReturnImmediateBytes(77)
    var endpoint = initHcrAgentEndpoint(
      SupportProfile, runtimeOps(target), agentPid = 1234)

    let input = newStringStream()
    let output = newStringStream()
    discard input.writeAgentMessage(coordinatorHelloAck())
    discard input.writeAgentMessage(patchRequest(patchBytes))
    input.setPosition(0)

    endpoint.runAgentEndpointOnce(input, output)

    let messages = collectMessages(output)
    check messages.len == 4
    check messages[0].kind == hmkHello
    check messages[0].hello.supportProfile == SupportProfile
    check messages[1].kind == hmkLifecycleEvent
    check messages[1].lifecycleEvent.event == "hcr/patchApplying"
    check messages[2].kind == hmkLifecycleEvent
    check messages[2].lifecycleEvent.event == "hcr/patchApplied"
    check messages[3].kind == hmkPatchApplied
    check messages[3].patchApplied.patchId == "patch-0001"
    check messages[3].patchApplied.symbolGeneration == 1'u64
    check messages[3].patchApplied.oldCodeRetained
    check not messages[3].patchApplied.sharedLibraryPositivePath
    check target.callOriginalPointer(FunctionName) == 77

  test "agent endpoint reports patch failures without a shared-library fallback":
    var target = initFakeTarget(
      FunctionName, aarch64PatchableReturnBytes(11, sledNops = 4))
    var request = patchRequest(aarch64ReturnImmediateBytes(77))
    request.patchRequest.directPatchPayload.digest = "blake3-256:wrong"
    var endpoint = initHcrAgentEndpoint(
      SupportProfile, runtimeOps(target), agentPid = 1234)

    discard endpoint.handleCoordinatorMessage(coordinatorHelloAck())
    let responses = endpoint.handleCoordinatorMessage(request)

    check responses.len == 3
    check responses[0].kind == hmkLifecycleEvent
    check responses[0].lifecycleEvent.event == "hcr/patchApplying"
    check responses[1].kind == hmkLifecycleEvent
    check responses[1].lifecycleEvent.event == "hcr/patchFailed"
    check responses[2].kind == hmkPatchFailed
    check responses[2].patchFailed.stage == "applyDirectPatchRequest"
    check target.callOriginalPointer(FunctionName) == 11

  # -------------------------------------------------------------------------
  # GDH-M4 — the endpoint half of design §4.4's capability negotiation.
  #
  # The C agent (`repro_hcr_agent.c`) is what the campaign's gates drive, and
  # it enforces the same rule. This suite covers the Nim endpoint, which is the
  # host shape a Nim embedding uses, so the rule cannot hold in one
  # implementation and quietly not in the other.
  # -------------------------------------------------------------------------

  test "a sourceChanged to a host that did not advertise source-reload is REFUSED, not ignored":
    var target = initFakeTarget(
      FunctionName, aarch64PatchableReturnBytes(11, sledNops = 4))
    var endpoint = initHcrAgentEndpoint(
      SupportProfile, runtimeOps(target), agentPid = 1234)
    discard endpoint.handleCoordinatorMessage(coordinatorHelloAck())

    # Anti-vacuity, the same order the campaign's gate uses: the capability is
    # ASSERTED ABSENT before the refusal means anything.
    check not endpoint.advertisesSourceReload()

    let content = bytesOfString("extends Node\n\nfunc tick() -> int:\n\treturn 2\n")
    let changed = HcrSourceChanged(
      reloadId: "r-0002",
      language: "gdscript",
      changedFiles: @[sourceChangedFile("res://probe.gd", 2'u32, content)])
    let responses = endpoint.handleCoordinatorMessage(HcrAgentMessage(
      schemaId: HcrAgentProtocolSchemaId,
      transportScope: HcrAgentTransportScope,
      protocolVersion: HcrAgentProtocolVersionSourceReload,
      messageId: "coordinator-source-changed-1",
      kind: hmkSourceChanged,
      sourceChanged: changed))

    # The host ANSWERED. An ignored notification would be an empty response
    # sequence, and design §4.4 calls that worse than a refused session.
    check responses.len == 1
    check responses[0].kind == hmkSourceReloadResult
    let res = responses[0].sourceReloadResult
    check res.reloadId == "r-0002"
    check res.outcome == hsroFailed
    check res.reason == HcrReloadReasonCapabilityNotNegotiated
    check res.appliedFiles.len == 0
    check res.refusedFiles.len == 1
    check res.refusedFiles[0].reason == HcrReloadReasonCapabilityNotNegotiated
    # And it survives the wire, so the refusal is a message and not just an
    # object this test built.
    let restored = parseFramedAgentMessage(frameAgentMessage(responses[0]))
    check restored.sourceReloadResult.reason ==
      HcrReloadReasonCapabilityNotNegotiated

  test "the control: the same message to a host that DID advertise is applied":
    var target = initFakeTarget(
      FunctionName, aarch64PatchableReturnBytes(11, sledNops = 4))
    var endpoint = initHcrAgentEndpoint(
      SupportProfile, runtimeOps(target), agentPid = 1234)

    var appliedContent: seq[byte] = @[]
    endpoint.withSourceReload(proc(changed: HcrSourceChanged):
        HcrSourceReloadResult {.gcsafe, raises: [CatchableError].} =
      # A handler that does something observable: it keeps the bytes and
      # reports a digest it recomputed over them, not the one it was sent.
      let file = changed.changedFiles[0]
      {.cast(gcsafe).}:
        appliedContent = file.content
      HcrSourceReloadResult(
        reloadId: changed.reloadId,
        outcome: hsroApplied,
        appliedFiles: @[
          HcrSourceReloadAppliedFile(
            sourcePath: file.sourcePath,
            generation: file.generation,
            pathIndex: 7'u64,
            stepIndex: 481230'u64,
            appliedDigest: sourceSnapshotDigest(file.content),
            appliedLineCount: sourceLineCount(file.content))]))

    check endpoint.advertisesSourceReload()
    check endpoint.capabilities.contains(HcrSourceReloadCapability)
    discard endpoint.handleCoordinatorMessage(coordinatorHelloAck())

    let content = bytesOfString("extends Node\n\nfunc tick() -> int:\n\treturn 2\n")
    let changed = HcrSourceChanged(
      reloadId: "r-0002",
      language: "gdscript",
      changedFiles: @[sourceChangedFile("res://probe.gd", 2'u32, content)])
    let responses = endpoint.handleCoordinatorMessage(HcrAgentMessage(
      schemaId: HcrAgentProtocolSchemaId,
      transportScope: HcrAgentTransportScope,
      protocolVersion: HcrAgentProtocolVersionSourceReload,
      messageId: "coordinator-source-changed-1",
      kind: hmkSourceChanged,
      sourceChanged: changed))

    check responses.len == 1
    let res = responses[0].sourceReloadResult
    check res.outcome == hsroApplied
    check res.reason == ""
    check res.appliedFiles.len == 1
    check res.appliedFiles[0].generation == 2'u32
    check res.appliedFiles[0].appliedDigest == sourceSnapshotDigest(content)
    # The handler really received the bytes — the acknowledgement is not the
    # only witness.
    check appliedContent == content

  test "advertising source-reload without a handler is refused at registration":
    var target = initFakeTarget(
      FunctionName, aarch64PatchableReturnBytes(11, sledNops = 4))
    var endpoint = initHcrAgentEndpoint(
      SupportProfile, runtimeOps(target), agentPid = 1234)
    expect ValueError:
      endpoint.withSourceReload(nil)
    check not endpoint.advertisesSourceReload()
