## Distributed-Execution M7, threat model G18 (FLOW-2: "auditable per
## message, with the record reaching the Evidence zone"): per-message audit
## holds under the most load the gate admits, and refusals cannot be turned
## into an unbounded record stream.
##
## Before the fix one caller could have 8000 frames/s admitted across the
## content and memo planes while the sink records 4000 per second per sender
## and refused a whole batch beyond that; and every unauthorized frame became
## a record. Now:
##
##   * the arithmetic holds statically (`auditBudgetIsConsistent`): the
##     node's GLOBAL admission budget, its outbound budget, its refusal-record
##     budget and a reserve fit the sink's per-sender rate;
##   * on a synthetic clock, twenty callers together offer five times the
##     node-wide budget: exactly the budget is admitted, the rest is shed
##     as `rate` refusals naming the admission budget;
##   * end to end, over real TLS: four peers, each offering blob fetches
##     well under its own per-caller limit (1500 each against a per-caller
##     burst of 3000), together offer 6000 — half again the node-wide burst.
##     The receiver's clock is held still for the flood (the server's clock
##     seam), so its budget does not refill and the outcome does not depend
##     on how fast this host can send: at most the node-wide burst is
##     admitted, the excess is refused `rate` (only the node-wide budget can
##     refuse here), every admitted frame has its audit record at the sink
##     (counted exactly) and nothing was dropped;
##   * one of those peers floods frames it is not authorized to send: far more
##     refusals happen than are recorded one by one, the rest are folded into
##     summary records (`suppressed=N`), and individual + folded = all of
##     them.
##
## MOCK POLICY — none: production hosts over real TLS, the real sink binary.

import std/[asyncdispatch, options, os, strutils, tables, tempfiles, times,
            unittest]

import repro_peer_cache
import repro_cli_support/peer_cache_wiring

import ../../repro_peer_cache/tests/m7_test_pki

proc tickFor(hosts: openArray[PeerCacheHost]; ms: int) =
  let deadline = epochTime() + ms.float / 1000.0
  while epochTime() < deadline:
    for h in hosts: h.tick(5)

suite "Distributed-Execution M7: audit holds at the gate's rate (G18)":

  test "the budgets fit the sink":
    check auditBudgetIsConsistent()
    check GateAdmittedPerSecond + OutboundAdmittedPerSecond +
      GateRefusalRecordsPerSecond + AuditReserveRecordsPerSecond <=
      SinkRecordsPerSecondPerSender

  test "the node-wide admission budget holds on a synthetic clock":
    # Twenty authenticated callers, each offering blob fetches BELOW its own
    # per-caller limit (500/s against 1500/s), together 10000/s for five
    # simulated seconds. The gate must admit exactly what the global budget
    # allows (its burst plus its rate times the time) and shed the rest as
    # `rate` refusals naming the admission budget.
    let gate = newReceiverGate()
    const callers = 20
    const durationMs = 5_000
    const baseMs = 1_000_000'i64
    var ids: seq[CallerIdentity]
    for i in 0 ..< callers:
      var raw: array[32, byte]
      raw[0] = byte(i + 1)
      ids.add CallerIdentity(authenticated: true, hostId: PeerId(raw),
        leafRole: lrDaemon, address: "10.0.0." & $(i + 1), helloDone: true)
    var admitted, budgetRefused, otherRefused = 0
    for t in 0 ..< durationMs:
      if t mod 2 != 0: continue          # each caller: one frame per 2 ms
      for c in ids:
        let d = gate.decide(c, uint16(ord(mkFetchRequest)), 32,
          baseMs + int64(t))
        if d.allowed: inc admitted
        elif d.refusal == rcRate and "admission budget" in d.reason:
          inc budgetRefused
        else: inc otherRefused
    let offered = callers * (durationMs div 2)
    let bound = GateAdmittedBurst +
      GateAdmittedPerSecond * (float(durationMs) / 1000.0)
    checkpoint("offered " & $offered & ", admitted " & $admitted &
      ", shed at the budget " & $budgetRefused & ", other " & $otherRefused &
      ", bound " & $bound)
    check otherRefused == 0               # no per-caller limit was reached
    check float(offered) > bound          # the load really exceeds the budget
    check float(admitted) <= bound
    check float(admitted) >= bound - GateAdmittedPerSecond * 0.01
    check budgetRefused == offered - admitted

  test "every admitted frame is audited; refusals are bounded and accounted":
    let base = createTempDir("m7-g18-", "")
    var a = newTestNode(base, "a")
    var senders: seq[TestNode]
    for name in ["b", "c", "d", "e"]:
      senders.add newTestNode(base, name)
    mutualTrust(@[a] & senders)
    var sink = prepareEvidenceSink(base)
    sink.acceptsFrom(a)
    for n in senders: sink.acceptsFrom(n)
    sink.startEvidenceSink()
    var hostA: PeerCacheHost
    var hosts: seq[PeerCacheHost]
    defer:
      for h in hosts: h.stop()
      if not hostA.isNil: hostA.stop()
      stopEvidenceSink(sink)
      removeDir(base)
    hostA = startPeerCacheHost(tlsConfig(a, evidence = sink.endpoint,
      heartbeatMs = 1000), a.identity.hostId, cacheRoot = base / "a-cache")
    for n in senders:
      hosts.add startPeerCacheHost(tlsConfig(n, seeds = @[initEndpoint(
        "127.0.0.1", hostA.actualPort)]), n.identity.hostId,
        cacheRoot = base / (n.name & "-cache"))
    let aId = a.identity.hostId
    let bId = senders[0].identity.hostId
    let hostB = hosts[0]
    for h in hosts:
      check h.client.isConnected(aId)
    tickFor(@[hostA] & hosts, 300)
    # -- Flood: four distinct callers, each under its own limit, together
    # over the node-wide budget. The receiver's clock stands still for the
    # flood, so no budget refills: whatever this host's send rate, at most
    # the node-wide BURST can be admitted, and each caller's 1500 frames
    # stay under its per-caller burst (3000), so a per-caller limit can
    # never be what refuses them.
    const perSender = 1_500
    let fetchSpec = Vocabulary[bmBlobFetch]
    check float(perSender) < fetchSpec.burst
    check float(perSender * 4) > GateAdmittedBurst * 1.25
    let fetchesBefore = hostA.server.metrics.fetchRequestsTotal
    let rateBefore = hostA.server.gate.refusedCount[rcRate]
    let frozen = int64(epochTime() * 1000.0)
    hostA.server.clock = proc(): int64 {.gcsafe, closure.} = frozen
    var sent = 0
    var probe: array[32, byte]
    let start = epochTime()
    for k in 0 ..< perSender:
      for j, h in hosts:
        probe[0] = byte(k and 0xff)
        probe[1] = byte((k shr 8) and 0xff)
        probe[2] = byte(j + 1)
        waitFor h.client.sendRawFrameForTesting(aId, mkFetchRequest,
          encodeFetchRequest(FetchRequest(digest: blobDigestFromBytes(probe))),
          expectReply = true)
        inc sent
      if k mod 16 == 15:
        tickFor([hostA], 2)
    # Let the receiver read everything that was sent before the clock moves.
    var quiet = 0
    var lastSeen = -1
    while quiet < 20 and epochTime() - start < 120.0:
      tickFor(@[hostA] & hosts, 50)
      let seen = int(hostA.server.metrics.fetchRequestsTotal) +
        hostA.server.gate.refusedCount[rcRate]
      if seen == lastSeen: inc quiet else: quiet = 0
      lastSeen = seen
    hostA.server.clock = nil
    let elapsed = epochTime() - start
    let admitted = int(hostA.server.metrics.fetchRequestsTotal - fetchesBefore)
    let rateRefused = hostA.server.gate.refusedCount[rcRate] - rateBefore
    checkpoint("sent " & $sent & ", admitted " & $admitted &
      ", refused (rate) " & $rateRefused & " in " & $elapsed & " s")
    check sent == 4 * perSender
    # The node-wide budget held: no more than its burst got through…
    check float(admitted) <= GateAdmittedBurst
    # …it really was the budget that bit (not a send that went missing):
    # every fetch was either admitted or refused for rate…
    check rateRefused > 0
    check admitted + rateRefused >= sent
    # …and the budget was used, not starved by something else.
    check float(admitted) >= GateAdmittedBurst * 0.75
    check hostA.appender.drain(30_000)
    check hostA.appender.dropped == 0
    # Every admitted blob fetch has its audit record at the sink.
    var senderIds: seq[string]
    for n in senders: senderIds.add $n.identity.hostId
    var audited = 0
    for e in sink.sinkEntries():
      if e.kind == ekRecord and e.record.category == ecAudit and
          e.senderHostId == aId and e.record.field("peer") in senderIds and
          e.record.trigger == "blob-fetch":
        inc audited
    let admittedFetches = hostA.server.metrics.fetchRequestsTotal
    checkpoint("audited blob fetches " & $audited & ", served " &
      $admittedFetches)
    check audited == int(admittedFetches)
    check audited > 0
    for h in hosts[1 .. ^1]: h.stop()
    hosts.setLen(1)
    # Leave the budget's refill window behind before the next flood.
    tickFor([hostA, hostB], 2500)
    if not hostB.client.isConnected(aId):
      discard waitFor hostB.client.connectKnownPeers()
    check hostB.client.isConnected(aId)

    # -- Flood: frames B may not send (ReachGoal needs the orchestrator role)
    let refusedBefore = hostA.server.gate.refusedCount[rcUnauthorized]
    let suppressedBefore = hostA.server.gate.refusalsSuppressed
    let goal = newSeq[byte](64)
    var refusalsSent = 0
    let start2 = epochTime()
    while epochTime() - start2 < 3.0:
      for i in 0 ..< 32:
        try:
          waitFor hostB.client.sendRawFrameForTesting(aId, mkReachGoalRequest,
            goal)
          inc refusalsSent
        except CatchableError:
          # B's own outbound gate may close the connection on the flood of
          # refusal notices it gets back (its budget is finite too): re-dial.
          discard waitFor hostB.client.connectKnownPeers()
      tickFor([hostA], 2)
    tickFor([hostA, hostB], 1500)
    check hostA.appender.drain(30_000)
    let refused = hostA.server.gate.refusedCount[rcUnauthorized] - refusedBefore
    var individual, folded = 0
    for e in sink.sinkEntries():
      if e.kind == ekRecord and e.record.trigger == "frame-refused" and
          e.senderHostId == aId and e.record.field("peer") == $bId and
          e.record.field("refusal") == "unauthorized":
        let s = e.record.field("suppressed")
        if s.len > 0: folded += parseInt(s)
        else: inc individual
    let suppressed = hostA.server.gate.refusalsSuppressed - suppressedBefore
    checkpoint("refused " & $refused & ": recorded one by one " & $individual &
      ", folded " & $folded & " (gate suppressed " & $suppressed & ")")
    check refused > 200
    check float(individual) <= RefusalRecordsBurst + 6.0 * RefusalRecordsPerSecond
    # Every refusal is accounted for: individually, or in a summary — the
    # last summary may still be pending at the gate.
    check individual + folded <= refused
    check refused - (individual + folded) <= suppressed
    check folded > 0
