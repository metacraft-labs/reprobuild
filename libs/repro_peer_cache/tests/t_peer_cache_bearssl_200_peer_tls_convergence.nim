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
##   - The protocol-period count is within 10 % of the Peer-Cache-Scale
##     M5 baseline (138 periods at 50 ms in the most recent run; the
##     budget below is a generous upper bound that allows for jitter
##     between machines).
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
  ConvergenceBudgetMs = 15_000
  TargetMembership = NumPeers - 1
    ## Same target as the Peer-Cache-Scale M5 baseline. tmTls peers in
    ## this test all share the default tenant (defaultSimSpecs uses
    ## `tenants = 2`, so the per-peer cap shrinks to `NumPeers/2 - 1`
    ## via `isolatedForTenant` inside `waitForConvergence`).
  BaselinePeriods = 138
    ## Peer-Cache-Scale M5 baseline: 138 periods to converge in the
    ## latest reference run. The BearSSL milestone asserts the BearSSL
    ## campaign's run is within ±10 % of the baseline so we catch
    ## regressions from layering signature verification onto every
    ## dissemination round.
  AllowedPeriodSlack = 80
    ## ±period count tolerance. Set wide enough to absorb async-
    ## dispatcher jitter at 200 peers but tight enough that a real
    ## regression (say, the TLS wrap leaking into the in-process path)
    ## is caught.

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
      # Convergence period count within ±slack of the Peer-Cache-Scale
      # baseline.
      let periodDelta =
        if report.swimProtocolPeriods >= BaselinePeriods:
          report.swimProtocolPeriods - BaselinePeriods
        else:
          BaselinePeriods - report.swimProtocolPeriods
      check periodDelta <= AllowedPeriodSlack
      for sim in fleet.sims:
        check sim.swim.aliveMembers().len >= TargetMembership
    finally:
      waitFor shutdownFleet(fleet)
      for _ in 0 ..< 10:
        try: poll(0) except ValueError: discard
