## The worker/peer Boundary vocabulary and its receiver-side gate —
## Distributed-Execution M7 (deployment-security-architecture.md FLOW-1,
## FLOW-2, FLOW-4, DET-2, EVID-1).
##
## FLOW-2: "The Boundary is a vocabulary, not a tunnel." A conformant
## Boundary enumerates its message types in the component's specification
## (`reprobuild-pm/spec/Distributed-Execution.md` §"Worker Boundary
## Vocabulary" — THESE tables are its implementation and the two must
## agree), validates every message against a schema at the receiving end
## with explicit size and rate limits, makes its own authorization decision
## PER MESSAGE (FLOW-4), and audits per message to the Evidence zone.
##
## A node receives frames on two kinds of connection, and both are gated:
##
## * INBOUND connections (a peer dialled this node's listener): every frame
##   passes `ReceiverGate.decide` against `Vocabulary`;
## * OUTBOUND connections (this node dialled a peer): every frame the peer
##   sends back — replies, advertisement pushes, and the hydration fetches a
##   worker makes over the connection its caller opened — passes
##   `ReceiverGate.decideOutbound` against `OutboundVocabulary`, with the
##   context of what this node actually asked for (`OutboundContext`): a
##   reply nobody asked for is a protocol violation, not data.
##
## The order of checks on an inbound frame is deliberate:
##
##   1. size, from the frame HEADER, before the payload is read: an
##      oversized frame is refused without allocating its body, and the
##      connection is closed (the stream cannot be resynchronised);
##   2. protocol order: nothing but identity proof / Hello / keep-alives
##      before the caller completed Hello;
##   3. the caller's credential, judged NOW: a leaf that expired since the
##      handshake ends the connection (threat model G15 — a connection must
##      not outlive the leaf that opened it);
##   4. revocation, de-authorization (the host's CA is no longer an anchor)
##      and FLOW-1 (a host designated an Edge host may not open connections
##      to this node at all);
##   5. authorization: the caller's ROLES, derived from its verified
##      identity on every message — never cached from connect time, so a
##      grant withdrawn mid-connection takes effect on the next frame;
##   6. rate: a token bucket per (caller, message class), then the node's
##      GLOBAL admission budget (threat model G18, below).
##
## AUDIT UNDER LOAD (G18). Every admitted frame is one audit record, and the
## evidence sink accepts `SinkRecordsPerSecondPerSender` records per second
## from one sender (with backpressure beyond its burst). So the gate's total
## admission rate is bounded by `GateAdmittedPerSecond` across ALL callers —
## the per-caller rates alone allow more when several callers are busy —
## and `OutboundAdmittedPerSecond` bounds the frames admitted on this
## node's own outbound connections. Refusals are recorded individually only
## within `RefusalRecordsPerSecond` per caller and `GateRefusalRecordsPerSecond`
## overall; beyond either, refused frames are counted and summarized (one
## `frame-refused` record per caller per second carrying the count), so an
## authenticated peer cannot turn refusals into an unbounded record stream.
## `auditBudgetIsConsistent` states the arithmetic and a test holds it.
##
## A message type that is enumerated but not implemented yet (the M3/M4
## orchestration messages) is still gated and audited, then refused as
## `rcNotImplemented`, so the vocabulary is closed before M2-M4 open it.

import std/[sets, strutils, tables, times]

import ./evidence_record
import ./identity
import ./types

type
  BoundaryMessage* = enum
    ## The Boundary vocabulary. One entry per message a RECEIVER can be
    ## asked to act on; replies travelling back on a connection the
    ## receiver opened are `bmReply`.
    bmIdentityProof = "identity-proof"
    bmHello = "hello"
    bmKeepalive = "keepalive"
    bmGoodbye = "goodbye"
    bmAdvertise = "advertise"
    bmAdvertiseRefresh = "advertise-refresh"
    bmBlobFetch = "blob-fetch"
    bmSelectorQuery = "selector-query"
    bmActionRecordQuery = "action-record-query"
    bmAttach = "attach"
    bmGraphDescriptorFetch = "graph-descriptor-fetch"
    bmExecutePips = "execute-pips"
    bmNotifyPipResults = "notify-pip-results"
    bmReachGoal = "reach-goal"
    bmShardDispatch = "shard-dispatch"
    bmHydrationReply = "hydration-reply"
      ## A caller's answer to a hydration fetch the worker made over the
      ## caller's own connection (FLOW-1: the worker never dials the
      ## caller). Admitted only while such a fetch is outstanding.
    bmReply = "reply"
    bmSwim = "swim"

  OutboundMessage* = enum
    ## What a node may receive on a connection IT opened.
    omIdentityProof = "identity-proof"
    omHelloOk = "hello-ok"
    omAdvertise = "advertise"
    omKeepalive = "keepalive"
    omGoodbye = "goodbye"
    omFetchResponse = "fetch-response"
    omSelectorsResponse = "selectors-response"
    omActionRecordResponse = "action-record-response"
    omRefused = "refused"
    omReachGoalResponse = "reach-goal-response"
    omHydrationFetch = "hydration-fetch"
      ## A worker fetching the descriptor, the snapshot manifest or one of
      ## its blobs back over the caller's connection, while the caller's
      ## `ReachGoal` is outstanding and only for digests the caller
      ## published for that goal.
    omUnexpected = "unexpected"

  BoundaryRole* = enum
    brCachePeer = "cache-peer"
      ## Reads the content and memoization planes; advertises.
    brOrchestrator = "orchestrator"
      ## May ask this worker to hydrate a graph and reach a goal in it.
    brWorkerReporter = "worker-reporter"
      ## May report pip results back to this orchestrator.

  MessageSpec* = object
    message*: BoundaryMessage
    maxPayloadBytes*: uint32
    ratePerSecond*: float
    burst*: float
    requiredRole*: set[BoundaryRole]
      ## Empty = any caller that passed the connection-level identity check
      ## (the handshake messages themselves).
    beforeHello*: bool
      ## May arrive before the caller completed Hello.
    implemented*: bool
      ## `false`: enumerated and gated, refused as `rcNotImplemented`.

  OutboundSpec* = object
    message*: OutboundMessage
    maxPayloadBytes*: uint32
    ratePerSecond*: float
      ## 0 = bounded by what this node asked for (`OutboundContext`).
    burst*: float
    requiresDaemonLeaf*: bool
      ## Only a peer that proved a `daemon` leaf may send it.

  RefusalClass* = enum
    rcNone = "none"
    rcSize = "size"
    rcProtocol = "protocol"
    rcUnauthenticated = "unauthenticated"
    rcUnauthorized = "unauthorized"
    rcRevoked = "revoked"
    rcRate = "rate"
    rcNotImplemented = "not-implemented"
    rcSchema = "schema"
    rcEdgeInitiated = "edge-initiated"
      ## FLOW-1: a host designated as an Edge (worker) host opened a
      ## connection to this node.

  CallerIdentity* = object
    ## Who sent a frame, as the RECEIVER established it.
    authenticated*: bool
      ## True only for a TLS peer whose leaf verified (`identity.nim`).
    hostId*: PeerId
    leafRole*: LeafRole
    leafNotAfter*: int64
      ## When the leaf the caller proved expires (unix seconds); 0 = no
      ## leaf (a CIDR-harness caller or a legacy identity).
    address*: string
    helloDone*: bool

  AuthorizationPolicy* = object
    ## The receiver's own authorization decision table (FLOW-4).
    authenticatedDefault*: set[BoundaryRole]
      ## Roles every authenticated host holds unless `grants` names it.
    grants*: Table[PeerId, set[BoundaryRole]]
      ## Per-host grants, replacing the default for that host.
    anonymousMessages*: set[BoundaryMessage]
      ## What an UNauthenticated (CIDR-only, loopback) caller may send.
      ## Never the memoization plane and never a worker message.
    revoked*: HashSet[PeerId]
      ## Hosts refused outright (`<tls dir>/revoked`, reloaded on change).
    revocationUnknown*: bool
      ## The revocation list exists but could not be read: nobody can be
      ## shown not to be revoked, so every authenticated caller is refused
      ## until it is fixed (fail closed).
    edgeHosts*: HashSet[PeerId]
      ## FLOW-1: hosts this node treats as Edge hosts (workers). They may
      ## not open connections to it; it opens them (the `edge` designation
      ## in the grants file).
    anchoredHosts*: HashSet[PeerId]
      ## When `requireAnchored`: the hosts whose CA is currently in the
      ## trust-anchor directory. A host whose anchor was removed is
      ## de-authorized on its next frame, not at its next reconnect.
    requireAnchored*: bool
    servesWorker*: bool
      ## This node holds the worker role; without it a `ReachGoal` is
      ## refused at the gate (`not-implemented`), before its payload is
      ## acted on — and audited as the refusal it is.

  GateDecision* = object
    allowed*: bool
    refusal*: RefusalClass
    reason*: string
    closeConnection*: bool
      ## The stream cannot continue (size / protocol violations).

  AuditEvent* = object
    caller*: CallerIdentity
    kindTag*: uint16
      ## Raw wire tag, so an unknown or reserved tag is still recorded.
    message*: string
      ## The vocabulary entry (`BoundaryMessage` or `OutboundMessage`).
    direction*: string
      ## "inbound" (a frame on a connection the peer opened) or "outbound".
    payloadLen*: uint32
    decision*: GateDecision
    payload*: seq[byte]
      ## The frame payload as read (a size refusal captures a bounded
      ## prefix — EVID-1: the payload, not only the fact).
    suppressed*: int
      ## A summary event: this many further refusals from the caller were
      ## counted but not recorded one by one (G18).

  AuditSink* = proc(event: AuditEvent) {.gcsafe, closure.}

  TokenBucket = object
    tokens: float
    lastMs: int64

  RefusalTally = object
    bucket: TokenBucket
    suppressed: int
    lastSummaryMs: int64
    firstSuppressed: GateDecision
    firstTag: uint16

  ReceiverGate* = ref object
    policy*: AuthorizationPolicy
    audit*: AuditSink
    buckets: Table[string, TokenBucket]
    globalBucket: TokenBucket
    outboundBucket: TokenBucket
    refusalGlobal: TokenBucket
    refusals: Table[string, RefusalTally]
    admittedCount*: int
    outboundAdmittedCount*: int
    refusedCount*: array[RefusalClass, int]
    refusalsSuppressed*: int
      ## Refusals counted but not recorded individually (G18).
    globalRatePerSecond*: float
    globalBurst*: float
    outboundRatePerSecond*: float
    outboundBurst*: float

  OutboundContext* = object
    ## What this node is waiting for from the peer on THIS connection.
    helloPending*: bool
    fetchesPending*: int
    selectorsPending*: int
    recordsPending*: int
    goalPending*: bool
    hydrationAllowed*: bool
      ## A `ReachGoal` to this peer is outstanding and published a
      ## hydration set (the peer may fetch from it).

const
  KiB = 1024'u32
  MiB = 1024'u32 * 1024'u32

  GateAdmittedPerSecond* = 2_000.0
  GateAdmittedBurst* = 4_000.0
    ## Every inbound frame admitted, all callers together (G18).
  OutboundAdmittedPerSecond* = 1_000.0
  OutboundAdmittedBurst* = 2_000.0
    ## Every frame admitted on this node's outbound connections.
  RefusalRecordsPerSecond* = 10.0
  RefusalRecordsBurst* = 20.0
    ## Refusals recorded one by one, per caller.
  GateRefusalRecordsPerSecond* = 200.0
  GateRefusalRecordsBurst* = 400.0
    ## Refusals recorded one by one, all callers together.
  AuditReserveRecordsPerSecond* = 800.0
    ## Detections, heartbeats, lease reports and refusal summaries.
  RefusalSummaryIntervalMs* = 1_000'i64

  LeafRoleCaps*: array[LeafRole, set[BoundaryRole]] = [
    lrLegacy: {brCachePeer},
    lrDaemon: {brCachePeer, brOrchestrator, brWorkerReporter},
    lrBuildWorker: {brCachePeer},
    lrLease: {brCachePeer}]
    ## A role a LEAF can exercise at most, whatever its host is granted:
    ## a daemon-forked build worker or an execution lease that is
    ## compromised cannot drive another worker even when its host is an
    ## orchestrator. Legacy (long-lived) identities are capped to the
    ## cache plane.

  MaxHydrationReplyBytes* = 520'u32 * MiB
    ## A hydration reply carries one snapshot blob (at most 512 MiB, the
    ## manifest's per-blob bound) plus framing.

  Vocabulary*: array[BoundaryMessage, MessageSpec] = [
    bmIdentityProof: MessageSpec(message: bmIdentityProof,
      maxPayloadBytes: 8 * KiB, ratePerSecond: 2, burst: 4,
      requiredRole: {}, beforeHello: true, implemented: true),
    bmHello: MessageSpec(message: bmHello, maxPayloadBytes: 256,
      ratePerSecond: 2, burst: 4, requiredRole: {}, beforeHello: true,
      implemented: true),
    bmKeepalive: MessageSpec(message: bmKeepalive, maxPayloadBytes: 64,
      ratePerSecond: 20, burst: 40, requiredRole: {}, beforeHello: true,
      implemented: true),
    bmGoodbye: MessageSpec(message: bmGoodbye, maxPayloadBytes: 64,
      ratePerSecond: 5, burst: 5, requiredRole: {}, beforeHello: true,
      implemented: true),
    bmAdvertise: MessageSpec(message: bmAdvertise,
      maxPayloadBytes: 32 * MiB, ratePerSecond: 20, burst: 40,
      requiredRole: {brCachePeer}, implemented: true),
    bmAdvertiseRefresh: MessageSpec(message: bmAdvertiseRefresh,
      maxPayloadBytes: 4 * MiB, ratePerSecond: 10, burst: 20,
      requiredRole: {brCachePeer}, implemented: true),
    bmBlobFetch: MessageSpec(message: bmBlobFetch, maxPayloadBytes: 64,
      ratePerSecond: 1500, burst: 3000, requiredRole: {brCachePeer},
      implemented: true),
    bmSelectorQuery: MessageSpec(message: bmSelectorQuery,
      maxPayloadBytes: 64, ratePerSecond: 500, burst: 1000,
      requiredRole: {brCachePeer}, implemented: true),
    bmActionRecordQuery: MessageSpec(message: bmActionRecordQuery,
      maxPayloadBytes: 96, ratePerSecond: 500, burst: 1000,
      requiredRole: {brCachePeer}, implemented: true),
    bmAttach: MessageSpec(message: bmAttach, maxPayloadBytes: 64 * KiB,
      ratePerSecond: 1, burst: 4, requiredRole: {brOrchestrator},
      implemented: false),
    bmGraphDescriptorFetch: MessageSpec(message: bmGraphDescriptorFetch,
      maxPayloadBytes: 64, ratePerSecond: 20, burst: 40,
      requiredRole: {brOrchestrator}, implemented: false),
    bmExecutePips: MessageSpec(message: bmExecutePips,
      maxPayloadBytes: 4 * MiB, ratePerSecond: 500, burst: 1000,
      requiredRole: {brOrchestrator}, implemented: false),
    bmNotifyPipResults: MessageSpec(message: bmNotifyPipResults,
      maxPayloadBytes: 4 * MiB, ratePerSecond: 500, burst: 1000,
      requiredRole: {brWorkerReporter}, implemented: false),
    bmReachGoal: MessageSpec(message: bmReachGoal,
      maxPayloadBytes: 64 * KiB, ratePerSecond: 2, burst: 4,
      requiredRole: {brOrchestrator}, implemented: true),
    bmShardDispatch: MessageSpec(message: bmShardDispatch,
      maxPayloadBytes: 1 * MiB, ratePerSecond: 10, burst: 20,
      requiredRole: {brOrchestrator}, implemented: false),
    bmHydrationReply: MessageSpec(message: bmHydrationReply,
      maxPayloadBytes: MaxHydrationReplyBytes, ratePerSecond: 200,
      burst: 400, requiredRole: {brOrchestrator}, implemented: true),
    bmReply: MessageSpec(message: bmReply, maxPayloadBytes: 0,
      ratePerSecond: 50, burst: 100, requiredRole: {}, implemented: true),
    bmSwim: MessageSpec(message: bmSwim, maxPayloadBytes: 0,
      ratePerSecond: 50, burst: 100, requiredRole: {}, implemented: false)]
    ## `bmReply` and `bmSwim` have a zero size budget at a RECEIVER: a reply
    ## arriving on an inbound connection with nothing outstanding, or a
    ## SWIM frame on the TCP plane (SWIM has its own transport), carries
    ## nothing a receiver acts on, so any payload is a protocol violation.

  OutboundVocabulary*: array[OutboundMessage, OutboundSpec] = [
    omIdentityProof: OutboundSpec(message: omIdentityProof,
      maxPayloadBytes: 8 * KiB, ratePerSecond: 0),
    omHelloOk: OutboundSpec(message: omHelloOk, maxPayloadBytes: 256,
      ratePerSecond: 0),
    omAdvertise: OutboundSpec(message: omAdvertise,
      maxPayloadBytes: 32 * MiB, ratePerSecond: 20, burst: 40),
    omKeepalive: OutboundSpec(message: omKeepalive, maxPayloadBytes: 64,
      ratePerSecond: 20, burst: 40),
    omGoodbye: OutboundSpec(message: omGoodbye, maxPayloadBytes: 64,
      ratePerSecond: 5, burst: 5),
    omFetchResponse: OutboundSpec(message: omFetchResponse,
      maxPayloadBytes: 101 * MiB, ratePerSecond: 0),
    omSelectorsResponse: OutboundSpec(message: omSelectorsResponse,
      maxPayloadBytes: 300 * KiB, ratePerSecond: 0),
    omActionRecordResponse: OutboundSpec(message: omActionRecordResponse,
      maxPayloadBytes: 101 * MiB, ratePerSecond: 0),
    omRefused: OutboundSpec(message: omRefused, maxPayloadBytes: 4 * KiB,
      ratePerSecond: 500, burst: 1000),
    omReachGoalResponse: OutboundSpec(message: omReachGoalResponse,
      maxPayloadBytes: 192 * KiB, ratePerSecond: 0,
      requiresDaemonLeaf: true),
    omHydrationFetch: OutboundSpec(message: omHydrationFetch,
      maxPayloadBytes: 64, ratePerSecond: 200, burst: 400,
      requiresDaemonLeaf: true),
    omUnexpected: OutboundSpec(message: omUnexpected, maxPayloadBytes: 0,
      ratePerSecond: 0)]

  DefaultAnonymousMessages* = {bmHello, bmKeepalive, bmGoodbye, bmAdvertise,
                               bmAdvertiseRefresh, bmBlobFetch}
    ## An unauthenticated caller exists only on a CIDR-trust server, which
    ## is an in-process harness mode bound to loopback (see
    ## `types.TrustMode`; no shipped entry point starts one). It may read the
    ## content plane — every reply there is BLAKE3-verified by the
    ## requester — and nothing else.

proc auditBudgetIsConsistent*(): bool =
  ## G18: everything a single node process can record per second, at the
  ## most its gates admit, fits the sink's per-sender rate.
  GateAdmittedPerSecond + OutboundAdmittedPerSecond +
    GateRefusalRecordsPerSecond + AuditReserveRecordsPerSecond <=
    SinkRecordsPerSecondPerSender and
    GateAdmittedBurst + OutboundAdmittedBurst + GateRefusalRecordsBurst <=
    SinkBurstPerSender

static:
  doAssert auditBudgetIsConsistent(),
    "the gates admit more frames per second than the evidence sink records"

proc defaultAuthorizationPolicy*(): AuthorizationPolicy =
  AuthorizationPolicy(authenticatedDefault: {brCachePeer},
    grants: initTable[PeerId, set[BoundaryRole]](),
    anonymousMessages: DefaultAnonymousMessages,
    revoked: initHashSet[PeerId](),
    edgeHosts: initHashSet[PeerId](),
    anchoredHosts: initHashSet[PeerId]())

proc newReceiverGate*(policy = defaultAuthorizationPolicy();
                      audit: AuditSink = nil): ReceiverGate =
  ReceiverGate(policy: policy, audit: audit,
    buckets: initTable[string, TokenBucket](),
    refusals: initTable[string, RefusalTally](),
    globalBucket: TokenBucket(tokens: GateAdmittedBurst, lastMs: 0),
    outboundBucket: TokenBucket(tokens: OutboundAdmittedBurst, lastMs: 0),
    refusalGlobal: TokenBucket(tokens: GateRefusalRecordsBurst, lastMs: 0),
    globalRatePerSecond: GateAdmittedPerSecond,
    globalBurst: GateAdmittedBurst,
    outboundRatePerSecond: OutboundAdmittedPerSecond,
    outboundBurst: OutboundAdmittedBurst)

proc boundaryMessageOfTag*(tag: uint16;
                           hydrationPending = false): tuple[known: bool;
                                                        message: BoundaryMessage] =
  ## Maps a raw wire tag (`MessageKind` ordinal) to its vocabulary entry.
  ## Kept on the raw tag so the gate can classify a frame from its header
  ## before the codec accepts it. A `mkFetchResponse` (5) on an inbound
  ## connection is a hydration reply while the worker has a hydration fetch
  ## outstanding on it, and an unsolicited reply otherwise.
  case int(tag)
  of 0: (true, bmHello)
  of 5:
    if hydrationPending: (true, bmHydrationReply) else: (true, bmReply)
  of 1, 18, 20, 22, 24: (true, bmReply)
  of 2, 16: (true, bmAdvertise)
  of 3: (true, bmAdvertiseRefresh)
  of 4: (true, bmBlobFetch)
  of 6, 7: (true, bmKeepalive)
  of 8: (true, bmGoodbye)
  of 9 .. 15: (true, bmSwim)
  of 17: (true, bmSelectorQuery)
  of 19: (true, bmActionRecordQuery)
  of 21: (true, bmIdentityProof)
  of 23: (true, bmReachGoal)
  of 25: (true, bmAttach)
  of 26: (true, bmGraphDescriptorFetch)
  of 27: (true, bmExecutePips)
  of 28: (true, bmNotifyPipResults)
  of 29: (true, bmShardDispatch)
  else: (false, bmReply)

proc outboundMessageOfTag*(tag: uint16): OutboundMessage =
  case int(tag)
  of 21: omIdentityProof
  of 1: omHelloOk
  of 2, 16: omAdvertise
  of 6, 7: omKeepalive
  of 8: omGoodbye
  of 5: omFetchResponse
  of 18: omSelectorsResponse
  of 20: omActionRecordResponse
  of 22: omRefused
  of 24: omReachGoalResponse
  of 4: omHydrationFetch
  else: omUnexpected

proc rolesFor*(policy: AuthorizationPolicy;
               caller: CallerIdentity): set[BoundaryRole] =
  ## The roles `caller` holds for THIS message: the host's grant (or the
  ## default), capped by what its leaf role may exercise.
  if not caller.authenticated:
    return {}
  let granted =
    if policy.grants.hasKey(caller.hostId): policy.grants[caller.hostId]
    else: policy.authenticatedDefault
  granted * LeafRoleCaps[caller.leafRole]

proc callerKey(caller: CallerIdentity): string =
  if caller.authenticated: "h:" & $caller.hostId
  else: "a:" & caller.address

proc refill(bucket: var TokenBucket; rate, burst: float; nowMs: int64) =
  if bucket.lastMs == 0:
    bucket.lastMs = nowMs
  let elapsed = float(max(0'i64, nowMs - bucket.lastMs)) / 1000.0
  bucket.tokens = min(burst, bucket.tokens + elapsed * rate)
  bucket.lastMs = nowMs

proc takeFrom(bucket: var TokenBucket; rate, burst: float;
              nowMs: int64): bool =
  bucket.refill(rate, burst, nowMs)
  result = bucket.tokens >= 1.0
  if result:
    bucket.tokens -= 1.0

proc takeToken(gate: ReceiverGate; key: string; rate, burst: float;
               nowMs: int64): bool =
  var bucket = gate.buckets.getOrDefault(key,
    TokenBucket(tokens: burst, lastMs: nowMs))
  result = bucket.takeFrom(rate, burst, nowMs)
  gate.buckets[key] = bucket

proc gateNowMs*(): int64 =
  int64(epochTime() * 1000.0)

proc refuse(refusal: RefusalClass; reason: string;
            close = false): GateDecision =
  GateDecision(allowed: false, refusal: refusal, reason: reason,
    closeConnection: close)

proc credentialDecision(gate: ReceiverGate; caller: CallerIdentity;
                        nowMs: int64): GateDecision =
  ## Steps 3-4 of the module doc for an authenticated caller; `allowed`
  ## when it passes.
  result = GateDecision(allowed: true)
  if not caller.authenticated:
    return
  let nowSec = nowMs div 1000
  if caller.leafNotAfter > 0 and
      nowSec - LeafClockSkewSeconds >= caller.leafNotAfter:
    return refuse(rcUnauthenticated, "the leaf host " & $caller.hostId &
      " proved at the handshake expired at " & $caller.leafNotAfter &
      " (now " & $nowSec & "); a connection does not outlive its leaf",
      close = true)
  if gate.policy.revocationUnknown:
    return refuse(rcRevoked, "this node's revocation list cannot be read; " &
      "every caller is refused until it is fixed", close = true)
  if caller.hostId in gate.policy.revoked:
    return refuse(rcRevoked, "host " & $caller.hostId & " is revoked",
      close = true)
  if gate.policy.requireAnchored and
      caller.hostId notin gate.policy.anchoredHosts:
    return refuse(rcRevoked, "host " & $caller.hostId & "'s CA is no " &
      "longer among this node's trust anchors", close = true)
  if caller.hostId in gate.policy.edgeHosts:
    return refuse(rcEdgeInitiated, "host " & $caller.hostId & " is an " &
      "Edge (worker) host: it may not open connections to this node " &
      "(FLOW-1; this node opens them)", close = true)

proc decide*(gate: ReceiverGate; caller: CallerIdentity; tag: uint16;
             payloadLen: uint32; nowMs: int64;
             hydrationPending = false): GateDecision =
  ## The authorization decision for one inbound frame, from its header
  ## alone (see the module doc for the order). Pure apart from the rate
  ## buckets.
  let (known, message) = boundaryMessageOfTag(tag, hydrationPending)
  if not known:
    return refuse(rcSchema, "unknown message tag " & $tag, close = true)
  let spec = Vocabulary[message]
  if payloadLen > spec.maxPayloadBytes:
    return refuse(rcSize, $message & " payload of " & $payloadLen &
      " bytes exceeds the " & $spec.maxPayloadBytes & "-byte limit",
      close = true)
  if not caller.helloDone and not spec.beforeHello:
    return refuse(rcProtocol, $message & " before Hello", close = true)
  let cred = gate.credentialDecision(caller, nowMs)
  if not cred.allowed:
    return cred
  if spec.requiredRole.len == 0:
    # The connection-establishing messages (identity proof, Hello,
    # keep-alives, Goodbye) carry no role requirement: they are HOW a caller
    # becomes authenticated, and the receiver itself refuses a Hello that
    # does not match the verified identity (`server.serveConnection`).
    discard
  elif not caller.authenticated:
    if message notin gate.policy.anonymousMessages:
      return refuse(rcUnauthenticated, $message &
        " requires an authenticated caller (tls=1)")
  else:
    let roles = rolesFor(gate.policy, caller)
    if (roles * spec.requiredRole).len == 0:
      return refuse(rcUnauthorized, "host " & $caller.hostId & " (" &
        $caller.leafRole & " leaf) holds " & $roles & ", " & $message &
        " needs one of " & $spec.requiredRole)
  if message == bmReachGoal and not gate.policy.servesWorker:
    return refuse(rcNotImplemented,
      "this node does not hold the worker role")
  if not gate.takeToken(callerKey(caller) & "/" & $message,
      spec.ratePerSecond, spec.burst, nowMs):
    return refuse(rcRate, $message & " rate limit (" &
      formatFloat(spec.ratePerSecond, ffDecimal, 0) & "/s) exceeded")
  if not spec.implemented:
    return refuse(rcNotImplemented, $message &
      " is enumerated in the vocabulary but not served by this release")
  # The node-wide admission budget (G18): what every caller together may
  # have admitted, so that every admitted frame's audit record fits the
  # evidence sink's rate. The handshake frames are exempt (they are few,
  # per connection, and a node must stay reachable).
  if spec.requiredRole.len > 0 and
      not gate.globalBucket.takeFrom(gate.globalRatePerSecond,
        gate.globalBurst, nowMs):
    return refuse(rcRate, "this node's admission budget (" &
      formatFloat(gate.globalRatePerSecond, ffDecimal, 0) &
      " frames/s across all callers) is exhausted")
  GateDecision(allowed: true, refusal: rcNone)

proc decideOutbound*(gate: ReceiverGate; peer: CallerIdentity; tag: uint16;
                     payloadLen: uint32; ctx: OutboundContext;
                     nowMs: int64): GateDecision =
  ## The decision for one frame received on a connection THIS node opened
  ## (threat model G29). `peer` is the server's identity as this node
  ## verified it at the handshake.
  let message = outboundMessageOfTag(tag)
  let spec = OutboundVocabulary[message]
  if message == omUnexpected:
    return refuse(rcProtocol, "message tag " & $tag &
      " is never sent to the node that opened the connection", close = true)
  if payloadLen > spec.maxPayloadBytes:
    return refuse(rcSize, $message & " payload of " & $payloadLen &
      " bytes exceeds the " & $spec.maxPayloadBytes & "-byte limit",
      close = true)
  let cred = gate.credentialDecision(peer, nowMs)
  if not cred.allowed and cred.refusal != rcEdgeInitiated:
    # (An Edge host is exactly whom this node DOES dial.)
    return cred
  if spec.requiresDaemonLeaf and peer.authenticated and
      peer.leafRole != lrDaemon:
    return refuse(rcUnauthorized, $message & " from a " & $peer.leafRole &
      " leaf; only a daemon leaf may send it", close = true)
  case message
  of omHelloOk, omIdentityProof:
    if not ctx.helloPending:
      return refuse(rcProtocol, $message & " outside the handshake",
        close = true)
  of omFetchResponse:
    if ctx.fetchesPending <= 0:
      return refuse(rcProtocol, "a fetch response nobody asked for",
        close = true)
  of omSelectorsResponse:
    if ctx.selectorsPending <= 0:
      return refuse(rcProtocol, "a selector response nobody asked for",
        close = true)
  of omActionRecordResponse:
    if ctx.recordsPending <= 0:
      return refuse(rcProtocol, "an action-record response nobody asked " &
        "for", close = true)
  of omReachGoalResponse:
    if not ctx.goalPending:
      return refuse(rcProtocol, "a ReachGoal response nobody asked for",
        close = true)
  of omHydrationFetch:
    if not ctx.hydrationAllowed:
      return refuse(rcProtocol, "a hydration fetch while no ReachGoal to " &
        "this peer is outstanding", close = true)
  else:
    discard
  if spec.ratePerSecond > 0 and not gate.takeToken("o:" & callerKey(peer) &
      "/" & $message, spec.ratePerSecond, spec.burst, nowMs):
    return refuse(rcRate, $message & " rate limit (" &
      formatFloat(spec.ratePerSecond, ffDecimal, 0) & "/s) exceeded",
      close = true)
  if not gate.outboundBucket.takeFrom(gate.outboundRatePerSecond,
      gate.outboundBurst, nowMs):
    return refuse(rcRate, "this node's outbound admission budget (" &
      formatFloat(gate.outboundRatePerSecond, ffDecimal, 0) &
      " frames/s) is exhausted", close = true)
  GateDecision(allowed: true, refusal: rcNone)

proc emit(gate: ReceiverGate; event: AuditEvent) =
  if gate.audit.isNil:
    return
  try:
    gate.audit(event)
  except CatchableError:
    discard

proc record*(gate: ReceiverGate; caller: CallerIdentity; tag: uint16;
             payloadLen: uint32; decision: GateDecision;
             payload: seq[byte] = @[]; outbound = false; nowMs = 0'i64) =
  ## Counts the decision and hands it to the audit sink (FLOW-2: auditable
  ## per message). An admitted frame is always recorded. A refusal is
  ## recorded with its payload within the refusal budgets; beyond them it
  ## is counted and folded into one summary record per caller per second
  ## (G18). Never raises.
  let at = if nowMs == 0: gateNowMs() else: nowMs
  let message =
    if outbound: $outboundMessageOfTag(tag)
    else: $boundaryMessageOfTag(tag).message
  let direction = if outbound: "outbound" else: "inbound"
  if decision.allowed:
    if outbound: inc gate.outboundAdmittedCount
    else: inc gate.admittedCount
    gate.emit(AuditEvent(caller: caller, kindTag: tag, message: message,
      direction: direction, payloadLen: payloadLen, decision: decision,
      payload: payload))
    return
  inc gate.refusedCount[decision.refusal]
  let key = callerKey(caller)
  var tally = gate.refusals.getOrDefault(key, RefusalTally(
    bucket: TokenBucket(tokens: RefusalRecordsBurst, lastMs: at)))
  let individually =
    tally.bucket.takeFrom(RefusalRecordsPerSecond, RefusalRecordsBurst, at) and
    gate.refusalGlobal.takeFrom(GateRefusalRecordsPerSecond,
      GateRefusalRecordsBurst, at)
  if individually:
    gate.refusals[key] = tally
    gate.emit(AuditEvent(caller: caller, kindTag: tag, message: message,
      direction: direction, payloadLen: payloadLen, decision: decision,
      payload: payload))
    return
  inc gate.refusalsSuppressed
  if tally.suppressed == 0:
    tally.firstSuppressed = decision
    tally.firstTag = tag
  inc tally.suppressed
  if at - tally.lastSummaryMs >= RefusalSummaryIntervalMs:
    let count = tally.suppressed
    tally.suppressed = 0
    tally.lastSummaryMs = at
    gate.refusals[key] = tally
    gate.emit(AuditEvent(caller: caller, kindTag: tally.firstTag,
      message: message, direction: direction, payloadLen: payloadLen,
      decision: tally.firstSuppressed, payload: payload, suppressed: count))
  else:
    gate.refusals[key] = tally

proc recordAdmitted*(gate: ReceiverGate; caller: CallerIdentity; tag: uint16;
                     payload: seq[byte]; outbound = false) =
  gate.record(caller, tag, uint32(payload.len),
    GateDecision(allowed: true, refusal: rcNone), payload, outbound)

proc parseRoles*(text: string): set[BoundaryRole] =
  ## `cache-peer,orchestrator` -> the set. Raises `ValueError` on an
  ## unknown role so a typo in a grants file fails closed. (`edge` is a
  ## designation, not a role: see `loadGrants`.)
  for piece in text.split(','):
    let name = piece.strip()
    if name.len == 0:
      continue
    var found = false
    for role in BoundaryRole:
      if $role == name:
        result.incl(role)
        found = true
    if not found:
      raise newException(ValueError, "unknown boundary role: " & name)

proc parseHostIdHex*(hex: string): PeerId =
  ## A 64-hex host id. Raises `ValueError` otherwise.
  if hex.len != 64:
    raise newException(ValueError, "a host id is 64 hex characters: " & hex)
  var raw32: array[32, byte]
  for i in 0 ..< 32:
    raw32[i] = byte(parseHexInt(hex[2 * i .. 2 * i + 1]))
  peerIdFromBytes(raw32)

type
  GrantsFile* = object
    grants*: Table[PeerId, set[BoundaryRole]]
    edgeHosts*: HashSet[PeerId]

proc loadGrants*(path: string): GrantsFile =
  ## A grants file: one `<hostIdHex> <role>[,<role>…]` per line, `#`
  ## comments. The designation `edge` (alone or beside roles) marks the
  ## host as an Edge (worker) host this node never accepts a connection
  ## from (FLOW-1). Raises on any malformed line (fail closed).
  result.grants = initTable[PeerId, set[BoundaryRole]]()
  result.edgeHosts = initHashSet[PeerId]()
  var lineNo = 0
  for raw in readFile(path).splitLines:
    inc lineNo
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let parts = line.splitWhitespace()
    if parts.len != 2:
      raise newException(ValueError, path & ":" & $lineNo &
        ": expected '<64-hex host id> <role>[,<role>...]'")
    let host =
      try: parseHostIdHex(parts[0])
      except ValueError:
        raise newException(ValueError, path & ":" & $lineNo &
          ": expected '<64-hex host id> <role>[,<role>...]'")
    var roles: seq[string] = @[]
    for piece in parts[1].split(','):
      if piece.strip() == "edge":
        result.edgeHosts.incl(host)
      else:
        roles.add(piece)
    result.grants[host] = parseRoles(roles.join(","))

proc loadGrantsFile*(path: string): Table[PeerId, set[BoundaryRole]] =
  ## The role grants of `loadGrants` (kept for callers that need only them).
  loadGrants(path).grants

proc loadRevokedFile*(path: string): HashSet[PeerId] =
  ## A revocation list: one 64-hex host id per line, `#` comments. Raises on
  ## any malformed line — the caller treats an unreadable list as "every
  ## caller may be revoked" (fail closed).
  result = initHashSet[PeerId]()
  var lineNo = 0
  for raw in readFile(path).splitLines:
    inc lineNo
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    try:
      result.incl(parseHostIdHex(line.splitWhitespace()[0]))
    except ValueError:
      raise newException(ValueError, path & ":" & $lineNo &
        ": expected a 64-hex host id")
