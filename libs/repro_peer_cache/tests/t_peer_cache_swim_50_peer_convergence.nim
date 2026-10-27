## Peer-Cache-Scale M0 verification: 50-peer SWIM convergence.
##
## Spawns 50 in-process SWIM peers, each seeded with a small random
## subset of ~5 others. Drives the async dispatcher and asserts that
## every peer's `aliveMembers` count reaches 49 (all the others) within
## 10 protocol periods. The protocol period is shortened to 100 ms so
## the wall-clock cost of the test stays around a second; the
## convergence metric — number of periods — matches the milestone's
## "10 periods at default 1 s = 10 s" budget.
##
## PERIODS ARE COUNTED, NOT INFERRED FROM THE CLOCK. Each engine counts
## the protocol periods its `periodLoop` has started
## (`protocolPeriodCount`), and the assertion is on that count. The test
## used to divide elapsed wall-clock time by the configured period and
## give it 500 ms of slack. A period's real length is the configured
## sleep PLUS the probe and the dispatcher's scheduling delay, so on a
## host running a full suite beside this case (load average above 100)
## fewer periods fitted into the same wall-clock budget, and the case
## failed with the cluster still converging on schedule in protocol
## terms (full run 38). The wall-clock limit below only stops a cluster
## that has stopped making progress altogether.
##
## MOCK POLICY — the peers talk over `newInProcessTransport`, the
## in-process transport `loopback.nim` provides (Peer-Cache-Scale M0
## "in-process transport only"). The engine, codec and dissemination are
## the production ones; only the kernel socket is absent.

import std/[asyncdispatch, monotimes, os, times, unittest]

import repro_peer_cache

const
  NumPeers = 50
  SeedsPerPeer = 5
  ProbePeriodMs = 100
    ## Test uses a tighter probe period than the spec default (1000 ms)
    ## so the wall-clock cost stays around a second. The convergence
    ## metric the milestone targets — the *number* of protocol periods —
    ## is independent of the per-period wall-clock duration.
  MaxPeriods = 10
  StallLimitMs = 60_000
    ## Wall-clock bound on the whole wait, there only so a cluster that
    ## stops running periods cannot hang the case. It is not the
    ## convergence budget; `MaxPeriods` is.
  PollIntervalMs = 10

proc allConverged(peers: seq[LoopbackPeer]): bool =
  for peer in peers:
    if peer.swim.aliveMembers().len < NumPeers - 1:
      return false
  true

proc periodsRun(peers: seq[LoopbackPeer]): tuple[least, most: int] =
  ## The fewest and the most protocol periods any peer has started.
  result = (least: high(int), most: 0)
  for peer in peers:
    let count = peer.swim.protocolPeriodCount
    result.least = min(result.least, count)
    result.most = max(result.most, count)

suite "peer-cache SWIM 50-peer convergence":
  test "50 peers converge within 10 protocol periods":
    var cfg = defaultSwimConfig()
    cfg.swimProbePeriodMs = ProbePeriodMs
    cfg.swimProbeTimeoutMs = 25
    cfg.swimGossipMessageCap = 32
    let peers = spawnLoopbackSwimPeers(
      NumPeers, cfg, seedsPerPeer = SeedsPerPeer)
    try:
      let started = getMonoTime()
      startLoopbackSwimPeers(peers)
      # Keep driving until the cluster converges, or until EVERY peer has
      # started more than `MaxPeriods` periods without it converging —
      # by then the target is missed whatever happens next.
      while not allConverged(peers) and
            periodsRun(peers).least <= MaxPeriods and
            (getMonoTime() - started).inMilliseconds < StallLimitMs:
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
      let converged = allConverged(peers)
      let periods = periodsRun(peers)
      let actualMs = (getMonoTime() - started).inMilliseconds
      echo "SWIM convergence: ", (if converged: "converged" else: "NOT converged"),
           " after ", periods.most, " protocol periods (fewest started by any",
           " peer: ", periods.least, "), ", actualMs, " ms wall-clock at ",
           ProbePeriodMs, " ms per period"
      if not converged:
        for i, peer in peers:
          let count = peer.swim.aliveMembers().len
          if count < NumPeers - 1:
            echo "  peer ", i, " sees ", count, "/", NumPeers - 1
      check converged
      # `most` is the period count of the peer furthest along: the cluster
      # converged no later than that period, so this is the conservative
      # reading of "within 10 protocol periods".
      check periods.most <= MaxPeriods
    finally:
      shutdownLoopbackSwimPeers(peers)
      # Drain the dispatcher so async tasks owned by stopped engines
      # release cleanly.
      for _ in 0 ..< 10:
        try: poll(0) except ValueError: discard
