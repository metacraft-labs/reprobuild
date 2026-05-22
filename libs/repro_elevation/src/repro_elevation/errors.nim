## Typed exception hierarchy for the M81 privileged-operation broker.
##
## Mirrors the M68 `EHomeResource` hierarchy: each error carries
## enough structured context (operation address, kind, observed /
## recorded digests, Win32 status) for the parent to render a useful
## diagnostic and for the M81 gate to assert against named fields.
##
## See Elevation-And-Privileged-Operations.md "Failure And Partial
## Apply" and "Security Properties" for the surface this hierarchy
## implements.

type
  EElevation* = object of CatchableError
    ## Root of the elevation / privileged-broker exception hierarchy.

  EElevationRequired* = object of EElevation
    ## A privileged operation could not be applied because `repro`
    ## is not elevated and elevation was declined (`--no-elevate`,
    ## a denied OS prompt, or a launch failure). This is NOT a hard
    ## error in the apply pipeline — the operation is reported
    ## skipped and the apply exits partial-success. Raised only when
    ## a caller explicitly demands the privileged work be done.
    operationAddress*: string
    operationKind*: string

  EBrokerLaunch* = object of EElevation
    ## The one-shot broker process could not be launched
    ## (`ShellExecuteEx`+`runas` failed for a reason OTHER than the
    ## user declining the UAC prompt — e.g. the binary is missing).
    ## A user-declined prompt is `EElevationDeclined`, not this.
    reason*: string

  EElevationDeclined* = object of EElevation
    ## The user declined the OS elevation prompt. Per the spec this
    ## is equivalent to `--no-elevate`: a clean partial result, not a
    ## crash. The apply driver catches it and reports every
    ## privileged operation skipped.

  EBrokerLost* = object of EElevation
    ## The broker process crashed or the IPC channel dropped
    ## mid-stream. Every not-yet-acknowledged privileged operation is
    ## treated as not applied.
    reason*: string

  EChannelAuth* = object of EElevation
    ## The IPC handshake failed authentication — a connecting peer
    ## presented the wrong nonce, or the peer SID / uid did not match
    ## the launching user. The broker serves exactly one parent;
    ## anything else is rejected and the channel closed.
    reason*: string

  EProtocol* = object of EElevation
    ## A framed `RBEB` message was malformed, carried an unknown
    ## magic / schema version / message type, or failed its BLAKE3
    ## checksum. Also raised when the broker receives a frame that is
    ## not a recognized typed `PrivilegedOperation` — the broker
    ## never executes anything outside the closed operation set.
    reason*: string

  EBrokerDrift* = object of EElevation
    ## The broker re-observed a privileged operation's real-world
    ## state before mutating and found it had drifted between the
    ## non-elevated plan and the elevated execution. Fail-closed: the
    ## broker refuses to blindly overwrite, exactly as a normal apply
    ## raises `EDrift`.
    operationAddress*: string
    operationKind*: string
    expectedDigestHex*: string
    observedDigestHex*: string

  ENotImplementedPlatform* = object of EElevation
    ## A platform-specific elevation primitive (broker launch, IPC
    ## channel) was invoked on a platform whose implementation is a
    ## skeleton — the M68 Phase A/B precedent. The cross-platform
    ## parts (partition, RBEB codec, the typed operation set, the
    ## closed-set validation) never raise this.
    currentPlatform*: string
    operation*: string

const
  CurrentPlatformTag* =
    when defined(windows): "windows"
    elif defined(macosx): "macosx"
    elif defined(linux): "linux"
    else: "unknown"

proc raiseElevationRequired*(address, kind: string) {.noreturn.} =
  var e = newException(EElevationRequired,
    "repro: privileged operation '" & address & "' (" & kind &
    ") requires elevation and elevation was not granted.")
  e.operationAddress = address
  e.operationKind = kind
  raise e

proc raiseBrokerLaunch*(reason: string) {.noreturn.} =
  var e = newException(EBrokerLaunch,
    "repro: could not launch the privileged broker: " & reason)
  e.reason = reason
  raise e

proc raiseElevationDeclined*() {.noreturn.} =
  raise newException(EElevationDeclined,
    "repro: the elevation prompt was declined; privileged operations " &
    "were skipped (equivalent to --no-elevate).")

proc raiseBrokerLost*(reason: string) {.noreturn.} =
  var e = newException(EBrokerLost,
    "repro: the privileged broker was lost mid-apply: " & reason)
  e.reason = reason
  raise e

proc raiseChannelAuth*(reason: string) {.noreturn.} =
  var e = newException(EChannelAuth,
    "repro: privileged-broker IPC authentication failed: " & reason)
  e.reason = reason
  raise e

proc raiseProtocol*(reason: string) {.noreturn.} =
  var e = newException(EProtocol,
    "repro: privileged-broker protocol error: " & reason)
  e.reason = reason
  raise e

proc raiseBrokerDrift*(address, kind, expectedHex, observedHex: string)
    {.noreturn.} =
  var e = newException(EBrokerDrift,
    "repro: privileged operation '" & address & "' (" & kind &
    ") drifted between plan and broker execution: expected " &
    (if expectedHex.len >= 12: expectedHex[0 ..< 12] else: expectedHex) &
    " but observed " &
    (if observedHex.len >= 12: observedHex[0 ..< 12] else: observedHex) &
    ". The broker fails closed rather than overwriting drifted state.")
  e.operationAddress = address
  e.operationKind = kind
  e.expectedDigestHex = expectedHex
  e.observedDigestHex = observedHex
  raise e

proc raiseNotImplementedPlatform*(operation: string) {.noreturn.} =
  var e = newException(ENotImplementedPlatform,
    "repro: elevation primitive '" & operation &
    "' is not implemented on platform '" & CurrentPlatformTag & "'.")
  e.currentPlatform = CurrentPlatformTag
  e.operation = operation
  raise e
