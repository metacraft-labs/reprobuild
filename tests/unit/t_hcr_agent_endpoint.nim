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
