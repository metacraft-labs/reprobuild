import std/[json, options, streams, unittest]

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

proc sourceGenerations(): seq[HcrSourceGenerationEntry] =
  @[
    HcrSourceGenerationEntry(
      sourcePath: "src/patchable.c",
      generation: 1,
      snapshotDigest: "blake3-256:source-generation-1",
      lineTableDigest: "blake3-256:line-table-1")
  ]

proc makeRequest(patchBytes: seq[byte]): HcrPatchRequest =
  directPatchRequest(
    patchId = "patch-0001",
    supportProfile = SupportProfile,
    changedFunctions = [FunctionName],
    targetSymbols = [FunctionName],
    directPatchBytes = patchBytes,
    debugObjectBytes = [byte 0x7f, 0x45, 0x4c, 0x46],
    unwindMetadataBytes = [byte 0x10, 0x00, 0x00, 0x00],
    sourceGenerationMap = sourceGenerations())

proc collectMessages(stream: StringStream): seq[HcrAgentMessage] =
  stream.setPosition(0)
  while not stream.atEnd:
    result.add stream.readAgentMessage()

suite "HCR coordinator":
  test "coordinator negotiates, sends direct patch bundle, and validates response":
    var target = initFakeTarget(
      FunctionName, aarch64PatchableReturnBytes(11, sledNops = 4))
    let patchBytes = aarch64ReturnImmediateBytes(77)
    let request = makeRequest(patchBytes)

    var endpoint = initHcrAgentEndpoint(
      SupportProfile, runtimeOps(target), agentPid = 1234)
    var previewCoordinator = initHcrCoordinatorClient(SupportProfile)

    let agentToCoordinator = newStringStream()
    discard agentToCoordinator.writeAgentMessage(endpoint.agentHelloMessage())
    discard endpoint.handleCoordinatorMessage(
      previewCoordinator.coordinatorHelloAckMessage())
    for response in endpoint.handleCoordinatorMessage(
        previewCoordinator.coordinatorPatchRequestMessage(request)):
      discard agentToCoordinator.writeAgentMessage(response)
    agentToCoordinator.setPosition(0)

    let coordinatorToAgent = newStringStream()
    var coordinator = initHcrCoordinatorClient(SupportProfile)
    let delivery = coordinator.deliverPatchRequest(
      agentToCoordinator, coordinatorToAgent, request)

    check delivery.session.state == hssPatchFinished
    check delivery.patchApplied.isSome
    check delivery.patchFailed.isNone
    check delivery.patchApplied.get().patchId == "patch-0001"
    check delivery.patchApplied.get().changedFunctions == @[FunctionName]
    check delivery.patchApplied.get().symbolGeneration == 1'u64
    check delivery.patchApplied.get().oldCodeRetained
    check not delivery.patchApplied.get().sharedLibraryPositivePath
    check target.callOriginalPointer(FunctionName) == 77

    let coordinatorMessages = collectMessages(coordinatorToAgent)
    check coordinatorMessages.len == 2
    check coordinatorMessages[0].kind == hmkHelloAck
    check coordinatorMessages[1].kind == hmkPatchRequest
    check coordinatorMessages[1].patchRequest.directPatchPayload.bytes ==
      patchBytes

    check delivery.transcript.len == 6
    check delivery.transcript[0].direction == hmdAgentToCoordinator
    check delivery.transcript[0].message.kind == hmkHello
    check delivery.transcript[1].direction == hmdCoordinatorToAgent
    check delivery.transcript[1].message.kind == hmkHelloAck
    check delivery.transcript[2].direction == hmdCoordinatorToAgent
    check delivery.transcript[2].message.kind == hmkPatchRequest
    check delivery.transcript[5].direction == hmdAgentToCoordinator
    check delivery.transcript[5].message.kind == hmkPatchApplied

    let report = coordinatorDeliveryJson(delivery)
    check report["schemaId"].getStr() ==
      "reprobuild.hcr.coordinator-report.v1"
    check report["supportProfile"].getStr() == SupportProfile
    check report["sessionState"].getStr() == "hssPatchFinished"
    check report["patchApplied"]["patchId"].getStr() == "patch-0001"
    check report["transcript"]["schemaId"].getStr() ==
      "reprobuild.hcr.agent-protocol-transcript.v1"
    check report["transcript"]["messages"].len == 6
