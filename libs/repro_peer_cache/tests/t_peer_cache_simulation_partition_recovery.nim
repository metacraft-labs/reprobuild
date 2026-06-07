## Peer-Cache-Scale M5 verification: partition recovery on a sim
## fleet.
##
## Spawns a 200-peer fleet (smaller cuts allowed per the milestone if
## the dispatcher strains), waits for convergence, kills 10% of peers
## by stopping their SWIM engines, and asserts the survivors mark the
## partitioned peers `Suspected` then `Confirmed`/removed within
## `swimSuspectTimeoutMs + swimConfirmTimeoutMs + slack`.

import std/[asyncdispatch, monotimes, os, sets, times, unittest]

import repro_peer_cache

const
  NumPeers = 200
  KillCount = 20
  ProbePeriodMs = 50
  SuspectMs = 400
  ConfirmMs = 1_500
  ConvergenceBudgetMs = 15_000
  RecoveryBudgetMs = 6_000
    ## Wall-clock budget for the kill -> survivors-recover phase. The
    ## milestone caps recovery at `swimConfirmTimeoutMs × 3` (= 4 500
    ## ms with the test config); 6 000 ms gives a small buffer above
    ## that cap so we can catch regressions without flaking on async-
    ## dispatcher jitter at 200 peers. The post-assertion check
    ## (`recoveryMs < HardCapMs`) keeps the cap enforced.
  HardCapMs = 4_500
    ## The milestone bound: after 20 stopped engines, every survivor
    ## must see them out of its `aliveMembers()` within
    ## `swimConfirmTimeoutMs × 3`.
  TargetMembership = NumPeers - 1

proc allSurvivorsRecovered(fleet: SimFleet;
                           killedIds: HashSet[PeerId]): bool =
  for sim in fleet.sims:
    if sim.peerId in killedIds: continue
    let alive = sim.swim.aliveMembers()
    for id in alive:
      if id in killedIds:
        return false
  true

suite "peer-cache simulation partition recovery":
  test "200-peer fleet, 20 killed, survivors recover":
    var cfg = defaultSwimConfig()
    cfg.swimProbePeriodMs = ProbePeriodMs
    cfg.swimProbeTimeoutMs = 20
    cfg.swimSuspectTimeoutMs = SuspectMs
    cfg.swimConfirmTimeoutMs = ConfirmMs
    cfg.swimGossipMessageCap = 32
    let specs = defaultSimSpecs(NumPeers)
    let fleet = waitFor spawnSimFleet(specs, cfg, seedsPerPeer = 5)
    try:
      startSwim(fleet)
      let convergeMs = waitFor waitForConvergence(
        fleet, TargetMembership, ConvergenceBudgetMs)
      check convergeMs >= 0
      echo "  pre-partition convergence: ", convergeMs, " ms"
      # Kill the first KillCount peers.
      var killedIds = initHashSet[PeerId]()
      for i in 0 ..< KillCount:
        fleet.sims[i].swim.stop()
        killedIds.incl(fleet.sims[i].peerId)
      let recoveryStart = getMonoTime()
      var recovered = false
      while (getMonoTime() - recoveryStart).inMilliseconds < RecoveryBudgetMs:
        try: poll(0) except ValueError: discard
        waitFor sleepAsync(50)
        if allSurvivorsRecovered(fleet, killedIds):
          recovered = true
          break
      let recoveryMs = (getMonoTime() - recoveryStart).inMilliseconds.int
      echo "  partition recovery wall-clock: ", recoveryMs, " ms"
      check recovered
      check recoveryMs < HardCapMs
    finally:
      waitFor shutdownFleet(fleet)
      for _ in 0 ..< 10:
        try: poll(0) except ValueError: discard
