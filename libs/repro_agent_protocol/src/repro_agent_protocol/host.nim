## The integration host (spec §"Parties", §"Authority", §"Lifecycle").
##
## The host is the protocol's trusted computing base. It holds sessions,
## grants, intents, plans, approvals and the audit log, and it executes
## every operation itself: source operations directly against the session
## workspace (through `paths`), everything else through a `Backend`, which
## is where Reprobuild, the generation system and the Remix libraries are
## plugged in.
##
## Every entry point takes the `Connection` the request arrived on. The
## channel of the connection, not anything the request says, decides
## whether it may carry consent (I-AGT-3), and the session a provider
## connection is attached to, not a session id in the request, decides
## whose authority is used.

import std/[os, sets, strutils, tables, times]

import nimcrypto/[hmac, sha2, sysrand]

import ./[types, capabilities, canonical, audit, paths]

type
  Clock* = proc (): int64 {.gcsafe, raises: [].}
    ## Seconds since the Unix epoch. Injected so tests can move time.

  Workspace* = object
    id*: string
    sessionId*: string
    package*: string
    root*: string ## absolute, symlink-free

  Backend* = ref object of RootObj
    ## The operations the host does not perform itself. Each method returns
    ## an `OpResult`; it raises only for programming errors. The base
    ## methods fail every operation, so a backend implements exactly the
    ## families it supports.

  Session* = ref object
    id*: string
    provider*: string
    secretDigest: Digest32
    state*: SessionState
    grants*: seq[Grant]
    epoch*: uint64
    intents: HashSet[string] ## hex intent ids
    evidence: Table[string, EvidenceRecord]
      ## Results this session's executions produced, by hex result id. A
      ## plan may cite only these as evidence.
    expiresAt*: int64

  EvidenceRecord* = object
    ## One executed operation's result, as the consent surface shows it.
    planId*: Digest32
    index*: int
    kind*: OperationKind
    status*: OpStatus
    detail*: string
    output*: string

  PendingPlan = object
    plan: Plan
    id: Digest32
    approvalRequired: seq[int]

  ApprovalRecord = object
    approvalId: string
    sessionId: string
    intentId: Digest32
    planId: Digest32
    operations: seq[int]
    epoch: uint64
    issuedAt, expiresAt: int64
    mac: array[32, byte]
    consumed: bool

  Host* = ref object
    clock: Clock
    backend*: Backend
    audit*: AuditLog
    bootKey: array[32, byte]
      ## Approval MAC key. Fresh per host start and never persisted, so a
      ## restart voids every approval (§"Crash recovery").
    sessions: Table[string, Session]
    intentsById: Table[string, Intent]
    plans: Table[string, PendingPlan]
    approvals: Table[string, ApprovalRecord]
    workspaces*: Table[string, Workspace]
    workspacesRoot*: string
    counter: int

  Connection* = ref object
    ## One accepted socket connection. `channel` is fixed by which socket
    ## accepted it; `sessionId` is set by a successful `attach`.
    channel*: AgentChannel
    families*: set[Family]
    helloDone*: bool
    sessionId*: string

  PlanReceipt* = object
    planId*: Digest32
    approvalRequired*: seq[int]

  ExecutionReport* = object
    planId*: Digest32
    results*: seq[OpResult]

# ---------------------------------------------------------------------
# Backend defaults.

method resolveOwnership*(b: Backend; target: string): OpResult {.base.} =
  OpResult(status: osFailed, detail: "ownership is not supported")
method createCheckout*(b: Backend; package, root: string): OpResult {.base.} =
  OpResult(status: osFailed, detail: "checkout is not supported")
method runBuild*(b: Backend; ws: Workspace; op: Operation): OpResult {.base.} =
  OpResult(status: osFailed, detail: "build is not supported")
method runTest*(b: Backend; ws: Workspace; op: Operation): OpResult {.base.} =
  OpResult(status: osFailed, detail: "test is not supported")
method diff*(b: Backend; ws: Workspace): OpResult {.base.} =
  ## The workspace's change against what was checked out, as a unified
  ## diff in `output`. Only the backend knows the workspace's base.
  OpResult(status: osFailed, detail: "diff is not supported")
method preview*(b: Backend; ws: Workspace; op: Operation): OpResult {.base.} =
  OpResult(status: osFailed, detail: "preview is not supported")
method activeGeneration*(b: Backend): string {.base.} = ""
method generation*(b: Backend; ws: Workspace; op: Operation): OpResult {.base.} =
  ## Stage, activate or roll back. `ws.id` is empty for activate and
  ## rollback, whose target is a generation id.
  OpResult(status: osFailed, detail: "generations are not supported")
method remix*(b: Backend; ws: Workspace; op: Operation): OpResult {.base.} =
  OpResult(status: osFailed, detail: "remix is not supported")

# ---------------------------------------------------------------------
# Construction and helpers.

proc systemClock*(): int64 {.gcsafe, raises: [].} =
  try: getTime().toUnix() except CatchableError: 0

proc randomHex(n: int): string =
  var b = newSeq[byte](n)
  if randomBytes(b) != n:
    raise newException(OSError, "system random source failed")
  for x in b:
    result.add "0123456789abcdef"[int(x shr 4)]
    result.add "0123456789abcdef"[int(x and 0xf)]

proc newHost*(backend: Backend; workspacesRoot: string; auditPath = "";
              clock: Clock = systemClock): Host =
  ## A host with no sessions. `workspacesRoot` is created and resolved to
  ## its symlink-free absolute form, which `paths` requires.
  createDir(workspacesRoot)
  result = Host(clock: clock, backend: backend,
                audit: newAuditLog(auditPath),
                workspacesRoot: expandFilename(workspacesRoot))
  if randomBytes(result.bootKey) != result.bootKey.len:
    raise newException(OSError, "system random source failed")

proc newConnection*(channel: AgentChannel): Connection =
  Connection(channel: channel)

proc secretDigestOf(secret: string): Digest32 =
  id("reproos.agent.session-secret.v1", secret.toBytes)

proc ctEqual(a, b: openArray[byte]): bool =
  ## Constant-time comparison, so MAC and secret checks leak no prefix.
  if a.len != b.len:
    return false
  var acc = 0'u8
  for i in 0 ..< a.len:
    acc = acc or (a[i] xor b[i])
  acc == 0

proc record(h: Host; conn: Connection; family, kind, decision: string;
            reason = ""; plan = ""; intent = ""; approval = "";
            grant = ""; resultDigest = ""): uint64 =
  let sid = if conn.isNil: "" else: conn.sessionId
  let provider =
    if sid.len > 0 and h.sessions.hasKey(sid): h.sessions[sid].provider
    else: ""
  h.audit.append(AuditRecord(time: h.clock(), sessionId: sid,
    provider: provider, family: family, kind: kind, decision: decision,
    reason: reason, planId: plan, intentId: intent, approvalId: approval,
    grant: grant, resultDigest: resultDigest))

template audited(h: Host; conn: Connection; family, kind: string;
                 body: untyped): untyped =
  ## Run `body`; a refusal it raises is recorded before it propagates, so
  ## every refused request is in the audit log (I-AGT-6).
  try:
    body
  except AgentRefusal as e:
    discard h.record(conn, family, kind, "refused", reason = $e.reason)
    raise

proc requireChannel(conn: Connection; ch: AgentChannel; what: string) =
  if conn.channel != ch:
    refuse(arWrongChannel, what & " is only accepted on the " & $ch &
      " channel")

proc requireLive(h: Host; sid: string): Session =
  if not h.sessions.hasKey(sid):
    refuse(arSessionUnknown, "no session " & sid)
  result = h.sessions[sid]
  if result.state != ssActive:
    refuse(arSessionNotLive, "session " & sid & " is " & $result.state)
  if h.clock() >= result.expiresAt:
    result.state = ssClosed
    refuse(arSessionNotLive, "session " & sid & " expired")

proc attachedSession(h: Host; conn: Connection): Session =
  conn.requireChannel(chProvider, "a provider request")
  if conn.sessionId.len == 0:
    refuse(arNotAttached, "the connection is not attached to a session")
  h.requireLive(conn.sessionId)

proc holds(s: Session; g: Grant): bool = g in s.grants

proc bumpEpoch(h: Host; s: Session) =
  ## Any change to a session's authority voids its outstanding approvals
  ## (§"Revocation").
  inc s.epoch

# ---------------------------------------------------------------------
# Hello.

proc hello*(h: Host; conn: Connection; protocol: uint64;
            families: set[Family]): set[Family] =
  ## Negotiate: the served families are the intersection of what the peer
  ## announces and what this host implements (all of v1).
  h.audited(conn, "hello", "hello"):
    if protocol != ProtocolVersion:
      refuse(arUnsupportedProtocol, "protocol " & $protocol)
    conn.families = families
    conn.helloDone = true
    discard h.record(conn, "hello", "hello", "allowed")
    families

# ---------------------------------------------------------------------
# Consent channel.

proc createSession*(h: Host; conn: Connection; provider: string;
                    grants: seq[Grant];
                    lifetimeSeconds = 8 * 3600'i64): tuple[id, secret: string] =
  ## The user accepted a provider's grant request on the consent surface.
  ## Approval-only grants cannot be held (they are conferred per plan) and
  ## refuse the whole request.
  h.audited(conn, "session", "create"):
    conn.requireChannel(chConsent, "session creation")
    if grants.len > MaxGrantsPerSession:
      refuse(arBoundsExceeded, "too many grants")
    var live = 0
    for s in h.sessions.values:
      if s.state in {ssActive, ssSuspended}:
        inc live
    if live >= MaxSessionsPerUser:
      refuse(arTooManySessions, "at most " & $MaxSessionsPerUser)
    for g in grants:
      validateGrant(g)
      if isApprovalOnly(g):
        refuse(arApprovalOnlyGrant, $g & " is conferred per plan only")
    inc h.counter
    let sid = "s" & $h.counter & "-" & randomHex(8)
    let secret = randomHex(32)
    h.sessions[sid] = Session(id: sid, provider: provider,
      secretDigest: secretDigestOf(secret), state: ssActive,
      grants: sortedUnique(grants), expiresAt: h.clock() + lifetimeSeconds)
    let saved = conn.sessionId
    conn.sessionId = sid
    for g in sortedUnique(grants):
      discard h.record(conn, "session", "create", "grant", grant = $g)
    discard h.record(conn, "session", "create", "allowed")
    conn.sessionId = saved
    (sid, secret)

proc captureIntent*(h: Host; conn: Connection; sessionId, text: string;
                    contextItems: seq[Grant] = @[]): Intent =
  ## The consent surface captured the user's request. Context items must
  ## be grants the session holds: an intent cannot smuggle context.
  h.audited(conn, "intent", "capture"):
    conn.requireChannel(chConsent, "intent capture")
    if text.len > MaxIntentTextBytes:
      refuse(arBoundsExceeded, "intent text")
    let s = h.requireLive(sessionId)
    for g in contextItems:
      validateGrant(g)
      if not s.holds(g):
        refuse(arCapabilityNotHeld, "context item " & $g)
    let intent = Intent(sessionId: sessionId, text: text,
                        contextItems: sortedUnique(contextItems),
                        capturedAt: h.clock())
    let iid = intentId(intent).hex
    s.intents.incl iid
    h.intentsById[iid] = intent
    discard h.record(conn, "intent", "capture", "allowed", intent = iid)
    intent

proc showEvidence*(h: Host; conn: Connection; sessionId,
                   resultIdHex: string): EvidenceRecord =
  ## What the consent surface shows for one piece of a plan's evidence:
  ## the before/after preview, a test run, a diff, an ownership record.
  h.audited(conn, "evidence", "show"):
    conn.requireChannel(chConsent, "evidence display")
    if not h.sessions.hasKey(sessionId):
      refuse(arSessionUnknown, sessionId)
    let s = h.sessions[sessionId]
    if not s.evidence.hasKey(resultIdHex):
      refuse(arEvidenceUnknown, resultIdHex)
    s.evidence[resultIdHex]

proc captureFeedback*(h: Host; conn: Connection; sessionId,
                      planIdHex, text: string): Intent =
  ## The user's response to a previewed or rejected plan, captured as a
  ## new intent the provider refines against. Feedback never approves
  ## anything: it is an intent, and an intent executes nothing.
  h.audited(conn, "intent", "feedback"):
    let intent = h.captureIntent(conn, sessionId, text)
    let saved = conn.sessionId
    conn.sessionId = sessionId
    discard h.record(conn, "intent", "feedback", "feedback",
                     plan = planIdHex, intent = intentId(intent).hex)
    conn.sessionId = saved
    intent

proc revokeGrant*(h: Host; conn: Connection; sessionId: string; g: Grant) =
  h.audited(conn, "session", "revoke-grant"):
    conn.requireChannel(chConsent, "revocation")
    if not h.sessions.hasKey(sessionId):
      refuse(arSessionUnknown, sessionId)
    let s = h.sessions[sessionId]
    let i = s.grants.find(g)
    if i >= 0:
      s.grants.delete(i)
    h.bumpEpoch(s)
    discard h.record(conn, "session", "revoke-grant", "revoke", grant = $g)

proc revokeSession*(h: Host; conn: Connection; sessionId: string) =
  h.audited(conn, "session", "revoke"):
    conn.requireChannel(chConsent, "revocation")
    if not h.sessions.hasKey(sessionId):
      refuse(arSessionUnknown, sessionId)
    let s = h.sessions[sessionId]
    if s.state != ssClosed:
      s.state = ssRevoked
    h.bumpEpoch(s)
    discard h.record(conn, "session", "revoke", "revoke")

# ---------------------------------------------------------------------
# Plan checking.

proc packageOfTarget(h: Host; s: Session; op: Operation): string =
  ## For a workspace-targeting operation, the package of that workspace,
  ## refusing a workspace of another session (`immutable-target`) or one
  ## that does not exist (`unknown-target`).
  if not usesWorkspaceTarget(op.kind):
    return ""
  if not h.workspaces.hasKey(op.target):
    refuse(arUnknownTarget, "no workspace " & op.target)
  let ws = h.workspaces[op.target]
  if ws.sessionId != s.id:
    refuse(arImmutableTarget, "workspace " & op.target &
      " belongs to another session")
  ws.package

proc checkPlan(h: Host; conn: Connection; s: Session;
               plan: Plan): seq[int] =
  ## §"Plan" checks 1-6, in order; returns the indices of the operations
  ## that need an approval.
  if plan.sessionId != s.id:
    refuse(arIntentNotInSession, "plan names session " & plan.sessionId)
  if plan.operations.len == 0 or plan.operations.len > MaxOperationsPerPlan:
    refuse(arBoundsExceeded, "a plan has 1.." & $MaxOperationsPerPlan &
      " operations")
  if plan.intentId.hex notin s.intents:
    refuse(arIntentNotInSession, "intent " & plan.intentId.hex)
  for e in plan.evidence:
    # Evidence the user is shown must be what this host produced for this
    # session, not a digest the provider made up.
    if not s.evidence.hasKey(e.hex):
      refuse(arEvidenceUnknown, "evidence " & e.hex &
        " is not a result of this session")
  for op in plan.operations:
    if familyOf(op.kind) notin conn.families:
      refuse(arUnsupportedFamily, $familyOf(op.kind) & " was not negotiated")
  for op in plan.operations:
    if usesPathArg(op.kind):
      let p = op.arg("path")
      if not (op.kind == okSourceList and p == ".") and
          not isCanonicalRelPath(p):
        refuse(arPathEscape, "operation path " & p.escape)
    if op.kind == okSourceWrite and op.arg("content").len > MaxSourceWriteBytes:
      refuse(arBoundsExceeded, "source write larger than 1 MiB")
  let declared = sortedUnique(plan.declaredCapabilities)
  for g in declared:
    validateGrant(g)
  var needsApproval: seq[int]
  for i, op in plan.operations:
    let pkg = h.packageOfTarget(s, op)
    for g in requiredGrants(op, pkg):
      if g notin declared:
        refuse(arCapabilityNotDeclared, $g & " for operation " & $i)
      if isApprovalOnly(g):
        if i notin needsApproval:
          needsApproval.add i
      elif not s.holds(g):
        refuse(arCapabilityNotHeld, $g & " for operation " & $i)
  for g in declared:
    if not isApprovalOnly(g) and not s.holds(g):
      refuse(arCapabilityNotHeld, "declared " & $g)
  for op in plan.operations:
    if op.kind in {okGenerationStage, okGenerationActivate,
                   okGenerationRollback} and
        plan.baseGeneration != h.backend.activeGeneration():
      refuse(arApprovalStaleBase, "plan is based on " & plan.baseGeneration &
        ", active is " & h.backend.activeGeneration())
  needsApproval

proc attach*(h: Host; conn: Connection; sessionId, secret: string) =
  ## Bind a provider connection to a session. The secret is the one the
  ## consent surface handed the provider at session creation; a
  ## connection can be attached once.
  h.audited(conn, "session", "attach"):
    conn.requireChannel(chProvider, "attach")
    if not conn.helloDone:
      refuse(arMalformed, "hello first")
    if conn.sessionId.len > 0:
      refuse(arMalformed, "already attached")
    if not h.sessions.hasKey(sessionId):
      refuse(arSessionUnknown, sessionId)
    let s = h.sessions[sessionId]
    if not ctEqual(secretDigestOf(secret), s.secretDigest):
      refuse(arSessionSecretMismatch, sessionId)
    if s.state == ssSuspended:
      s.state = ssActive
      conn.sessionId = sessionId
      discard h.record(conn, "session", "attach", "recover")
    discard h.requireLive(sessionId)
    conn.sessionId = sessionId
    discard h.record(conn, "session", "attach", "allowed")

proc submitPlan*(h: Host; conn: Connection; plan: Plan): PlanReceipt =
  h.audited(conn, "plan", "submit"):
    let s = h.attachedSession(conn)
    let needs = h.checkPlan(conn, s, plan)
    let pid = planId(plan)
    h.plans[pid.hex] = PendingPlan(plan: plan, id: pid,
                                   approvalRequired: needs)
    discard h.record(conn, "plan", "submit", "allowed", plan = pid.hex,
                     intent = plan.intentId.hex)
    PlanReceipt(planId: pid, approvalRequired: needs)

proc showPlan*(h: Host; conn: Connection; planIdHex: string): Plan =
  ## What the consent surface shows: the plan exactly as the host holds
  ## it, so the user approves the bytes that will run.
  h.audited(conn, "plan", "show"):
    conn.requireChannel(chConsent, "plan display")
    if not h.plans.hasKey(planIdHex):
      refuse(arPlanUnknown, planIdHex)
    h.plans[planIdHex].plan

# ---------------------------------------------------------------------
# Approvals (consent channel).

proc approvalMac(h: Host; a: ApprovalRecord): array[32, byte] =
  let body = approvalBody(a.approvalId, a.sessionId, a.intentId, a.planId,
                          a.operations, a.epoch, a.issuedAt, a.expiresAt)
  let digest = id(ApprovalContext, body)
  sha256.hmac(h.bootKey, digest).data

proc approvePlan*(h: Host; conn: Connection; planIdHex: string;
                  lifetimeSeconds = DefaultApprovalLifetimeSeconds): string =
  ## The user accepted the plan on the consent surface. Returns the
  ## approval handle the provider names when it executes the plan.
  h.audited(conn, "approval", "approve"):
    conn.requireChannel(chConsent, "approval")
    if not h.plans.hasKey(planIdHex):
      refuse(arPlanUnknown, planIdHex)
    let p = h.plans[planIdHex]
    let s = h.requireLive(p.plan.sessionId)
    let now = h.clock()
    var a = ApprovalRecord(approvalId: "a-" & randomHex(16),
      sessionId: s.id, intentId: p.plan.intentId, planId: p.id,
      operations: p.approvalRequired, epoch: s.epoch, issuedAt: now,
      expiresAt: min(now + lifetimeSeconds, s.expiresAt))
    a.mac = h.approvalMac(a)
    h.approvals[a.approvalId] = a
    let saved = conn.sessionId
    conn.sessionId = s.id
    discard h.record(conn, "approval", "approve", "approve",
                     plan = planIdHex, intent = p.plan.intentId.hex,
                     approval = a.approvalId)
    conn.sessionId = saved
    a.approvalId

proc rejectPlan*(h: Host; conn: Connection; planIdHex: string) =
  h.audited(conn, "approval", "reject"):
    conn.requireChannel(chConsent, "rejection")
    if not h.plans.hasKey(planIdHex):
      refuse(arPlanUnknown, planIdHex)
    let sid = h.plans[planIdHex].plan.sessionId
    h.plans.del(planIdHex)
    let saved = conn.sessionId
    conn.sessionId = sid
    discard h.record(conn, "approval", "reject", "reject", plan = planIdHex)
    conn.sessionId = saved

proc checkApproval(h: Host; s: Session; p: PendingPlan;
                   approvalId: string): string =
  ## Every validity condition of §"Approval", in the spec's order; returns
  ## the approval id to consume.
  if approvalId.len == 0:
    refuse(arApprovalRequired, "operations " & $p.approvalRequired)
  if not h.approvals.hasKey(approvalId):
    refuse(arApprovalUnknown, approvalId)
  let a = h.approvals[approvalId]
  if not ctEqual(h.approvalMac(a), a.mac):
    refuse(arApprovalUnknown, "MAC does not verify")
  if a.sessionId != s.id:
    refuse(arApprovalWrongSession, approvalId)
  if a.planId != p.id or planId(p.plan) != a.planId:
    refuse(arApprovalPlanMismatch, approvalId)
  if a.intentId != p.plan.intentId:
    refuse(arApprovalIntentMismatch, approvalId)
  if h.clock() >= a.expiresAt:
    refuse(arApprovalExpired, approvalId)
  if a.consumed:
    refuse(arApprovalConsumed, approvalId)
  if a.epoch != s.epoch:
    refuse(arApprovalStaleEpoch, approvalId)
  approvalId

# ---------------------------------------------------------------------
# Execution.

proc workspaceOf(h: Host; op: Operation): Workspace =
  if usesWorkspaceTarget(op.kind): h.workspaces[op.target] else: Workspace()

proc runOne(h: Host; s: Session; op: Operation): OpResult =
  case op.kind
  of okOwnershipResolve:
    result = h.backend.resolveOwnership(op.target)
  of okCheckoutCreate:
    inc h.counter
    let wid = "w" & $h.counter & "-" & randomHex(6)
    let root = h.workspacesRoot / wid
    createDir(root)
    result = h.backend.createCheckout(op.target, root)
    if result.status == osCompleted:
      h.workspaces[wid] = Workspace(id: wid, sessionId: s.id,
                                    package: op.target, root: root)
      result.detail = wid
    else:
      removeDir(root)
  of okSourceRead:
    let ws = h.workspaces[op.target]
    result = OpResult(status: osCompleted,
                      output: readBeneath(ws.root, op.arg("path")))
  of okSourceWrite:
    let ws = h.workspaces[op.target]
    writeBeneath(ws.root, op.arg("path"), op.arg("content"))
    result = OpResult(status: osCompleted)
  of okSourceList:
    let ws = h.workspaces[op.target]
    var names = ""
    for n in listBeneath(ws.root, op.arg("path")):
      names.add n & "\n"
    result = OpResult(status: osCompleted, output: names)
  of okSourceDiff:
    result = h.backend.diff(h.workspaceOf(op))
  of okBuildRun:
    result = h.backend.runBuild(h.workspaceOf(op), op)
  of okTestRun:
    result = h.backend.runTest(h.workspaceOf(op), op)
  of okPreviewStart, okPreviewStop:
    result = h.backend.preview(h.workspaceOf(op), op)
  of okGenerationStage, okGenerationActivate, okGenerationRollback:
    result = h.backend.generation(h.workspaceOf(op), op)
  of okRemixCapture, okRemixExport, okRemixSubmit:
    result = h.backend.remix(h.workspaceOf(op), op)

proc execute*(h: Host; conn: Connection; planIdHex: string;
              approvalId = ""): ExecutionReport =
  ## Execute a submitted plan. The plan is re-checked against the
  ## session's CURRENT grants (a revocation since submission refuses), an
  ## approval is validated and consumed when the plan needs one, and
  ## operations run in order, stopping at the first failure (§"Partial
  ## results").
  h.audited(conn, "plan", "execute"):
    let s = h.attachedSession(conn)
    if not h.plans.hasKey(planIdHex):
      refuse(arPlanUnknown, planIdHex)
    let p = h.plans[planIdHex]
    if p.plan.sessionId != s.id:
      refuse(arPlanUnknown, planIdHex & " is not a plan of this session")
    let needs = h.checkPlan(conn, s, p.plan)
    var consumed = ""
    if needs.len > 0 or approvalId.len > 0:
      consumed = h.checkApproval(s, p, approvalId)
      h.approvals[consumed].consumed = true
      discard h.record(conn, "approval", "consume", "consume",
                       plan = planIdHex, approval = consumed)
    h.plans.del(planIdHex)
    result.planId = p.id
    var failed = false
    for i, op in p.plan.operations:
      if failed:
        result.results.add OpResult(status: osNotRun)
        continue
      discard h.record(conn, $familyOf(op.kind), $op.kind, "allowed",
                       plan = planIdHex, approval = consumed)
      var r: OpResult
      try:
        r = h.runOne(s, op)
      except AgentRefusal as e:
        r = OpResult(status: osFailed, detail: $e.reason & ": " & e.msg)
      except OSError, IOError:
        r = OpResult(status: osFailed, detail: getCurrentExceptionMsg())
      r.resultId = resultIdOf(p.id, i, op.kind, r.status, r.detail, r.output)
      s.evidence[r.resultId.hex] = EvidenceRecord(planId: p.id, index: i,
        kind: op.kind, status: r.status, detail: r.detail, output: r.output)
      discard h.record(conn, $familyOf(op.kind), $op.kind, "result",
                       reason = $r.status, plan = planIdHex,
                       resultDigest = r.resultId.hex)
      if r.status != osCompleted:
        failed = true
      result.results.add r

# ---------------------------------------------------------------------
# Lifecycle.

proc disconnect*(h: Host; conn: Connection) =
  ## The provider's connection closed (cleanly or by a crash). Its session
  ## is suspended and its approvals voided until it re-attaches.
  if conn.channel != chProvider or conn.sessionId.len == 0:
    return
  if h.sessions.hasKey(conn.sessionId):
    let s = h.sessions[conn.sessionId]
    if s.state == ssActive:
      s.state = ssSuspended
      h.bumpEpoch(s)
      discard h.record(conn, "session", "disconnect", "suspend")
  conn.sessionId = ""

proc sessionState*(h: Host; sessionId: string): SessionState =
  if not h.sessions.hasKey(sessionId):
    refuse(arSessionUnknown, sessionId)
  h.sessions[sessionId].state

proc sessionGrants*(h: Host; sessionId: string): seq[Grant] =
  if not h.sessions.hasKey(sessionId):
    refuse(arSessionUnknown, sessionId)
  h.sessions[sessionId].grants
