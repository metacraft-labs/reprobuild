## The consent surface's view of a session, derived in one place
## (ReproOS-Agent-Harbor-Integration M2 deliverables 2 and 4, headless).
##
## Whatever draws the Agent Harbor pane — the UI stack is open decision
## AGT-OD-3 / Q2 — renders a `SurfaceView` and never recomputes one, so the
## pane cannot show a state the host is not in. The view names one of the
## eight states M2 requires fixtures for, the provider and how it runs, the
## session's grants, the plans waiting for the user, what is running, and
## the actions the user can take right now.

import std/[algorithm, strutils, tables]

import ./[types, canonical, host]

type
  SurfaceState* = enum
    svIdle = "idle"            ## nothing asked, nothing pending
    svConsent = "consent"      ## a plan waits for the user's approval
    svPlanning = "planning"    ## the user asked; the agent has not planned
    svRunning = "running"      ## an operation is executing
    svPreview = "preview"      ## the last execution ended in a preview
    svConflict = "conflict"    ## a reapply or composition met a conflict
    svError = "error"          ## the last execution failed
    svCompletion = "completion"## the last execution completed

  PendingApproval* = object
    planId*: string
    operations*: seq[string]   ## operation kinds, in plan order
    capabilities*: seq[string] ## what approving confers

  ProviderProfile* = object
    ## How the provider runs, as the activity configured it (M1).
    model*: string
    inference*: string         ## "local" or "remote"

  SurfaceView* = object
    state*: SurfaceState
    sessionId*: string
    provider*: string
    profile*: ProviderProfile
    sessionState*: SessionState
    grants*: seq[string]
    pending*: seq[PendingApproval]
    running*: string
    lastResults*: seq[tuple[kind: string; status: string; detail: string]]
    canCancel*: bool           ## something is running
    canRevoke*: bool           ## the session can still be revoked

proc isConflict(r: EvidenceRecord): bool =
  r.output.startsWith("reapply=conflict") or
    (r.kind == okRemixCompose and r.status == osFailed and
     ("patch" in r.detail or "conflict" in r.detail or "blocked" in r.detail))

proc surfaceViewOf*(h: Host; sessionId: string;
                    profile = ProviderProfile()): SurfaceView =
  ## The view of `sessionId`. Precedence, highest first: running, consent,
  ## conflict, error, preview, completion, planning, idle — what needs the
  ## user most is what the pane shows.
  let s = h.session(sessionId)
  result = SurfaceView(sessionId: sessionId, provider: s.provider,
    profile: profile, sessionState: s.state, running: s.running,
    canCancel: s.running.len > 0,
    canRevoke: s.state in {ssRequested, ssActive, ssSuspended})
  for g in s.grants:
    result.grants.add $g
  for pid, plan in h.pendingPlansNeedingApproval(sessionId):
    var pa = PendingApproval(planId: pid)
    for op in plan.operations:
      pa.operations.add $op.kind
    for g in plan.declaredCapabilities:
      pa.capabilities.add $g
    result.pending.add pa
  result.pending.sort(proc (a, b: PendingApproval): int = cmp(a.planId, b.planId))
  for r in s.lastResults:
    result.lastResults.add ($r.kind, $r.status, r.detail)
  result.state =
    if s.running.len > 0: svRunning
    elif result.pending.len > 0: svConsent
    elif s.lastResults.len > 0 and s.lastResults[^1].isConflict: svConflict
    elif s.lastResults.len > 0 and s.lastResults[^1].status == osFailed: svError
    elif s.lastIntent.len > 0 and not s.plannedSinceIntent: svPlanning
    elif s.lastResults.len > 0 and s.lastResults[^1].kind == okPreviewStart:
      svPreview
    elif s.lastResults.len > 0: svCompletion
    else: svIdle
