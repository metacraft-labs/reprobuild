## Distributed-Execution M7: `t_worker_message_authorization_is_per_message_not_per_peer`.
##
## An AUTHENTICATED peer that is not authorized for a message type is refused
## at the receiver (FLOW-4), and the same request delivered directly to the
## daemon's own socket gets the same or a stricter decision — the
## metacraft-api-gateway §7.6 shape applied to this Boundary. Positive
## control: an ordinary authorized message of each declared type still
## succeeds, so the test observes an authorization DECISION rather than a
## closed port.
##
## Nodes: a real worker daemon W (TLS, worker role, evidence sink as its own
## process); an orchestrator O that W grants `cache-peer,orchestrator`; a
## peer P that is authenticated (W pins its host CA) but holds only the
## default `cache-peer` role.
##
##   * every vocabulary entry, sent by an authorized caller, gets the answer
##     its role permits: Hello / identity proof (the connection itself),
##     advertise, advertise refresh, keep-alive, blob fetch, selector query,
##     action-record query, ReachGoal (completed) — and the enumerated but
##     unimplemented M3/M4 messages a `not-implemented` refusal, which is
##     the decision AFTER authorization passed;
##   * P's ReachGoal and P's Attach are refused `unauthorized`, while the
##     same frames from O are not — the decision depends on the caller, per
##     message;
##   * PER MESSAGE, NOT PER PEER: on O's SAME live connection, W's grant to
##     O is withdrawn (the grants file is rewritten; W reloads it) and O's
##     next ReachGoal is refused; restored, the next succeeds. A decision
##     taken at connect time (the neuter experiment recorded in the
##     milestone) keeps admitting O and reddens this case;
##   * a `build-worker` leaf of O's own host is refused ReachGoal (its leaf
##     role caps it to the cache plane whatever its host is granted);
##   * §7.6: the same ReachGoal frame sent to W's daemon control socket is
##     not executed (stricter: that socket has no such verb), and a frame
##     sent to the peer-cache port without TLS never reaches a decision;
##   * every refusal reaches the off-host sink as a `frame-refused`
##     detection stamped as sent by W, naming the caller.
##
## TRUST PROFILES (2026-10-20): per-message authorization at the receiver
## is kept in BOTH profiles. The first case is the hardened worker (refusals
## asserted at the off-host sink); the second is a TRUSTED worker (no sink):
## the same per-caller, per-message decisions, including the withdrawn grant
## on the same live connection, with the refusals in the node's local
## audit log.
##
## MOCK POLICY — none (see `m7_worker_fixture.nim`).

import std/[asyncdispatch, net, options, os, strutils, tables, times,
            unittest]

import repro_peer_cache
import repro_workspace_snapshot
import repro_distributed_worker
import repro_cli_support/peer_cache_wiring

import repro_test_support/reasoned_skip
import ./m7_worker_fixture

const
  Hello = "#include <stdio.h>\nint main(void){puts(\"auth\");return 0;}\n"

proc refusedWith(c: PeerCacheClient; before: int;
                 timeoutMs = 5_000): RefusedNotice =
  let deadline = epochTime() + timeoutMs.float / 1000.0
  while c.refusalsReceived <= before and epochTime() < deadline:
    pump(20)
  c.lastRefusal

suite "Distributed-Execution M7: per-message authorization at the worker":

  test "t_worker_message_authorization_is_per_message_not_per_peer":
    if not hardenedWorkerHere():
      echo HardenedWorkerNA
      skip("platform N/A: hardened workers are Linux-only")
    else:
      let cc = ccPath()
      if cc.len == 0:
        checkpoint("no C compiler on PATH")
        fail()
      else:
        let base = m7TestBase("repro-m7-auth")
        var w = newTestNode(base, "worker")
        var o = newTestNode(base, "orch")
        var p = newTestNode(base, "peer")
        mutualTrust([w, o, p])
        w.grantRoles(o, "cache-peer,orchestrator")
        var sink = prepareEvidenceSink(base)
        for n in [w, o, p]: sink.acceptsFrom(n)
        sink.startEvidenceSink()
        let repo = makeFixtureRepo(base, [("src/hello.c", Hello)])
        writeFile(base / "repos", "fixture " & repo.cache & "\n")
        var worker = newWorkerDaemon(base, w)
        var orch: Orchestrator
        var peer: Orchestrator
        var capped: PeerCacheClient
        defer:
          if not capped.isNil: stopPeerCacheClient(capped)
          if not peer.host.isNil: peer.host.stop()
          if not orch.host.isNil: orch.host.stop()
          stopWorkerDaemon(worker)
          stopEvidenceSink(sink)
          removeDir(base)
        worker.startWorkerDaemon(workerSpec(sink, base / "repos"))
        let workerId = w.identity.hostId
        orch = newOrchestrator(base, o, worker.peerCachePort(), sink.endpoint)
        check orch.waitConnected(workerId, worker)
        peer = newOrchestrator(base, p, worker.peerCachePort(), sink.endpoint)
        check peer.host.client.isConnected(workerId)   # identity proof + Hello

        let snap = repo.snapshotOf("fixture", [])
        let manifestDigest = orch.publish(encodeManifest(snap.manifest))
        var desc = GraphCacheDescriptor(schema: DescriptorSchema,
          project: "m7-auth", platform: hostOS & "/" & hostCPU,
          snapshotContentId: contentIdOf(snap.manifest),
          nodes: @[GraphNode(id: "build",
            argv: @[cc, "-o", "out/hello", "src/hello.c"],
            inputs: @["src/hello.c"], outputs: @["out/hello"])])
        let descDigest = orch.publish(encodeDescriptor(desc))
        pump(300)
        let goal = encodeRequest(ReachGoalRequest(requestId: "g",
          graphDescriptorDigest: descDigest,
          snapshotManifestDigest: manifestDigest, goalNode: "build"))

        # -- Authorized messages of each declared type succeed ----------------
        let ok = waitFor orch.host.client.requestReachGoal(workerId, goal,
          orch.hydrationSet())
        check ok.kind == grkResponse
        let okResp = decodeResponse(ok.payload)
        checkpoint("authorized ReachGoal: " & $okResp.status & " " &
          okResp.reason & "\n" & worker.daemonLog())
        check okResp.status == gsCompleted
        let refusalsBefore = orch.host.client.refusalsReceived
        # Blob fetch (the goal's output), selector and record queries,
        # advertise refresh and keep-alive: answered, never refused. (Advertise
        # itself was exchanged, and admitted, in the connection handshake.)
        if okResp.outputs.len == 1:
          let got = waitFor peer.host.client.requestFetchFrom(workerId,
            blobDigestFromBytes(okResp.outputs[0].digest))
          check got.isSome
        let weak = blobDigestFromBytes(manifestDigest)
        check (waitFor orch.host.client.requestSelectorsFrom(workerId,
          weak)).isSome
        discard waitFor orch.host.client.requestMemoEntryFrom(workerId, weak,
          weak)
        check (waitFor orch.host.client.requestAdvertisementRefresh()) >= 1
        waitFor orch.host.client.sendRawFrameForTesting(workerId, mkPing,
          encodePing(Ping()))
        pump(500)
        check orch.host.client.refusalsReceived == refusalsBefore
        # Reserved vocabulary from an AUTHORIZED caller: refused only as
        # not-implemented — the authorization decision itself passed.
        for kind in [mkAttach, mkExecutePips, mkShardDispatch,
                     mkGraphDescriptorFetch]:
          let before = orch.host.client.refusalsReceived
          waitFor orch.host.client.sendRawFrameForTesting(workerId, kind, @[])
          let notice = refusedWith(orch.host.client, before)
          check notice.refusedTag == uint16(ord(kind))
          check notice.refusalClass == uint8(ord(rcNotImplemented))
        # NotifyPipResults needs the worker-reporter role, which O lacks.
        block:
          let before = orch.host.client.refusalsReceived
          waitFor orch.host.client.sendRawFrameForTesting(workerId,
            mkNotifyPipResults, @[])
          check refusedWith(orch.host.client, before).refusalClass ==
            uint8(ord(rcUnauthorized))

        # -- An authenticated but unauthorized peer is refused ----------------
        let pGoal = waitFor peer.host.client.requestReachGoal(workerId, goal,
          peer.hydrationSet())
        check pGoal.kind == grkRefused
        check pGoal.refusal.refusalClass == uint8(ord(rcUnauthorized))
        block:
          let before = peer.host.client.refusalsReceived
          waitFor peer.host.client.sendRawFrameForTesting(workerId, mkAttach,
            @[])
          check refusedWith(peer.host.client, before).refusalClass ==
            uint8(ord(rcUnauthorized))

        # -- Per message, not per peer: withdraw O's grant mid-connection ------
        let versionBefore = worker.statusInt("grants_version")
        writeFile(w.tlsDir / "grants", "")
        var deadline = epochTime() + 15.0
        while worker.statusInt("grants_version") <= versionBefore and
            epochTime() < deadline:
          pump(50)
        check worker.statusInt("grants_version") > versionBefore
        check orch.host.client.isConnected(workerId)   # the SAME connection
        let withdrawn = waitFor orch.host.client.requestReachGoal(workerId, goal,
          orch.hydrationSet())
        check withdrawn.kind == grkRefused
        check withdrawn.refusal.refusalClass == uint8(ord(rcUnauthorized))
        w.grantRoles(o, "cache-peer,orchestrator")
        let v2 = worker.statusInt("grants_version")
        deadline = epochTime() + 15.0
        while worker.statusInt("grants_version") <= v2 and epochTime() < deadline:
          pump(50)
        let restored = waitFor orch.host.client.requestReachGoal(workerId, goal,
          orch.hydrationSet())
        check restored.kind == grkResponse
        check decodeResponse(restored.payload).status == gsCompleted

        # -- A build-worker leaf of the orchestrator host is capped -----------
        let workerLeaf = mintLeaf(o.identity, lrBuildWorker)
        let anchors = loadTrustAnchorDir(o.anchorsDir)
        capped = newPeerCacheClient(o.identity.hostId, 0'u16,
          newPeerRegistry(o.identity.hostId, initEndpoint("127.0.0.1", Port(0))),
          @[initEndpoint("127.0.0.1", Port(worker.peerCachePort()))],
          @[parseCidrV4("127.0.0.0/8")], trustMode = tmTls,
          ourCert = workerLeaf.cert, trustAnchorSet = anchors)
        capped.leafProvider = proc(): LeafCredential {.gcsafe.} = workerLeaf
        capped.requireShortLivedLeaves = true
        waitFor capped.start()
        check capped.isConnected(workerId)
        let cappedGoal = waitFor capped.requestReachGoal(workerId, goal)
        check cappedGoal.kind == grkRefused
        check cappedGoal.refusal.refusalClass == uint8(ord(rcUnauthorized))

        # -- §7.6: straight to the daemon's own sockets -----------------------
        # The worker's own count of goals it ran (the status file, rewritten
        # on the daemon's store-scan tick): the two authorized ReachGoals above
        # moved it, so it is a live counter. Wait for the file to show them.
        var statusDeadline = epochTime() + 10.0
        while worker.statusInt("worker_goals_executed") < 2 and
            epochTime() < statusDeadline:
          pump(50)
        let leasesBefore = worker.statusInt("worker_goals_executed")
        check leasesBefore >= 2
        block:
          let frame = encodeFrame(mkReachGoalRequest, goal)
          var raw = newString(frame.len)
          copyMem(addr raw[0], unsafeAddr frame[0], frame.len)
          let s = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
          var answer = ""
          try:
            s.connectUnix(worker.endpoint)
            s.send(raw)
            answer = s.recv(4096, timeout = 3_000)
          except CatchableError as err:
            answer = "closed: " & err.msg
          finally:
            s.close()
          checkpoint("daemon control socket answered: " & answer.escape)
          # No ReachGoal response frame comes back: its header (version 1,
          # tag mkReachGoalResponse, little-endian) appears nowhere in the
          # answer. The lease count below is the stronger half: nothing ran.
          let responseHeader = encodeFrame(mkReachGoalResponse, @[])[0 .. 3]
          var headerText = newString(4)
          copyMem(addr headerText[0], unsafeAddr responseHeader[0], 4)
          check headerText notin answer
          let t = newSocket()
          var tcpAnswer = ""
          try:
            t.connect("127.0.0.1", Port(worker.peerCachePort()))
            t.send(raw)
            tcpAnswer = t.recv(64, timeout = 3_000)
          except CatchableError:
            discard
          finally:
            t.close()
          check tcpAnswer.len < 8 or tcpAnswer[0 .. 1] != "\x01\x00"
        # Several status-file rewrites later, the count has not moved:
        # nothing executed.
        pump(2_000)
        check worker.statusInt("worker_goals_executed") == leasesBefore
        # Lease metadata (the goal's stdout/stderr) is not retained (EVID-6).
        var metaLeft = 0
        for _ in walkDir(worker.stateDir / "worker" / "lease-meta"): inc metaLeft
        check metaLeft == 0

        # -- Every refusal reached the off-host sink --------------------------
        let refused = sink.waitForDetection("frame-refused")
        var fromPeer, fromOrch = 0
        for e in sink.detections("frame-refused"):
          check e.senderHostId == workerId
          if e.record.field("refusal") == "unauthorized":
            if e.record.field("peer") == $p.identity.hostId: inc fromPeer
            if e.record.field("peer") == $o.identity.hostId: inc fromOrch
        checkpoint("frame-refused: peer=" & $fromPeer & " orch=" & $fromOrch &
          " total=" & $refused.len)
        check fromPeer >= 2
        check fromOrch >= 2   # NotifyPipResults + the withdrawn-grant ReachGoal

  test "trusted profile: per-message authorization, no sink":
    let cc = ccPath()
    if cc.len == 0:
      checkpoint("no C compiler on PATH")
      fail()
    else:
      let base = m7TestBase("repro-m7-auth-trusted")
      var w = newTestNode(base, "worker")
      var o = newTestNode(base, "orch")
      var p = newTestNode(base, "peer")
      mutualTrust([w, o, p])
      w.grantRoles(o, "cache-peer,orchestrator")
      let repo = makeFixtureRepo(base, [("src/hello.c", Hello)])
      writeFile(base / "repos", "fixture " & repo.cache & "\n")
      var worker = newWorkerDaemon(base, w)
      var orch, peer: Orchestrator
      defer:
        if not peer.host.isNil: peer.host.stop()
        if not orch.host.isNil: orch.host.stop()
        stopWorkerDaemon(worker)
        removeDir(base)
      worker.startWorkerDaemon(trustedWorkerSpec(base / "repos"))
      let workerId = w.identity.hostId
      orch = newOrchestrator(base, o, worker.peerCachePort(),
        profile = tpTrusted)
      check orch.waitConnected(workerId, worker)
      peer = newOrchestrator(base, p, worker.peerCachePort(),
        profile = tpTrusted)
      check peer.host.client.isConnected(workerId)
      let snap = repo.snapshotOf("fixture", [])
      let manifestDigest = orch.publish(encodeManifest(snap.manifest))
      let desc = GraphCacheDescriptor(schema: DescriptorSchema,
        project: "m7-auth", platform: hostOS & "/" & hostCPU,
        snapshotContentId: contentIdOf(snap.manifest),
        nodes: @[GraphNode(id: "build",
          argv: @[cc, "-o", "out/hello", "src/hello.c"],
          inputs: @["src/hello.c"], outputs: @["out/hello"])])
      let descDigest = orch.publish(encodeDescriptor(desc))
      pump(300)
      let goal = encodeRequest(ReachGoalRequest(requestId: "g",
        graphDescriptorDigest: descDigest,
        snapshotManifestDigest: manifestDigest, goalNode: "build"))
      # Positive control: the authorized orchestrator's goal runs.
      let ok = waitFor orch.host.client.requestReachGoal(workerId, goal,
        orch.hydrationSet())
      check ok.kind == grkResponse
      if ok.kind == grkResponse:
        check decodeResponse(ok.payload).status == gsCompleted
      # An authenticated peer without the orchestrator role: refused.
      pump(600)
      let pGoal = waitFor peer.host.client.requestReachGoal(workerId, goal,
        peer.hydrationSet())
      check pGoal.kind == grkRefused
      if pGoal.kind == grkRefused:
        check pGoal.refusal.refusalClass == uint8(ord(rcUnauthorized))
      # Per message: withdraw O's grant on the SAME live connection.
      let versionBefore = worker.statusInt("grants_version")
      writeFile(w.tlsDir / "grants", "")
      var deadline = epochTime() + 15.0
      while worker.statusInt("grants_version") <= versionBefore and
          epochTime() < deadline:
        pump(50)
      check orch.host.client.isConnected(workerId)
      pump(600)
      let withdrawn = waitFor orch.host.client.requestReachGoal(workerId, goal,
        orch.hydrationSet())
      check withdrawn.kind == grkRefused
      w.grantRoles(o, "cache-peer,orchestrator")
      let v2 = worker.statusInt("grants_version")
      deadline = epochTime() + 15.0
      while worker.statusInt("grants_version") <= v2 and epochTime() < deadline:
        pump(50)
      pump(600)
      let restored = waitFor orch.host.client.requestReachGoal(workerId, goal,
        orch.hydrationSet())
      check restored.kind == grkResponse
      # The refusals are in the trusted node's LOCAL audit log.
      let audit = worker.stateDir / "peer-cache-audit.log"
      let text = if fileExists(audit): readFile(audit) else: ""
      check "unauthorized" in text
      check $p.identity.hostId in text
