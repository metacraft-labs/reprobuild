import repro_hcr_agent/protocol

type
  HcrMessageDirection* = enum
    hmdCoordinatorToAgent
    hmdAgentToCoordinator

  HcrAgentSessionState* = enum
    hssNew
    hssAgentHelloReceived
    hssNegotiated
    hssPatchRequested
    hssPatchFinished
    hssFailed

  HcrAgentSession* = object
    supportProfile*: string
    state*: HcrAgentSessionState
    agentCapabilities*: seq[string]
    activePatchId*: string
    lifecycleEvents*: seq[string]

proc initHcrAgentSession*(supportProfile: string): HcrAgentSession =
  HcrAgentSession(
    supportProfile: supportProfile,
    state: hssNew)

proc containsValue(values: openArray[string]; value: string): bool =
  for item in values:
    if item == value:
      return true

proc requireState(session: HcrAgentSession; expected: HcrAgentSessionState;
                  action: string) =
  if session.state != expected:
    raise newException(ValueError,
      action & " is invalid in HCR session state " & $session.state)

proc requireDirection(actual, expected: HcrMessageDirection; action: string) =
  if actual != expected:
    raise newException(ValueError,
      action & " has wrong HCR message direction: " & $actual)

proc requirePatchId(session: HcrAgentSession; patchId: string; action: string) =
  if patchId.len == 0:
    raise newException(ValueError, action & " has empty patch id")
  if session.activePatchId.len > 0 and patchId != session.activePatchId:
    raise newException(ValueError,
      action & " patch id mismatch: expected " & session.activePatchId &
        ", got " & patchId)

proc observeHello(session: var HcrAgentSession; direction: HcrMessageDirection;
                  message: HcrAgentMessage) =
  direction.requireDirection(hmdAgentToCoordinator, "agent hello")
  session.requireState(hssNew, "agent hello")
  if message.hello.supportProfile != session.supportProfile:
    raise newException(ValueError,
      "agent support profile mismatch: expected " & session.supportProfile &
        ", got " & message.hello.supportProfile)
  if not message.hello.capabilities.containsValue("hcr-agent-protocol"):
    raise newException(ValueError, "agent did not advertise hcr-agent-protocol")
  session.agentCapabilities = message.hello.capabilities
  session.state = hssAgentHelloReceived

proc observeHelloAck(session: var HcrAgentSession;
                     direction: HcrMessageDirection) =
  direction.requireDirection(hmdCoordinatorToAgent, "coordinator helloAck")
  session.requireState(hssAgentHelloReceived, "coordinator helloAck")
  session.state = hssNegotiated

proc observePatchRequest(session: var HcrAgentSession;
                         direction: HcrMessageDirection;
                         request: HcrPatchRequest) =
  direction.requireDirection(hmdCoordinatorToAgent, "patch request")
  session.requireState(hssNegotiated, "patch request")
  if request.supportProfile != session.supportProfile:
    raise newException(ValueError,
      "patch request support profile mismatch: expected " &
        session.supportProfile & ", got " & request.supportProfile)
  if request.mode != hpmDirect:
    raise newException(ValueError, "only direct HCR patch requests are accepted")
  if request.changedFunctions.len == 0:
    raise newException(ValueError, "patch request has no changed functions")
  session.requirePatchId(request.patchId, "patch request")
  session.activePatchId = request.patchId
  session.lifecycleEvents.setLen(0)
  session.state = hssPatchRequested

proc observeLifecycleEvent(session: var HcrAgentSession;
                           direction: HcrMessageDirection;
                           event: HcrLifecycleEvent) =
  direction.requireDirection(hmdAgentToCoordinator, "lifecycle event")
  session.requireState(hssPatchRequested, "lifecycle event")
  session.requirePatchId(event.patchId, "lifecycle event")
  session.lifecycleEvents.add event.event

proc observePatchApplied(session: var HcrAgentSession;
                         direction: HcrMessageDirection;
                         applied: HcrPatchApplied) =
  direction.requireDirection(hmdAgentToCoordinator, "patch applied")
  session.requireState(hssPatchRequested, "patch applied")
  session.requirePatchId(applied.patchId, "patch applied")
  if applied.changedFunctions.len == 0:
    raise newException(ValueError, "patch applied has no changed functions")
  if applied.sharedLibraryPositivePath:
    raise newException(ValueError,
      "direct profile cannot report a shared-library positive path")
  if not applied.oldCodeRetained:
    raise newException(ValueError,
      "direct profile must retain old code for debugger/replay identity")
  if not session.lifecycleEvents.containsValue("hcr/patchApplied"):
    raise newException(ValueError,
      "patch applied response arrived before hcr/patchApplied lifecycle event")
  session.state = hssPatchFinished

proc observePatchFailed(session: var HcrAgentSession;
                        direction: HcrMessageDirection;
                        failure: HcrPatchFailed) =
  direction.requireDirection(hmdAgentToCoordinator, "patch failed")
  session.requireState(hssPatchRequested, "patch failed")
  session.requirePatchId(failure.patchId, "patch failed")
  if failure.stage.len == 0 or failure.message.len == 0:
    raise newException(ValueError, "patch failed must include stage and message")
  session.state = hssFailed

proc observeAgentProtocolMessage*(session: var HcrAgentSession;
                                  direction: HcrMessageDirection;
                                  message: HcrAgentMessage) =
  case message.kind
  of hmkHello:
    session.observeHello(direction, message)
  of hmkHelloAck:
    session.observeHelloAck(direction)
  of hmkPatchRequest:
    session.observePatchRequest(direction, message.patchRequest)
  of hmkLifecycleEvent:
    session.observeLifecycleEvent(direction, message.lifecycleEvent)
  of hmkPatchApplied:
    session.observePatchApplied(direction, message.patchApplied)
  of hmkPatchFailed:
    session.observePatchFailed(direction, message.patchFailed)
