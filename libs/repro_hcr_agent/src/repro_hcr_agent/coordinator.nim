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

proc coordinatorSourceChangedMessage*(client: var HcrCoordinatorClient;
                                      changed: HcrSourceChanged):
                                      HcrAgentMessage =
  ## Design §4.3/§4.4 — carried on `protocolVersion` 2, the wire that has the
  ## message on it at all.
  HcrAgentMessage(
    schemaId: HcrAgentProtocolSchemaId,
    transportScope: HcrAgentTransportScope,
    protocolVersion: HcrAgentProtocolVersionSourceReload,
    messageId: client.nextMessageId("source-changed"),
    kind: hmkSourceChanged,
    sourceChanged: changed)

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

proc completeHandshake*(client: var HcrCoordinatorClient;
                        connection: HcrAgentSocketConnection) =
  ## Receive the agent's `hello` and answer it, leaving the session
  ## `hssNegotiated` and the connection OPEN.
  ##
  ## Split out of `deliverPatchRequest` so a caller that means to publish more
  ## than one patch over one connection does the handshake once. It is the
  ## same two messages in the same order; `deliverPatchRequest` is written in
  ## terms of it rather than beside it, so there is no second handshake path to
  ## drift out of step with this one.
  discard client.receiveAgentMessage(connection)
  client.sendCoordinatorMessage(
    connection, client.coordinatorHelloAckMessage())

proc requestPatchOnOpenSession*(client: var HcrCoordinatorClient;
                                connection: HcrAgentSocketConnection;
                                request: HcrPatchRequest):
                                HcrCoordinatorDelivery =
  ## Publish one patch on an already-negotiated session and wait for its
  ## verdict. Callable repeatedly: the session state machine admits a patch
  ## request from `hssNegotiated`, `hssPatchFinished` and `hssFailed`.
  ##
  ## THE PREVIOUS VERDICT IS CLEARED FIRST, and that is not tidiness. Both
  ## verdict fields are `Option`s that only ever get assigned, so a second
  ## patch that was REFUSED would otherwise return a delivery still carrying
  ## the first patch's `patchApplied` — a caller reading "applied" for a patch
  ## the agent declined, which is the silent-self-pass shape in its purest
  ## form. The one-shot path never noticed because it could only ever hold one.
  client.patchApplied = none(HcrPatchApplied)
  client.patchFailed = none(HcrPatchFailed)
  client.sendCoordinatorMessage(
    connection, client.coordinatorPatchRequestMessage(request))

  while client.session.state == hssPatchRequested:
    discard client.receiveAgentMessage(connection)

  client.delivery()

proc deliverPatchRequest*(client: var HcrCoordinatorClient;
                          connection: HcrAgentSocketConnection;
                          request: HcrPatchRequest):
                          HcrCoordinatorDelivery =
  client.completeHandshake(connection)
  client.requestPatchOnOpenSession(connection, request)

when defined(windows):
  proc receiveAgentMessage*(client: var HcrCoordinatorClient;
                            connection: HcrAgentPipeConnection):
                            HcrAgentMessage =
    let (frame, message) = connection.readAgentMessageWithFrame()
    client.observe(hmdAgentToCoordinator, frame, message)
    message

  proc sendCoordinatorMessage*(client: var HcrCoordinatorClient;
                               connection: HcrAgentPipeConnection;
                               message: HcrAgentMessage) =
    let frame = connection.writeAgentMessage(message)
    client.observe(hmdCoordinatorToAgent, frame, message)

  proc completeHandshake*(client: var HcrCoordinatorClient;
                          connection: HcrAgentPipeConnection) =
    ## Named-pipe peer of the open Unix-socket session handshake. Keeping the
    ## connection open after this call lets a Windows target accept the second
    ## and later live edits without restarting the process.
    discard client.receiveAgentMessage(connection)
    client.sendCoordinatorMessage(
      connection, client.coordinatorHelloAckMessage())

  proc requestPatchOnOpenSession*(client: var HcrCoordinatorClient;
                                  connection: HcrAgentPipeConnection;
                                  request: HcrPatchRequest):
                                  HcrCoordinatorDelivery =
    ## Publish one patch on an already-negotiated Windows named-pipe session.
    ## Clear the prior verdict for the same reason as the socket overload: a
    ## refusal of edit N must never inherit edit N-1's applied result.
    client.patchApplied = none(HcrPatchApplied)
    client.patchFailed = none(HcrPatchFailed)
    client.sendCoordinatorMessage(
      connection, client.coordinatorPatchRequestMessage(request))
    while client.session.state == hssPatchRequested:
      discard client.receiveAgentMessage(connection)
    client.delivery()

  proc deliverPatchRequest*(client: var HcrCoordinatorClient;
                            connection: HcrAgentPipeConnection;
                            request: HcrPatchRequest):
                            HcrCoordinatorDelivery =
    client.completeHandshake(connection)
    client.requestPatchOnOpenSession(connection, request)
