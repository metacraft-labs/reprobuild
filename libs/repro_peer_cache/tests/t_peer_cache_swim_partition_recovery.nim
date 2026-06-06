## Peer-Cache-Scale M0 verification: SWIM partition recovery.
##
## Spawns a 50-peer cluster, waits for convergence, then "kills" 5
## peers by stopping their SWIM engines. The remaining 45 survivors
## must mark the 5 partitioned peers as `Suspected` then `Confirmed`
## within `swimSuspectTimeoutMs + swimConfirmTimeoutMs + 5_000 ms`,
## and the 5 must drop out of every survivor's `aliveMembers`.

import std/[asyncdispatch, monotimes, os, sets, tables, times, unittest]

import repro_peer_cache

const
  NumPeers = 50
  KillCount = 5
  ProbePeriodMs = 50
  PollIntervalMs = 10

proc allConverged(peers: seq[LoopbackPeer]): bool =
  for peer in peers:
    if peer.swim.aliveMembers().len < NumPeers - 1:
      return false
  true

proc allSurvivorsRecovered(peers: seq[LoopbackPeer];
                           killedIndices: HashSet[int];
                           killedIds: HashSet[PeerId]): bool =
  for i, peer in peers:
    if i in killedIndices: continue
    let alive = peer.swim.aliveMembers()
    for id in alive:
      if id in killedIds:
        return false
  true

suite "peer-cache SWIM partition recovery":
  test "50-peer cluster recovers after 5-peer partition":
    var cfg = defaultSwimConfig()
    cfg.swimProbePeriodMs = ProbePeriodMs
    cfg.swimProbeTimeoutMs = 25
    cfg.swimSuspectTimeoutMs = 500
    cfg.swimConfirmTimeoutMs = 1_000
    let peers = spawnLoopbackSwimPeers(NumPeers, cfg, seedsPerPeer = 5)
    try:
      startLoopbackSwimPeers(peers)
      # Phase 1: wait for initial convergence (bounded budget).
      let convergeBudgetMs = 30 * ProbePeriodMs
      let convergeStart = getMonoTime()
      while (getMonoTime() - convergeStart).inMilliseconds <
            convergeBudgetMs and not allConverged(peers):
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
      check allConverged(peers)

      # Phase 2: kill the last KillCount peers.
      var killedIndices = initHashSet[int]()
      var killedIds = initHashSet[PeerId]()
      for i in (NumPeers - KillCount) ..< NumPeers:
        killedIndices.incl(i)
        killedIds.incl(peers[i].peerId)
        peers[i].swim.stop()

      # Phase 3: wait until every survivor stops listing any of the 5
      # killed peers in its `aliveMembers`.
      let recoveryBudgetMs =
        cfg.swimSuspectTimeoutMs + cfg.swimConfirmTimeoutMs + 5_000
      let recoveryStart = getMonoTime()
      while (getMonoTime() - recoveryStart).inMilliseconds <
            recoveryBudgetMs and
            not allSurvivorsRecovered(peers, killedIndices, killedIds):
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)

      let recoveredMs = (getMonoTime() - recoveryStart).inMilliseconds
      echo "SWIM partition recovery: ", recoveredMs, " ms"
      let recovered = allSurvivorsRecovered(
        peers, killedIndices, killedIds)
      if not recovered:
        var totalProbes = 0
        var totalMarkedSuspected = 0
        var totalSuspectTransitions = 0
        for i, peer in peers:
          if i in killedIndices: continue
          totalProbes += peer.swim.sentDirectProbeCount
          totalMarkedSuspected += peer.swim.markedSuspectedCount
          totalSuspectTransitions += peer.swim.suspectTransitionCount
        echo "  survivor probes since convergence: total=", totalProbes,
             " avg=", float(totalProbes) / float(NumPeers - KillCount)
        echo "  markSuspected calls: ", totalMarkedSuspected,
             " suspect->confirmed transitions: ", totalSuspectTransitions
        # Diagnostic: classify each killed peer's status on every
        # survivor so we can tell whether the suspect timer fired at
        # all.
        var aliveCount = 0
        var suspectCount = 0
        var confirmedCount = 0
        var goneCount = 0
        for i, peer in peers:
          if i in killedIndices: continue
          for killedId in killedIds.items:
            let kid: PeerId = killedId
            if peer.swim.registry.hasPeer(kid):
              let entry = peer.swim.registry.entries[kid]
              case entry.swimStatus
              of smsAlive: inc aliveCount
              of smsSuspected: inc suspectCount
              of smsConfirmed: inc confirmedCount
            else:
              inc goneCount
        echo "  killed-peer status totals across survivors:"
        echo "    alive=", aliveCount, " suspect=", suspectCount,
             " confirmed=", confirmedCount, " gone=", goneCount
      check recovered
    finally:
      shutdownLoopbackSwimPeers(peers)
      for _ in 0 ..< 10:
        try: poll(0) except ValueError: discard
