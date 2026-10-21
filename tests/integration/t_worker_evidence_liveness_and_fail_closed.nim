## Distributed-Execution M7: the worker's evidence path is visible when it is
## dead, and the worker stops when its evidence cannot leave.
##
## Threat model G22 (DET-5: "Detector silence alerts, distinctly from nothing
## detected"):
##   * the lease supervisor's detector heartbeats only after a CANARY lease
##     proved it — an exec outside the closure that the supervisor must
##     report — so its heartbeat carries `probe=ok`; the in-daemon detectors
##     (`goal-receiver`, `certificate-issuance`) heartbeat on their interval;
##   * a detector the operator expects but that never reported at all (here
##     a host that never connected) is a `never-reported` row, not an absent
##     one.
##
## Threat model G28 (DET-6, EVID-2):
##   * every acknowledged batch leaves a signed RECEIPT with the worker
##     (`<state>/evidence-receipt`), and the sink's store verifies against it
##     — and stops verifying once the store is truncated behind it;
##   * with the sink down, the worker executes nothing (`goal-evidence-
##     unavailable`, fail closed); with the sink back, it executes again.
##
## The negative controls (a canary that never runs leaves `lease-supervisor`
## never-reported; a receiver that ignores the evidence health executes with
## the sink down) are neuter experiments recorded in the milestone.
##
## MOCK POLICY — none (see `m7_worker_fixture.nim`).

import std/[asyncdispatch, options, os, sets, strutils, tables, times,
            unittest]

import repro_peer_cache
import repro_workspace_snapshot
import repro_distributed_worker

import repro_test_support/reasoned_skip
import ./m7_worker_fixture

proc statusOf(rows: seq[DetectorLiveness]; host: PeerId;
              detector: string): Option[LivenessStatus] =
  for r in rows:
    if r.hostId == host and r.detector == detector:
      return some(r.status)
  none(LivenessStatus)

suite "Distributed-Execution M7: evidence liveness and fail-closed workers":

  test "detectors prove themselves; the worker stops without its sink":
    if not hardenedWorkerHere():
      echo HardenedWorkerNA
      skip("platform N/A: hardened workers are Linux-only")
    else:
      let base = m7TestBase("repro-m7-live")
      var w = newTestNode(base, "worker")
      var o = newTestNode(base, "orch")
      let ghost = newTestNode(base, "ghost")
      mutualTrust([w, o])
      w.grantRoles(o, "cache-peer,orchestrator")
      var sink = prepareEvidenceSink(base)
      sink.acceptsFrom(w)
      sink.acceptsFrom(o)
      sink.startEvidenceSink()
      let repo = makeFixtureRepo(base, [("ok.sh", "#!/bin/sh\nmkdir -p out\necho ok > out/ok\n")])
      writeFile(base / "repos", "fixture " & repo.cache & "\n")
      var worker = newWorkerDaemon(base, w)
      var orch: Orchestrator
      defer:
        if not orch.host.isNil: orch.host.stop()
        stopWorkerDaemon(worker)
        stopEvidenceSink(sink)
        removeDir(base)
      worker.startWorkerDaemon(workerSpec(sink, base / "repos"))
      orch = newOrchestrator(base, o, worker.peerCachePort(), sink.endpoint)
      let workerId = w.identity.hostId
      check orch.waitConnected(workerId, worker)
      let snap = repo.snapshotOf("fixture", [])
      let manifestDigest = orch.publish(encodeManifest(snap.manifest))
      let desc = GraphCacheDescriptor(schema: DescriptorSchema,
        project: "m7-live", platform: hostOS & "/" & hostCPU,
        snapshotContentId: contentIdOf(snap.manifest),
        nodes: @[GraphNode(id: "ok", argv: @["/bin/sh", "ok.sh"],
          inputs: @["ok.sh"], outputs: @["out/ok"])])
      let descDigest = orch.publish(encodeDescriptor(desc))
      pump(300)
      proc goal(id: string): ReachGoalResponse =
        let r = orch.reachGoal(workerId, ReachGoalRequest(requestId: id,
          graphDescriptorDigest: descDigest,
          snapshotManifestDigest: manifestDigest, goalNode: "ok"))
        check r.kind == grkResponse
        if r.kind == grkResponse:
          result = decodeResponse(r.payload)
          checkpoint(id & ": " & $result.status & " " & result.trigger & " " &
            result.reason)

      # -- G22: the lease supervisor heartbeats only after its canary --------
      var probed = false
      let probeDeadline = epochTime() + 45.0
      while not probed and epochTime() < probeDeadline:
        for e in sink.sinkEntries():
          if e.kind == ekRecord and e.record.category == ecHeartbeat and
              e.senderHostId == workerId and
              e.record.detector == "lease-supervisor" and
              e.record.field("probe") == "ok":
            probed = true
        if not probed: pump(250)
      check probed
      pump(1_000)
      # ... and ONLY after it: every lease-supervisor heartbeat at the sink
      # carries the canary's proof. A heartbeat from the appender's timer
      # (what a dead `log stream` used to keep sending) would have none.
      var unproven = 0
      for e in sink.sinkEntries():
        if e.kind == ekRecord and e.record.category == ecHeartbeat and
            e.senderHostId == workerId and
            e.record.detector == "lease-supervisor" and
            e.record.field("probe") != "ok":
          inc unproven
      checkpoint("unproven lease-supervisor heartbeats: " & $unproven)
      check unproven == 0
      let expected: seq[ExpectedDetector] = @[
        (workerId, "lease-supervisor"), (workerId, "goal-receiver"),
        (workerId, "certificate-issuance"), (workerId, "boundary-gate"),
        (ghost.identity.hostId, "boundary-gate")]
      let rows = livenessReport(sink.dir, int64(epochTime() * 1000), 3, expected)
      checkpoint($rows)
      check statusOf(rows, workerId, "lease-supervisor") == some(lsLiveIdle)
      check statusOf(rows, workerId, "goal-receiver") == some(lsLiveIdle)
      check statusOf(rows, workerId, "certificate-issuance") == some(lsLiveIdle)
      check statusOf(rows, ghost.identity.hostId, "boundary-gate") ==
        some(lsNeverReported)

      # -- G28: receipts --------------------------------------------------------
      check goal("g1").status == gsCompleted
      pump(1_000)
      let receiptPath = worker.stateDir / "evidence-receipt"
      check fileExists(receiptPath)
      let receipts = sinkReceipts(receiptPath)
      check receipts.len == 1
      let key = sinkCheckpointKey(sink)
      check verifyEvidenceStore(sink.dir, key, receipts,
        allowUnanchoredTail = true).ok

      # -- G28: fail closed while the sink is down ------------------------------
      stopEvidenceSink(sink)
      var unhealthy = false
      let downDeadline = epochTime() + 20.0
      while not unhealthy and epochTime() < downDeadline:
        pump(200)
        unhealthy = worker.status().getOrDefault("worker_evidence_healthy") == "0"
      check unhealthy
      let refused = goal("g2")
      check refused.status == gsRefused
      check refused.trigger == "goal-evidence-unavailable"
      # A store truncated behind the receipt no longer verifies against it.
      let truncatedCopy = base / "truncated-store"
      copyDir(sink.dir, truncatedCopy)
      let segs = listSegments(truncatedCopy)
      check segs.len >= 1
      # Cut the last segment right after an earlier checkpoint — what an
      # attacker on the sink host does so that the store ALONE still verifies.
      let lastSeg = segs[^1]
      let content = readFile(lastSeg)
      var offsets: seq[int] = @[]
      var pos = content.find("EVE1")
      while pos >= 0:
        offsets.add(pos)
        pos = content.find("EVE1", pos + 4)
      let all = readEvidenceStore(truncatedCopy)
      let segEntries = all[all.len - offsets.len .. ^1]
      var cutAt = -1
      for i, e in segEntries:
        if e.kind == ekCheckpoint and e.seq + 1 < receipts[0].headSeq and
            i + 1 < offsets.len:
          cutAt = offsets[i + 1]
      check cutAt > 0
      if cutAt > 0:
        writeFile(lastSeg, content[0 ..< cutAt])
        check verifyEvidenceStore(truncatedCopy, key).ok   # alone: fine
        check not verifyEvidenceStore(truncatedCopy, key, receipts).ok
      # -- …and executes again once the sink is back --------------------------
      sink.startEvidenceSink()
      var healthy = false
      let upDeadline = epochTime() + 30.0
      while not healthy and epochTime() < upDeadline:
        pump(200)
        healthy = worker.status().getOrDefault("worker_evidence_healthy") == "1"
      check healthy
      check goal("g3").status == gsCompleted
      check sink.waitForDetection("goal-evidence-unavailable").len >= 1
