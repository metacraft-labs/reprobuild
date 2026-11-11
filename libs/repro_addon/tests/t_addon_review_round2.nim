## The A11 code review's second round (reprobuild-pm ``issues/2026-11-06-*``
## at ``2ea89eb8``), each finding held at unit level through the real code:
## the real Evidence sink and store, the real off-host check, the real own
## profile renderer and re-pin, the real static tree and custody pass under
## a scratch store. Each case is the reviewer's probe
## (``t_a11rev2_probe_logic.nim``, ``t_a11rev2_probe_static_marker.nim``)
## turned round: it asserts the fixed behaviour.
##
## 1. The shipping backoff's ceiling, plus the run's own bounds, stays
##    strictly below the unit's ``TimeoutStartSec`` (the rendered unit's).
## 2. A host re-keyed twice (A to B to C) raises no retired-without-successor;
##    a chain that ends at an id not enrolled, or loops, does.
## 3. An unreadable check state alerts and is left as it is; an unwritable
##    one alerts; a missing one is reported as new.
## 4. Past the per-check cap, the destinations not recorded by address stay
##    owed and the next check records them, first; the summary says the list
##    was truncated.
## 5. Uninstall's evidence refusal sees an object left aside.
## 6. A re-pin changes the egress observer unit (it names its table), so
##    the switch restarts it; an own profile rendered before is migrated.
## 7. An alert on a heartbeat or an audit record can be acknowledged, and
##    the acknowledgement handles that kind only.
## 8. The static tree's crash marker is written only while a tree is
##    really written, removed when the write fails, and never makes a tree
##    the realisation index records a tear.
## 9. The containment sequence survives the loss of its file: a contain
##    after it is not refused as replayed.
##
## Falsifying builds (each turns its own case red):
## ``ship-backoff-reaches-timeout`` (1), ``successor-chain-one-step`` (2),
## ``lag-state-fails-open`` (3), ``egress-cap-advances-all`` (4),
## ``uninstall-ignores-asides`` (5), ``egress-unit-ignores-table`` (6),
## ``ack-detections-only`` (7), ``tree-marker-on-reuse`` (8),
## ``containment-sequence-unsynced`` (9).
##
## Mocks: none. The sink is the real in-process sink fixture; the store is
## a scratch root.

import std/[options, os, sequtils, strutils, tables, times, unittest]

import repro_peer_cache/auth as peerAuth
import repro_peer_cache/evidence
import repro_peer_cache/evidence_record
import repro_peer_cache/types
import repro_deploy_agent/manifest

import repro_addon/agent_repin
import repro_addon/attestation
import repro_addon/containment
import repro_addon/egress_observer
import repro_addon/evidence as addonEvidence
import repro_addon/evidence_check
import repro_addon/evidence_ship
import repro_addon/evidence_sink_cli
import repro_addon/fingerprint
import repro_addon/generation0
import repro_addon/own_profile
import repro_addon/static_tree
import repro_addon/store_custody

import ./addon_evidence_fixture

let root = getTempDir() / ("a11-round2-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

proc unitTimeoutSec(unit: string): int =
  for l in unit.splitLines():
    if l.startsWith("TimeoutStartSec="):
      let v = l["TimeoutStartSec=".len .. ^1]
      if v.endsWith("min"): return parseInt(v[0 ..< ^3]) * 60
      if v.endsWith("s"): return parseInt(v[0 ..< ^1])
      return parseInt(v)
  -1

proc scratchSite(name: string): CustodySite =
  let st = root / name / "state"
  createDir(st / "addon")
  writeFile(root / name / "evidence.conf", "sink = 127.0.0.1:1\n")
  createDir(root / name / "store")
  custodySite(st, root / name / "store").withEvidence(EvidenceSite(
    stateDir: st, dir: root / name / "ev", outbox: root / name / "ev" / "outbox",
    confPath: root / name / "evidence.conf", attestationKey: root / "none",
    host: "h", journal: false))

proc ownProfileWith(addresses: seq[string]):
    tuple[own: string; agent: AgentUnitsInputs] =
  let agent = AgentUnitsInputs(target: "h1",
    sources: @["http://cache.example:8080/m"],
    allowedAddresses: addresses,
    hosts: @[(address: addresses[0], name: "cache.example")])
  (renderOwnProfile(generation0Objects(Gen0Inputs(
     reproExe: "/repro/store/prefixes/repro-addon-bin/x/bin/repro",
     agent: agent,
     egress: EgressObserverInputs(nft: "/usr/sbin/nft",
                                  allowedAddresses: agent.allowedAddresses))),
     "/repro/store/prefixes/repro-addon-files/y"), agent)

suite "the A11 code review's second round":
  let sink = startSink(root)
  writeFile(sink.storeDir / SinkHostName, sink.hostId & "\n")

  test "1: the shipping backoff stays below the unit's start timeout":
    let unit = evidenceShipUnit("/repro/store/prefixes/x/bin/repro",
      EvidenceUnitsInputs(sinkAddress: "192.0.2.9", sinkPort: 7443,
                          heartbeatSec: 0))
    let timeout = unitTimeoutSec(unit)
    let ss = ShipSite(stateDir: root / "ship1" / "state",
                      outbox: root / "ship1" / "outbox")
    createDir(ss.outbox)
    writeFile(ss.outbox / "1-x.evr", "queued")
    var longest = 0
    for i in 0 ..< 16:
      longest = max(longest, shipRunWait(ss, DefaultEvidenceHeartbeatSec))
    checkpoint "TimeoutStartSec=" & $timeout & " longest wait " & $longest
    # The run's own bounds come on top of the wait: the lock it may wait
    # for, and each pass's drain.
    check timeout > 0
    check longest + ShipLockWaitSec + ShipPassesMax * ShipDrainTimeoutSec <
          timeout

  test "2: a host re-keyed twice raises no retired-without-successor":
    let a = "aa".repeat(32)
    let b = "bb".repeat(32)
    let c = "cc".repeat(32)
    let d = "dd".repeat(32)
    let chain = parseHosts(a & " t - - retired@10:" & b & "\n" &
                           b & " t - - retired@20:" & c & "\n" & c & " t\n")
    let r = runEvidenceCheck(CheckInputs(storeDir: sink.storeDir,
      hosts: chain, nowMs: int64(epochTime() * 1000), silenceFactor: 3))
    checkpoint render(r)
    check not r.alerts.anyIt(it.trigger == "retired-without-successor")
    # A chain that ends at an id not enrolled, or loops, still alerts.
    let dangling = parseHosts(a & " t - - retired@10:" & b & "\n" &
                              b & " t - - retired@20:" & d & "\n")
    check runEvidenceCheck(CheckInputs(storeDir: sink.storeDir,
      hosts: dangling, nowMs: int64(epochTime() * 1000),
      silenceFactor: 3)).alerts.countIt(
        it.trigger == "retired-without-successor") == 2
    let loop = parseHosts(a & " t - - retired@10:" & b & "\n" &
                          b & " t - - retired@20:" & a & "\n")
    check runEvidenceCheck(CheckInputs(storeDir: sink.storeDir, hosts: loop,
      nowMs: int64(epochTime() * 1000), silenceFactor: 3)).alerts.anyIt(
        it.trigger == "retired-without-successor")

  test "3: a check state that cannot be read or written fails closed":
    let kp = peerAuth.generateKeypair()
    proc pub(issuedAgo: int64): DeployManifest =
      result = DeployManifest(target: "lag", sequence: 2, deploymentId: "d2",
        profileText: "p\n", issuedAt: uint64(getTime().toUnix() - issuedAgo),
        maxAgeSeconds: 60)
      signManifest(kp, result)
    let hosts = @[EnrolledHost(hostId: "ef".repeat(32), target: "lag")]
    let dir = root / "lagstate"
    createDir(dir)
    let state = dir / "hosts.check-state"
    var inp = CheckInputs(storeDir: sink.storeDir, hosts: hosts,
      nowMs: int64(epochTime() * 1000), silenceFactor: 3, statePath: state)
    inp.manifests = @[pub(7200)]
    let r0 = runEvidenceCheck(inp)
    check r0.statuses.anyIt(it.detector == "check-state" and it.status == "new")
    let before = readFile(state)
    check before.len > 0
    # Unreadable: an alert, and the file is left exactly as it was.
    setFilePermissions(state, {})
    inp.manifests = @[pub(10)]
    let r1 = runEvidenceCheck(inp)
    setFilePermissions(state, {fpUserRead, fpUserWrite})
    check r1.alerts.anyIt(it.trigger == "check-state-unreadable")
    check readFile(state) == before
    # Readable again: the first publication still counts.
    check runEvidenceCheck(inp).alerts.anyIt(it.detector == "DET-AO-10" and
                                             it.trigger == "lag")
    # A line that is not one of the file's is refused the same way.
    writeFile(state, before & "garbage\n")
    check runEvidenceCheck(inp).alerts.anyIt(
      it.trigger == "check-state-unreadable")
    check readFile(state) == before & "garbage\n"
    # Unwritable: an alert, every run.
    let ro = root / "lagro"
    createDir(ro)
    setFilePermissions(ro, {fpUserRead, fpUserExec})
    inp.statePath = ro / "hosts.check-state"
    inp.manifests = @[pub(7200)]
    let r2 = runEvidenceCheck(inp)
    setFilePermissions(ro, {fpUserRead, fpUserWrite, fpUserExec})
    check r2.alerts.anyIt(it.trigger == "check-state-unwritable")

  test "4: destinations past the cap stay owed and are recorded next":
    let state = root / "egress4.state"
    let ev = EvidenceSite(stateDir: root / "eg4", dir: root / "eg4" / "ev",
      outbox: root / "eg4" / "ev" / "o", confPath: root / "none",
      attestationKey: root / "none", host: "e", journal: false)
    var refused: seq[RefusedDestination]
    for i in 0 ..< EgressDetectionsMax: refused.add(("10.0.0." & $i, 1'i64))
    refused.add(("203.0.113.66", 3'i64))
    let first = freshSince(refused, state, "t")
    recordEgressCheck(EgressCheck(present: true, refused: refused,
                                  fresh: first), ev, 30_000)
    let summary = evidenceRecords("egress-refused-summary", ev.dir)
    check summary.len == 1
    # The decoys grow again; the owed destination is recorded first.
    var again = refused
    for d in again.mitems:
      if d.address != "203.0.113.66": d.packets += 1
    let second = freshSince(again, state, "t")
    recordEgressCheck(EgressCheck(present: true, refused: again,
                                  fresh: second), ev, 30_000)
    var named = false
    for p in evidenceRecords("egress-refused", ev.dir):
      if "203.0.113.66" in readFile(p): named = true
    check named
    check second.len > 0 and second[0].address == "203.0.113.66"

  test "5: uninstall sees an object left aside":
    let site = scratchSite("un5")
    let obj = site.storeRoot / "prefixes" / "x" / "1-a"
    createDir(obj)
    writeFile(obj / "f", "altered\n")
    discard moveAside(site, obj)               # a crash right after this
    check evidenceEntries(site).len == 0
    let pending = pendingStoreEvidence(site)
    check pending.len == 1 and pending[0].startsWith(asideRoot(site))

  test "6: a re-pin changes the unit that loads the egress table":
    let (own, agent) = ownProfileWith(@["192.0.2.1"])
    let unit0 = unitContentOf(own, EgressUnit)
    check sha256Hex(renderEgressNft(@["192.0.2.1"])) in unit0
    var moved = agent
    moved.allowedAddresses = @["198.51.100.7"]
    moved.hosts = @[(address: "198.51.100.7", name: "cache.example")]
    let plan = repinOwnProfile(own, moved, renderAgentHosts(agent))
    check plan.newFiles.len == 1
    let unit1 = unitContentOf(plan.ownText, EgressUnit)
    check unit1 != unit0
    check sha256Hex(plan.newFiles[0].content) in unit1
    # The switch restarts a unit whose content changed: the plan's own
    # migration leaves it so (idempotent).
    check migrateOwnProfile(plan.ownText) == plan.ownText
    # An own profile rendered before (no table digest in the unit) is
    # migrated to name its table.
    var old = own
    old = replaceUnitContent(old, EgressUnit, egressUnit("/usr/sbin/nft"))
    check unitContentOf(migrateOwnProfile(old), EgressUnit) == unit0

  test "7: an alert on a heartbeat can be acknowledged, by its kind":
    let h = newHost(root, "ack7", sink)
    sink.enrol(h)
    createDir(h.evidence.stateDir / "addon")
    layGeneration(h.evidence.stateDir, "g0", "ledger 0\n", "")
    discard recordEvidence(EvidenceEvent(detector: edBootstrap,
      category: ecAudit, trigger: "bootstrap", attest: true), h.evidence)
    let other = root / "ack7-other.key"
    discard ensureAttestationKey(other)
    var ev = h.evidence
    ev.attestationKey = other
    discard recordEvidence(EvidenceEvent(detector: edAgentTick,
      category: ecHeartbeat, kind: "tick", attest: true,
      fields: @[("intervalMs", "330000")]), ev)
    discard runEvidenceShip(h.site, h.conf, "ack7", forceHeartbeat = true)
    let hosts = @[EnrolledHost(hostId: h.credentialHost, target: "t",
                               attestationKey: h.attestationKey)]
    proc check7(): CheckReport =
      runEvidenceCheck(CheckInputs(storeDir: sink.storeDir, hosts: hosts,
        nowMs: int64(epochTime() * 1000), silenceFactor: 3,
        sinkHostId: sinkHostOf(sink.storeDir)))
    let bad = check7().alerts.filterIt(it.trigger == "attestation-invalid")
    check bad.len == 1
    let kind = bad[0].detector & "/" & bad[0].trigger
    check ackRefusal(sink.storeDir, bad[0].sinkSeq.get, kind) == ""
    check ackRefusal(sink.storeDir, bad[0].sinkSeq.get, "not a kind").len > 0
    let inbox = sink.storeDir / OperatorInboxName
    createDir(inbox)
    writeFile(inbox / "7.ack", $bad[0].sinkSeq.get & "\n" & kind &
      "\nalice\nforged heartbeat investigated\n")
    discard processOperatorInbox(sink.server.store, peerIdOfHex(sink.hostId),
                                 inbox)
    let after = check7()
    check not after.alerts.anyIt(it.trigger == "attestation-invalid")
    check after.handled.anyIt(it.alert.trigger == "attestation-invalid")
    # The sink's own acknowledgement is not acknowledged.
    var ackSeq = 0'u64
    for e in sink.entries():
      if e.kind == ekRecord and e.record.detector == "sink-operator": ackSeq = e.seq
    check ackRefusal(sink.storeDir, ackSeq, kind).len > 0

  test "8: the tree marker is written only while a tree is written":
    let site = scratchSite("tree8")
    let files = @[
      StaticFile(path: "/etc/ssh/sshd_config.d/50-hardening.conf",
                 content: "PasswordAuthentication no\nPermitRootLogin no\n"),
      StaticFile(path: "/etc/sudoers.d/50-ops", content: "Defaults use_pty\n")]
    let first = realiseStaticTree(files, site)
    check not fileExists(treeRealisingMarker(site))
    # A marker a crash left naming the committed tree: a truncation is
    # still an alteration (the index records the tree).
    writeFile(treeRealisingMarker(site), first.path & "\n")
    let f = first.path / staticRelPath(files[0].path)
    setFilePermissions(f, {fpUserRead, fpUserWrite})
    writeFile(f, "PasswordAuthentication no\n")
    let again = realiseStaticTree(files, site)
    check readFile(again.path / staticRelPath(files[0].path)) ==
          files[0].content
    check evidenceRecords("store-recovered", site.evidence.dir).len == 1
    check evidenceEntries(site).len == 1
    # A reuse writes no marker.
    discard realiseStaticTree(files, site)
    check not fileExists(treeRealisingMarker(site))

  test "9: a lost containment sequence cannot refuse a genuine contain":
    let h = newHost(root, "seq9", sink)
    sink.enrol(h)
    createDir(h.evidence.stateDir / "addon")
    layGeneration(h.evidence.stateDir, "g0", "ledger 0\n", "")
    discard recordEvidence(EvidenceEvent(detector: edBootstrap,
      category: ecAudit, trigger: "bootstrap", attest: true), h.evidence)
    let st = h.evidence.stateDir
    discard recordContainmentAs(h.evidence, h.credentialHost, "contain",
      "alice", "drill", nextContainmentSequence(st))
    discard recordContainmentAs(h.evidence, h.credentialHost, "release",
      "alice", "done", nextContainmentSequence(st))
    # The counter file is lost (a crash before its data reached the disk,
    # a restore): the next contain must still be newer.
    removeFile(st / "addon" / "containment-sequence")
    sleep(20)          # time moves on, as it does between two operator verbs
    discard recordContainmentAs(h.evidence, h.credentialHost, "contain",
      "alice", "again", nextContainmentSequence(st))
    discard runEvidenceShip(h.site, h.conf, "seq9", forceHeartbeat = true)
    let hosts = @[EnrolledHost(hostId: h.credentialHost, target: "t",
                               attestationKey: h.attestationKey)]
    let r = runEvidenceCheck(CheckInputs(storeDir: sink.storeDir, hosts: hosts,
      nowMs: int64(epochTime() * 1000), silenceFactor: 3,
      sinkHostId: sinkHostOf(sink.storeDir)))
    checkpoint render(r)
    check not r.alerts.anyIt(it.trigger.startsWith("containment-"))

  sink.server.stop()
removeDir(root)
