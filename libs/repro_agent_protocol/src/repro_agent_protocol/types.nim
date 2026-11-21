## Domain types of the ReproOS Agent Integration Protocol.
##
## Spec: reprobuild-pm `spec/ReproOS-Agent-Integration-Protocol.md`.
##
## Every vocabulary here is closed. The string values are the wire
## spellings and are normative: a value outside an enum is a refusal
## (I-AGT-9), never a default.

import std/[algorithm, strutils]

import repro_remix/types as remixTypes

export remixTypes.Digest32

const
  ProtocolVersion* = 1'u64
    ## The `protocol` field of `Hello`. A peer announcing another value is
    ## refused; minor evolution happens per family, not here.

  MaxOperationsPerPlan* = 64
  MaxGrantsPerSession* = 64
  MaxSessionsPerUser* = 16
  MaxSourceWriteBytes* = 1 shl 20
  MaxPathBytes* = 4096
  MaxPathComponentBytes* = 255
  MaxIntentTextBytes* = 16 * 1024
  MaxScopeBytes* = 4096
  MaxFrameBytes* = 16 shl 20
  DefaultApprovalLifetimeSeconds* = 600'i64
  DefaultProvider* = "agent-harbor"
    ## The provider ReproOS curator policy selects by default (M7).

type
  AgentRefusalReason* = enum
    ## The named refusal codes of the spec. Each is the reason recorded in
    ## the audit log and returned to the peer.
    arMalformed = "malformed"
    arBoundsExceeded = "bounds-exceeded"
    arUnsupportedProtocol = "unsupported-protocol"
    arUnsupportedFamily = "unsupported-family"
    arWrongChannel = "wrong-channel"
    arNotAttached = "not-attached"
    arSessionUnknown = "session-unknown"
    arSessionSecretMismatch = "session-secret-mismatch"
    arSessionNotLive = "session-not-live"
    arTooManySessions = "too-many-sessions"
    arUnknownCapability = "unknown-capability"
    arBadScope = "bad-scope"
    arApprovalOnlyGrant = "approval-only-grant"
    arIntentNotInSession = "intent-not-in-session"
    arPathEscape = "path-escape"
    arCapabilityNotDeclared = "capability-not-declared"
    arCapabilityNotHeld = "capability-not-held"
    arImmutableTarget = "immutable-target"
    arUnknownTarget = "unknown-target"
    arPlanUnknown = "plan-unknown"
    arApprovalRequired = "approval-required"
    arApprovalUnknown = "approval-unknown"
    arApprovalWrongSession = "approval-wrong-session"
    arApprovalPlanMismatch = "approval-plan-mismatch"
    arApprovalIntentMismatch = "approval-intent-mismatch"
    arApprovalExpired = "approval-expired"
    arApprovalConsumed = "approval-consumed"
    arApprovalStaleEpoch = "approval-stale-epoch"
    arApprovalStaleBase = "approval-stale-base"
    arOperationFailed = "operation-failed"
    arCancelled = "cancelled"
    arTooLate = "too-late"
    arAuditCorrupt = "audit-corrupt"
    arEvidenceUnknown = "evidence-unknown"
    arProviderNotAdmitted = "provider-not-admitted"
    arBusy = "busy"
      ## Another execution is in progress on this host; retry after it.

  AgentRefusal* = object of CatchableError
    ## Raised for every refusal. `reason` is the machine-readable code;
    ## the message is human detail and is never parsed.
    reason*: AgentRefusalReason

  AgentChannel* = enum
    ## The two sockets of §"Encoding and transport". The provider channel
    ## can never carry consent (I-AGT-3).
    chProvider = "provider"
    chConsent = "consent"

  Family* = enum
    ## §"Operation families". `build` is the family of `build.run`.
    fInvocation = "invocation"
    fIntent = "intent"
    fOwnership = "ownership"
    fCheckout = "checkout"
    fSource = "source"
    fBuild = "build"
    fPlan = "plan"
    fTest = "test"
    fPreview = "preview"
    fApproval = "approval"
    fGeneration = "generation"
    fRemix = "remix"

  CapabilityKind* = enum
    ## §"Capabilities", the closed v1 vocabulary.
    ckContextActiveApp = "context.active-app"
    ckContextPackage = "context.package"
    ckContextFile = "context.file"
    ckContextSelection = "context.selection"
    ckContextScreenshot = "context.screenshot"
    ckWorkspaceCreate = "workspace.create"
    ckSourceRead = "source.read"
    ckSourceWrite = "source.write"
    ckBuildRun = "build.run"
    ckTestRun = "test.run"
    ckDebugAttach = "debug.attach"
    ckPreviewRun = "preview.run"
    ckDesktopAutomate = "desktop.automate"
    ckNetworkEgress = "network.egress"
    ckCredentialsUse = "credentials.use"
    ckSystemGeneration = "system.generation"
    ckRemixPublish = "remix.publish"

  Grant* = object
    ## One `(kind, scope)` capability. `scope` is empty for kinds without
    ## a scope.
    kind*: CapabilityKind
    scope*: string

  OperationKind* = enum
    ## The executable operations a plan may contain, by family.
    okOwnershipResolve = "ownership.resolve"
    okCheckoutCreate = "checkout.create"
    okCheckoutReapply = "checkout.reapply"
    okSourceRead = "source.read"
    okSourceWrite = "source.write"
    okSourceList = "source.list"
    okSourceDiff = "source.diff"
    okBuildRun = "build.run"
    okTestRun = "test.run"
    okPreviewStart = "preview.start"
    okPreviewStop = "preview.stop"
    okGenerationStage = "generation.stage"
    okGenerationActivate = "generation.activate"
    okGenerationRollback = "generation.rollback"
    okRemixCapture = "remix.capture"
    okRemixExport = "remix.export"
    okRemixSubmit = "remix.submit"
    okRemixCompose = "remix.compose"

  OpArg* = object
    ## A named operation argument. Values are bytes so a source write
    ## carries its content exactly; text arguments are UTF-8.
    name*: string
    value*: string

  Operation* = object
    kind*: OperationKind
    target*: string
      ## A package name, a workspace id, a generation id or `active-app`,
      ## as the kind requires.
    args*: seq[OpArg]
      ## Sorted by name, names unique (checked by `canonicalize`).

  Intent* = object
    ## §"Intent". Created only by the consent surface.
    sessionId*: string
    text*: string
    contextItems*: seq[Grant]
    capturedAt*: int64

  Plan* = object
    ## §"Plan". `PlanId` is the identity of its canonical bytes.
    sessionId*: string
    intentId*: Digest32
    baseGeneration*: string
    operations*: seq[Operation]
    declaredCapabilities*: seq[Grant]
    evidence*: seq[Digest32]

  SessionState* = enum
    ssRequested = "requested"
    ssActive = "active"
    ssSuspended = "suspended"
    ssClosed = "closed"
    ssRevoked = "revoked"

  OpStatus* = enum
    osCompleted = "completed"
    osFailed = "failed"
    osNotRun = "not-run"

  OpResult* = object
    status*: OpStatus
    detail*: string
      ## Failure reason, or a short result for the provider (for example
      ## the id of a workspace a checkout created).
    output*: string
      ## Result bytes (file contents for `source.read`).
    resultId*: Digest32
      ## Set by the host: the identity of this result, which a later plan
      ## cites as evidence (§"Evidence").

proc refuse*(reason: AgentRefusalReason; detail: string) {.noreturn.} =
  ## Raise the refusal for `reason`. Every refusal goes through here so a
  ## caller can rely on `AgentRefusal.reason` being set.
  var e = newException(AgentRefusal, $reason & ": " & detail)
  e.reason = reason
  raise e

proc parseEnumStrict*[T: enum](s: string; reason: AgentRefusalReason): T =
  ## Parse a wire spelling, refusing (not defaulting) an unknown value.
  for v in T:
    if $v == s:
      return v
  refuse(reason, "unknown value " & s.escape)

proc `<`*(a, b: Grant): bool =
  if a.kind != b.kind: ord(a.kind) < ord(b.kind) else: a.scope < b.scope

proc `$`*(g: Grant): string =
  if g.scope.len == 0: $g.kind else: $g.kind & ":" & g.scope

proc arg*(op: Operation; name: string): string =
  ## The value of argument `name`, or "" when absent.
  for a in op.args:
    if a.name == name:
      return a.value
  ""

proc hasArg*(op: Operation; name: string): bool =
  for a in op.args:
    if a.name == name:
      return true
  false

proc sortedUnique*(gs: seq[Grant]): seq[Grant] =
  result = gs
  result.sort()
  var i = 1
  while i < result.len:
    if result[i] == result[i - 1]:
      result.delete(i)
    else:
      inc i
