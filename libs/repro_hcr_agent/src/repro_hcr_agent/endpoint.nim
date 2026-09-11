import std/streams

import repro_hcr_agent/ipc
import repro_hcr_agent/protocol
import repro_hcr_agent/runtime
import repro_hcr_agent/transport

const DefaultAgentCapabilities* = [
  "hcr-agent-protocol",
  "direct-patch-injection",
  "debug-object-payloads",
  "unwind-metadata-payloads",
  "source-generation-metadata"
]

type
  HcrSourceReloadHandler* = proc(changed: HcrSourceChanged):
    HcrSourceReloadResult {.gcsafe, raises: [CatchableError].}
    ## What a host DOES with a `sourceChanged`. A host that has none cannot
    ## reload, must not advertise `source-reload`, and answers
    ## `capability-not-negotiated` — which is why registering the handler and
    ## advertising the capability are the same act (`withSourceReload`).

  HcrAgentEndpoint* = object
    supportProfile*: string
    agentPid*: int
    capabilities*: seq[string]
    runtime*: HcrAgentRuntimeOps
    negotiated*: bool
    activePatchId*: string
    nextSequence*: uint64
    sourceReload*: HcrSourceReloadHandler

proc initHcrAgentEndpoint*(supportProfile: string;
                           runtime: HcrAgentRuntimeOps;
                           agentPid = 0;
                           capabilities: openArray[string] = []):
                           HcrAgentEndpoint =
  result = HcrAgentEndpoint(
    supportProfile: supportProfile,
    agentPid: agentPid,
    runtime: runtime)
  if capabilities.len == 0:
    result.capabilities = @DefaultAgentCapabilities
  else:
    result.capabilities = @capabilities

proc withSourceReload*(endpoint: var HcrAgentEndpoint;
                       handler: HcrSourceReloadHandler) =
  ## Register the handler AND advertise the capability, together.
  ##
  ## They are one call because the alternative — a host that advertises
  ## `source-reload` and has nothing to apply it with — is the failure §4.4
  ## calls worse than no session: the coordinator sends a notification, the
  ## host answers nothing meaningful, and the recording attributes post-reload
  ## steps to v1 with nothing saying so.
  if handler.isNil:
    raise newException(ValueError,
      "withSourceReload needs a handler; a host with none must not advertise " &
        HcrSourceReloadCapability)
  endpoint.sourceReload = handler
  if HcrSourceReloadCapability notin endpoint.capabilities:
    endpoint.capabilities.add HcrSourceReloadCapability

proc advertisesSourceReload*(endpoint: HcrAgentEndpoint): bool =
  HcrSourceReloadCapability in endpoint.capabilities

proc nextMessageId(endpoint: var HcrAgentEndpoint; label: string): string =
  endpoint.nextSequence.inc
  "agent-" & label & "-" & $endpoint.nextSequence

proc agentHelloMessage*(endpoint: var HcrAgentEndpoint): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: endpoint.nextMessageId("hello"),
    kind: hmkHello,
    hello: HcrHello(
      supportProfile: endpoint.supportProfile,
      agentPid: endpoint.agentPid,
      capabilities: endpoint.capabilities))

proc lifecycleMessage(endpoint: var HcrAgentEndpoint; patchId, event: string):
    HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: endpoint.nextMessageId("lifecycle"),
    kind: hmkLifecycleEvent,
    lifecycleEvent: HcrLifecycleEvent(
      patchId: patchId,
      event: event,
      sequence: endpoint.nextSequence))

proc patchAppliedMessage(endpoint: var HcrAgentEndpoint;
                         applied: HcrPatchApplied): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: endpoint.nextMessageId("patch-applied"),
    kind: hmkPatchApplied,
    patchApplied: applied)

proc patchFailedMessage(endpoint: var HcrAgentEndpoint; patchId, stage,
                        message: string): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: endpoint.nextMessageId("patch-failed"),
    kind: hmkPatchFailed,
    patchFailed: HcrPatchFailed(
      patchId: patchId,
      stage: stage,
      message: message))

proc sourceReloadResultMessage(endpoint: var HcrAgentEndpoint;
                               value: HcrSourceReloadResult): HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersionSourceReload,
    messageId: endpoint.nextMessageId("source-reload-result"),
    kind: hmkSourceReloadResult,
    sourceReloadResult: value)

proc refuseWholeReload(changed: HcrSourceChanged; reason: string;
                       detail = ""): HcrSourceReloadResult =
  result = HcrSourceReloadResult(
    reloadId: changed.reloadId,
    outcome: hsroFailed,
    reason: reason)
  for file in changed.changedFiles:
    result.refusedFiles.add HcrSourceReloadRefusedFile(
      sourcePath: file.sourcePath,
      generation: file.generation,
      reason: reason,
      detail: detail)

proc handleSourceChanged*(endpoint: var HcrAgentEndpoint;
                          changed: HcrSourceChanged): HcrSourceReloadResult =
  ## Design §4.4: a `sourceChanged` that arrives at a host which did not
  ## advertise `source-reload` is ANSWERED, not ignored. An ignored
  ## notification leaves the coordinator unable to tell a host that refused
  ## from a host that is not listening.
  if not endpoint.advertisesSourceReload() or endpoint.sourceReload.isNil:
    return refuseWholeReload(changed, HcrReloadReasonCapabilityNotNegotiated,
      "this host did not advertise " & HcrSourceReloadCapability &
        " in its hello, so the coordinator must not have sent it")
  try:
    endpoint.sourceReload(changed)
  except CatchableError as err:
    refuseWholeReload(changed, HcrReloadReasonParseError, err.msg)

proc requireSupportProfile(endpoint: HcrAgentEndpoint; supportProfile: string;
                           action: string) =
  if supportProfile != endpoint.supportProfile:
    raise newException(ValueError,
      action & " support profile mismatch: expected " &
        endpoint.supportProfile & ", got " & supportProfile)

proc handleCoordinatorMessage*(endpoint: var HcrAgentEndpoint;
                               message: HcrAgentMessage):
                               seq[HcrAgentMessage] =
  case message.kind
  of hmkHelloAck:
    endpoint.requireSupportProfile(message.hello.supportProfile,
      "coordinator helloAck")
    endpoint.negotiated = true
  of hmkPatchRequest:
    if not endpoint.negotiated:
      raise newException(ValueError,
        "HCR agent received patch request before helloAck")
    endpoint.requireSupportProfile(message.patchRequest.supportProfile,
      "patch request")
    endpoint.activePatchId = message.patchRequest.patchId
    result.add endpoint.lifecycleMessage(
      message.patchRequest.patchId, "hcr/patchApplying")
    try:
      let applied = endpoint.runtime.applyDirectPatchRequest(
        message.patchRequest)
      result.add endpoint.lifecycleMessage(
        message.patchRequest.patchId, "hcr/patchApplied")
      result.add endpoint.patchAppliedMessage(applied.patchApplied)
    except CatchableError as err:
      result.add endpoint.lifecycleMessage(
        message.patchRequest.patchId, "hcr/patchFailed")
      result.add endpoint.patchFailedMessage(
        message.patchRequest.patchId, "applyDirectPatchRequest", err.msg)
  of hmkSourceChanged:
    if not endpoint.negotiated:
      raise newException(ValueError,
        "HCR agent received sourceChanged before helloAck")
    result.add endpoint.sourceReloadResultMessage(
      endpoint.handleSourceChanged(message.sourceChanged))
  else:
    raise newException(ValueError,
      "HCR agent endpoint cannot handle coordinator message kind " &
        message.kind.kindName)

proc runAgentEndpointOnce*(endpoint: var HcrAgentEndpoint;
                           input, output: Stream) =
  discard output.writeAgentMessage(endpoint.agentHelloMessage())
  let helloAck = input.readAgentMessage()
  for response in endpoint.handleCoordinatorMessage(helloAck):
    discard output.writeAgentMessage(response)

  let patchRequest = input.readAgentMessage()
  for response in endpoint.handleCoordinatorMessage(patchRequest):
    discard output.writeAgentMessage(response)

proc runAgentEndpointOnce*(endpoint: var HcrAgentEndpoint;
                           connection: HcrAgentSocketConnection) =
  discard connection.writeAgentMessage(endpoint.agentHelloMessage())
  let helloAck = connection.readAgentMessage()
  for response in endpoint.handleCoordinatorMessage(helloAck):
    discard connection.writeAgentMessage(response)

  let patchRequest = connection.readAgentMessage()
  for response in endpoint.handleCoordinatorMessage(patchRequest):
    discard connection.writeAgentMessage(response)

proc runAgentEndpointSession*(endpoint: var HcrAgentEndpoint;
                              connection: HcrAgentSocketConnection;
                              maxMessages = 0): int {.discardable.} =
  ## The multi-message form (GDH-M4). Reads coordinator frames until the peer
  ## closes the connection, answering each. The one-shot
  ## `runAgentEndpointOnce` is kept because HLX's gates drive it directly and
  ## its shape is what they assert.
  discard connection.writeAgentMessage(endpoint.agentHelloMessage())
  while maxMessages == 0 or result < maxMessages:
    var message: HcrAgentMessage
    try:
      message = connection.readAgentMessage()
    except IOError:
      # The peer closed. This is a NAMED end of session, distinct from a stall.
      return
    result.inc
    for response in endpoint.handleCoordinatorMessage(message):
      discard connection.writeAgentMessage(response)

proc runAgentEndpointFromEnvOnce*(endpoint: var HcrAgentEndpoint) =
  var connection = connectHcrAgentFromEnv()
  defer: connection.close()
  endpoint.runAgentEndpointOnce(connection)
