## Peer-Cache-Scale M5 verification: simulated fetch workload finds
## blobs through the peer-cache index.
##
## Spawns a 50-peer fleet, seeds 20 blobs per peer (1000 unique
## blobs), and runs a workload of 10 fetches per peer. The seed phase
## populates each peer's `findPeersWithBlob` index via the same
## `applyAdvertise` path the production server uses. Every fetch
## attempt should map to a peer that owns the requested blob, so the
## hit ratio must be effectively 1.0; we assert
## `fetchHitsPeer + fetchHitsLocal > 90%` of attempts (a small slack
## absorbs cuckoo-filter false positives if any).

import std/[asyncdispatch, os, unittest]

import repro_peer_cache

const
  NumPeers = 50
  BlobsPerPeer = 20
  BlobBytes = 32
  FetchesPerPeer = 10

suite "peer-cache simulation fetch workload":
  test "50-peer fleet hits the peer-cache on workload fetches":
    var cfg = defaultSwimConfig()
    cfg.swimProbePeriodMs = 100
    cfg.swimProbeTimeoutMs = 25
    let specs = defaultSimSpecs(NumPeers)
    var fleet = waitFor spawnSimFleet(specs, cfg, seedsPerPeer = 5)
    try:
      startSwim(fleet)
      # Seed + workload — both run synchronously in the helper, but we
      # interleave a short SWIM warm-up so the registries are populated
      # via the same path production code uses.
      waitFor seedRandomBlobs(fleet, BlobsPerPeer, BlobBytes)
      waitFor runWorkload(fleet, FetchesPerPeer)
      let report = collectReport(fleet, 0, 0)
      echo "fetches attempted=", report.fetchesAttempted,
           " hitsPeer=", report.fetchesHitPeer,
           " missed=", report.fetchesMissed
      check report.fetchesAttempted == uint64(NumPeers * FetchesPerPeer)
      check report.fetchesHitPeer > 0'u64
      let hits = report.fetchesHitPeer + report.fetchesHitLocal
      check float(hits) >= 0.90 * float(report.fetchesAttempted)
    finally:
      waitFor shutdownFleet(fleet)
      for _ in 0 ..< 10:
        try: poll(0) except ValueError: discard
