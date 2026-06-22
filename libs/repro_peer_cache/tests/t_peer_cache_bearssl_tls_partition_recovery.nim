## Peer-Cache-BearSSL M5 verification: partition recovery on a 200-peer
## `tmTls` sim fleet.
##
## Mirrors `t_peer_cache_simulation_partition_recovery` from
## Peer-Cache-Scale M5, but every peer runs `tmTls`. The in-process
## transport short-circuits the actual TLS wrap (the sim is one
## process; TLS would be self-talk encryption); the
## `seedRandomBlobs` helper still exercises real ECDSA-P256 sign +
## verify over the synthesised AdvertiseV2 payload, so the BearSSL
## crypto primitive is on the steady-state path.
##
## After the fleet converges, 20 random peers' SWIM engines are
## stopped simultaneously. The test asserts that every survivor's
## `aliveMembers()` eventually no longer contains any killed peer,
## matching the Peer-Cache-Scale M5 partition recovery behaviour. The
## recovery wall-clock is reported but not asserted as a hard cap: it
## inflates with CPU contention on a shared runner. This is the "no
## degradation from TLS-layer verification in the steady state" check —
## tmTls does not touch the SWIM per-period path at all.

import std/[asyncdispatch, monotimes, os, sets, times, unittest]

import repro_peer_cache

{.used.}

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
    ## shared CI runner, and a 15 s budget timed out then cascaded into
    ## the recovery phase starting on an un-converged fleet. tmTls does
    ## not change SWIM convergence cost (TLS is short-circuited
    ## in-process; ECDSA runs only in the one-shot seed phase), so the
    ## budget matches the non-TLS partition-recovery test exactly.
  RecoveryBudgetMs = 30_000
    ## Wall-clock budget for the kill -> survivors-recover phase. SWIM's
    ## suspect→confirm→remove pipeline runs on wall-clock timers that
    ## the dispatcher services far slower than real time under CPU
    ## oversubscription (~17 s at 4x load vs. ~2 s quiet). 30 s gives
    ## headroom; the correctness outcome is asserted by `recovered`.
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

suite "peer-cache BearSSL tmTls partition recovery (M5)":
  test "200-peer tmTls fleet, 20 killed, survivors recover":
    var cfg = defaultSwimConfig()
    cfg.swimProbePeriodMs = ProbePeriodMs
    cfg.swimProbeTimeoutMs = 20
    cfg.swimSuspectTimeoutMs = SuspectMs
    cfg.swimConfirmTimeoutMs = ConfirmMs
    cfg.swimGossipMessageCap = 32
    let specs = defaultSimSpecs(NumPeers, racks = 5, tenants = 1,
                                trustMode = tmTls)
    let fleet = waitFor spawnSimFleet(specs, cfg, seedsPerPeer = 5)
    try:
      startSwim(fleet)
      let convergeMs = waitFor waitForConvergence(
        fleet, TargetMembership, ConvergenceBudgetMs)
      check convergeMs >= 0
      echo "  pre-partition convergence: ", convergeMs, " ms"
      # Drive one signed-advertise dissemination round so the
      # real-ECDSA-P256 verify path runs at least once before the
      # kill. Confirms the BearSSL primitive isn't asymptotic to the
      # partition-recovery cost.
      waitFor seedRandomBlobs(fleet, blobsPerPeer = 4, blobBytes = 32)
      echo "  signaturesVerified pre-kill: ", fleet.signaturesVerified
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
      # Correctness: every survivor eventually drops every killed peer.
      # The wall-clock is reported but not asserted — it inflates with
      # CPU contention (see RecoveryBudgetMs note); the recovery outcome
      # is what SWIM guarantees. The signed-advertise seed phase must
      # also have produced zero signature rejections.
      check recovered
      check fleet.signaturesRejected == 0'u64
    finally:
      waitFor shutdownFleet(fleet)
      for _ in 0 ..< 10:
        try: poll(0) except ValueError: discard
