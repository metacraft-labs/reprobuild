## SWIM membership + failure detection — Peer-Cache-Scale M0.
##
## Implements the SWIM gossip protocol (Das, Gupta & Motivala 2002) on
## top of the existing `PeerRegistry`. The engine owns a periodic
## scheduler (one async task) that, on each tick:
##
## 1. Ages `Suspected` → `Confirmed` and `Confirmed` → removed using
##    the configured timeouts.
## 2. Picks a random `Alive` (or, with reduced weight, `Suspected`)
##    peer and sends `mkSwimProbe`. On direct-probe timeout, picks K
##    random members and sends each `mkSwimProbeReq`. After the
##    suspect window expires with no ack, transitions the target to
##    `Suspected` and seeds dissemination.
##
## Transport. The engine delegates message I/O to a `SwimTransport`
## object: in-process loopback tests register every engine in a global
## directory keyed by `(host, port)` so probe frames are decoded by
## the engine itself rather than crossing a real socket. The wire
## codec (encode → decode) is exercised on every send so the codec
## path stays under test.
##
## Dissemination. Membership changes ride piggybacked on probe /
## ack messages. The engine maintains a `seq[(SwimMember,
## forwardCount)]` per peer; on each outgoing message it picks up to
## `swimGossipMessageCap` entries with the lowest forward count,
## increments their counts, attaches them to the frame, and retires
## any whose count exceeds the configured cap.
##
## Test seams. Two seams are exposed for the M0 verification tests:
##
##   - `dropDirectProbesFrom: HashSet[PeerId]` — when a probe arrives
##     from one of these peers, the engine drops it (simulating a
##     firewall). Production never sets this.
##   - `injectIncomingSuspect(engine, fakeMember)` — applies a fake
##     `mkSwimSuspect` to the engine as if it had arrived from gossip.
##     Used by the incarnation-self-refute test.

import std/[asyncdispatch, hashes, math, monotimes, random, sequtils,
            sets, tables, times]

import ./codec
import ./registry
import ./types

export types.SwimConfig, types.defaultSwimConfig
export types.SwimMember, types.SwimMemberStatus
export types.SwimProbe, types.SwimAck, types.SwimProbeReq,
       types.SwimProbeAckIndirect

# ---------------------------------------------------------------------------
# Gossip buffer entry.
# ---------------------------------------------------------------------------

type
  GossipEntry = object
    member: SwimMember
    forwardCount: int

  SwimEngine* = ref object
    selfPeerId*: PeerId
    selfEndpoint*: Endpoint
    selfIncarnation*: uint64
    registry*: PeerRegistry
    config*: SwimConfig
    rng: Rand
    running*: bool
    transport: SwimTransport
    seedEndpoints: seq[Endpoint]

    gossip: seq[GossipEntry]
      ## Pending dissemination updates. New updates are appended; the
      ## scheduler picks the lowest-forward-count entries up to
      ## `swimGossipMessageCap` each outgoing message.
    pendingProbes: Table[PeerId, Future[bool]]
      ## In-flight direct or indirect probe futures, keyed by the
      ## probed peer ID. The future is completed `true` when an ack
      ## (direct or indirect) lands; `false` on the suspect-window
      ## timeout.

    # Test seams.
    dropDirectProbesFrom*: HashSet[PeerId]
      ## When non-empty, incoming `mkSwimProbe` frames whose
      ## `sourcePeerId` matches one of these IDs are silently dropped
      ## by the engine — used by the indirect-probe test to simulate
      ## a one-way firewall.

    # Instrumentation counters (Peer-Cache-Scale M0).
    sentDirectProbeCount*: int
    sentIndirectProbeReqCount*: int
    sentAckCount*: int
    sentIndirectAckCount*: int
    receivedDirectProbeCount*: int
    receivedAckCount*: int
    receivedProbeReqCount*: int
    receivedIndirectAckCount*: int
    markedSuspectedCount*: int
      ## Number of times this peer's `markSuspected` was invoked
      ## (after a direct + indirect probe failure). Test instrument.
    suspectTransitionCount*: int
      ## Number of times this peer's `agedTransitions` moved a peer
      ## from Suspected → Confirmed. Test instrument.
    standaloneDisseminationCount*: int
      ## Number of `mkSwimSuspect` / `mkSwimConfirm` / `mkSwimRefute`
      ## frames sent as their own message (not piggybacked). The
      ## dissemination test asserts this stays at 0 under steady-state
      ## operation — all updates ride piggybacked.
    piggybackedDisseminationCount*: int
      ## Number of `(member, status)` updates attached to outbound
      ## probe/ack frames as gossip. Compared against the standalone
      ## count by the verification test.

  SwimTransport* = ref object of RootObj
    ## Abstract send surface used by the engine. The default
    ## in-process implementation routes encoded frames directly to
    ## the engine bound to the destination `Endpoint`.
    sendProbe*: proc (target: Endpoint;
                      payload: seq[byte]) {.gcsafe, closure.}
    sendAck*: proc (target: Endpoint;
                    payload: seq[byte]) {.gcsafe, closure.}
    sendProbeReq*: proc (target: Endpoint;
                         payload: seq[byte]) {.gcsafe, closure.}
    sendIndirectAck*: proc (target: Endpoint;
                            payload: seq[byte]) {.gcsafe, closure.}
    sendStandalone*: proc (target: Endpoint;
                           kind: MessageKind;
                           payload: seq[byte]) {.gcsafe, closure.}

# ---------------------------------------------------------------------------
# In-process transport directory.
#
# The loopback tests register every engine in this directory; the engine's
# default transport looks up the destination engine and feeds it the encoded
# frame bytes via `deliverFrame`. This stays purely in-process (no sockets)
# while still exercising the wire codec on every send.
# ---------------------------------------------------------------------------

var inProcessDirectory: Table[Endpoint, SwimEngine]

proc endpointKey(endpoint: Endpoint): Endpoint =
  endpoint

proc registerEngineInDirectory*(engine: SwimEngine) {.gcsafe.} =
  {.cast(gcsafe).}:
    inProcessDirectory[endpointKey(engine.selfEndpoint)] = engine

proc unregisterEngineFromDirectory*(engine: SwimEngine) {.gcsafe.} =
  {.cast(gcsafe).}:
    inProcessDirectory.del(endpointKey(engine.selfEndpoint))

proc lookupEngine*(endpoint: Endpoint): SwimEngine {.gcsafe.} =
  {.cast(gcsafe).}:
    if inProcessDirectory.hasKey(endpointKey(endpoint)):
      return inProcessDirectory[endpointKey(endpoint)]
  return nil

# Forward declarations — the in-process transport calls back into engine
# handlers, which use the transport for outbound replies.
proc handleProbe*(engine: SwimEngine; msg: SwimProbe) {.gcsafe.}
proc handleAck*(engine: SwimEngine; msg: SwimAck) {.gcsafe.}
proc handleProbeReq*(engine: SwimEngine; msg: SwimProbeReq) {.gcsafe.}
proc handleIndirectAck*(engine: SwimEngine;
                       msg: SwimProbeAckIndirect) {.gcsafe.}
proc handleSuspect*(engine: SwimEngine; msg: SwimMember) {.gcsafe.}
proc handleConfirm*(engine: SwimEngine; msg: SwimMember) {.gcsafe.}
proc handleRefute*(engine: SwimEngine; msg: SwimMember) {.gcsafe.}

proc deliverFrame*(engine: SwimEngine; kind: MessageKind;
                   payload: seq[byte]) {.gcsafe.} =
  ## Decodes `payload` per `kind` and calls the matching engine
  ## handler. Exposed for transports that already have the raw
  ## payload bytes ready (the in-process loopback transport).
  case kind
  of mkSwimProbe:
    handleProbe(engine, decodeSwimProbe(payload))
  of mkSwimAck:
    handleAck(engine, decodeSwimAck(payload))
  of mkSwimProbeReq:
    handleProbeReq(engine, decodeSwimProbeReq(payload))
  of mkSwimProbeAckIndirect:
    handleIndirectAck(engine, decodeSwimProbeAckIndirect(payload))
  of mkSwimSuspect:
    handleSuspect(engine, decodeSwimSuspect(payload))
  of mkSwimConfirm:
    handleConfirm(engine, decodeSwimConfirm(payload))
  of mkSwimRefute:
    handleRefute(engine, decodeSwimRefute(payload))
  else:
    discard

proc newInProcessTransport*(): SwimTransport =
  ## In-process transport for loopback tests. Each outbound proc looks
  ## up the destination engine in `inProcessDirectory` and delivers
  ## the encoded frame directly. When the destination engine is not
  ## registered (e.g. the peer has been shut down), the send is a
  ## no-op — modelling a network drop.
  let probeImpl: proc (target: Endpoint; payload: seq[byte])
                   {.gcsafe, closure.} =
    proc (target: Endpoint; payload: seq[byte]) {.gcsafe, closure.} =
      let engine = lookupEngine(target)
      if engine.isNil: return
      if not engine.running: return
      deliverFrame(engine, mkSwimProbe, payload)
  let ackImpl: proc (target: Endpoint; payload: seq[byte])
                 {.gcsafe, closure.} =
    proc (target: Endpoint; payload: seq[byte]) {.gcsafe, closure.} =
      let engine = lookupEngine(target)
      if engine.isNil: return
      if not engine.running: return
      deliverFrame(engine, mkSwimAck, payload)
  let probeReqImpl: proc (target: Endpoint; payload: seq[byte])
                      {.gcsafe, closure.} =
    proc (target: Endpoint; payload: seq[byte]) {.gcsafe, closure.} =
      let engine = lookupEngine(target)
      if engine.isNil: return
      if not engine.running: return
      deliverFrame(engine, mkSwimProbeReq, payload)
  let indirectAckImpl: proc (target: Endpoint; payload: seq[byte])
                         {.gcsafe, closure.} =
    proc (target: Endpoint; payload: seq[byte]) {.gcsafe, closure.} =
      let engine = lookupEngine(target)
      if engine.isNil: return
      if not engine.running: return
      deliverFrame(engine, mkSwimProbeAckIndirect, payload)
  let standaloneImpl: proc (target: Endpoint; kind: MessageKind;
                            payload: seq[byte])
                        {.gcsafe, closure.} =
    proc (target: Endpoint; kind: MessageKind;
          payload: seq[byte]) {.gcsafe, closure.} =
      let engine = lookupEngine(target)
      if engine.isNil: return
      if not engine.running: return
      deliverFrame(engine, kind, payload)
  result = SwimTransport(
    sendProbe: probeImpl,
    sendAck: ackImpl,
    sendProbeReq: probeReqImpl,
    sendIndirectAck: indirectAckImpl,
    sendStandalone: standaloneImpl)

# ---------------------------------------------------------------------------
# Engine construction.
# ---------------------------------------------------------------------------

proc newSwimEngine*(selfPeerId: PeerId;
                    selfEndpoint: Endpoint;
                    registry: PeerRegistry;
                    config: SwimConfig;
                    transport: SwimTransport = nil;
                    seedEndpoints: openArray[Endpoint] = @[]):
                    SwimEngine =
  ## Constructs a SWIM engine. The caller wires in a `PeerRegistry`
  ## (typically the same registry the rest of the peer-cache code
  ## uses) so SWIM state + advertisements share a single source of
  ## truth. A `nil` transport is replaced with `newInProcessTransport`,
  ## the default for loopback tests.
  result = SwimEngine(
    selfPeerId: selfPeerId,
    selfEndpoint: selfEndpoint,
    selfIncarnation: 0'u64,
    registry: registry,
    config: config,
    rng: initRand(int64(hash(selfPeerId)) xor int64(getMonoTime().ticks)),
    running: false,
    transport: (if transport.isNil: newInProcessTransport() else: transport),
    seedEndpoints: @seedEndpoints,
    gossip: @[],
    pendingProbes: initTable[PeerId, Future[bool]](),
    dropDirectProbesFrom: initHashSet[PeerId]())

proc transportOf(engine: SwimEngine): SwimTransport =
  engine.transport

proc seedsOf(engine: SwimEngine): seq[Endpoint] =
  engine.seedEndpoints

# ---------------------------------------------------------------------------
# Gossip buffer management.
# ---------------------------------------------------------------------------

proc maxForwardsFor(engine: SwimEngine): int =
  if engine.config.swimGossipMaxForwards > 0:
    return engine.config.swimGossipMaxForwards
  # Dynamic cap, biased higher than `3 * ceil(log2(N))` because the
  # epidemic spread under uniformly random probe selection has a
  # heavy tail at small N. Empirically `8 * ceil(log2(N + 2))` keeps
  # the tail below the convergence budget for 10- to 200-peer
  # clusters without flooding the wire on large clusters.
  let n = engine.registry.peerCount() + 1
  let lg = max(1, int(ceil(log2(float(n + 2)))))
  8 * lg

proc enqueueGossip*(engine: SwimEngine; member: SwimMember) =
  ## Adds (or refreshes) a dissemination update. If the same peer is
  ## already pending with an older incarnation or lower-priority
  ## status, the existing entry is replaced; otherwise the new entry
  ## is appended with `forwardCount = 0`. Same-incarnation/same-status
  ## re-enqueues are treated as "still alive — keep gossiping" and
  ## reset the forward count to zero so the entry continues to spread.
  for i in 0 ..< engine.gossip.len:
    if engine.gossip[i].member.peerId == member.peerId:
      let existing = engine.gossip[i].member
      let supersedes =
        member.incarnation > existing.incarnation or
        (member.incarnation == existing.incarnation and
         ord(member.status) > ord(existing.status))
      let sameAlive =
        member.incarnation == existing.incarnation and
        member.status == existing.status
      if supersedes:
        engine.gossip[i].member = member
        engine.gossip[i].forwardCount = 0
      elif sameAlive:
        engine.gossip[i].forwardCount = 0
      return
  engine.gossip.add(GossipEntry(member: member, forwardCount: 0))

proc nextGossipBatch(engine: SwimEngine): seq[SwimMember] =
  ## Returns up to `swimGossipMessageCap` entries with the lowest
  ## forward counts. Increments each chosen entry's count and retires
  ## any whose count crosses the per-engine max-forwards threshold.
  ##
  ## Retired entries can be re-introduced by `enqueueGossip` if a new
  ## update arrives for the same peer (e.g. an incarnation bump or a
  ## fresh "alive" beacon during continuing dissemination).
  result = @[]
  if engine.gossip.len == 0:
    return
  let cap =
    if engine.config.swimGossipMessageCap > 0:
      engine.config.swimGossipMessageCap
    else: DefaultSwimGossipMessageCap

  # Sort indices by forwardCount, breaking ties with a per-call random
  # shuffle so multiple peers selecting from the same gossip buffer
  # don't converge on the same 32 entries (which would starve the
  # remaining 18 of forwarding bandwidth).
  var indices = newSeq[int](engine.gossip.len)
  for i in 0 ..< indices.len:
    indices[i] = i
  engine.rng.shuffle(indices)
  # Stable insertion sort by forwardCount on the pre-shuffled order:
  # the shuffle is the tie-breaker, the count is the primary key.
  for i in 1 ..< indices.len:
    var j = i
    while j > 0 and
          engine.gossip[indices[j]].forwardCount <
          engine.gossip[indices[j - 1]].forwardCount:
      let tmp = indices[j]
      indices[j] = indices[j - 1]
      indices[j - 1] = tmp
      dec j

  let take = min(cap, indices.len)
  for k in 0 ..< take:
    let idx = indices[k]
    result.add(engine.gossip[idx].member)
    engine.gossip[idx].forwardCount += 1

  # Retire entries whose forward count has exceeded the cap. Retired
  # entries get re-added by the next dissemination round if other
  # peers are still gossiping about the same peer.
  let limit = maxForwardsFor(engine)
  var keep: seq[GossipEntry] = @[]
  for entry in engine.gossip:
    if entry.forwardCount < limit:
      keep.add(entry)
  engine.gossip = keep

# ---------------------------------------------------------------------------
# Applying incoming gossip / dissemination updates.
# ---------------------------------------------------------------------------

proc bumpSelfIncarnation(engine: SwimEngine) =
  engine.selfIncarnation += 1
  let refute = SwimMember(
    peerId: engine.selfPeerId,
    endpoint: engine.selfEndpoint,
    status: smsAlive,
    incarnation: engine.selfIncarnation)
  engine.enqueueGossip(refute)

proc applyMemberUpdate*(engine: SwimEngine; member: SwimMember) =
  ## Folds a single dissemination update into the local registry.
  ## Self-refutes when the update marks us as suspected. Forwards
  ## updates back into the engine's gossip buffer so they continue to
  ## propagate epidemically.
  if member.peerId == engine.selfPeerId:
    if member.status == smsSuspected and
       member.incarnation >= engine.selfIncarnation:
      bumpSelfIncarnation(engine)
    elif member.status == smsConfirmed and
         member.incarnation >= engine.selfIncarnation:
      bumpSelfIncarnation(engine)
    return

  if not engine.registry.hasPeer(member.peerId):
    if member.status == smsAlive:
      engine.registry.addPeer(member.peerId, member.endpoint)
      var entry = engine.registry.entries[member.peerId]
      entry.swimStatus = smsAlive
      entry.swimIncarnation = member.incarnation
      entry.swimStatusSince = getMonoTime()
      engine.registry.entries[member.peerId] = entry
      engine.enqueueGossip(member)
    return

  var entry = engine.registry.entries[member.peerId]
  let isNewerIncarnation = member.incarnation > entry.swimIncarnation
  let isSameIncarnation = member.incarnation == entry.swimIncarnation
  let shouldUpdate =
    isNewerIncarnation or
    (isSameIncarnation and ord(member.status) > ord(entry.swimStatus)) or
    (isSameIncarnation and entry.swimStatus == smsConfirmed and
     member.status == smsAlive)
  if not shouldUpdate:
    # Even if we don't change registry state, re-enqueue the entry for
    # gossip so that knowledge about this peer keeps flowing through
    # the cluster. Without this, an alive member's record is retired
    # from every peer's buffer after a finite number of forwards, and
    # a still-unconverged peer would never learn about the member.
    engine.enqueueGossip(member)
    return
  let priorStatus = entry.swimStatus
  entry.swimIncarnation = member.incarnation
  entry.swimStatus = member.status
  entry.endpoint = member.endpoint
  if priorStatus != member.status:
    entry.swimStatusSince = getMonoTime()
  engine.registry.entries[member.peerId] = entry
  engine.enqueueGossip(member)

proc applyGossip*(engine: SwimEngine; gossip: seq[SwimMember]) =
  for member in gossip:
    applyMemberUpdate(engine, member)

# ---------------------------------------------------------------------------
# Outbound builders.
# ---------------------------------------------------------------------------

proc selfMember(engine: SwimEngine; status: SwimMemberStatus = smsAlive):
    SwimMember =
  SwimMember(
    peerId: engine.selfPeerId,
    endpoint: engine.selfEndpoint,
    status: status,
    incarnation: engine.selfIncarnation)

proc sendProbe(engine: SwimEngine; target: Endpoint;
               targetPeerId: PeerId) =
  let gossip = engine.nextGossipBatch()
  let probe = SwimProbe(
    sourcePeerId: engine.selfPeerId,
    sourceEndpoint: engine.selfEndpoint,
    targetPeerId: targetPeerId,
    sourceIncarnation: engine.selfIncarnation,
    gossip: gossip)
  let payload = encodeSwimProbe(probe)
  let transport = transportOf(engine)
  transport.sendProbe(target, payload)
  inc engine.sentDirectProbeCount
  engine.piggybackedDisseminationCount += gossip.len

proc sendAck(engine: SwimEngine; target: Endpoint) =
  let gossip = engine.nextGossipBatch()
  let ack = SwimAck(
    responderPeerId: engine.selfPeerId,
    responderEndpoint: engine.selfEndpoint,
    responderIncarnation: engine.selfIncarnation,
    gossip: gossip)
  let payload = encodeSwimAck(ack)
  let transport = transportOf(engine)
  transport.sendAck(target, payload)
  inc engine.sentAckCount
  engine.piggybackedDisseminationCount += gossip.len

proc sendProbeReq(engine: SwimEngine; intermediary: Endpoint;
                  targetPeerId: PeerId; targetEndpoint: Endpoint) =
  let gossip = engine.nextGossipBatch()
  let req = SwimProbeReq(
    initiatorPeerId: engine.selfPeerId,
    initiatorEndpoint: engine.selfEndpoint,
    targetPeerId: targetPeerId,
    targetEndpoint: targetEndpoint,
    gossip: gossip)
  let payload = encodeSwimProbeReq(req)
  let transport = transportOf(engine)
  transport.sendProbeReq(intermediary, payload)
  inc engine.sentIndirectProbeReqCount
  engine.piggybackedDisseminationCount += gossip.len

proc sendIndirectAck(engine: SwimEngine; target: Endpoint;
                     initiatorPeerId: PeerId; targetPeerId: PeerId;
                     targetIncarnation: uint64) =
  let gossip = engine.nextGossipBatch()
  let ack = SwimProbeAckIndirect(
    initiatorPeerId: initiatorPeerId,
    targetPeerId: targetPeerId,
    intermediaryPeerId: engine.selfPeerId,
    targetIncarnation: targetIncarnation,
    gossip: gossip)
  let payload = encodeSwimProbeAckIndirect(ack)
  let transport = transportOf(engine)
  transport.sendIndirectAck(target, payload)
  inc engine.sentIndirectAckCount
  engine.piggybackedDisseminationCount += gossip.len

# ---------------------------------------------------------------------------
# Incoming handlers.
# ---------------------------------------------------------------------------

proc handleProbe*(engine: SwimEngine; msg: SwimProbe) =
  if not engine.running:
    return
  if msg.sourcePeerId in engine.dropDirectProbesFrom:
    # Test seam: pretend the probe never arrived.
    return
  inc engine.receivedDirectProbeCount
  # Learn the source's endpoint if we don't know about them yet — and
  # enqueue a gossip update so we tell every peer we probe about this
  # new member.
  let isNew = not engine.registry.hasPeer(msg.sourcePeerId)
  if isNew:
    engine.registry.addPeer(msg.sourcePeerId, msg.sourceEndpoint)
    var entry = engine.registry.entries[msg.sourcePeerId]
    entry.swimStatus = smsAlive
    entry.swimIncarnation = msg.sourceIncarnation
    entry.swimStatusSince = getMonoTime()
    engine.registry.entries[msg.sourcePeerId] = entry
    engine.enqueueGossip(SwimMember(
      peerId: msg.sourcePeerId,
      endpoint: msg.sourceEndpoint,
      status: smsAlive,
      incarnation: msg.sourceIncarnation))
  engine.registry.updateLastSeen(msg.sourcePeerId)
  applyGossip(engine, msg.gossip)
  sendAck(engine, msg.sourceEndpoint)

proc handleAck*(engine: SwimEngine; msg: SwimAck) =
  if not engine.running:
    return
  inc engine.receivedAckCount
  let isNew = not engine.registry.hasPeer(msg.responderPeerId)
  if isNew:
    engine.registry.addPeer(msg.responderPeerId, msg.responderEndpoint)
  var entry = engine.registry.entries[msg.responderPeerId]
  entry.swimStatus = smsAlive
  entry.swimIncarnation =
    max(entry.swimIncarnation, msg.responderIncarnation)
  entry.swimStatusSince = getMonoTime()
  entry.lastSeen = getMonoTime()
  engine.registry.entries[msg.responderPeerId] = entry
  if isNew:
    engine.enqueueGossip(SwimMember(
      peerId: msg.responderPeerId,
      endpoint: msg.responderEndpoint,
      status: smsAlive,
      incarnation: msg.responderIncarnation))
  applyGossip(engine, msg.gossip)
  if engine.pendingProbes.hasKey(msg.responderPeerId):
    let fut = engine.pendingProbes[msg.responderPeerId]
    engine.pendingProbes.del(msg.responderPeerId)
    if not fut.finished:
      fut.complete(true)

proc relayProbe(engine: SwimEngine;
                req: SwimProbeReq) {.async.} =
  ## Per the SWIM paper §3, the intermediary issues a fresh direct
  ## probe to the target and forwards the resulting ack back to the
  ## initiator. We open a per-request future on the engine's
  ## `pendingProbes` table, send a `mkSwimProbe` to the target, and
  ## only forward the indirect ack to the initiator when the target's
  ## ack actually lands. On in-process loopback the chain is
  ## synchronous; on a real network the same await would translate to
  ## "wait up to the direct-probe timeout for an ack."
  let fut = newFuture[bool]("swim.relayProbe")
  engine.pendingProbes[req.targetPeerId] = fut
  sendProbe(engine, req.targetEndpoint, req.targetPeerId)
  let directTimeout = max(1, engine.config.swimProbeTimeoutMs)
  let ok = await withTimeout(fut, directTimeout)
  if engine.pendingProbes.hasKey(req.targetPeerId) and
     engine.pendingProbes[req.targetPeerId] == fut:
    engine.pendingProbes.del(req.targetPeerId)
  if not ok or not fut.read():
    return
  if not engine.registry.hasPeer(req.targetPeerId):
    return
  let entry = engine.registry.entries[req.targetPeerId]
  if entry.swimStatus != smsAlive:
    return
  sendIndirectAck(engine, req.initiatorEndpoint,
                  req.initiatorPeerId, req.targetPeerId,
                  entry.swimIncarnation)

proc handleProbeReq*(engine: SwimEngine; msg: SwimProbeReq) =
  if not engine.running:
    return
  inc engine.receivedProbeReqCount
  if not engine.registry.hasPeer(msg.initiatorPeerId):
    engine.registry.addPeer(msg.initiatorPeerId, msg.initiatorEndpoint)
  applyGossip(engine, msg.gossip)
  asyncCheck relayProbe(engine, msg)

proc handleIndirectAck*(engine: SwimEngine;
                       msg: SwimProbeAckIndirect) =
  if not engine.running:
    return
  inc engine.receivedIndirectAckCount
  applyGossip(engine, msg.gossip)
  if engine.registry.hasPeer(msg.targetPeerId):
    var entry = engine.registry.entries[msg.targetPeerId]
    entry.swimStatus = smsAlive
    entry.swimIncarnation = max(entry.swimIncarnation, msg.targetIncarnation)
    entry.swimStatusSince = getMonoTime()
    entry.lastSeen = getMonoTime()
    engine.registry.entries[msg.targetPeerId] = entry
  if engine.pendingProbes.hasKey(msg.targetPeerId):
    let fut = engine.pendingProbes[msg.targetPeerId]
    engine.pendingProbes.del(msg.targetPeerId)
    if not fut.finished:
      fut.complete(true)

proc handleSuspect*(engine: SwimEngine; msg: SwimMember) =
  if not engine.running:
    return
  applyMemberUpdate(engine, msg)

proc handleConfirm*(engine: SwimEngine; msg: SwimMember) =
  if not engine.running:
    return
  applyMemberUpdate(engine, msg)

proc handleRefute*(engine: SwimEngine; msg: SwimMember) =
  if not engine.running:
    return
  applyMemberUpdate(engine, msg)

# ---------------------------------------------------------------------------
# Test seam: inject an incoming suspect as if it had arrived via gossip.
# ---------------------------------------------------------------------------

proc injectIncomingSuspect*(engine: SwimEngine; member: SwimMember) =
  ## Test-only seam. Applies a fake `mkSwimSuspect` to the engine's
  ## dissemination path, as if it had arrived piggybacked on a probe.
  ## The verification test for the incarnation-self-refute behaviour
  ## uses this to assert that a peer marked suspected by a remote
  ## bumps its own incarnation on receipt.
  applyMemberUpdate(engine, member)

# ---------------------------------------------------------------------------
# Periodic scheduler.
# ---------------------------------------------------------------------------

proc agedTransitions(engine: SwimEngine) =
  let now = getMonoTime()
  var toRemove: seq[PeerId] = @[]
  let suspectMs = max(1, engine.config.swimSuspectTimeoutMs)
  let confirmMs = max(1, engine.config.swimConfirmTimeoutMs)
  for peerId in toSeq(engine.registry.entries.keys):
    var entry = engine.registry.entries[peerId]
    if entry.swimStatus == smsSuspected:
      let elapsed = (now - entry.swimStatusSince).inMilliseconds.int
      if elapsed >= suspectMs:
        entry.swimStatus = smsConfirmed
        entry.swimStatusSince = now
        engine.registry.entries[peerId] = entry
        inc engine.suspectTransitionCount
        engine.enqueueGossip(SwimMember(
          peerId: peerId,
          endpoint: entry.endpoint,
          status: smsConfirmed,
          incarnation: entry.swimIncarnation))
    elif entry.swimStatus == smsConfirmed:
      let elapsed = (now - entry.swimStatusSince).inMilliseconds.int
      if elapsed >= confirmMs:
        toRemove.add(peerId)
  for peerId in toRemove:
    engine.registry.removePeer(peerId)

proc chooseRandomMember(engine: SwimEngine; exclude: openArray[PeerId];
                       suspected: var bool): PeerId =
  ## Picks a random `Alive` member (preferred) or `Suspected` member
  ## (fallback). Sets `suspected = true` if the choice was a
  ## `Suspected` peer. Returns a zeroed `PeerId` if no candidates
  ## exist.
  var alive: seq[PeerId] = @[]
  var susp: seq[PeerId] = @[]
  for peerId, entry in engine.registry.entries.pairs:
    if peerId in exclude: continue
    if entry.swimStatus == smsAlive:
      alive.add(peerId)
    elif entry.swimStatus == smsSuspected:
      susp.add(peerId)
  if alive.len > 0:
    suspected = false
    return alive[engine.rng.rand(alive.len - 1)]
  if susp.len > 0:
    suspected = true
    return susp[engine.rng.rand(susp.len - 1)]
  var zero: array[32, byte]
  return peerIdFromBytes(zero)

proc isZeroPeerId(peerId: PeerId): bool =
  let raw = bytes(peerId)
  for b in raw:
    if b != 0'u8: return false
  true

proc runIndirectProbe(engine: SwimEngine; targetPeerId: PeerId;
                      targetEndpoint: Endpoint) {.async.} =
  let k = max(1, engine.config.swimIndirectProbeCount)
  # Pick K random members other than the target.
  var candidates: seq[PeerId] = @[]
  for peerId, entry in engine.registry.entries.pairs:
    if peerId == targetPeerId: continue
    if entry.swimStatus != smsAlive: continue
    candidates.add(peerId)
  engine.rng.shuffle(candidates)
  let take = min(k, candidates.len)
  for i in 0 ..< take:
    let intermediary = candidates[i]
    let endpoint = engine.registry.endpointOf(intermediary)
    sendProbeReq(engine, endpoint, targetPeerId, targetEndpoint)
  # Wait for the suspect window (minus what's already elapsed against
  # the direct probe timeout).
  let suspectWindow = max(engine.config.swimSuspectTimeoutMs div 2,
                          engine.config.swimProbeTimeoutMs * 3)
  await sleepAsync(suspectWindow)
  if not engine.pendingProbes.hasKey(targetPeerId):
    return
  let fut = engine.pendingProbes[targetPeerId]
  if fut.finished:
    return
  engine.pendingProbes.del(targetPeerId)
  fut.complete(false)

proc markSuspected(engine: SwimEngine; targetPeerId: PeerId;
                   targetEndpoint: Endpoint) =
  if not engine.registry.hasPeer(targetPeerId):
    return
  inc engine.markedSuspectedCount
  var entry = engine.registry.entries[targetPeerId]
  if entry.swimStatus == smsAlive:
    entry.swimStatus = smsSuspected
    entry.swimStatusSince = getMonoTime()
    engine.registry.entries[targetPeerId] = entry
  engine.enqueueGossip(SwimMember(
    peerId: targetPeerId,
    endpoint: targetEndpoint,
    status: smsSuspected,
    incarnation: entry.swimIncarnation))

proc probeOnce(engine: SwimEngine) {.async.} =
  agedTransitions(engine)
  var suspected: bool
  let targetPeerId = chooseRandomMember(engine, @[engine.selfPeerId], suspected)
  if isZeroPeerId(targetPeerId):
    return
  let targetEndpoint = engine.registry.endpointOf(targetPeerId)
  let fut = newFuture[bool]("swim.probe")
  engine.pendingProbes[targetPeerId] = fut
  sendProbe(engine, targetEndpoint, targetPeerId)

  let directTimeout = max(1, engine.config.swimProbeTimeoutMs)
  let directOk = await withTimeout(fut, directTimeout)
  if directOk:
    let ackArrived = fut.read()
    if ackArrived:
      return
  if not engine.pendingProbes.hasKey(targetPeerId):
    return
  # Initiate indirect probes; the relay will complete the future.
  await runIndirectProbe(engine, targetPeerId, targetEndpoint)
  if engine.pendingProbes.hasKey(targetPeerId):
    let f2 = engine.pendingProbes[targetPeerId]
    engine.pendingProbes.del(targetPeerId)
    if not f2.finished:
      f2.complete(false)
  if fut.finished and fut.read():
    return
  markSuspected(engine, targetPeerId, targetEndpoint)

proc periodLoop*(engine: SwimEngine) {.async.} =
  let period = max(1, engine.config.swimProbePeriodMs)
  while engine.running:
    try:
      await probeOnce(engine)
    except CatchableError:
      discard
    await sleepAsync(period)

# ---------------------------------------------------------------------------
# Bootstrap.
# ---------------------------------------------------------------------------

proc bootstrap*(engine: SwimEngine) {.async.} =
  ## Sends an initial probe to every seed endpoint so the joining peer
  ## populates its membership table from the seed's ack gossip.
  for seed in seedsOf(engine):
    if seed == engine.selfEndpoint: continue
    # The seed may not be in our registry yet; we still send the probe
    # directly to the endpoint. The ack handler will register the seed
    # under its true peerId.
    let probe = SwimProbe(
      sourcePeerId: engine.selfPeerId,
      sourceEndpoint: engine.selfEndpoint,
      targetPeerId: engine.selfPeerId,  # unknown — use self as a sentinel
      sourceIncarnation: engine.selfIncarnation,
      gossip: @[selfMember(engine)])
    let payload = encodeSwimProbe(probe)
    transportOf(engine).sendProbe(seed, payload)
    inc engine.sentDirectProbeCount

proc start*(engine: SwimEngine) =
  ## Starts the engine: registers in the in-process directory, fires
  ## off bootstrap probes to every configured seed, then spawns the
  ## periodic probe loop.
  if engine.running:
    return
  engine.running = true
  # Seed the gossip buffer with our own "alive" record so the very
  # first probe ack — and every probe-ack until we've spread to the
  # configured forward-count limit — teaches the receiver about us.
  engine.enqueueGossip(selfMember(engine))
  registerEngineInDirectory(engine)
  asyncCheck bootstrap(engine)
  asyncCheck periodLoop(engine)

proc stop*(engine: SwimEngine) =
  if not engine.running:
    return
  engine.running = false
  unregisterEngineFromDirectory(engine)
  # Cancel pending probes by completing them as failed.
  for peerId, fut in engine.pendingProbes.pairs:
    if not fut.finished:
      fut.complete(false)
  engine.pendingProbes.clear()

# ---------------------------------------------------------------------------
# Convenience accessors used by tests.
# ---------------------------------------------------------------------------

proc aliveMembers*(engine: SwimEngine): seq[PeerId] =
  ## Returns the peer IDs the engine currently considers `Alive`.
  ## Does not include the engine's own peerId.
  result = @[]
  for peerId, entry in engine.registry.entries.pairs:
    if entry.swimStatus == smsAlive:
      result.add(peerId)

proc suspectedMembers*(engine: SwimEngine): seq[PeerId] =
  result = @[]
  for peerId, entry in engine.registry.entries.pairs:
    if entry.swimStatus == smsSuspected:
      result.add(peerId)

proc confirmedMembers*(engine: SwimEngine): seq[PeerId] =
  result = @[]
  for peerId, entry in engine.registry.entries.pairs:
    if entry.swimStatus == smsConfirmed:
      result.add(peerId)
