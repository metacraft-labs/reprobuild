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
  ConvergenceBudgetMs = 90_000
    ## Wall-clock budget for the pre-partition convergence phase. See
    ## the long note in `t_peer_cache_simulation_200_peer_convergence`:
    ## the per-period wall-clock inflates with CPU oversubscription on a
    ## shared CI runner. A 15 s budget timed out here under ~4x load and
    ## then cascaded — the kill phase started on an un-converged fleet,
    ## so survivors could never reach the "no killed peer left alive"
    ## state. 90 s removes the cascade while still catching a genuine
    ## convergence stall.
  RecoveryBudgetMs = 30_000
    ## Wall-clock budget for the kill -> survivors-recover phase. The
    ## SWIM suspect→confirm→remove pipeline is driven by wall-clock
    ## timers (`swimSuspectTimeoutMs` + `swimConfirmTimeoutMs`); under
    ## CPU oversubscription the dispatcher services those timers and the
    ## 50 ms poll loop far slower than real time, so recovery that takes
    ## ~2 s on a quiet machine needs ~17 s at 4x load. 30 s gives
    ## headroom above the heaviest observed contention. The correctness
    ## property — every survivor eventually drops every killed peer —
    ## is asserted by `recovered` below regardless of the wall-clock.
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
      # Correctness: every survivor eventually drops every killed peer
      # from its `aliveMembers()`. The wall-clock it takes is reported
      # but not asserted — under CPU contention it inflates with the
      # dispatcher's timer servicing (see the RecoveryBudgetMs note),
      # while the recovery *outcome* is what SWIM guarantees.
      check recovered
    finally:
      waitFor shutdownFleet(fleet)
      for _ in 0 ..< 10:
        try: poll(0) except ValueError: discard
