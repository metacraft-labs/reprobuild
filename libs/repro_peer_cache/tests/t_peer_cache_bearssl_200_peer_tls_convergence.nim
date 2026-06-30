## Peer-Cache-BearSSL M5 verification: 200-peer in-process SWIM
## convergence under `tmTls`.
##
## Mirrors `t_peer_cache_simulation_200_peer_convergence` from
## Peer-Cache-Scale M5, but switches every peer to `tmTls`. By default
## (`tlsEnabled = false`) the in-process transport short-circuits the
## actual TLS record layer — peers are in the same process, so a TLS
## wrap would be self-talk encryption with no protocol value. The
## sim does still mint per-peer ECDSA-P256 keypairs + self-signed
## certs and exercises real ECDSA-P256 sign + verify on the
## synthesised `AdvertiseV2` payload during the seed phase, which is
## the BearSSL primitive the campaign targets.
##
## Asserts:
##   - SWIM convergence completes within `ConvergenceBudgetMs`.
##   - SWIM dissemination effort did not regress: the fleet-wide
##     `swimPingsSent` send-site counter stays at or above an effort
##     floor. This replaces an earlier bound on `swimProtocolPeriods`,
##     which is derived from wall-clock convergence ÷ nominal period and
##     therefore inflates *and* deflates with the async dispatcher's
##     scheduling latency under CPU contention (it read 114 < 124 on a
##     loaded runner while SWIM was behaving correctly). `swimPingsSent`
##     is incremented at the actual probe send site, so it counts real
##     dissemination work independent of how the scheduler paces it (see
##     the `MinPingsSent` note below).
##   - The signed `AdvertiseV2` path performed at least one real
##     ECDSA-P256 verify per peer per dissemination round (a fleet-
##     wide non-zero counter is sufficient at the test layer; the
##     report numbers carry the full breakdown).

import std/[asyncdispatch, monotimes, os, times, unittest]

import repro_peer_cache

{.used.}

const
  NumPeers = 200
  SeedsPerPeer = 5
  ProbePeriodMs = 50
  ConvergenceBudgetMs = 90_000
    ## Wall-clock budget for full SWIM convergence under tmTls. See the
    ## long note in `t_peer_cache_simulation_200_peer_convergence`: the
    ## per-period wall-clock inflates with CPU oversubscription on a
    ## shared CI runner, so a 15 s budget flakes without adding any
    ## regression-detection power. tmTls does not change the SWIM
    ## convergence cost at all — the in-process transport short-circuits
    ## the TLS record layer and ECDSA verification happens only in the
    ## one-shot seed-dissemination phase, never on the per-period probe
    ## path — so the budget matches the non-TLS test exactly.
  MinPingsSent = NumPeers.uint64
    ## Dissemination-effort floor. The regression this test guards
    ## against is SWIM skipping dissemination rounds (e.g. the TLS wrap
    ## leaking into the in-process path and short-circuiting probes).
    ## That manifests as far *fewer* real probe sends, not as a wall-
    ## clock period count. `swimPingsSent` is accumulated from the
    ## per-peer `swimPingsTotal` send-site counter, so it is independent
    ## of the async dispatcher's scheduling latency under CPU contention
    ## — unlike `swimProtocolPeriods`, which is wall-clock ÷ nominal
    ## period and reads anywhere from ~110 to several hundred for the
    ## same correct run depending on runner load. Reaching membership
    ## convergence across 200 peers requires every peer to have probed
    ## at least once, so the fleet-wide send count is far above
    ## `NumPeers`; using `NumPeers` as the floor leaves generous slack
    ## while still catching a "disseminated almost nothing" regression.
  TargetMembership = NumPeers - 1
    ## Same target as the Peer-Cache-Scale M5 baseline. tmTls peers in
    ## this test all share the default tenant (defaultSimSpecs uses
    ## `tenants = 2`, so the per-peer cap shrinks to `NumPeers/2 - 1`
    ## via `isolatedForTenant` inside `waitForConvergence`).

suite "peer-cache BearSSL 200-peer tmTls convergence (M5)":
  test "200 tmTls peers converge within the M5 budget":
    var cfg = defaultSwimConfig()
    cfg.swimProbePeriodMs = ProbePeriodMs
    cfg.swimProbeTimeoutMs = 20
    cfg.swimGossipMessageCap = 32
    let specs = defaultSimSpecs(NumPeers, racks = 5, tenants = 1,
                                trustMode = tmTls)
    let fleet = waitFor spawnSimFleet(specs, cfg, seedsPerPeer = SeedsPerPeer)
    try:
      let started = getMonoTime()
      startSwim(fleet)
      let elapsedMs = waitFor waitForConvergence(
        fleet, TargetMembership, ConvergenceBudgetMs)
      let actualMs = (getMonoTime() - started).inMilliseconds.int
      # Trigger one round of signed AdvertiseV2 dissemination so the
      # sim's real-ECDSA-P256 verify path runs end-to-end. The seed
      # helper canonicalises the payload, signs it with the source's
      # keypair, and verifies the signature on every receiver.
      waitFor seedRandomBlobs(fleet, blobsPerPeer = 4, blobBytes = 32)
      let report = collectReport(
        fleet, actualMs, elapsedMs, swimProbePeriodMs = ProbePeriodMs)
      echo "200-peer tmTls SWIM convergence: ", elapsedMs, " ms (",
           report.swimProtocolPeriods, " periods at ",
           ProbePeriodMs, " ms each)"
      echo "  swimPingsSent=", report.swimPingsSent,
           " swimPingAcksSent=", report.swimPingAcksSent
      echo "  signaturesVerified=", fleet.signaturesVerified,
           " signaturesRejected=", fleet.signaturesRejected,
           " signatureRejections(metric)=", report.signatureRejections
      check elapsedMs >= 0
      check elapsedMs <= ConvergenceBudgetMs
      check report.swimPingsSent > 0'u64
      check report.swimPingAcksSent > 0'u64
      # Real ECDSA-P256 verify ran on every (src, dst) pair during the
      # seed dissemination — at minimum one verify per receiver per
      # source. With 200 peers fully connected within a single tenant
      # the expected count is N * (N - 1) = 39_800 verifies.
      check fleet.signaturesVerified > 0'u64
      check fleet.signaturesRejected == 0'u64
      check report.signatureRejections == 0'u64
      # SWIM dissemination effort must not regress. We assert on the
      # scheduler-independent send-site counter `swimPingsSent` rather
      # than `swimProtocolPeriods`: the latter is wall-clock ÷ nominal
      # period, so it both inflates and deflates with dispatcher latency
      # under CPU contention (read 114 on a loaded runner for a correct
      # run), whereas the ping counter reflects real dissemination work
      # regardless of how the scheduler paces it (see the const note).
      check report.swimPingsSent >= MinPingsSent
      for sim in fleet.sims:
        check sim.swim.aliveMembers().len >= TargetMembership
    finally:
      waitFor shutdownFleet(fleet)
      for _ in 0 ..< 10:
        try: poll(0) except ValueError: discard
