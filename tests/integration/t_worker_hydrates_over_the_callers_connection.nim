## Distributed-Execution M7, threat model deviation D4 (FLOW-1: "The Interior
## initiates. Always."): a worker never opens a connection to its requester
## or orchestrator — developer workstations, Interior hosts. It hydrates the
## graph descriptor, the snapshot manifest and the snapshot's blobs over the
## connection the CALLER opened, and the caller answers only for what it
## published for that goal.
##
##   * the orchestrator's Hello puts its listener in the worker's registry,
##     and the worker's membership loop runs every second — yet the worker
##     opens no connection to it (its client dials only declared seeds);
##   * a goal that needs the orchestrator's blobs completes regardless
##     (positive control): every byte came back over the orchestrator's own
##     connection, BLAKE3-verified;
##   * the requester side refuses worker-initiated connections: once the
##     orchestrator designates the worker an Edge host (`edge` in its grants
##     file), a worker that dials it anyway — here because an operator
##     declared the orchestrator as its seed — is refused at its first frame
##     after the identity proof (`edge-initiated`), recorded off-host, while
##     the goals the orchestrator sends still complete.
##
## A build the worker daemon HOSTS (a local `repro build --daemon=require`,
## forked from the daemon) is held to the same rule: its short-lived
## peer-cache client is seeded with the daemon's declared seeds only, never
## with the requesters and orchestrators the daemon's registry learned from
## their Hellos. The second case observes the forked build's dials from the
## far side — every node counts the inbound connections whose identity
## proof verified, per host and leaf role — so a build-worker connection to
## the orchestrator cannot go unseen; a declared seed receives one
## (positive control: the observation sees build dials, and declared seeds
## still work). That case needs no execution lease.
##
## The client side of the hydration vocabulary — a worker asking for a
## digest the caller did not publish is refused and ends the connection — is
## covered in `t_worker_message_authorization`.
##
## MOCK POLICY — none (see `m7_worker_fixture.nim`).

import std/[asyncdispatch, options, os, osproc, sets, strtabs, strutils,
            tables, times, unittest]

import repro_peer_cache
import repro_workspace_snapshot
import repro_distributed_worker

import repro_test_support/reasoned_skip
import ./m7_worker_fixture

const Hello = "#include <stdio.h>\nint main(void){puts(\"hydrated\");return 0;}\n"

proc writeHostedProject(projectRoot: string) =
  ## A one-action cacheable project (`sh -c` copies `input.txt` into a
  ## declared output), built through the worker daemon.
  createDir(projectRoot)
  writeFile(projectRoot / "input.txt", "hosted\n")
  let script = "set -eu\nmkdir -p build\ncat input.txt > build/artifact.txt\n"
  writeFile(projectRoot / "reprobuild.nim",
    "import repro_project_dsl\n\n" &
    "package workerHostedD4:\n" &
    "  uses:\n" &
    "    \"sh >=1\"\n\n" &
    "  executable shTool:\n" &
    "    name \"sh\"\n" &
    "    cli:\n" &
    "      subcmd \"-c\":\n" &
    "        pos args, seq[string], position = 0\n\n" &
    "    build:\n" &
    "      let action = buildAction(\"hosted-copy\",\n" &
    "        workerHostedD4.executable(\"sh\").subcmd_2d_c(\n" &
    "          args = @[" & escape(script) & ", \"sh\"]),\n" &
    "        inputs = @[\"input.txt\"],\n" &
    "        outputs = @[\"build/artifact.txt\"],\n" &
    "        cacheable = true)\n" &
    "      defaultBuildAction(action)\n")

proc buildThroughWorkerDaemon(d: WorkerDaemon; projectRoot: string;
                              keepServing: openArray[PeerCacheHost]): int =
  ## `repro build --daemon=require` through the worker daemon, so the build
  ## runs in a worker the daemon forks. The in-process nodes keep serving
  ## while it runs: a dial they did not accept would go unobserved.
  var env = newStringTable(modeCaseSensitive)
  for key, value in envPairs():
    env[key] = value
  for (key, value) in daemonEnv(d):
    env[key] = value
  if getEnv("REPRO_NIM_COMPILER").len == 0 and findExe("nim").len > 0:
    env["REPRO_NIM_COMPILER"] = findExe("nim")
  var p = startProcess(publicReproBin(),
    args = @["build", projectRoot, "--daemon=require",
             "--tool-provisioning=path", "--action-cache-root=" & d.cacheRoot,
             "--progress=quiet", "--log=summary"],
    workingDir = repoRootDir(), env = env,
    options = {poUsePath, poStdErrToStdOut, poParentStreams})
  defer: p.close()
  let deadline = epochTime() + 600.0
  while p.running and epochTime() < deadline:
    for h in keepServing: h.tick(20)
  if p.running:
    p.terminate()
  result = p.waitForExit()
  for _ in 0 ..< 10:
    for h in keepServing: h.tick(20)

suite "Distributed-Execution M7: the worker hydrates over the caller's connection (D4)":

  test "the worker never dials the requester, and the requester refuses it":
    if not hardenedWorkerHere():
      echo HardenedWorkerNA
      skip("platform N/A: hardened workers are Linux-only")
    else:
      let cc = ccPath()
      check cc.len > 0
      let base = m7TestBase("repro-m7-d4")
      var w = newTestNode(base, "worker")
      var o = newTestNode(base, "orch")
      mutualTrust([w, o])
      w.grantRoles(o, "cache-peer,orchestrator")
      var sink = prepareEvidenceSink(base)
      sink.acceptsFrom(w)
      sink.acceptsFrom(o)
      sink.startEvidenceSink()
      let repo = makeFixtureRepo(base, [("src/hello.c", "int main(void){return 0;}\n")])
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
      # The worker learned the orchestrator's listener from its Hello; over
      # three membership rounds it must still dial nothing.
      let quietUntil = epochTime() + 3.5
      while epochTime() < quietUntil:
        orch.host.tick(50)
      check worker.statusInt("peers_known") >= 1
      check worker.statusInt("peers_connected") == 0

      # A goal whose inputs exist only at the orchestrator (an uncommitted
      # edit): hydrated over the orchestrator's connection.
      writeFile(repo.dir / "src/hello.c", Hello)
      let snap = repo.snapshotOf("fixture", ["src/hello.c"])
      let manifestDigest = orch.publish(encodeManifest(snap.manifest))
      for blob in snap.blobs: discard orch.publish(blob)
      let desc = GraphCacheDescriptor(schema: DescriptorSchema, project: "m7-d4",
        platform: hostOS & "/" & hostCPU,
        snapshotContentId: contentIdOf(snap.manifest),
        nodes: @[GraphNode(id: "build", argv: @[cc, "-o", "out/hello",
          "src/hello.c"], inputs: @["src/hello.c"], outputs: @["out/hello"])])
      let descDigest = orch.publish(encodeDescriptor(desc))
      pump(300)
      let servedBefore = orch.host.client.hydrationServed
      let reply = orch.reachGoal(workerId, ReachGoalRequest(requestId: "h1",
        graphDescriptorDigest: descDigest, snapshotManifestDigest: manifestDigest,
        goalNode: "build"))
      check reply.kind == grkResponse
      if reply.kind == grkResponse:
        let resp = decodeResponse(reply.payload)
        checkpoint("goal: " & $resp.status & " " & resp.reason & "\n" &
          resp.stderrTail)
        check resp.status == gsCompleted
      # Descriptor, manifest and the edited blob: three hydration fetches
      # served over the orchestrator's connection.
      check orch.host.client.hydrationServed - servedBefore >= 3
      check worker.statusInt("peers_connected") == 0

      # -- The requester refuses worker-initiated connections -----------------
      let grants = o.tlsDir / "grants"
      writeFile(grants, $workerId & " cache-peer,edge\n")
      for _ in 0 ..< 20: orch.host.tick(50)
      check workerId in orch.host.server.gate.policy.edgeHosts
      let workerPort = worker.peerCachePort()
      stopWorkerDaemon(worker)
      # Same listener port, so the orchestrator's seed still names it.
      worker.startWorkerDaemon(workerSpec(sink, base / "repos",
        extra = "&listen=" & $workerPort & "&seeds=127.0.0.1:" &
          $int(orch.host.actualPort)))
      discard waitFor orch.host.client.connectKnownPeers()
      check orch.waitConnected(workerId, worker)
      var refusedEdge = false
      let deadline = epochTime() + 15.0
      while not refusedEdge and epochTime() < deadline:
        orch.host.tick(50)
        for e in sink.detections("frame-refused"):
          if e.record.field("refusal") == "edge-initiated" and
              e.record.field("peer") == $workerId and
              e.senderHostId == o.identity.hostId:
            refusedEdge = true
      check refusedEdge
      check orch.host.server.gate.refusedCount[rcEdgeInitiated] >= 1
      check worker.statusInt("peers_connected") == 0
      # …and the orchestrator's own goals still complete over its connection.
      let again = orch.reachGoal(workerId, ReachGoalRequest(requestId: "h2",
        graphDescriptorDigest: descDigest, snapshotManifestDigest: manifestDigest,
        goalNode: "build"))
      check again.kind == grkResponse
      if again.kind == grkResponse:
        check decodeResponse(again.payload).status == gsCompleted

  test "a build the worker daemon hosts dials only its declared seeds":
    let base = m7TestBase("repro-m7-d4-hosted")
    var w = newTestNode(base, "worker")
    var o = newTestNode(base, "orch")
    var sd = newTestNode(base, "seed")
    mutualTrust([w, o, sd])
    w.grantRoles(o, "cache-peer,orchestrator")
    # TRUSTED profile (D4 is kept in both profiles, and this case needs no
    # sink): pinned long-lived host keys, the hosted build's own
    # build-worker certificate.
    let repo = makeFixtureRepo(base, [("src/hello.c", "int main(void){return 0;}\n")])
    writeFile(base / "repos", "fixture " & repo.cache & "\n")
    let project = base / "ws"
    writeHostedProject(project)
    # The declared seed: an ordinary cache peer the operator named.
    let seedCache = base / "seed-cache"
    createDir(seedCache)
    let seedHost = startPeerCacheHost(tlsConfig(sd, profile = tpTrusted),
      sd.identity.hostId, cacheRoot = seedCache)
    var worker = newWorkerDaemon(base, w)
    var orch: Orchestrator
    defer:
      if not orch.host.isNil: orch.host.stop()
      stopWorkerDaemon(worker)
      seedHost.stop()
      removeDir(base)
    worker.startWorkerDaemon(trustedWorkerSpec(base / "repos",
      extra = "&seeds=127.0.0.1:" & $int(seedHost.actualPort)))
    orch = newOrchestrator(base, o, worker.peerCachePort(),
      profile = tpTrusted)
    let workerId = w.identity.hostId
    check orch.waitConnected(workerId, worker)
    # The orchestrator's Hello put its listener in the worker's registry
    # (beside the seed): exactly what a hosted build used to be seeded with.
    var known = false
    let knownDeadline = epochTime() + 15.0
    while not known and epochTime() < knownDeadline:
      orch.host.tick(50)
      seedHost.tick(10)
      known = worker.statusInt("peers_known") >= 2
    check known
    let orchBefore = orch.host.server.inboundAuthenticated[(workerId, lrBuildWorker)]
    let seedBefore = seedHost.server.inboundAuthenticated[(workerId, lrBuildWorker)]
    check orchBefore == 0

    let code = buildThroughWorkerDaemon(worker, project, [orch.host, seedHost])
    if code != 0:
      checkpoint("worker daemon log:\n" & worker.daemonLog())
    check code == 0
    check fileExists(project / "build" / "artifact.txt")
    # Positive control: the hosted build dialled its declared seed with its
    # own build-worker leaf, and the seed saw it.
    check seedHost.server.inboundAuthenticated[(workerId, lrBuildWorker)] >
      seedBefore
    # …and never the orchestrator, under any leaf.
    check orch.host.server.inboundAuthenticated[(workerId, lrBuildWorker)] == 0
    for role in LeafRole:
      check orch.host.server.inboundAuthenticated[(workerId, role)] == 0
    check worker.statusInt("peers_connected") >= 1   # the seed, nothing else
