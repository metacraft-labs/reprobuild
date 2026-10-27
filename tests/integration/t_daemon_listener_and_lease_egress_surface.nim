## Distributed-Execution M7: `t_daemon_listener_and_lease_egress_surface`.
##
## FLOW-6: the listener table of a worker daemon (`ss -tlnp` on Linux, `lsof
## -iTCP -sTCP:LISTEN` on macOS) shows ONLY the declared interface and the
## ports the specification calls public — the peer-cache port. A wildcard
## bind is refused outright, and the listener checker flags a `0.0.0.0`
## listener (rebinding the daemon to `0.0.0.0` reddens this test; that
## neuter experiment is recorded in the milestone).
##
## FLOW-3: from inside an execution lease, an off-allow-list destination
## fails and the attempt is REPORTED to the off-host sink, while the DECLARED
## egress destinations (a peer cache and a tool source) succeed through the
## supervisor's forwarders — the positive control separating a deny from a
## dead network. Distributed-Execution M7 review (threat model G26): the
## allow-list is exactly the operator's declared `egress=` destinations and
## nothing else — not even the node's own listener, which a lease holds no
## credential to use; a lease that needs a peer cache is given one as a
## declared destination. So a DNS probe (UDP/53) is also denied and reported
## here (FLOW-3 "including DNS", which had no test).
##
## Trust profiles (2026-10-20): the listener rule and lease egress are kept
## in BOTH profiles. The hardened phase below asserts the denials at the
## off-host sink; the trusted phase (the default profile — no sink at all,
## and a non-loopback listener is allowed without one) asserts the same
## denials in the goal's execution record and the worker's local detection
## log — every one on Linux, where the supervisor refuses and reports each
## connect itself; on macOS every report that ARRIVES, because the kernel's
## Seatbelt report channel is lossy under host-wide report load (threat
## model G8, G41: the denial is asserted always, a missing report is
## printed; `t_execution_lease_confinement` asserts the macOS report path
## end to end). A lease's network is exactly the destinations its NODE declares
## (`GraphNode.egress`): a node that declares none has no network, even to
## a destination the operator allows (the `no-network` node).
##
## The declared interface is the host's first non-loopback interface with
## an IPv4 address (a real LAN interface on a workstation), falling back to
## the loopback interface on a host that has none; either way it is NAMED,
## and the listener must carry exactly its address.
##
## MOCK POLICY — none: the shipped daemon, the OS's own socket table, a real
## lease running bash's /dev/tcp against real sockets.

import std/[asyncdispatch, asyncnet, nativesockets, net, options, os, osproc,
            sequtils, strutils, tables, times, unittest]

import repro_peer_cache
import repro_workspace_snapshot
import repro_distributed_worker

import ./m7_worker_fixture

type
  Listener* = object
    address*: string
    port*: int

proc tcpListenersOf*(pid: int): seq[Listener] =
  ## The TCP listeners process `pid` holds, from the OS's socket table.
  when defined(linux):
    let res = execCmdEx("ss -H -tlnp")
    for line in res.output.splitLines:
      if ("pid=" & $pid & ",") notin line: continue
      let cols = line.splitWhitespace()
      if cols.len < 4: continue
      let local = cols[3]
      let colon = local.rfind(':')
      result.add(Listener(address: local[0 ..< colon].strip(chars = {'[', ']'}),
        port: parseInt(local[colon + 1 .. ^1])))
  else:
    let res = execCmdEx("lsof -nP -a -p " & $pid & " -iTCP -sTCP:LISTEN -F n")
    for line in res.output.splitLines:
      if not line.startsWith("n"): continue
      let local = line[1 .. ^1]
      let colon = local.rfind(':')
      if colon < 0: continue
      var address = local[0 ..< colon]
      if address == "*": address = "0.0.0.0"
      result.add(Listener(address: address.strip(chars = {'[', ']'}),
        port: parseInt(local[colon + 1 .. ^1])))

proc undeclared*(listeners: seq[Listener]; address: string;
                 ports: seq[int]): seq[string] =
  ## Every listener not on the declared address and public ports.
  for l in listeners:
    if l.address != address or l.port notin ports:
      result.add(l.address & ":" & $l.port)

proc declaredInterface(): tuple[name, address: string] =
  for la in localIpv4Addresses():
    if not la.isLoopback:
      return (la.interfaceName, la.address)
  for la in localIpv4Addresses():
    if la.isLoopback:
      return (la.interfaceName, la.address)
  ("", "")

const NoEgressScript = """#!/bin/bash
mkdir -p out
: > out/none.txt
if (exec 3<>"/dev/tcp/127.0.0.1/CACHE_PORT") 2>/dev/null; then echo UNDECLARED_OPEN >> out/none.txt; fi
echo done >> out/none.txt
"""

const EgressScript = """#!/bin/bash
set -u
pc=$REPRO_LEASE_EGRESS_PEER_CACHE
tl=$REPRO_LEASE_EGRESS_TOOLS
out=out/egress.txt
mkdir -p out
: > "$out"
if (exec 3<>"/dev/tcp/${pc%:*}/${pc##*:}") 2>/dev/null; then echo PEER_CACHE_OK >> "$out"; fi
if exec 4<>"/dev/tcp/${tl%:*}/${tl##*:}" 2>/dev/null; then
  read -r line <&4 || true
  echo "TOOL_OK $line" >> "$out"
  exec 4>&-
fi
if (exec 5<>"/dev/tcp/127.0.0.1/EXFIL_PORT") 2>/dev/null; then echo EXFIL_OPEN >> "$out"; fi
if (exec 6<>"/dev/tcp/1.1.1.1/443") 2>/dev/null; then echo INTERNET_OPEN >> "$out"; fi
# G26: not even this node's own peer-cache listener is reachable.
if [ -n "$M7_SELF" ] && (exec 8<>"/dev/tcp/${M7_SELF%:*}/${M7_SELF##*:}") 2>/dev/null; then echo SELF_OPEN >> "$out"; fi
# FLOW-3 "including DNS": a UDP/53 resolve attempt must be denied too.
if (exec 7<>"/dev/udp/1.1.1.1/53") 2>/dev/null; then echo DNS_OPEN >> "$out"; fi
echo done >> "$out"
"""

proc hostBash(): string =
  ## An absolute `bash` inside the lease closure. The scripts need bash for
  ## `/dev/tcp`, but a fixed `/bin/bash` exists on an FHS host only (NixOS
  ## has no `/bin` beyond `/bin/sh`): take the one on PATH, followed through
  ## profile symlinks until it lies under a closure root.
  var p = findExe("bash")
  doAssert p.len > 0, "no `bash` on PATH"
  for _ in 0 ..< 16:
    let dir = p.parentDir
    if dir in ["/usr/bin", "/bin"] or dir.startsWith("/nix/store/"):
      return p
    if not symlinkExists(p): break
    let target = expandSymlink(p)
    p = if target.isAbsolute: target else: dir / target
  p

proc serveOnce(sock: AsyncSocket; reply: string; hits: ref int) {.async.} =
  while true:
    let c = await sock.accept()
    inc hits[]
    if reply.len > 0:
      try: await c.send(reply) except CatchableError: discard
    c.close()

suite "Distributed-Execution M7: daemon listener and lease egress surface":

  test "t_daemon_listener_and_lease_egress_surface":
    let iface = declaredInterface()
    check iface.name.len > 0
    let base = m7TestBase("repro-m7-surface")
    var w = newTestNode(base, "worker")
    var o = newTestNode(base, "orch")
    mutualTrust([w, o])
    w.grantRoles(o, "cache-peer,orchestrator")
    var sink = prepareEvidenceSink(base)
    sink.acceptsFrom(w)
    sink.acceptsFrom(o)
    sink.startEvidenceSink()
    # A declared tool source and an exfiltration target, both real sockets.
    let tool = newAsyncSocket()
    tool.setSockOpt(OptReuseAddr, true)
    tool.bindAddr(Port(0), "127.0.0.1")
    tool.listen()
    let toolPort = int(getLocalAddr(tool.getFd(), Domain.AF_INET)[1])
    let toolHits = new(int)
    asyncCheck serveOnce(tool, "tool-bytes\n", toolHits)
    let exfil = newAsyncSocket()
    exfil.setSockOpt(OptReuseAddr, true)
    exfil.bindAddr(Port(0), "127.0.0.1")
    exfil.listen()
    let exfilPort = int(getLocalAddr(exfil.getFd(), Domain.AF_INET)[1])
    let exfilHits = new(int)
    asyncCheck serveOnce(exfil, "", exfilHits)
    # A declared peer cache: a real accepting socket. G26 — the lease reaches
    # it only because it is a DECLARED egress destination (`egress=peer-cache`),
    # not because it is the node's own listener.
    let cacheSock = newAsyncSocket()
    cacheSock.setSockOpt(OptReuseAddr, true)
    cacheSock.bindAddr(Port(0), "127.0.0.1")
    cacheSock.listen()
    let cachePort = int(getLocalAddr(cacheSock.getFd(), Domain.AF_INET)[1])
    let cacheHits = new(int)
    asyncCheck serveOnce(cacheSock, "cache\n", cacheHits)

    let repo = makeFixtureRepo(base, [("egress.sh",
      EgressScript.replace("EXFIL_PORT", $exfilPort)),
      ("none.sh", NoEgressScript.replace("CACHE_PORT", $cachePort))])
    writeFile(base / "repos", "fixture " & repo.cache & "\n")
    var worker = newWorkerDaemon(base, w)
    var refused = newWorkerDaemon(base, newTestNode(base, "wildcard"))
    var tw = newTestNode(base, "tworker")
    var to = newTestNode(base, "torch")
    mutualTrust([tw, to])
    tw.grantRoles(to, "cache-peer,orchestrator")
    var trusted = newWorkerDaemon(base, tw)
    var orch, torch: Orchestrator
    defer:
      if not orch.host.isNil: orch.host.stop()
      if not torch.host.isNil: torch.host.stop()
      stopWorkerDaemon(trusted)
      stopWorkerDaemon(refused)
      stopWorkerDaemon(worker)
      stopEvidenceSink(sink)
      tool.close()
      exfil.close()
      cacheSock.close()
      removeDir(base)

    # -- FLOW-6: a wildcard bind is refused ------------------------------------
    check not resolveBindSpec("0.0.0.0").ok
    # (Profile-independent: the wildcard is refused when the spec is parsed.)
    refused.startWorkerDaemon(trustedWorkerSpec(base / "repos") &
      "&bind=0.0.0.0", expectStart = false)
    check refused.peerCachePort() == 0

    let cidr = iface.address & "/32"
    if not hardenedWorkerHere():
      # The hardened profile refuses this host's worker (macOS/Windows):
      # the trusted phase below covers the listener and egress here.
      echo HardenedWorkerNA
    else:
      # -- The daemon binds the declared interface, nothing else ---------------
      worker.startWorkerDaemon(workerSpec(sink, base / "repos", cidr = cidr,
        extra = "&bind=" & iface.name & "&egress=peer-cache@127.0.0.1:" &
          $cachePort & ",tools@127.0.0.1:" & $toolPort))
      let endpoint = worker.peerCacheEndpoint()
      checkpoint("declared interface " & iface.name & " = " & iface.address &
        "; peer cache endpoint " & endpoint)
      # G26: the lease allow-list is EXACTLY the two declared destinations —
      # no forwarder to the node's own listener is added beside them (a lease
      # could reach such a forwarder by its loopback port even if no variable
      # names it).
      check " egress=2 " in worker.daemonLog()
      check endpoint == iface.address & ":" & $worker.peerCachePort()
      let listeners = tcpListenersOf(worker.process.processID)
      checkpoint("listeners of the worker daemon: " & $listeners)
      check listeners.len >= 1
      check undeclared(listeners, iface.address, @[worker.peerCachePort()]).len == 0
      # The checker is not vacuous: a wildcard listener IS flagged.
      let wildcard = newSocket()
      wildcard.setSockOpt(OptReuseAddr, true)
      wildcard.bindAddr(Port(0), "0.0.0.0")
      wildcard.listen()
      let own = tcpListenersOf(getCurrentProcessId())
      wildcard.close()
      check undeclared(own, iface.address, @[worker.peerCachePort()]).anyIt(
        it.startsWith("0.0.0.0:"))

      # -- FLOW-3: lease egress --------------------------------------------------
      # The orchestrator binds the same declared interface: the worker dials
      # it back there to hydrate the descriptor and snapshot.
      orch = newOrchestrator(base, o, worker.peerCachePort(), sink.endpoint,
        workerAddress = iface.address, bindSpec = iface.name, cidr = cidr)
      let workerId = w.identity.hostId
      check orch.waitConnected(workerId, worker)
      let snap = repo.snapshotOf("fixture", [])
      let manifestDigest = orch.publish(encodeManifest(snap.manifest))
      let desc = GraphCacheDescriptor(schema: DescriptorSchema,
        project: "m7-egress", platform: hostOS & "/" & hostCPU,
        snapshotContentId: contentIdOf(snap.manifest),
        nodes: @[GraphNode(id: "egress", argv: @[hostBash(), "egress.sh"],
          inputs: @["egress.sh"], outputs: @["out/egress.txt"],
          env: @[("M7_SELF", iface.address & ":" & $worker.peerCachePort())],
          egress: @["peer-cache", "tools"]),
          GraphNode(id: "no-network", argv: @[hostBash(), "none.sh"],
          inputs: @["none.sh"], outputs: @["out/none.txt"])])
      let descDigest = orch.publish(encodeDescriptor(desc))
      pump(300)
      let reply = orch.reachGoal(workerId, ReachGoalRequest(requestId: "e",
        graphDescriptorDigest: descDigest,
        snapshotManifestDigest: manifestDigest, goalNode: "egress"))
      check reply.kind == grkResponse
      let resp = decodeResponse(reply.payload)
      checkpoint("egress goal: " & $resp.status & " " & resp.reason &
        " reports=" & $resp.leaseReports & "\n" & worker.daemonLog())
      check resp.status == gsCompleted
      var observed = ""
      if resp.outputs.len == 1:
        let bytes = waitFor orch.host.client.requestFetchFrom(workerId,
          blobDigestFromBytes(resp.outputs[0].digest))
        if bytes.isSome:
          observed = newString(bytes.get().len)
          copyMem(addr observed[0], unsafeAddr bytes.get()[0], observed.len)
      checkpoint("inside the lease:\n" & observed)
      check "PEER_CACHE_OK" in observed          # allow-listed: peer cache
      check "TOOL_OK tool-bytes" in observed     # allow-listed: tool source
      check "EXFIL_OPEN" notin observed          # denied
      check "INTERNET_OPEN" notin observed       # denied
      check "DNS_OPEN" notin observed            # denied (FLOW-3 incl. DNS)
      check "SELF_OPEN" notin observed           # G26: not the node's listener
      check "done" in observed
      check exfilHits[] == 0                     # the deny happened below it
      check cacheHits[] >= 1                     # the declared peer cache
      check toolHits[] >= 1
      # Each denied attempt was REPORTED off-host.
      # The supervisor reports each attempt as it happens and the appender
      # delivers them in order, so wait for BOTH destinations rather than for
      # the first detection to land.
      var sawExfil, sawInternet, sawDns = false
      var denied: seq[EvidenceEntry] = @[]
      let deadline = epochTime() + 15.0
      while not (sawExfil and sawInternet and sawDns) and
          epochTime() < deadline:
        denied = sink.detections("egress-denied")
        for e in denied:
          let dest = e.record.field("destination")
          if dest.endsWith(":" & $exfilPort): sawExfil = true
          if dest.endsWith(":443"): sawInternet = true
          if dest.endsWith(":53"): sawDns = true
        if not (sawExfil and sawInternet and sawDns): pump(100)
      for e in denied:
        check e.senderHostId == workerId
        check e.record.detector == "lease-supervisor"
      checkpoint("egress-denied detections: " & $denied.len)
      check sawExfil
      check sawInternet
      check sawDns                                # the DNS attempt, reported (G26)

      # -- Network off unless the NODE declares destinations --------------------
      let hitsBefore = cacheHits[]
      let noNet = orch.reachGoal(workerId, ReachGoalRequest(requestId: "n",
        graphDescriptorDigest: descDigest,
        snapshotManifestDigest: manifestDigest, goalNode: "no-network"))
      check noNet.kind == grkResponse
      let noResp = decodeResponse(noNet.payload)
      check noResp.status == gsCompleted
      var noObserved = ""
      if noResp.outputs.len == 1:
        let bytes = waitFor orch.host.client.requestFetchFrom(workerId,
          blobDigestFromBytes(noResp.outputs[0].digest))
        if bytes.isSome:
          noObserved = newString(bytes.get().len)
          copyMem(addr noObserved[0], unsafeAddr bytes.get()[0], noObserved.len)
      checkpoint("no-network node:\n" & noObserved)
      check "done" in noObserved
      check "UNDECLARED_OPEN" notin noObserved   # the operator allows it; the
      check cacheHits[] == hitsBefore            # node did not declare it

    # -- TRUSTED profile: same listener rule and egress, no sink ---------------
    # A trusted worker on the declared LAN interface starts WITHOUT an
    # evidence sink (a hardened one is refused without one) and binds only
    # that interface; its denials land in the execution record and the local
    # detection log.
    trusted.startWorkerDaemon(trustedWorkerSpec(base / "repos", cidr = cidr,
      extra = "&bind=" & iface.name & "&egress=peer-cache@127.0.0.1:" &
        $cachePort & ",tools@127.0.0.1:" & $toolPort))
    check "profile=trusted" in trusted.daemonLog()
    check trusted.peerCacheEndpoint() == iface.address & ":" &
      $trusted.peerCachePort()
    let tListeners = tcpListenersOf(trusted.process.processID)
    check tListeners.len >= 1
    check undeclared(tListeners, iface.address,
      @[trusted.peerCachePort()]).len == 0
    torch = newOrchestrator(base, to, trusted.peerCachePort(),
      workerAddress = iface.address, bindSpec = iface.name, cidr = cidr,
      profile = tpTrusted)
    let tId = tw.identity.hostId
    check torch.waitConnected(tId, trusted)
    let tSnap = repo.snapshotOf("fixture", [])
    let tDescObj = GraphCacheDescriptor(schema: DescriptorSchema,
      project: "m7-egress", platform: hostOS & "/" & hostCPU,
      snapshotContentId: contentIdOf(tSnap.manifest),
      nodes: @[GraphNode(id: "egress", argv: @[hostBash(), "egress.sh"],
        inputs: @["egress.sh"], outputs: @["out/egress.txt"],
        env: @[("M7_SELF", iface.address & ":" & $trusted.peerCachePort())],
        egress: @["peer-cache", "tools"])])
    let tMan = torch.publish(encodeManifest(tSnap.manifest))
    let tDesc = torch.publish(encodeDescriptor(tDescObj))
    pump(300)
    let tReply = torch.reachGoal(tId, ReachGoalRequest(requestId: "te",
      graphDescriptorDigest: tDesc, snapshotManifestDigest: tMan,
      goalNode: "egress"))
    check tReply.kind == grkResponse
    let tResp = decodeResponse(tReply.payload)
    checkpoint("trusted egress goal: " & $tResp.status & " " & tResp.reason &
      "\n" & trusted.daemonLog())
    check tResp.status == gsCompleted
    check tResp.profile == "trusted"
    var tObserved = ""
    if tResp.outputs.len == 1:
      let bytes = waitFor torch.host.client.requestFetchFrom(tId,
        blobDigestFromBytes(tResp.outputs[0].digest))
      if bytes.isSome:
        tObserved = newString(bytes.get().len)
        copyMem(addr tObserved[0], unsafeAddr bytes.get()[0], tObserved.len)
    check "PEER_CACHE_OK" in tObserved
    check "TOOL_OK tool-bytes" in tObserved
    check "EXFIL_OPEN" notin tObserved
    check "INTERNET_OPEN" notin tObserved
    check "DNS_OPEN" notin tObserved
    check exfilHits[] == 0
    let recBytes = torch.fetchExecutionRecord(tId, tResp.executionRecordDigest)
    check recBytes.len > 0
    if recBytes.len > 0:
      let rec = decodeExecutionRecord(recBytes)
      check rec.profile == "trusted"
      check rec.egress == @["peer-cache", "tools"]
      checkpoint("trusted record detections: " & describeDetections(rec))
      var tExfil, tInternet, tDns = false
      var tDenied = 0
      for d in rec.detections:
        if d.trigger == "egress-denied":
          inc tDenied
          if d.detail.endsWith(":" & $exfilPort): tExfil = true
          if d.detail.endsWith(":443"): tInternet = true
          if d.detail.endsWith(":53"): tDns = true
          # Whatever is reported names a destination the lease was denied
          # (the exfil port, the internet, DNS, the node's own listener —
          # G26), never one of the declared (forwarded) ones.
          check d.detail.endsWith(":" & $exfilPort) or
            d.detail.endsWith(":443") or d.detail.endsWith(":53") or
            d.detail.endsWith(":" & $trusted.peerCachePort())
      let tLog = trusted.detectionLog()
      when defined(macosx):
        # macOS: the lease supervisor learns of a denial only from the
        # kernel's Seatbelt report in the unified log, and that channel is
        # lossy — measured (2026-10-27): with another process on the host
        # producing Sandbox reports, 19 of 30 tagged leases lost some or all
        # of their network reports. The DENIAL above is asserted always;
        # each report that arrives is asserted to reach the execution record
        # and the local log with its destination; a missing one is printed,
        # not failed (threat model G8, G41; the loss-free path is M8's
        # VM-boundary deliverable). The kernel-report path itself is
        # asserted end to end by `t_execution_lease_confinement`'s
        # "denied egress is reported" case.
        if tDenied == 0:
          echo "[lossy channel G41] no egress-denied report reached this " &
            "lease's record (the denials themselves held)"
        else:
          check "egress-denied" in tLog
          if not (tExfil and tInternet and tDns):
            echo "[lossy channel G41] some egress-denied reports did not " &
              "arrive (exfil=" & $tExfil & " internet=" & $tInternet &
              " dns=" & $tDns & "; the denials themselves held)"
        if tExfil: check ":" & $exfilPort in tLog
      else:
        # Linux: the supervisor refuses and reports each connect itself
        # (seccomp), in process; every attempt is reported.
        check tExfil
        check tInternet
        check tDns
        check "egress-denied" in tLog
        check ":" & $exfilPort in tLog
