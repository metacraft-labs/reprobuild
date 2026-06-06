## Peer-Cache-Scale M0 verification: SWIM K=3 indirect probe.
##
## 10-peer cluster. Configure the test seam so peer B drops every
## direct probe whose source is peer A. A is otherwise alive. After
## several protocol periods, assert:
##
##   1. A's view of B stays `Alive` (the indirect probe path kept B
##      out of `Suspected` state).
##   2. A's `sentIndirectProbeReqCount` is non-zero (indirect probes
##      were actually used).
##   3. A's `receivedIndirectAckCount` is non-zero (intermediaries
##      successfully relayed acks back to A).

import std/[asyncdispatch, monotimes, os, sets, tables, times, unittest]

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

suite "peer-cache SWIM indirect probe K=3":
  test "A's direct probes to B fail; indirect probes via K=3 succeed":
    var cfg = defaultSwimConfig()
    cfg.swimProbePeriodMs = ProbePeriodMs
    cfg.swimProbeTimeoutMs = 25
    cfg.swimIndirectProbeCount = 3
    cfg.swimSuspectTimeoutMs = 5_000
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

      let a = peers[0]
      let b = peers[1]
      # Configure the test seam: B drops every probe whose source is
      # peer A. Production code never sets this.
      b.swim.dropDirectProbesFrom.incl(a.peerId)

      # Reset instrumentation so the assertions below count only the
      # post-firewall window.
      a.swim.sentDirectProbeCount = 0
      a.swim.sentIndirectProbeReqCount = 0
      a.swim.receivedIndirectAckCount = 0

      # Let several protocol periods elapse so peer A has a few
      # opportunities to pick B as its probe target.
      let runMs = 30 * ProbePeriodMs
      let runStart = getMonoTime()
      while (getMonoTime() - runStart).inMilliseconds < runMs:
        try: poll(0) except ValueError: discard
        sleep(PollIntervalMs)

      # A must keep B in Alive state (since indirect probes succeed).
      check a.swim.registry.hasPeer(b.peerId)
      check a.swim.registry.entries[b.peerId].swimStatus == smsAlive
      # And A must have actually exercised the indirect-probe path.
      check a.swim.sentIndirectProbeReqCount > 0
      check a.swim.receivedIndirectAckCount > 0
      echo "  A.sentDirectProbeCount=", a.swim.sentDirectProbeCount,
           " A.sentIndirectProbeReqCount=",
           a.swim.sentIndirectProbeReqCount,
           " A.receivedIndirectAckCount=",
           a.swim.receivedIndirectAckCount
    finally:
      shutdownLoopbackSwimPeers(peers)
      for _ in 0 ..< 10:
        try: poll(0) except ValueError: discard
