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
    hssSourceReloadRequested

  HcrAgentSession* = object
    supportProfile*: string
    state*: HcrAgentSessionState
    agentCapabilities*: seq[string]
    activePatchId*: string
    lifecycleEvents*: seq[string]
    activeReloadId*: string
      ## The `reloadId` of the outstanding `sourceChanged`, if any.
    stateBeforeSourceReload*: HcrAgentSessionState
    sourceReloadResults*: seq[HcrSourceReloadResult]
    seenReloadIds*: seq[string]
      ## Every `reloadId` this session has sent. GDH design §4.3 requires the
      ## id to be unique per notification and monotonic per session, and a
      ## SECOND reload that reuses the first one's id is exactly the shape
      ## GDH-G8 exists to catch — so the reuse is refused here rather than
      ## left for a gate to remember to check.

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

proc verifyBundleSupportProfile*(bundleProfile, hostProfile: string) =
  ## HLX-M7 / design §10.3, protocol §7.3 — the replay-side twin of the live
  ## negotiation check below.
  ##
  ## §7.3 replays a patched recording by loading the stored patch bundle out of
  ## the CTFS container and applying it to the replay process. The bundle's wire
  ## format carries no architecture or ABI tag, so on a foreign host it would be
  ## applied BLINDLY — a `linux-x86_64` `E9 rel32` published into an arm64
  ## process is not a wrong patch, it is arbitrary code. `observeHello` already
  ## refuses a profile mismatch during a LIVE session; replay reads its profile
  ## out of the recorded `CodePatchEvent` instead of off a socket, so the check
  ## has to be callable without one. This is that check.
  ##
  ## An EMPTY recorded profile is refused rather than waved through. A trace
  ## that does not say what it was recorded on cannot be shown to match this
  ## host, and "cannot be shown to match" must not be spelled "matches".
  if bundleProfile.len == 0:
    raise newException(ValueError,
      "patch bundle carries no supportProfile: it cannot be shown to target " &
        "this host (" & hostProfile & "), and a bundle applied on an " &
        "unverified host is arbitrary code, not a patch")
  if hostProfile.len == 0:
    raise newException(ValueError,
      "this host advertises no direct-patch support profile, so the bundle's " &
        bundleProfile & " cannot be honoured here")
  if bundleProfile != hostProfile:
    raise newException(ValueError,
      "patch bundle support profile mismatch: the recording was patched on " &
        bundleProfile & " and this replay host is " & hostProfile)

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

proc hostAdvertisedSourceReload*(session: HcrAgentSession): bool =
  ## Whether the host's `hello` listed `source-reload` (design §4.4). A gate
  ## that asserts a refusal must be able to state that the capability was
  ## absent from a handshake that COMPLETED — a host that never connected also
  ## sends no reply, and the two must not be conflated.
  session.agentCapabilities.containsValue(HcrSourceReloadCapability)

proc observeSourceChanged(session: var HcrAgentSession;
                          direction: HcrMessageDirection;
                          changed: HcrSourceChanged) =
  direction.requireDirection(hmdCoordinatorToAgent, "sourceChanged")
  if session.state notin {hssNegotiated, hssPatchFinished}:
    raise newException(ValueError,
      "sourceChanged is invalid in HCR session state " & $session.state)
  if session.seenReloadIds.containsValue(changed.reloadId):
    raise newException(ValueError,
      "sourceChanged reuses reloadId " & changed.reloadId &
        "; §4.3 requires it to be unique per notification")
  session.seenReloadIds.add changed.reloadId
  session.activeReloadId = changed.reloadId
  session.stateBeforeSourceReload = session.state
  session.state = hssSourceReloadRequested

proc observeSourceReloadResult(session: var HcrAgentSession;
                               direction: HcrMessageDirection;
                               reloadResult: HcrSourceReloadResult) =
  direction.requireDirection(hmdAgentToCoordinator, "sourceReloadResult")
  session.requireState(hssSourceReloadRequested, "sourceReloadResult")
  if reloadResult.reloadId != session.activeReloadId:
    raise newException(ValueError,
      "sourceReloadResult reloadId mismatch: expected " &
        session.activeReloadId & ", got " & reloadResult.reloadId)
  session.sourceReloadResults.add reloadResult
  session.activeReloadId = ""
  session.state = session.stateBeforeSourceReload

proc observeAgentProtocolMessage*(session: var HcrAgentSession;
                                  direction: HcrMessageDirection;
                                  message: HcrAgentMessage) =
  case message.kind
  of hmkSourceChanged:
    session.observeSourceChanged(direction, message.sourceChanged)
  of hmkSourceReloadResult:
    session.observeSourceReloadResult(direction, message.sourceReloadResult)
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
