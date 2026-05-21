import std/[options, streams]

import repro_hcr_agent/ipc
import repro_hcr_agent/protocol
import repro_hcr_agent/session
import repro_hcr_agent/transport

const DefaultCoordinatorCapabilities* = [
  "hcr-agent-protocol",
  "coordinator-agent-negotiation",
  "direct-patch-bundle-delivery"
]

type
  HcrCoordinatorClient* = object
    supportProfile*: string
    capabilities*: seq[string]
    session*: HcrAgentSession
    transcript*: seq[HcrProtocolTranscriptEntry]
    patchApplied*: Option[HcrPatchApplied]
    patchFailed*: Option[HcrPatchFailed]
    nextMessageSequence*: uint64

  HcrCoordinatorDelivery* = object
    session*: HcrAgentSession
    transcript*: seq[HcrProtocolTranscriptEntry]
    patchApplied*: Option[HcrPatchApplied]
    patchFailed*: Option[HcrPatchFailed]

proc initHcrCoordinatorClient*(supportProfile: string;
                               capabilities: openArray[string] = []):
                               HcrCoordinatorClient =
  result = HcrCoordinatorClient(
    supportProfile: supportProfile,
    session: initHcrAgentSession(supportProfile))
  if capabilities.len == 0:
    result.capabilities = @DefaultCoordinatorCapabilities
  else:
    result.capabilities = @capabilities

proc nextMessageId(client: var HcrCoordinatorClient; label: string): string =
  client.nextMessageSequence.inc
  "coordinator-" & label & "-" & $client.nextMessageSequence

proc directPatchRequest*(patchId, supportProfile: string;
                         changedFunctions, targetSymbols: openArray[string];
                         directPatchBytes, debugObjectBytes,
                         unwindMetadataBytes: openArray[byte];
                         sourceGenerationMap:
                           openArray[HcrSourceGenerationEntry]):
                         HcrPatchRequest =
  HcrPatchRequest(
    schemaId: HcrPatchRequestSchemaId,
    patchId: patchId,
    supportProfile: supportProfile,
    mode: hpmDirect,
    changedFunctions: @changedFunctions,
    targetSymbols: @targetSymbols,
    directPatchPayload: payload(directPatchBytes),
    debugObjectPayload: payload(debugObjectBytes),
    unwindMetadataPayload: payload(unwindMetadataBytes),
    sourceGenerationMap: @sourceGenerationMap)

proc coordinatorHelloAckMessage*(client: var HcrCoordinatorClient):
    HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: client.nextMessageId("hello-ack"),
    kind: hmkHelloAck,
    hello: HcrHello(
      supportProfile: client.supportProfile,
      agentPid: 0,
      capabilities: client.capabilities))

proc coordinatorPatchRequestMessage*(client: var HcrCoordinatorClient;
                                     request: HcrPatchRequest):
                                     HcrAgentMessage =
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersion,
    messageId: client.nextMessageId("patch-request"),
    kind: hmkPatchRequest,
    patchRequest: request)

proc observe(client: var HcrCoordinatorClient; direction: HcrMessageDirection;
             rawFrame: string; message: HcrAgentMessage) =
  client.session.observeAgentProtocolMessage(direction, message)
  client.transcript.add transcriptEntry(direction, rawFrame, message)
  case message.kind
  of hmkPatchApplied:
    client.patchApplied = some(message.patchApplied)
  of hmkPatchFailed:
    client.patchFailed = some(message.patchFailed)
  else:
    discard

proc receiveAgentMessage*(client: var HcrCoordinatorClient;
                          input: Stream): HcrAgentMessage =
  let (frame, message) = input.readAgentMessageWithFrame()
  client.observe(hmdAgentToCoordinator, frame, message)
  message

proc receiveAgentMessage*(client: var HcrCoordinatorClient;
                          connection: HcrAgentSocketConnection):
                          HcrAgentMessage =
  let (frame, message) = connection.readAgentMessageWithFrame()
  client.observe(hmdAgentToCoordinator, frame, message)
  message

proc sendCoordinatorMessage*(client: var HcrCoordinatorClient;
                             output: Stream;
                             message: HcrAgentMessage) =
  let frame = output.writeAgentMessage(message)
  client.observe(hmdCoordinatorToAgent, frame, message)

proc sendCoordinatorMessage*(client: var HcrCoordinatorClient;
                             connection: HcrAgentSocketConnection;
                             message: HcrAgentMessage) =
  let frame = connection.writeAgentMessage(message)
  client.observe(hmdCoordinatorToAgent, frame, message)

proc delivery(client: HcrCoordinatorClient): HcrCoordinatorDelivery =
  HcrCoordinatorDelivery(
    session: client.session,
    transcript: client.transcript,
    patchApplied: client.patchApplied,
    patchFailed: client.patchFailed)

proc deliverPatchRequest*(client: var HcrCoordinatorClient;
                          agentToCoordinator, coordinatorToAgent: Stream;
                          request: HcrPatchRequest):
                          HcrCoordinatorDelivery =
  discard client.receiveAgentMessage(agentToCoordinator)
  client.sendCoordinatorMessage(
    coordinatorToAgent, client.coordinatorHelloAckMessage())
  client.sendCoordinatorMessage(
    coordinatorToAgent, client.coordinatorPatchRequestMessage(request))

  while client.session.state == hssPatchRequested:
    discard client.receiveAgentMessage(agentToCoordinator)

  client.delivery()

proc deliverPatchRequest*(client: var HcrCoordinatorClient;
                          connection: HcrAgentSocketConnection;
                          request: HcrPatchRequest):
                          HcrCoordinatorDelivery =
  discard client.receiveAgentMessage(connection)
  client.sendCoordinatorMessage(
    connection, client.coordinatorHelloAckMessage())
  client.sendCoordinatorMessage(
    connection, client.coordinatorPatchRequestMessage(request))

  while client.session.state == hssPatchRequested:
    discard client.receiveAgentMessage(connection)

  client.delivery()
