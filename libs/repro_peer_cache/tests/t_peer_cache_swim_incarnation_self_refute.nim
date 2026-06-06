## Peer-Cache-Scale M0 verification: SWIM incarnation self-refute.
##
## 10-peer cluster, fully converged. Pick a victim peer P. Inject a
## fake `mkSwimSuspect` for P into peer Q's incoming gossip via the
## `injectIncomingSuspect` test seam, with P's current incarnation.
## After a few protocol periods the test asserts:
##
##   1. P's local `selfIncarnation` was bumped by 1 (refutation).
##   2. Q's view of P (after refutation gossip propagates back) is
##      `Alive` with the new incarnation.

import std/[asyncdispatch, monotimes, os, tables, times, unittest]

import repro_peer_cache

const
  NumPeers = 10
  ProbePeriodMs = 50
  PollIntervalMs = 5

proc allConverged(peers: seq[LoopbackPeer]): bool =
  for peer in peers:
    if peer.swim.aliveMembers().len < NumPeers - 1:
      return false
  true

suite "peer-cache SWIM incarnation self-refute":
  test "P self-refutes on receiving suspect, Q sees refuted Alive":
    var cfg = defaultSwimConfig()
    cfg.swimProbePeriodMs = ProbePeriodMs
    cfg.swimProbeTimeoutMs = 25
    cfg.swimSuspectTimeoutMs = 5_000
    cfg.swimConfirmTimeoutMs = 10_000
    let peers = spawnLoopbackSwimPeers(NumPeers, cfg, seedsPerPeer = 4)
    try:
      startLoopbackSwimPeers(peers)
      # Wait for convergence so every peer knows P.
      let convergeBudgetMs = 30 * ProbePeriodMs
      let convergeStart = getMonoTime()
      while (getMonoTime() - convergeStart).inMilliseconds <
            convergeBudgetMs and not allConverged(peers):
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
      check allConverged(peers)

      # Pick P (peer 0) and Q (peer 5).
      let p = peers[0]
      let q = peers[5]
      let initialIncarnation = p.swim.selfIncarnation
      check q.swim.registry.hasPeer(p.peerId)
      let qViewOfPBefore =
        q.swim.registry.entries[p.peerId].swimStatus

      # Inject a fake suspect about P into Q's gossip pipeline.
      let fakeSuspect = SwimMember(
        peerId: p.peerId,
        endpoint: p.swim.selfEndpoint,
        status: smsSuspected,
        incarnation: initialIncarnation)
      q.swim.injectIncomingSuspect(fakeSuspect)

      # Q now thinks P is Suspected with incarnation `initialIncarnation`.
      check q.swim.registry.entries[p.peerId].swimStatus == smsSuspected
      check q.swim.registry.entries[p.peerId].swimIncarnation ==
            initialIncarnation

      # Let gossip propagate to P. P should self-refute on receipt.
      let refuteBudgetMs = 10 * ProbePeriodMs
      let refuteStart = getMonoTime()
      while (getMonoTime() - refuteStart).inMilliseconds <
            refuteBudgetMs and
            p.swim.selfIncarnation == initialIncarnation:
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
      check p.swim.selfIncarnation == initialIncarnation + 1

      # Wait for Q to receive the refute and update its view of P.
      let qBudgetMs = 10 * ProbePeriodMs
      let qStart = getMonoTime()
      while (getMonoTime() - qStart).inMilliseconds < qBudgetMs and
            (q.swim.registry.entries[p.peerId].swimStatus != smsAlive or
             q.swim.registry.entries[p.peerId].swimIncarnation <
             initialIncarnation + 1):
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)
      check q.swim.registry.entries[p.peerId].swimStatus == smsAlive
      check q.swim.registry.entries[p.peerId].swimIncarnation ==
            initialIncarnation + 1
      discard qViewOfPBefore  # silence unused
    finally:
      shutdownLoopbackSwimPeers(peers)
      for _ in 0 ..< 10:
        try: poll(0) except ValueError: discard
