## Peer-Cache-Scale M0 verification: 50-peer SWIM convergence.
##
## Spawns 50 in-process SWIM peers, each seeded with a small random
## subset of ~5 others, and asserts that every peer's `aliveMembers`
## count reaches 49 (all the others) within 10 protocol periods — the
## milestone's "10 periods at default 1 s = 10 s" budget.
##
## THE TEST DRIVES THE PROTOCOL PERIODS ITSELF. The claim is stated in
## protocol periods, so the case runs them in lock step: in each period
## every peer, in index order, runs one `runProtocolPeriod` (age
## suspicions, probe the next member, take the ack and its piggybacked
## gossip). Nothing waits on a timer, and the spawn seed fixes every
## random choice (seed lists, probe order), so the case makes the same
## choices and converges after the same number of periods on every run,
## on an idle host and on one running a full suite beside it.
##
## It used to start each peer's timer-driven `periodLoop` (100 ms
## periods) and count the periods the engines had started. That count
## was right, but what happened inside a period was not fixed: each
## engine seeded its choices from the monotonic clock, and the order in
## which the peers' period timers fired — which decides how far gossip
## travels within one period — followed the host's scheduling. Full run
## 53 (load average 150–240) reported 11 periods.
##
## The production timer loop is `periodLoop` = `runProtocolPeriod` +
## `sleepAsync`; the other SWIM cases still run it.
##
## MOCK POLICY — the peers talk over `newInProcessTransport`, the
## in-process transport `loopback.nim` provides (Peer-Cache-Scale M0
## "in-process transport only"). The engine, codec and dissemination are
## the production ones; only the kernel socket is absent. The transport
## delivers a probe and its ack synchronously, so no probe times out and
## no peer is ever suspected; the case checks that too.

import std/[asyncdispatch, unittest]

import repro_peer_cache

const
  NumPeers = 50
  SeedsPerPeer = 5
  MaxPeriods = 10
  ObservedPeriods = 40
    ## How long the case keeps running a cluster that missed the target,
    ## so the failure report says when (or whether) it converged.

proc allConverged(peers: seq[LoopbackPeer]): bool =
  for peer in peers:
    if peer.swim.aliveMembers().len < NumPeers - 1:
      return false
  true

suite "peer-cache SWIM 50-peer convergence":
  test "50 peers converge within 10 protocol periods":
    var cfg = defaultSwimConfig()
    cfg.swimProbeTimeoutMs = 25
    cfg.swimGossipMessageCap = 32
    let peers = spawnLoopbackSwimPeers(
      NumPeers, cfg, seedsPerPeer = SeedsPerPeer)
    try:
      startLoopbackSwimPeers(peers, runPeriodTimers = false)
      var periods = 0
      while not allConverged(peers) and periods < ObservedPeriods:
        inc periods
        for peer in peers:
          waitFor peer.swim.runProtocolPeriod()
      let converged = allConverged(peers)
      echo "SWIM convergence: ", (if converged: "converged" else: "NOT converged"),
           " after ", periods, " protocol periods"
      if not converged:
        for i, peer in peers:
          let count = peer.swim.aliveMembers().len
          if count < NumPeers - 1:
            echo "  peer ", i, " sees ", count, "/", NumPeers - 1
      var suspicions = 0
      for peer in peers:
        check peer.swim.protocolPeriodCount == periods
        suspicions += peer.swim.markedSuspectedCount
      check suspicions == 0
      check converged
      check periods <= MaxPeriods
    finally:
      shutdownLoopbackSwimPeers(peers)
      # Drain the dispatcher so the probe-timeout timers the periods
      # armed fire and release cleanly.
      for _ in 0 ..< 10:
        try: poll(0) except ValueError: discard
