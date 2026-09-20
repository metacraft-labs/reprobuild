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
    seenPatchIds*: seq[string]
      ## Every `patchId` this session has requested. The direct-patch twin of
      ## `seenReloadIds`, and it exists for the same reason: a session that
      ## serves more than one patch must be able to tell them apart, and a
      ## second request reusing the first's id makes every downstream
      ## artifact that keys on it — the agent's own report, the recorded
      ## `evCodePatch`, a gate reading either — ambiguous in a way that looks
      ## exactly like a correct second patch.
    patchesRequested*: int
      ## How many patch requests this session has sent. A gate that wants to
      ## show a SECOND patch was served must be able to read the count rather
      ## than infer it from the last verdict, which is identical after one
      ## patch and after five.

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
  # HLX-M9 — CAPABILITY-TIME REFUSAL.
  #
  # The agent probes the host's `mprotect` RW->RX round trip at start-up and,
  # on a host that cannot complete it, has refused since HLX-M4 — but in
  # `txn_prepare`, at the FIRST RELOAD. That is late and it is unclear: the
  # developer edits a file, waits for a rebuild, and gets a refusal named
  # `unsupported-host` that says nothing about which policy blocked it.
  #
  # Refusing HERE is what lets a coordinator stop offering patches at all,
  # and the agent's diagnostic names the blocking policy rather than its
  # symptom — it reads `PR_GET_MDWE` instead of guessing.
  #
  # ABSENT is UNKNOWN. An agent predating this change does not answer, and so
  # reaches the same behaviour it always had; only an explicit `false` refuses.
  if message.hello.patchingSupportedReported and
      not message.hello.patchingSupported:
    let reason =
      if message.hello.unsupportedReason.len > 0:
        message.hello.unsupportedReason
      else:
        "the agent reported the host unsupported and named no reason"
    raise newException(ValueError,
      "agent reports this host cannot be patched: " & reason)
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
  # A SESSION SERVES MORE THAN ONE PATCH.
  #
  # This used to require `hssNegotiated` and nothing else, which made a second
  # direct patch on one connection impossible from the coordinator side —
  # `patch request is invalid in HCR session state hssPatchFinished`. Both of
  # the other two layers had already lifted that limit and this one had not:
  # GDH-M4 replaced the agent's one-frame session with a loop that dispatches
  # frames until the peer closes, and the Linux provider's per-site
  # bookkeeping (`repro_hcr_linux_x86_64.h`, design §4.5) exists precisely so
  # a window this provider already published into is an admissible pre-state,
  # bumping `site->generation` instead of refusing. So the observable effect of
  # this line was that the only component with no re-patch machinery of its own
  # vetoed the two that had it.
  #
  # `hssFailed` is in the set deliberately. A refused patch is an ANSWER, not
  # the end of a conversation — the agent does not close the socket on one —
  # and an edit-as-you-type loop in which one rejected value ends the session
  # would be a worse tool than one that never accepted the rejected value at
  # all. Typing `rise_speeed`, being told which knobs exist, and fixing it must
  # leave the flame still patchable.
  if session.state notin {hssNegotiated, hssPatchFinished, hssFailed}:
    raise newException(ValueError,
      "patch request is invalid in HCR session state " & $session.state)
  if request.supportProfile != session.supportProfile:
    raise newException(ValueError,
      "patch request support profile mismatch: expected " &
        session.supportProfile & ", got " & request.supportProfile)
  if request.mode != hpmDirect:
    raise newException(ValueError, "only direct HCR patch requests are accepted")
  if request.changedFunctions.len == 0:
    raise newException(ValueError, "patch request has no changed functions")
  if request.patchId.len == 0:
    raise newException(ValueError, "patch request has empty patch id")
  # Unique per session, for `seenReloadIds`' reason one protocol over. Two
  # patches sharing an id are indistinguishable in the agent's report and in
  # the recorded code-version boundary, and "indistinguishable" is how a
  # second patch that never landed reads as one that did.
  if session.seenPatchIds.containsValue(request.patchId):
    raise newException(ValueError,
      "patch request reuses patchId " & request.patchId &
        "; a session that serves more than one patch must be able to tell " &
        "them apart")
  session.seenPatchIds.add request.patchId
  session.patchesRequested.inc
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
  if applied.sharedLibraryPositivePath and
      session.supportProfile != HcrWindowsX86_64DirectSupportProfile:
    raise newException(ValueError,
      "this direct profile cannot report a shared-library positive path")
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
