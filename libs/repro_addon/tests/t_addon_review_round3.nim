## The A11 code review's third round (reprobuild-pm ``issues/2026-11-06-*``
## at ``65ffa248``), and §13 decision 56, held at unit level through the
## real code: the observer check's state, the off-host check's state, the
## real in-process Evidence sink over TLS, the sink's acknowledgement
## inbox, the custody site under a scratch store.
##
## 1. Owed egress destinations are recorded oldest first: with 200 decoys
##    kept fresh, a destination listed last is recorded within a bounded
##    number of checks.
## 2. Owed destinations survive a reload (an empty table of a new instance)
##    and are recorded at the next check.
## 3. An empty or headerless state file fails closed: the observer check's
##    and the off-host check's.
## 4. A forbidden-verb probe the sink never received is not a refusal: the
##    self-test fails and names it.
## 5. The acknowledgement rules hold where acknowledgements are appended
##    and where they are honoured, not only in the ``ack`` command.
## 6. Uninstall's evidence (decision 56): every object left aside and every
##    entry filed but not recorded gets a ``store-recovery-interrupted``
##    record, once.
## 7. The containment sequence keeps growing when the host clock goes back.
## 8. An alert on the sink store's first entry names sequence 0, and the
##    operator's own `ack --seq 0` command handles it; a silence names none.
##
## Falsifying builds (each turns its own case red):
## ``egress-owed-by-listing`` (1), ``egress-owed-dropped-at-reload`` (2),
## ``egress-state-empty-is-valid`` and ``check-state-empty-is-valid`` (3),
## ``probe-undelivered-is-refused`` (4), ``ack-rules-cli-only`` (5),
## ``uninstall-discards-unrecorded`` (6), ``alert-seq-zero-is-none`` (8).
## Case 7 holds behaviour the time
## floor's ``last + 1`` already gives; no build breaks it but one that drops
## that floor.
##
## Mocks: none. The sinks are the real in-process sink fixture.

import std/[asyncdispatch, options, os, osproc, sequtils, streams, strtabs, strutils, tables, times, unittest]

import repro_peer_cache/auth as peerAuth
import repro_peer_cache/evidence
import repro_peer_cache/evidence_record
import repro_peer_cache/identity
import repro_peer_cache/types
import repro_deploy_agent/manifest

import repro_addon/containment
import repro_addon/egress_observer
import repro_addon/evidence as addonEvidence
import repro_addon/evidence_check
import repro_addon/evidence_ship
import repro_addon/evidence_sink_cli
import repro_addon/store_custody

import ./addon_evidence_fixture

let root = getTempDir() / ("a11-round3-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

proc scratchSite(name: string): CustodySite =
  let st = root / name / "state"
  createDir(st / "addon")
  writeFile(root / name / "evidence.conf", "sink = 127.0.0.1:1\n")
  createDir(root / name / "store")
  custodySite(st, root / name / "store").withEvidence(EvidenceSite(
    stateDir: st, dir: root / name / "ev", outbox: root / name / "ev" / "outbox",
    confPath: root / name / "evidence.conf", attestationKey: root / "none",
    host: "h", journal: false))

if getEnv("A11_ACK_CHILD").len > 0:
  # Case 8's operator: the sink's `ack` command, exactly as documented.
  quit(runSinkCli(["ack", "--dir", getEnv("A11_ACK_CHILD"), "--seq", "0",
    "--alert", "DET-AO-2/apply-refused", "--operator", "alice",
    "--reason", "handled", "--wait-seconds", "60"]))

suite "the A11 code review's third round":
  let sink = startSink(root)
  writeFile(sink.storeDir / SinkHostName, sink.hostId & "\n")

  test "1: owed egress destinations are recorded oldest first":
    let state = root / "egress1.state"
    var refused: seq[RefusedDestination]
    for i in 0 ..< 200: refused.add(("10.1." & $(i div 250) & "." & $(i mod 250), 1'i64))
    refused.add(("203.0.113.66", 1'i64))           # listed last
    # One check records EgressDetectionsMax; everything else is owed, in
    # the order it became owed. 201 fresh at once: recorded by check 4.
    let bound = (refused.len + EgressDetectionsMax - 1) div EgressDetectionsMax + 1
    var recordedAt = -1
    for check in 1 .. 40:
      let fresh = freshSince(refused, state, "t")
      let cap = min(fresh.len, EgressDetectionsMax)
      if recordedAt < 0 and fresh[0 ..< cap].anyIt(it.address == "203.0.113.66"):
        recordedAt = check
      for d in refused.mitems: d.packets += 1        # every one sends again
    checkpoint "recorded at check " & $recordedAt & ", bound " & $bound
    check recordedAt > 0 and recordedAt <= bound

  test "2: owed destinations survive a reload":
    let state = root / "egress2.state"
    var refused: seq[RefusedDestination]
    for i in 0 ..< EgressDetectionsMax: refused.add(("10.2.0." & $i, 1'i64))
    refused.add(("203.0.113.77", 2'i64))
    let first = freshSince(refused, state, "t1")
    check not first[0 ..< EgressDetectionsMax].anyIt(it.address == "203.0.113.77")
    # A reload: a new table instance, its sets empty.
    let second = freshSince(@[], state, "t2")
    check second.len >= 1 and second[0].address == "203.0.113.77"
    check second[0].packets == 2

  test "3: an empty state file fails closed":
    # The observer check's.
    let es = root / "egress3.state"
    writeFile(es, "")
    expect EgressStateError:
      discard freshSince(@[("192.0.2.1", 1'i64)], es, "t")
    check readFile(es) == ""
    # The off-host check's.
    let kp = peerAuth.generateKeypair()
    proc pub(issuedAgo: int64): DeployManifest =
      result = DeployManifest(target: "lag", sequence: 2, deploymentId: "d2",
        profileText: "p\n", issuedAt: uint64(getTime().toUnix() - issuedAgo),
        maxAgeSeconds: 60)
      signManifest(kp, result)
    let state = root / "lag3" / "hosts.check-state"
    createDir(parentDir(state))
    var inp = CheckInputs(storeDir: sink.storeDir,
      hosts: @[EnrolledHost(hostId: "ef".repeat(32), target: "lag")],
      nowMs: int64(epochTime() * 1000), silenceFactor: 3, statePath: state)
    inp.manifests = @[pub(7200)]
    discard runEvidenceCheck(inp)
    check readFile(state).startsWith(CheckStateHeader)
    writeFile(state, "")
    inp.manifests = @[pub(10)]
    let r = runEvidenceCheck(inp)
    check r.alerts.anyIt(it.trigger == "check-state-unreadable")
    check readFile(state) == ""

  test "4: a probe the sink never received is not a refusal":
    let sink4 = startSink(root / "s4")
    let h = newHost(root / "s4", "gone", sink4)
    sink4.enrol(h)
    let a = openAppender(h.site, h.conf)
    a.append(newEvidenceRecord(ecAudit, "addon-evidence-ship",
      "credential-probe", [("host", "gone")], nowMs = 1))
    check a.drain(20_000)
    a.close()
    sink4.server.stop()                    # the sink goes away
    var outcomes: seq[ProbeOutcome]
    for op in ForbiddenOperation:
      outcomes.add(try: waitFor a.probeForbiddenOperation(op)
                   except CatchableError: poUndelivered)
    checkpoint $outcomes
    check outcomes.allIt(it == poUndelivered)
    check credentialCheckOk(CredentialCheck(appended: true,
      answered: toSeq(ForbiddenOperation).mapIt((it, poUndelivered)))) == false

  test "5: the acknowledgement rules hold where acknowledgements are kept":
    let h = newHost(root, "ack5", sink)
    sink.enrol(h)
    let a = openAppender(h.site, h.conf)
    a.append(newEvidenceRecord(ecDetection, "addon-apply-refusal",
      "apply-refused", [("host", "ack5")], nowMs = 1))
    check a.drain(20_000)
    a.close()
    var det = 0'u64
    var found = false
    for e in sink.entries():
      if e.kind == ekRecord and e.record.trigger == "apply-refused":
        det = e.seq
        found = true
    check found
    let inbox = sink.storeDir / OperatorInboxName
    createDir(inbox)
    proc drop(name, body: string): int =
      writeFile(inbox / name, body)
      processOperatorInbox(sink.server.store, peerIdOfHex(sink.hostId), inbox)
    # Not appended: a malformed kind, a sequence not in the store.
    check drop("bad-kind.ack", $det & "\nnot a kind\nalice\nx\n") == 0
    check drop("future.ack", $(det + 1000) & "\nDET-AO-2/apply-refused\nalice\nx\n") == 0
    # Appended: a valid one. Then the sink's own acknowledgement is refused.
    check drop("ok.ack", $det & "\nDET-AO-2/apply-refused\nalice\nhandled\n") == 1
    var ackSeq = 0'u64
    for e in sink.entries():
      if e.kind == ekRecord and e.record.detector == "sink-operator": ackSeq = e.seq
    check drop("own.ack", $ackSeq & "\nDET-AO-2/apply-refused\nalice\nx\n") == 0
    # An acknowledgement record of a sequence after its own (appended by
    # anything but the inbox) is never honoured by the check: the record it
    # names came after it.
    var role = lrDaemon
    for e in sink.entries():
      if e.seq == det: role = e.senderRole
    let L = sink.server.store.appendRecord(peerIdOfHex(sink.hostId),
      lrDaemon, ackRecord(sink.entries()[^1].seq + 2, "DET-AO-2/apply-refused",
                          "mallory", "early", int64(epochTime() * 1000)))
    let D = sink.server.store.appendRecord(peerIdOfHex(h.credentialHost), role,
      newEvidenceRecord(ecDetection, "addon-apply-refusal", "apply-refused",
                        [("host", "ack5")], nowMs = 3))
    checkpoint "early ack at " & $L & ", detection at " & $D
    check D == L + 1
    let r = runEvidenceCheck(CheckInputs(storeDir: sink.storeDir,
      hosts: @[EnrolledHost(hostId: h.credentialHost, target: "t")],
      nowMs: int64(epochTime() * 1000), silenceFactor: 3,
      sinkHostId: sinkHostOf(sink.storeDir)))
    checkpoint render(r)
    check r.handled.anyIt(it.alert.sinkSeq == some(det))
    check r.alerts.anyIt(it.trigger == "apply-refused" and it.sinkSeq == some(D))

  test "6: uninstall reports set-aside and unrecorded evidence first, once":
    let site = scratchSite("un6")
    let obj = site.storeRoot / "prefixes" / "x" / "1-a"
    createDir(obj)
    writeFile(obj / "f", "altered\n")
    discard moveAside(site, obj)                       # a crash after step 2
    let obj2 = site.storeRoot / "prefixes" / "x" / "2-b"
    createDir(obj2)
    writeFile(obj2 / "f", "altered too\n")
    discard fileEvidence(site, moveAside(site, obj2), obj2, "e", "o", "t")
    # (filed, its record not yet written: a crash between steps 3 and 5)
    check recordUnreportedStoreEvidence(site) == 2
    check evidenceRecords("store-recovery-interrupted",
                          site.evidence.dir).len == 2
    check toSeq(walkDir(asideRoot(site))).anyIt(it.kind == pcDir)  # not moved
    check recordUnreportedStoreEvidence(site) == 0             # once
    check evidenceRecords("store-recovery-interrupted",
                          site.evidence.dir).len == 2

  test "7: the containment sequence grows when the clock goes back":
    let st = root / "seq7"
    createDir(st / "addon")
    let t = int64(epochTime() * 1000)
    let a = nextContainmentSequence(st, t)
    let b = nextContainmentSequence(st, t - 3_600_000)    # an hour back
    check b > a

  test "8: an alert on the store's first entry names sequence 0 and can be handled":
    let sink8 = startSink(root / "s8")
    defer: sink8.server.stop()
    writeFile(sink8.storeDir / SinkHostName, sink8.hostId & "\n")
    let h = newHost(root / "s8", "first", sink8)
    sink8.enrol(h)
    let a = openAppender(h.site, h.conf)
    a.append(newEvidenceRecord(ecDetection, "addon-apply-refusal",
      "apply-refused", [("host", "first")], nowMs = 1))
    check a.drain(20_000)
    a.close()
    check sink8.entries()[0].kind == ekRecord and
          sink8.entries()[0].record.trigger == "apply-refused"
    let first = sink8.entries()[0].seq
    check first == 0'u64
    proc run8(): CheckReport =
      runEvidenceCheck(CheckInputs(storeDir: sink8.storeDir,
        hosts: @[EnrolledHost(hostId: h.credentialHost, target: "t")],
        nowMs: int64(epochTime() * 1000), silenceFactor: 3,
        sinkHostId: sinkHostOf(sink8.storeDir)))
    let r0 = run8()
    check r0.alerts.anyIt(it.trigger == "apply-refused" and
                          it.sinkSeq == some(0'u64))
    check "apply-refused seq=0" in render(r0)
    # Through the operator's own command, `repro-evidence-sink ack --seq 0`
    # (run in a child process, as an operator runs it); this process stands
    # in for the running sink's inbox loop meanwhile.
    let inbox = sink8.storeDir / OperatorInboxName
    createDir(inbox)
    let child = startProcess(getAppFilename(), env = newStringTable({
      "A11_ACK_CHILD": sink8.storeDir, "TMPDIR": getTempDir()}),
      options = {poStdErrToStdOut})
    var appended = 0
    while child.running:
      appended += processOperatorInbox(sink8.server.store,
                                       peerIdOfHex(sink8.hostId), inbox)
      sleep(100)
    appended += processOperatorInbox(sink8.server.store,
                                     peerIdOfHex(sink8.hostId), inbox)
    let ackOut = child.outputStream.readAll()
    let ackCode = child.waitForExit()
    child.close()
    checkpoint ackOut
    check ackCode == 0 and appended == 1
    let r1 = run8()
    checkpoint render(r1)
    check not r1.alerts.anyIt(it.trigger == "apply-refused")
    check r1.handled.anyIt(it.alert.sinkSeq == some(0'u64))
    # A silence has no sequence at all, and prints none.
    check r1.alerts.filterIt(it.trigger == "never-reported").allIt(
      it.sinkSeq.isNone)

  sink.server.stop()
removeDir(root)
