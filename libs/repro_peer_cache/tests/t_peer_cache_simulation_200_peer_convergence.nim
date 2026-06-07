## Peer-Cache-Scale M5 verification: 200-peer in-process SWIM
## convergence.
##
## Spawns 200 peers via the M5 `spawnSimFleet` harness, drives SWIM
## with a 50 ms protocol period, and asserts that the membership view
## of every peer reaches `peerCount - 1` within a generous wall-clock
## budget. The 50-peer test (M0) takes ~800 ms at 100 ms periods; 200
## peers at 50 ms periods should land well inside the 15 s budget.
##
## Beyond the strict "all converge" check, the test asserts that the
## simulation harness's `collectReport` returns a non-zero
## `swimPingsSent` counter (so the M5 send-site metric wiring is
## exercised end-to-end).

import std/[asyncdispatch, monotimes, os, times, unittest]

import repro_peer_cache

const
  NumPeers = 200
  SeedsPerPeer = 5
  ProbePeriodMs = 50
  ConvergenceBudgetMs = 15_000
  TargetMembership = NumPeers - 1

suite "peer-cache simulation 200-peer convergence":
  test "200 peers converge within the M5 budget":
    var cfg = defaultSwimConfig()
    cfg.swimProbePeriodMs = ProbePeriodMs
    cfg.swimProbeTimeoutMs = 20
    cfg.swimGossipMessageCap = 32
    let specs = defaultSimSpecs(NumPeers)
    let fleet = waitFor spawnSimFleet(specs, cfg, seedsPerPeer = SeedsPerPeer)
    try:
      let started = getMonoTime()
      startSwim(fleet)
      let elapsedMs = waitFor waitForConvergence(
        fleet, TargetMembership, ConvergenceBudgetMs)
      let actualMs = (getMonoTime() - started).inMilliseconds.int
      let report = collectReport(
        fleet, actualMs, elapsedMs, swimProbePeriodMs = ProbePeriodMs)
      echo "200-peer SWIM convergence: ", elapsedMs, " ms (",
           report.swimProtocolPeriods, " periods at ",
           ProbePeriodMs, " ms each)"
      echo "  swimPingsSent=", report.swimPingsSent,
           " swimPingAcksSent=", report.swimPingAcksSent
      check elapsedMs >= 0
      check report.swimPingsSent > 0'u64
      check report.swimPingAcksSent > 0'u64
      for sim in fleet.sims:
        check sim.swim.aliveMembers().len >= TargetMembership
    finally:
      waitFor shutdownFleet(fleet)
      for _ in 0 ..< 10:
        try: poll(0) except ValueError: discard
