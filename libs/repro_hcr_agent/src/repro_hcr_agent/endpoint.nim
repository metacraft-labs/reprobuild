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
  HcrAgentEndpoint* = object
    supportProfile*: string
    agentPid*: int
    capabilities*: seq[string]
    runtime*: HcrAgentRuntimeOps
    negotiated*: bool
    activePatchId*: string
    nextSequence*: uint64

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

proc runAgentEndpointFromEnvOnce*(endpoint: var HcrAgentEndpoint) =
  var connection = connectHcrAgentFromEnv()
  defer: connection.close()
  endpoint.runAgentEndpointOnce(connection)
