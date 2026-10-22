## Distributed-Execution M7 GATE: `t_worker_executes_only_the_hydrated_graph`.
##
## A `ReachGoalRequest` whose named argv or input path cannot be derived from
## the `GraphCacheDescriptor` and `WorkspaceSnapshotManifest` the worker
## hydrated is REFUSED at the receiver and REPORTED off-host; a legitimate
## goal still reaches node X on the same worker — the positive control that
## the gate is not satisfied by a worker that executes nothing.
##
## Setup: a real worker daemon (`repro daemon serve … worker=1`, TLS with a
## host CA, the evidence sink as its own process), an orchestrator node the
## worker grants the `orchestrator` role, and a git repository with an
## UNCOMMITTED edit to `src/hello.c`. The orchestrator publishes the
## snapshot manifest (git's own temp-index tree id), the edited blob, and a
## descriptor with two nodes — `build-hello` (compile) and `test-hello`
## (run it) — into its CAS. The worker hydrates all three over the content
## plane by BLAKE3 digest.
##
## Refused, each reported to the sink with the orchestrator as `peer`:
##   1. an argv the orchestrator composed (`/bin/sh -c "touch pwned"` claimed
##      for `build-hello`) — `goal-argv-not-derivable`, nothing runs;
##   2. a node the descriptor does not contain — `goal-argv-not-derivable`;
##   3. an input path outside the snapshot (`../../../etc/passwd`, then a
##      path that is valid but absent from the verified tree) —
##      `goal-path-outside-snapshot`;
##   4. a descriptor evaluated from a different tree than the snapshot —
##      `goal-descriptor-unbound`.
## Executed: `build-hello` with no claims; the compiled binary (fetched back
## from the worker's CAS by its output digest) prints the UNCOMMITTED
## greeting, so the worker ran the descriptor's argv on the verified dirty
## snapshot.
##
## The daemon collects declared outputs OUTSIDE every lease layer, so it
## never reads one through a symlink: a goal that plants `out/leak` pointing
## at the worker's host-CA key gets `gsFailed`, no output, a
## `goal-output-not-regular` detection, and the key's digest is not in the
## worker's CAS; a snapshot whose symlink stands where an output directory
## goes is refused (`goal-path-outside-snapshot`) before anything runs,
## because that directory would become a lease read/exec rule.
##
## Detectors reaching the sink (threat model G23, positive controls built
## from this same harness): a malformed request (`goal-schema-invalid`); a
## goal that executes a copy of /bin/sh from its own temporary directory —
## outside the closure — whose `exec-outside-closure` arrives at the sink
## WHILE THE GOAL IS STILL RUNNING (G21: lease detections leave as they
## happen, not when the lease ends); and a goal that writes outside its lease
## (`fs-denied`). And FLOW-1 (D4): the worker hydrated everything over the
## orchestrator's connection and opened none of its own.
##
## A snapshot that names `repro develop` siblings is refused before anything
## is materialized (`goal-schema-invalid`, reported off-host with the
## request captured): this worker materializes the primary repository only,
## and a goal run without the siblings must not be certified as their state.
## The control is the same manifest without the sibling, which passes that
## check and is refused only at the next one (no repository cache for its
## repo id) — so the sibling is what refused the first, and neither case
## needs an execution lease (the second test case).
##
## TRUST PROFILES (2026-10-20). The derivation check is kept in BOTH
## profiles. The first case runs a HARDENED worker (refusals and lease
## detections asserted at the off-host sink). The third case runs a TRUSTED
## worker — the default profile, no sink: the same refusals and the
## `exec-outside-closure` detection are asserted in each goal's EXECUTION
## RECORD (fetched from the worker's CAS by the digest in the response) and
## in the worker's local detection log, and the legitimate goal's record
## names its argv, outputs and isolation level.
##
## The trusted case also covers, on the same worker:
##
##   * THE HOST KEY (threat model G16, trusted profile): a goal whose action
##     tries to read the worker's long-lived host key from disk, to see the
##     daemon's process and to open its memory (`/proc/<pid>/mem`) gets
##     none of them — the key's bytes are not in anything it can publish.
##     (The daemon's own forked BUILD worker does hold that key in the
##     trusted profile, by design: it is the same uid that can read the
##     key file. What matters is that a LEASE — the action — cannot.) On
##     macOS another process's memory needs its task port, which no build-
##     user process is granted, so only the disk half is observable there;
##   * SYMLINK-FREE OUTPUT READS (kept in both profiles): a goal that plants
##     `out/leak` pointing at the worker's host key gets `gsFailed`, no
##     output, a recorded `goal-output-not-regular`, and the key's digest is
##     not in the worker's CAS;
##   * a declared IMPURE (fixed-output) action: the one whose output matches
##     its declared BLAKE3 publishes it; the one that does not fails with
##     `impure-output-mismatch`, publishes nothing, and is recorded;
##   * INPUT ARTIFACTS: node `run-hello` declares `build-hello` as its input
##     node and RUNS the binary `build-hello` produced, which the request
##     carries by digest and the worker mounts read-only and executable
##     (`REPRO_LEASE_INPUTS`); the action cannot overwrite it; a request
##     naming an artifact of a node that is not a declared input node is
##     refused. (Writing and running a binary in the writable worktree is
##     still refused — `t_execution_lease_confinement`, the noexec test.)
##
## The reddening negative control (removing the derivation check lets case 1
## execute) is a neuter experiment recorded in the milestone's Verification
## log, per the in-house model (Reprobuild-Binary-Cache-Fleet R3).
##
## MOCK POLICY — none (see `m7_worker_fixture.nim`).

import std/[asyncdispatch, options, os, osproc, strutils, tables, times,
            unittest]

import blake3

import repro_peer_cache
import repro_workspace_snapshot
import repro_distributed_worker

import repro_test_support/reasoned_skip
import ./m7_worker_fixture

const
  BaseHello = "#include <stdio.h>\nint main(void){puts(\"committed greeting\");return 0;}\n"
  DirtyHello = "#include <stdio.h>\nint main(void){puts(\"uncommitted greeting\");return 0;}\n"
  TestScript = "#!/bin/sh\nset -eu\n./out/hello | grep -q greeting\n"

suite "Distributed-Execution M7 gate: the worker executes only the hydrated graph":

  test "t_worker_executes_only_the_hydrated_graph":
    if not hardenedWorkerHere():
      echo HardenedWorkerNA
      skip("platform N/A: hardened workers are Linux-only")
    else:
      let cc = ccPath()
      if cc.len == 0:
        checkpoint("no C compiler on PATH; node X is a real compile")
        fail()
      else:
        let base = m7TestBase("repro-m7-gate")
        var w = newTestNode(base, "worker")
        var o = newTestNode(base, "orch")
        mutualTrust([w, o])
        w.grantRoles(o, "cache-peer,orchestrator")
        var sink = prepareEvidenceSink(base)
        sink.acceptsFrom(w)
        sink.acceptsFrom(o)
        sink.startEvidenceSink()
        let repo = makeFixtureRepo(base, [("src/hello.c", BaseHello),
          ("test.sh", TestScript), ("README", "fixture\n")])
        writeFile(base / "repos", "fixture " & repo.cache & "\n")
        var worker = newWorkerDaemon(base, w)
        var orch: Orchestrator
        defer:
          if not orch.host.isNil: orch.host.stop()
          stopWorkerDaemon(worker)
          stopEvidenceSink(sink)
          removeDir(base)
        worker.startWorkerDaemon(workerSpec(sink, base / "repos"))
        checkpoint("worker daemon log:\n" & worker.daemonLog())
        check "worker role started" in worker.daemonLog()
        orch = newOrchestrator(base, o, worker.peerCachePort(), sink.endpoint)
        let workerId = w.identity.hostId
        check orch.waitConnected(workerId, worker)

        # -- The dirty working tree, snapshotted -------------------------------
        writeFile(repo.dir / "src/hello.c", DirtyHello)
        let snap = repo.snapshotOf("fixture", ["src/hello.c"])
        check snap.manifest.primaryRepo.gitTreeSha1 != ""
        let manifestDigest = orch.publish(encodeManifest(snap.manifest))
        for blob in snap.blobs:
          discard orch.publish(blob)
        var desc = GraphCacheDescriptor(schema: DescriptorSchema,
          project: "m7-fixture", platform: hostOS & "/" & hostCPU,
          snapshotContentId: contentIdOf(snap.manifest),
          nodes: @[
            GraphNode(id: "build-hello",
              argv: @[cc, "-O1", "-o", "out/hello", "src/hello.c"],
              inputs: @["src/hello.c"], outputs: @["out/hello"]),
            GraphNode(id: "test-hello", argv: @["/bin/sh", "test.sh"],
              inputs: @["test.sh"], outputs: @["out/test.ok"], isTest: true)])
        desc.sortNodes()
        check validateDescriptor(desc) == ""
        let descDigest = orch.publish(encodeDescriptor(desc))
        pump(300)

        proc request(id, node: string; argv: seq[string] = @[];
                     inputs: seq[string] = @[];
                     descriptor = descDigest): ReachGoalRequest =
          ReachGoalRequest(requestId: id, graphDescriptorDigest: descriptor,
            snapshotManifestDigest: manifestDigest, goalNode: node,
            claimedArgv: argv, claimedInputs: inputs)

        proc expectRefused(r: GoalReply; trigger: string) =
          check r.kind == grkResponse
          if r.kind == grkResponse:
            let resp = decodeResponse(r.payload)
            checkpoint("refusal: " & resp.trigger & ": " & resp.reason)
            check resp.status == gsRefused
            check resp.trigger == trigger

        # 1. An orchestrator-composed argv is refused, and nothing runs.
        let pwned = base / "pwned"
        expectRefused(orch.reachGoal(workerId, request("r1", "build-hello",
          argv = @["/bin/sh", "-c", "touch " & pwned])),
          "goal-argv-not-derivable")
        check not fileExists(pwned)
        # 2. A node the hydrated descriptor does not contain.
        expectRefused(orch.reachGoal(workerId, request("r2", "fetch-and-run")),
          "goal-argv-not-derivable")
        # 3. Input paths not derivable from the snapshot.
        expectRefused(orch.reachGoal(workerId, request("r3", "build-hello",
          inputs = @["../../../etc/passwd"])), "goal-path-outside-snapshot")
        expectRefused(orch.reachGoal(workerId, request("r4", "build-hello",
          inputs = @["src/secret.c"])), "goal-path-outside-snapshot")
        # 4. A descriptor not evaluated from the snapshot's tree.
        var unbound = desc
        unbound.snapshotContentId = "git-tree-sha1:" & repeat('0', 40)
        let unboundDigest = orch.publish(encodeDescriptor(unbound))
        pump(300)
        expectRefused(orch.reachGoal(workerId, request("r5", "build-hello",
          descriptor = unboundDigest)), "goal-descriptor-unbound")

        # Every refusal is in the OFF-HOST sink, stamped as sent by the worker
        # and naming the orchestrator.
        for trigger in ["goal-argv-not-derivable", "goal-path-outside-snapshot",
                        "goal-descriptor-unbound"]:
          let found = sink.waitForDetection(trigger)
          check found.len >= 1
          for e in found:
            check e.senderHostId == workerId
            check e.record.field("peer") == $o.identity.hostId
        check sink.detections("goal-argv-not-derivable").len >= 2
        # The composed argv is captured as evidence (EVID-1).
        var sawArgv = false
        for e in sink.detections("goal-argv-not-derivable"):
          if pwned in e.record.field("argv"): sawArgv = true
        check sawArgv

        # -- Positive control: the legitimate goal reaches node X -------------
        let built = orch.reachGoal(workerId, request("ok1", "build-hello"))
        check built.kind == grkResponse
        let resp = decodeResponse(built.payload)
        checkpoint("build-hello: " & $resp.status & " exit=" & $resp.exitCode &
          " reason=" & resp.reason & " reports=" & $resp.leaseReports &
          "\nstderr: " & resp.stderrTail &
          "\nworker log:\n" & worker.daemonLog())
        check resp.status == gsCompleted
        check resp.exitCode == 0
        check resp.treeBefore == snap.manifest.primaryRepo.gitTreeSha1
        check resp.outputs.len == 1
        if resp.outputs.len == 1:
          # Fetch the compiled binary back BY ITS DIGEST from the worker.
          let digest = blobDigestFromBytes(resp.outputs[0].digest)
          let bin = waitFor orch.host.client.requestFetchFrom(workerId, digest)
          check bin.isSome
          if bin.isSome:
            let path = base / "hello-from-worker"
            var text = newString(bin.get().len)
            copyMem(addr text[0], unsafeAddr bin.get()[0], text.len)
            writeFile(path, text)
            setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
            check execProcess(path).strip() == "uncommitted greeting"
        check not fileExists(pwned)

        # -- The daemon never reads a declared output through a symlink -------
        # The lease cannot read the worker's host-CA key (it is hidden), but it
        # CAN plant a symlink to it as a declared output. Collecting outputs
        # happens in the daemon, outside every lease layer, so following that
        # link would put the key into the CAS the worker serves.
        let keyPath = w.tlsDir / "host-ca.key"
        let keyBytes = toBytes(readFile(keyPath))
        var leaky = desc
        leaky.nodes.add(GraphNode(id: "leak", argv: @["/bin/sh", "-c",
          "mkdir -p out && ln -s " & quoteShell(keyPath) & " out/leak"],
          inputs: @[], outputs: @["out/leak"]))
        leaky.sortNodes()
        let leakyDigest = orch.publish(encodeDescriptor(leaky))
        pump(300)
        let leak = orch.reachGoal(workerId, request("leak1", "leak",
          descriptor = leakyDigest))
        check leak.kind == grkResponse
        if leak.kind == grkResponse:
          let lr = decodeResponse(leak.payload)
          checkpoint("leak: " & $lr.status & " " & lr.reason)
          check lr.status == gsFailed
          check lr.outputs.len == 0
        check (waitFor orch.host.client.requestFetchFrom(workerId,
          blobDigestFromBytes(blake3.digest(keyBytes)))).isNone
        var sawLeak = false
        for e in sink.waitForDetection("goal-output-not-regular"):
          if e.record.field("path") == "out/leak" and
              e.senderHostId == workerId:
            sawLeak = true
        check sawLeak

        # -- …nor turns a symlinked output directory into a lease rule --------
        # A snapshot may carry symlinks (mode 120000). One standing where an
        # output's directory goes would make the lease's read/exec rules name
        # its target — the worker's own state here. Refused before anything
        # runs, and reported.
        createSymlink(w.root, repo.dir / "outdir")
        var linked = snap.manifest
        let target = toBytes(w.root)
        linked.primaryRepo.modified.add(ModifiedFileEntry(relPath: "outdir",
          mode: ModeSymlink, gitOid: gitBlobOid(target),
          blake3Digest: blake3.digest(target), size: uint64(target.len)))
        linked.primaryRepo.gitTreeSha1 = repo.gitTreeOfWorktree()
        linked.primaryRepo.sortedEntries()
        let linkedDigest = orch.publish(encodeManifest(linked))
        discard orch.publish(target)
        var viaLink = desc
        viaLink.snapshotContentId = contentIdOf(linked)
        viaLink.nodes = @[GraphNode(id: "via-link", argv: @["/bin/sh", "-c",
          "true"], inputs: @[], outputs: @["outdir/x"])]
        let viaLinkDigest = orch.publish(encodeDescriptor(viaLink))
        pump(300)
        let viaReq = ReachGoalRequest(requestId: "link1",
          graphDescriptorDigest: viaLinkDigest,
          snapshotManifestDigest: linkedDigest, goalNode: "via-link")
        expectRefused(orch.reachGoal(workerId, viaReq),
          "goal-path-outside-snapshot")

        # -- goal-schema-invalid reaches the sink ------------------------------
        pump(600)   # the receiver's declared ReachGoal rate (2/s), as `reachGoal` paces
        let garbage = waitFor orch.host.client.requestReachGoal(workerId,
          @[byte(0x52), 0x47, 0x52, 0x51, 0x01, 0x00, 0xff], orch.hydrationSet())
        if garbage.kind == grkRefused:
          checkpoint("refused by the gate: class " &
            $garbage.refusal.refusalClass & ": " & garbage.refusal.reason)
        check garbage.kind == grkResponse
        if garbage.kind == grkResponse:
          check decodeResponse(garbage.payload).trigger == "goal-schema-invalid"
        check sink.waitForDetection("goal-schema-invalid").len >= 1

        # -- exec outside the closure: refused, reported, and reported AT ONCE --
        # The goal execs a copy of /bin/sh from its TMPDIR, then keeps running
        # for several seconds: the detection must be at the sink before the
        # goal ends (G21).
        var probes = desc
        probes.nodes.add(GraphNode(id: "exec-outside", argv: @["/bin/sh", "-c",
          "cp /bin/sh \"$TMPDIR/sh-copy\" && \"$TMPDIR/sh-copy\" -c true; " &
          "sleep 6; true"], inputs: @[], outputs: @[]))
        probes.nodes.add(GraphNode(id: "write-outside", argv: @["/bin/sh", "-c",
          "echo x > " & quoteShell(base / "outside-canary") & " 2>/dev/null; true"],
          inputs: @[], outputs: @[]))
        probes.sortNodes()
        let probesDigest = orch.publish(encodeDescriptor(probes))
        pump(300)
        let execFut = orch.host.client.requestReachGoal(workerId, encodeRequest(
          request("x1", "exec-outside", descriptor = probesDigest)),
          orch.hydrationSet(), timeoutMs = 120_000)
        var seenWhileRunning = false
        let execDeadline = epochTime() + 60.0
        while not execFut.finished and epochTime() < execDeadline:
          for e in sink.detections("exec-outside-closure"):
            if "sh-copy" in e.record.field("destination") and
                e.record.field("peer") == $o.identity.hostId and
                e.senderHostId == workerId:
              seenWhileRunning = true
          if seenWhileRunning: break
          pump(100)
        checkpoint("exec-outside-closure at the sink while the goal ran: " &
          $seenWhileRunning)
        check seenWhileRunning
        let execReply = waitFor execFut
        check execReply.kind == grkResponse
        if execReply.kind == grkResponse:
          check decodeResponse(execReply.payload).leaseReports >= 1
        for e in sink.detections("exec-outside-closure"):
          check e.record.detector == "lease-supervisor"

        # -- a write outside the lease: refused by the filesystem layer, and
        #    reported (fs-denied) -------------------------------------------------
        let writeReply = orch.reachGoal(workerId, request("w1", "write-outside",
          descriptor = probesDigest))
        check writeReply.kind == grkResponse
        check not fileExists(base / "outside-canary")
        var sawFs = false
        for e in sink.waitForDetection("fs-denied", timeoutMs = 15_000):
          if "outside-canary" in e.record.field("destination") and
              e.senderHostId == workerId:
            sawFs = true
        check sawFs

        # -- FLOW-1: the worker opened no connection of its own -----------------
        check worker.statusInt("peers_connected") == 0

  test "a snapshot naming develop siblings is refused before materializing":
    if not hardenedWorkerHere():
      echo HardenedWorkerNA
      skip("platform N/A: hardened workers are Linux-only")
    else:
      let base = m7TestBase("repro-m7-siblings")
      var w = newTestNode(base, "worker")
      var o = newTestNode(base, "orch")
      mutualTrust([w, o])
      w.grantRoles(o, "cache-peer,orchestrator")
      var sink = prepareEvidenceSink(base)
      sink.acceptsFrom(w)
      sink.acceptsFrom(o)
      sink.startEvidenceSink()
      let repo = makeFixtureRepo(base, [("README", "fixture\n")])
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
      # A repo id this worker holds no cache for, in BOTH manifests: the only
      # difference between them is the sibling.
      var plain = repo.snapshotOf("fixture", []).manifest
      plain.primaryRepo.repoId = "not-cached"
      var withSibling = plain
      withSibling.developSiblings = @[RepoSnapshot(repoId: "sibling",
        baseCommitSha: repeat('a', 40), gitTreeSha1: repeat('b', 40))]
      check validateManifest(withSibling) == ""
      proc goalFor(m: WorkspaceSnapshotManifest; id: string): ReachGoalResponse =
        let manifestDigest = orch.publish(encodeManifest(m))
        let desc = GraphCacheDescriptor(schema: DescriptorSchema,
          project: "m7-siblings", platform: hostOS & "/" & hostCPU,
          snapshotContentId: contentIdOf(m),
          nodes: @[GraphNode(id: "t", argv: @["/bin/sh", "-c", "true"],
            inputs: @["README"], outputs: @["out/ok"])])
        let descDigest = orch.publish(encodeDescriptor(desc))
        pump(300)
        let r = orch.reachGoal(workerId, ReachGoalRequest(requestId: id,
          graphDescriptorDigest: descDigest,
          snapshotManifestDigest: manifestDigest, goalNode: "t"))
        check r.kind == grkResponse
        if r.kind == grkResponse:
          result = decodeResponse(r.payload)
          checkpoint(id & ": " & $result.status & " " & result.trigger & ": " &
            result.reason)
      let refused = goalFor(withSibling, "siblings")
      check refused.status == gsRefused
      check refused.trigger == "goal-schema-invalid"
      check "develop" in refused.reason
      var reported = false
      for e in sink.waitForDetection("goal-schema-invalid", pump = proc() =
          orch.host.tick(50)):
        if e.senderHostId == workerId and "develop" in e.record.field("reason") and
            e.record.payload.len > 0:
          reported = true
      check reported
      check worker.statusInt("worker_goals_executed") == 0
      # Control: without the sibling, the sibling check passes and the next
      # one refuses.
      let control = goalFor(plain, "control")
      check control.status == gsRefused
      check control.trigger == "goal-descriptor-unbound"
      check "no repository cache" in control.reason
      check "develop" notin control.reason

  test "trusted profile: the gate refuses and records; the legitimate goal runs":
    let cc = ccPath()
    if cc.len == 0:
      checkpoint("no C compiler on PATH; node X is a real compile")
      fail()
    else:
      let base = m7TestBase("repro-m7-gate-trusted")
      var w = newTestNode(base, "worker")
      var o = newTestNode(base, "orch")
      mutualTrust([w, o])
      w.grantRoles(o, "cache-peer,orchestrator")
      let repo = makeFixtureRepo(base, [("src/hello.c", BaseHello),
        ("README", "fixture\n")])
      writeFile(base / "repos", "fixture " & repo.cache & "\n")
      var worker = newWorkerDaemon(base, w)
      var orch: Orchestrator
      defer:
        if not orch.host.isNil: orch.host.stop()
        stopWorkerDaemon(worker)
        removeDir(base)
      worker.startWorkerDaemon(trustedWorkerSpec(base / "repos"))
      checkpoint("worker daemon log:\n" & worker.daemonLog())
      check "worker role started profile=trusted" in worker.daemonLog()
      orch = newOrchestrator(base, o, worker.peerCachePort(),
        profile = tpTrusted)
      let workerId = w.identity.hostId
      check orch.waitConnected(workerId, worker)
      writeFile(repo.dir / "src/hello.c", DirtyHello)
      let snap = repo.snapshotOf("fixture", ["src/hello.c"])
      let manifestDigest = orch.publish(encodeManifest(snap.manifest))
      for blob in snap.blobs:
        discard orch.publish(blob)
      var desc = GraphCacheDescriptor(schema: DescriptorSchema,
        project: "m7-fixture", platform: hostOS & "/" & hostCPU,
        snapshotContentId: contentIdOf(snap.manifest),
        nodes: @[
          GraphNode(id: "build-hello",
            argv: @[cc, "-O1", "-o", "out/hello", "src/hello.c"],
            inputs: @["src/hello.c"], outputs: @["out/hello"]),
          GraphNode(id: "exec-outside", argv: @["/bin/sh", "-c",
            "cp /bin/sh \"$TMPDIR/sh-copy\" && \"$TMPDIR/sh-copy\" -c true; true"],
            inputs: @[], outputs: @[]),
          # G16, trusted: the action tries the host key on disk and the
          # daemon's process and memory.
          GraphNode(id: "read-host-key", argv: @["/bin/sh", "-c",
            "K=\"$1\"; P=\"$2\"; mkdir -p out; echo LEASE-RAN > out/key.txt; " &
            "if cat \"$K\" >> out/key.txt 2>/dev/null; then echo DISK-READ >> out/key.txt; fi; " &
            "if [ -e \"/proc/$P\" ]; then echo DAEMON-VISIBLE >> out/key.txt; fi; " &
            "if ( exec 3< \"/proc/$P/mem\" ) 2>/dev/null; then echo MEM-OPENED >> out/key.txt; fi; " &
            "if ( exec 3< /proc/self/mem ) 2>/dev/null; then echo SELF-MEM >> out/key.txt; fi; true",
            "sh", w.keyPath, $worker.process.processID],
            outputs: @["out/key.txt"]),
          # A declared impure (fixed-output) action, honest and lying.
          GraphNode(id: "fetch-ok", argv: @["/bin/sh", "-c",
            "mkdir -p out && printf fixed-payload > out/f"],
            outputs: @["out/f"], impure: true,
            fixedOutputs: @[("out/f", blake3.digest(toBytes("fixed-payload")))]),
          GraphNode(id: "fetch-bad", argv: @["/bin/sh", "-c",
            "mkdir -p out && printf fixed-payload > out/f"],
            outputs: @["out/f"], impure: true,
            fixedOutputs: @[("out/f", blake3.digest(toBytes("another-payload")))]),
          # Symlink-free output reads: a link to the host key as an output.
          GraphNode(id: "leak", argv: @["/bin/sh", "-c",
            "mkdir -p out && ln -s " & quoteShell(w.keyPath) & " out/leak"],
            outputs: @["out/leak"]),
          # Runs the binary `build-hello` produced (an input artifact).
          GraphNode(id: "run-hello", argv: @["/bin/sh", "-c",
            "set -u; mkdir -p out; " &
            "\"$REPRO_LEASE_INPUTS/build-hello/out/hello\" > out/ran.txt; " &
            "if ( echo x > \"$REPRO_LEASE_INPUTS/build-hello/out/hello\" ) 2>/dev/null; " &
            "then echo INPUT-WRITTEN >> out/ran.txt; " &
            "else echo INPUT-WRITE-BLOCKED >> out/ran.txt; fi"],
            outputs: @["out/ran.txt"], inputNodes: @["build-hello"],
            isTest: true)])
      desc.sortNodes()
      check validateDescriptor(desc) == ""
      let descDigest = orch.publish(encodeDescriptor(desc))
      pump(300)
      proc fetchText(digest: array[32, byte]): string =
        let got = waitFor orch.host.client.requestFetchFrom(workerId,
          blobDigestFromBytes(digest))
        if got.isSome and got.get().len > 0:
          result = newString(got.get().len)
          copyMem(addr result[0], unsafeAddr got.get()[0], result.len)
      proc record(resp: ReachGoalResponse): ExecutionRecord =
        let bytes = orch.fetchExecutionRecord(workerId,
          resp.executionRecordDigest)
        check bytes.len > 0
        if bytes.len > 0:
          check executionRecordDigestOf(bytes) == resp.executionRecordDigest
          result = decodeExecutionRecord(bytes)
      proc goal(id, node: string; argv: seq[string] = @[];
                inputs: seq[string] = @[];
                artifacts: seq[InputArtifact] = @[]): ReachGoalResponse =
        let r = orch.reachGoal(workerId, ReachGoalRequest(requestId: id,
          graphDescriptorDigest: descDigest,
          snapshotManifestDigest: manifestDigest, goalNode: node,
          claimedArgv: argv, claimedInputs: inputs,
          inputArtifacts: artifacts))
        check r.kind == grkResponse
        if r.kind == grkResponse:
          result = decodeResponse(r.payload)
          checkpoint(id & ": " & $result.status & " " & result.trigger &
            ": " & result.reason)

      # An orchestrator-composed argv: refused, nothing runs, recorded.
      let pwned = base / "pwned"
      let r1 = goal("r1", "build-hello", argv = @["/bin/sh", "-c",
        "touch " & pwned])
      check r1.status == gsRefused
      check r1.trigger == "goal-argv-not-derivable"
      check r1.profile == "trusted"
      check not fileExists(pwned)
      let rec1 = record(r1)
      check rec1.status == "refused"
      check rec1.trigger == "goal-argv-not-derivable"
      check rec1.detections.len >= 1
      if rec1.detections.len >= 1:
        check rec1.detections[0].trigger == "goal-argv-not-derivable"
      # An input path outside the snapshot: refused, recorded.
      let r3 = goal("r3", "build-hello", inputs = @["../../../etc/passwd"])
      check r3.status == gsRefused
      check r3.trigger == "goal-path-outside-snapshot"
      check record(r3).trigger == "goal-path-outside-snapshot"
      # Both are in the worker's local detection log, the composed argv with
      # them (the trusted profile's EVID-1).
      let localLog = worker.detectionLog()
      check "goal-argv-not-derivable" in localLog
      check "goal-path-outside-snapshot" in localLog
      check pwned in localLog

      # Positive control: the legitimate goal reaches node X.
      let ok = goal("ok1", "build-hello")
      check ok.status == gsCompleted
      check ok.treeBefore == snap.manifest.primaryRepo.gitTreeSha1
      check ok.outputs.len == 1
      # What this host's trusted worker can run (Linux: Landlock and the
      # floor when present — `linux-namespace+landlock+floor` on a host with
      # both, `linux-namespace` without).
      let expectedIsolation = isolationLevelOf(LeaseSpec(
        layers: availableLeaseLayers(hardened = false).layers))
      check "isolation=" & expectedIsolation in worker.daemonLog()
      check ok.isolation == expectedIsolation
      if ok.outputs.len == 1:
        let bin = waitFor orch.host.client.requestFetchFrom(workerId,
          blobDigestFromBytes(ok.outputs[0].digest))
        check bin.isSome
        if bin.isSome:
          let path = base / "hello-from-worker"
          var text = newString(bin.get().len)
          copyMem(addr text[0], unsafeAddr bin.get()[0], text.len)
          writeFile(path, text)
          setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
          check execProcess(path).strip() == "uncommitted greeting"
      let okRec = record(ok)
      checkpoint("legitimate goal's record detections: " &
        describeDetections(okRec))
      check okRec.profile == "trusted"
      check okRec.status == "completed"
      check okRec.isolation == expectedIsolation
      check okRec.argv == @[cc, "-O1", "-o", "out/hello", "src/hello.c"]
      check okRec.treeBefore == snap.manifest.primaryRepo.gitTreeSha1
      check okRec.treeAfter == okRec.treeBefore
      when defined(linux):
        # A C compile in a Linux lease produces NO detection at all (G38:
        # the libc's nscd probe connects to a unix socket that does not
        # exist in the lease's new root — it reaches nothing, so it is not
        # reported). No exec outside the closure, no egress, no filesystem
        # or syscall denial.
        check okRec.detections.len == 0
      else:
        # A macOS lease (Seatbelt) reports the compiler's probes of the build
        # user's home and of the daemon state as read denials; nothing else
        # (no exec outside the closure, no egress) may appear.
        for d in okRec.detections:
          check d.trigger == "fs-denied"
      check okRec.outputs.len == 1
      if okRec.outputs.len == 1 and ok.outputs.len == 1:
        check okRec.outputs[0].digest == recordHex(ok.outputs[0].digest)

      # DET-1 in the trusted profile: an exec outside the closure is refused
      # and lands in the execution record and the local log.
      let x = goal("x1", "exec-outside")
      check x.leaseReports >= 1
      var sawExec = false
      for d in record(x).detections:
        if d.trigger == "exec-outside-closure" and "sh-copy" in d.detail:
          sawExec = true
      check sawExec
      check "exec-outside-closure" in worker.detectionLog()

      # G16, trusted: the lease cannot read the worker's host key — not on
      # disk, not in the daemon's memory.
      let keyText = readFile(w.keyPath)
      check keyText.len > 0
      let hk = goal("hk1", "read-host-key")
      check hk.status == gsCompleted
      check hk.outputs.len == 1
      if hk.outputs.len == 1:
        let seen = fetchText(hk.outputs[0].digest)
        checkpoint("read-host-key output:\n" & seen)
        check "LEASE-RAN" in seen                     # positive control
        check "DISK-READ" notin seen
        check keyText.strip() notin seen
        check "BEGIN" notin seen
        check "DAEMON-VISIBLE" notin seen
        check "MEM-OPENED" notin seen
        when defined(linux):
          check "SELF-MEM" in seen                    # /proc works in a lease

      # Symlink-free output reads (both profiles): the planted link to the
      # host key is refused, recorded, and the key never enters the CAS.
      let lk = goal("lk1", "leak")
      check lk.status == gsFailed
      check lk.outputs.len == 0
      var sawLeak = false
      for d in record(lk).detections:
        if d.trigger == "goal-output-not-regular": sawLeak = true
      check sawLeak
      check (waitFor orch.host.client.requestFetchFrom(workerId,
        blobDigestFromBytes(blake3.digest(toBytes(keyText))))).isNone

      # A declared impure action: the matching output publishes…
      let fo = goal("fo1", "fetch-ok")
      check fo.status == gsCompleted
      check fo.outputs.len == 1
      if fo.outputs.len == 1:
        check fo.outputs[0].digest == blake3.digest(toBytes("fixed-payload"))
      let foRec = record(fo)
      check foRec.impure
      for d in foRec.detections:
        check d.trigger != "impure-output-mismatch"
      # …the mismatching one fails, publishes nothing, and is recorded.
      let fb = goal("fb1", "fetch-bad")
      check fb.status == gsFailed
      check fb.outputs.len == 0
      check "does not match its declared digest" in fb.reason
      var sawImpure = false
      for d in record(fb).detections:
        if d.trigger == "impure-output-mismatch": sawImpure = true
      check sawImpure
      check "impure-output-mismatch" in worker.detectionLog()

      # Input artifacts: node 2 RUNS the binary node 1 produced.
      if ok.outputs.len == 1:
        let artifact = InputArtifact(node: "build-hello", path: "out/hello",
          digest: ok.outputs[0].digest)
        let run = goal("run1", "run-hello", artifacts = @[artifact])
        check run.status == gsCompleted
        check run.outputs.len == 1
        if run.outputs.len == 1:
          let ran = fetchText(run.outputs[0].digest)
          checkpoint("run-hello output:\n" & ran)
          check "uncommitted greeting" in ran          # it executed
          check "INPUT-WRITE-BLOCKED" in ran           # and could not alter it
          check "INPUT-WRITTEN" notin ran
        let runRec = record(run)
        check runRec.inputArtifacts.len == 1
        if runRec.inputArtifacts.len == 1:
          check runRec.inputArtifacts[0].node == "build-hello"
          check runRec.inputArtifacts[0].digest == recordHex(ok.outputs[0].digest)
        for d in runRec.detections:
          check d.trigger != "exec-outside-closure"
        # An artifact of a node that is NOT a declared input node: refused.
        let stray = goal("run2", "exec-outside", artifacts = @[artifact])
        check stray.status == gsRefused
        check stray.trigger == "goal-path-outside-snapshot"
        check "not a declared input node" in stray.reason

      # FLOW-1 (D4): the trusted worker opened no connection of its own.
      check worker.statusInt("peers_connected") == 0

      # EVID-6 (the trusted profile's local stores): the detection log, the
      # execution-record index and the execution record itself are
      # owner-only, and every record is listed for its retention sweep.
      let workerDir = worker.stateDir / "worker"
      let indexPath = workerDir / "execution-records.index"
      check fileExists(indexPath)
      if fileExists(indexPath):
        check recordHex(ok.executionRecordDigest) in readFile(indexPath)
      when defined(posix):
        check getFilePermissions(workerDir / "detections.log") ==
          {fpUserRead, fpUserWrite}
        check getFilePermissions(indexPath) == {fpUserRead, fpUserWrite}
        let recPath = worker.casBlobPath(ok.executionRecordDigest)
        check fileExists(recPath)
        if fileExists(recPath):
          check getFilePermissions(recPath) == {fpUserRead}

      # RETENTION WITH AUTOMATED DELETION, end to end on the real store: the
      # production sweep with the production `deleteRecord` (the worker
      # role's, `deleteExecutionRecordBlob` on the daemon's action-cache
      # root), run with a zero retention, deletes the REAL record the worker
      # stored and listed, and the index no longer lists it.
      let realRec = worker.casBlobPath(ok.executionRecordDigest)
      check fileExists(realRec)
      let cacheRoot = worker.cacheRoot
      let prodDelete = proc(d: array[32, byte]): bool {.gcsafe, closure.} =
        {.cast(gcsafe).}:
          deleteExecutionRecordBlob(cacheRoot, d)
      let swept = sweepExecutionRecords(indexPath, prodDelete,
        retentionSeconds = 0)
      checkpoint("execution records swept: " & $swept)
      check swept >= 1
      check not fileExists(realRec)
      check recordHex(ok.executionRecordDigest) notin readFile(indexPath)
      check orch.fetchExecutionRecord(workerId,
        ok.executionRecordDigest).len == 0

      # DET-5 (trusted, no sink): every worker detector heartbeats into the
      # local detection log — the lease supervisor only after its canary
      # proved the detection path (G22) — and the status file names the last
      # heartbeat and the interval, so a dead worker's silent detector is
      # told apart from an idle one.
      var heartbeatMs = 0
      let heartbeatDeadline = epochTime() + 60.0
      while epochTime() < heartbeatDeadline:
        heartbeatMs = worker.statusInt("worker_heartbeat_ms")
        if heartbeatMs > 0 and
            "heartbeat lease-supervisor" in worker.detectionLog():
          break
        sleep(200)
      let heartbeats = worker.detectionLog()
      checkpoint("trusted worker detection log:\n" & heartbeats)
      check heartbeatMs > 0
      check worker.statusInt("worker_heartbeat_interval_ms") > 0
      for detector in ["goal-receiver", "lease-supervisor",
                       "certificate-issuance"]:
        check ("heartbeat " & detector & " ") in heartbeats
      check "heartbeat lease-supervisor intervalMs=" in heartbeats
      check "probe=ok" in heartbeats
      check "detector-probe-failed" notin heartbeats

      # …and the canary's verdict is in the status file, so a trusted
      # worker (no sink to go silent at) whose detection path FAILS is
      # visible there too: with its lease root made unusable (a regular
      # file where the directory was), the next canary cannot run and the
      # status file says so, with the reason, as does the detection log.
      var probeOk = ""
      let okDeadline = epochTime() + 30.0
      while epochTime() < okDeadline:
        probeOk = worker.status().getOrDefault("worker_detector_probe_ok", "")
        if probeOk == "1": break
        sleep(200)
      check probeOk == "1"
      check worker.status().getOrDefault(
        "worker_detector_probe_last_failure", "missing") == ""
      let leaseRoot = workerDir / "leases"
      removeDir(leaseRoot)
      writeFile(leaseRoot, "not a directory\n")
      var failure = ""
      let failDeadline = epochTime() + 60.0
      while epochTime() < failDeadline:
        let st = worker.status()
        probeOk = st.getOrDefault("worker_detector_probe_ok", "")
        failure = st.getOrDefault("worker_detector_probe_last_failure", "")
        if probeOk == "0" and failure.len > 0: break
        sleep(200)
      checkpoint("status after a failed canary: ok=" & probeOk & " failure=" &
        failure)
      check probeOk == "0"
      check "canary lease could not start" in failure
      check "detector-probe-failed" in worker.detectionLog()
