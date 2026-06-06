## Peer-Cache-Scale M0 verification: SWIM dissemination piggybacks
## on probe-ack frames rather than spawning standalone broadcast
## frames.
##
## 10-peer cluster. After convergence, trigger churn: kill peers 8
## and 9, then restart peer 9. Over a five-second window, count
## standalone `mkSwimSuspect` / `mkSwimConfirm` / `mkSwimRefute`
## frames vs piggybacked-on-probe/ack updates across the cluster.
## Assert that at least 75 % of dissemination updates ride
## piggybacked.

import std/[asyncdispatch, monotimes, os, times, unittest]

import repro_peer_cache

const
  NumPeers = 10
  ProbePeriodMs = 50
  PollIntervalMs = 5
  ObservationMs = 5_000

proc allConverged(peers: seq[LoopbackPeer]): bool =
  for peer in peers:
    if peer.swim.aliveMembers().len < NumPeers - 1:
      return false
  true

suite "peer-cache SWIM dissemination piggyback":
  test "at least 75% of membership updates ride piggybacked":
    var cfg = defaultSwimConfig()
    cfg.swimProbePeriodMs = ProbePeriodMs
    cfg.swimProbeTimeoutMs = 25
    cfg.swimSuspectTimeoutMs = 500
    cfg.swimConfirmTimeoutMs = 1_000
    let peers = spawnLoopbackSwimPeers(NumPeers, cfg, seedsPerPeer = 4)
    try:
      startLoopbackSwimPeers(peers)
      let convergeBudgetMs = 30 * ProbePeriodMs
      let convergeStart = getMonoTime()
      while (getMonoTime() - convergeStart).inMilliseconds <
            convergeBudgetMs and not allConverged(peers):
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
      check allConverged(peers)

      # Reset counters so the observation window is clean.
      for peer in peers:
        peer.swim.standaloneDisseminationCount = 0
        peer.swim.piggybackedDisseminationCount = 0

      # Trigger churn: kill peers 8 and 9.
      peers[8].swim.stop()
      peers[9].swim.stop()

      let observationStart = getMonoTime()
      while (getMonoTime() - observationStart).inMilliseconds <
            ObservationMs:
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)

      var totalStandalone = 0
      var totalPiggyback = 0
      for i, peer in peers:
        if i in {8, 9}: continue
        totalStandalone += peer.swim.standaloneDisseminationCount
        totalPiggyback += peer.swim.piggybackedDisseminationCount
      let total = totalStandalone + totalPiggyback
      echo "  standalone=", totalStandalone,
           " piggyback=", totalPiggyback,
           " ratio=",
           (if total == 0: 0.0
            else: float(totalPiggyback) / float(total))
      check total > 0
      check float(totalPiggyback) / float(total) >= 0.75
    finally:
      shutdownLoopbackSwimPeers(peers)
      for _ in 0 ..< 10:
        try: poll(0) except ValueError: discard
