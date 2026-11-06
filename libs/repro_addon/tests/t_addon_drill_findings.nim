## The A11 drill's findings (reprobuild-pm
## ``Measurements/2026-11-05-addon-a11-drill.md``), each held at unit level
## through the real Evidence sink, its real store and the real off-host
## check (spec §13 decisions 51 and 52, §10.4):
##
## * D1: a record that lands while a shipping run ships leaves with that
##   run, and the path unit starts the shipping unit on a non-empty outbox
##   (``DirectoryNotEmpty=``), not on a change systemd may drop.
## * D3: the sink shows a record's payload, escaped, between untrusted
##   markers.
## * D4: an operator's acknowledgement, appended by the sink under its own
##   id, turns the acknowledged alert into a handled one; one appended by a
##   host does not.
## * D5: a signed containment recorded while the tick was live reads
##   ``contained`` past the silence window; an unsigned one, or one recorded
##   after the tick went silent, still reads ``silent``; a release restarts
##   the silence clock.
## * D6: the refusal record names its preserved staging copy and the
##   compiler.
## * D7: a key hand-over signed by the enrolled key is followed by
##   ``--update-hosts`` (new id enrolled, old id retired); one signed by
##   another key, or after the old key was retired, is an alert; a record
##   under a retired id is an alert.
## * D9: the host's announced credential self-test reads as ``self-test``,
##   not four G34 alerts; unannounced refused verbs still alert.
##
## Falsifying builds: ``evidence-path-changed-only`` (D1),
## ``sink-payload-unescaped`` (D3), ``check-ignores-acks`` (D4),
## ``check-ignores-containment`` (D5), ``refusal-names-no-copy`` (D6),
## ``handover-unverified`` (D7), ``check-ignores-probe-announcement`` (D9):
## each turns its step red.
##
## Mocks: none. The sink runs in this process (``addon_evidence_fixture``,
## for the reason given there); time is the check's ``nowMs``.

import std/[asyncdispatch, os, sequtils, strutils, times, unittest]

import repro_peer_cache/evidence
import repro_peer_cache/evidence_record
import repro_peer_cache/types
import repro_deploy_agent/agent
import repro_deploy_agent/tick_status

import repro_addon/agent_split
import repro_addon/attestation
import repro_addon/evidence as addonEvidence
import repro_addon/evidence_check
import repro_addon/evidence_ship
import repro_addon/evidence_sink_cli
import repro_addon/generation0

import ./addon_evidence_fixture

let root = getTempDir() / ("addon-drill-findings-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

proc bootstrapHost(h: HostFixture) =
  createDir(h.evidence.stateDir / "addon")
  layGeneration(h.evidence.stateDir, "g0", "ledger 0\n", "")
  discard recordEvidence(EvidenceEvent(detector: edBootstrap,
    category: ecAudit, trigger: "bootstrap", attest: true), h.evidence)

proc tick(h: HostFixture; ctx = AgentApplyContext(); kind = aoConverged) =
  recordTickEvidence(RecordedTick(outcome: AgentOutcome(kind: kind,
    target: "t", message: ctx.refusal)), ctx, h.evidence)

proc ship(h: HostFixture) =
  let r = runEvidenceShip(h.site, h.conf, h.evidence.host, forceHeartbeat = true)
  doAssert r.error == "", r.error

proc statusOf(r: CheckReport; host, det: string): string =
  for s in r.statuses:
    if s.host == host and s.detector == det: return s.status
  "absent"

proc inputsFor(sink: SinkFixture; hosts: seq[EnrolledHost];
               nowMs: int64): CheckInputs =
  CheckInputs(storeDir: sink.storeDir, hosts: hosts, nowMs: nowMs,
    silenceFactor: 3, sinkHostId: sinkHostOf(sink.storeDir))

suite "the A11 drill's findings":
  let sink = startSink(root)
  writeFile(sink.storeDir / SinkHostName, sink.hostId & "\n")

  test "D1: a record landing during a shipping run leaves with it":
    let h = newHost(root, "ship", sink)
    sink.enrol(h)
    discard recordEvidence(EvidenceEvent(detector: edApplyRefusal,
      category: ecDetection, trigger: "apply-refused"), h.evidence)
    var wrote = false
    let r = runEvidenceShip(h.site, h.conf, "ship", onPass = proc () =
      if not wrote:
        wrote = true
        discard recordEvidence(EvidenceEvent(detector: edRollback,
          category: ecDetection, trigger: "rolled-back"), h.evidence))
    check r.shipped == 2
    check outboxEntries(h.site.outbox).len == 0
    check "DirectoryNotEmpty=" & EvidenceOutboxPath in evidenceShipPathUnit()

  test "D3: a payload is shown escaped, between untrusted markers":
    let h = newHost(root, "payload", sink)
    sink.enrol(h)
    discard recordEvidence(EvidenceEvent(detector: edApplyRefusal,
      category: ecDetection, trigger: "addon-staging-refused",
      payload: "planted\n\x1b[2Jcleared"), h.evidence)
    h.ship()
    var found = false
    for e in sink.entries():
      if e.kind == ekRecord and e.record.trigger == "addon-staging-refused" and
          $e.senderHostId == h.credentialHost:
        let shown = renderPayload(e)
        check "BEGIN UNTRUSTED PAYLOAD" in shown
        check "planted\n" in shown
        check "\\x1b[2J" in shown
        check '\x1b' notin shown
        found = true
    check found

  test "D4: the sink's acknowledgement handles an alert; a host's does not":
    let h = newHost(root, "ack", sink)
    sink.enrol(h)
    bootstrapHost(h)
    discard recordEvidence(EvidenceEvent(detector: edApplyRefusal,
      category: ecDetection, trigger: "apply-refused"), h.evidence)
    h.tick()
    h.ship()
    var det = 0'u64
    for e in sink.entries():
      if e.kind == ekRecord and $e.senderHostId == h.credentialHost and
          e.record.category == ecDetection: det = e.seq
    check det > 0'u64
    # A host forging an acknowledgement: ignored.
    var forged = ackRecord(det, "DET-AO-2/apply-refused", "mallory",
                           "nothing to see", 0)
    writeOutboxRecord(h.site.outbox, forged, "forged-ack")
    h.ship()
    let hosts = @[EnrolledHost(hostId: h.credentialHost, target: "t")]
    let before = runEvidenceCheck(inputsFor(sink, hosts, int64(epochTime() * 1000)))
    check before.alerts.anyIt(it.sinkSeq == det)
    # The operator, through the sink's own inbox.
    let inbox = sink.storeDir / OperatorInboxName
    createDir(inbox)
    writeFile(inbox / "1.ack", $det & "\nDET-AO-2/apply-refused\nalice\n" &
      "investigated\n")
    check processOperatorInbox(sink.server.store, peerIdOfHex(sink.hostId),
                               inbox) == 1
    let after = runEvidenceCheck(inputsFor(sink, hosts, int64(epochTime() * 1000)))
    check not after.alerts.anyIt(it.sinkSeq == det)
    check after.handled.anyIt(it.alert.sinkSeq == det and it.operator == "alice")
    check "HANDLED" in render(after)

  test "D5: a signed containment reads contained; an unsigned or late one, silent":
    # One-second ticks, so the three-interval silence window is three
    # seconds and a late containment can be produced by waiting.
    proc fastHost(name: string): HostFixture =
      result = newHost(root, name, sink)
      writeFile(result.site.confPath,
        readFile(result.site.confPath).replace("tick-interval = 330",
                                               "tick-interval = 1"))
      result.conf = loadEvidenceConf(result.site.confPath)
      sink.enrol(result)
      bootstrapHost(result)
    var sequence = 0'u64
    proc contain(h: HostFixture; signed: bool; trigger = "operator-contained") =
      # The verb's record: its own statement, signed (decision 51); the
      # unsigned one carries none.
      var fields = @[("operator", "alice"), ("reason", "drill")]
      if signed:
        inc sequence
        let st = signContainment(ContainmentStatement(host: h.evidence.host,
          credentialHost: h.credentialHost,
          action: (if trigger == "operator-contained": "contain" else: "release"),
          operator: "alice", reason: "drill", sequence: sequence,
          atMs: int64(epochTime() * 1000)), h.evidence.attestationKey)
        fields.add(("containment", st.statement))
        fields.add(("containmentSignature", st.signature))
      discard recordEvidence(EvidenceEvent(detector: edContainment,
        category: ecAudit, trigger: trigger, fields: fields, attest: signed),
        h.evidence)
    let ok = fastHost("contained")
    let unsigned = fastHost("unsigned")
    let late = fastHost("late")
    for h in [ok, unsigned]:
      h.tick()
      h.ship()
      h.contain(signed = h.evidence.host == "contained")
      h.ship()
    late.tick()
    late.ship()
    sleep(4500)                   # the tick is silent before it is contained
    late.contain(signed = true)
    late.ship()
    let hosts = @[EnrolledHost(hostId: ok.credentialHost, target: "t"),
                  EnrolledHost(hostId: unsigned.credentialHost, target: "t"),
                  EnrolledHost(hostId: late.credentialHost, target: "t")]
    let later = int64(epochTime() * 1000) + 3_600_000
    let r = runEvidenceCheck(inputsFor(sink, hosts, later))
    checkpoint render(r)
    check statusOf(r, ok.credentialHost, "addon-agent-tick") == "contained"
    check not r.alerts.anyIt(it.host == ok.credentialHost and
                             it.detector == "DET-AO-8" and
                             "addon-agent-tick" in it.detail)
    check statusOf(r, unsigned.credentialHost, "addon-agent-tick") == "silent"
    check statusOf(r, late.credentialHost, "addon-agent-tick") == "silent"
    # A release restarts the silence clock.
    ok.contain(signed = true, trigger = "operator-released")
    ok.ship()
    let rel = runEvidenceCheck(inputsFor(sink, @[hosts[0]],
                                         int64(epochTime() * 1000)))
    check statusOf(rel, ok.credentialHost, "addon-agent-tick").startsWith("live")

  test "D6: the refusal record names its staging copy and the compiler":
    let h = newHost(root, "refusal", sink)
    sink.enrol(h)
    bootstrapHost(h)
    let ctx = AgentApplyContext(refusal: "EAddOnCompiledProfile: mismatch",
      refusalPayload: "planted\n", stagingCopy: "/var/lib/repro/agent/refused/x",
      compiler: "/opt/c", compilerSha256: "ab".repeat(32))
    h.tick(ctx, aoApplyFailed)
    h.ship()
    var ok = false
    for e in sink.entries():
      if e.kind == ekRecord and $e.senderHostId == h.credentialHost and
          e.record.trigger == "addon-staging-refused":
        ok = e.record.field("stagingCopy") == "/var/lib/repro/agent/refused/x" and
             e.record.field("compiler") == "/opt/c" and
             e.record.field("compilerSha256") == "ab".repeat(32)
    check ok

  test "D7: a signed hand-over is followed; a forged or late one alerts":
    let h = newHost(root, "rekey", sink)
    sink.enrol(h)
    bootstrapHost(h)
    let newKeyPath = root / "rekey-next.key"
    let newKey = ensureAttestationKey(newKeyPath).publicKeyHex
    let newHost = "cd".repeat(32)
    let hv = KeyHandover(host: "rekey", oldKey: h.attestationKey,
      newKey: newKey, newCredentialHost: newHost, atMs: 1)
    let good = signHandover(hv, h.evidence.attestationKey)
    let forged = signHandover(hv, newKeyPath)        # not the enrolled key
    for (st, sg, trig) in [(forged.statement, forged.signature, "rekey-handover")]:
      writeOutboxRecord(h.site.outbox, newEvidenceRecord(ecAudit, $edKeys, trig,
        [("handover", st), ("handoverSignature", sg)], nowMs = 1), "handover")
    h.ship()
    var hosts = @[EnrolledHost(hostId: h.credentialHost, target: "t",
                               attestationKey: h.attestationKey)]
    let forgedRun = enrolFromStore(hosts, sink.storeDir)
    check forgedRun.hosts.len == 1
    check runEvidenceCheck(inputsFor(sink, hosts, int64(epochTime() * 1000))).alerts.anyIt(
      it.trigger == "handover-invalid")
    writeOutboxRecord(h.site.outbox, newEvidenceRecord(ecAudit, $edKeys,
      "rekey-handover", [("handover", good.statement),
      ("handoverSignature", good.signature)], nowMs = 1), "handover")
    h.ship()
    let followed = enrolFromStore(hosts, sink.storeDir)
    check followed.changed
    check followed.hosts.anyIt(it.hostId == newHost and it.attestationKey == newKey)
    check followed.hosts[0].retiredAt > 0'u64
    # A record under the retired id is an alert.
    h.tick()
    h.ship()
    let r = runEvidenceCheck(inputsFor(sink, followed.hosts[0 .. 0],
                                       int64(epochTime() * 1000)))
    check r.alerts.anyIt(it.trigger == "record-after-retirement")
    check statusOf(r, h.credentialHost, "host") == "retired"
    # Retired before the hand-over (presumed compromised): it is refused.
    var early = hosts
    early[0].retiredAt = 1
    let refused = enrolFromStore(early, sink.storeDir)
    check not refused.hosts.anyIt(it.hostId == newHost)
    check runEvidenceCheck(inputsFor(sink, early, int64(epochTime() * 1000))).alerts.anyIt(
      it.trigger == "handover-after-retirement")
    check parseHosts(renderHosts(followed.hosts)) == followed.hosts

  test "D9: the announced credential self-test is not a G34 alert":
    let h = newHost(root, "probe", sink)
    sink.enrol(h)
    let c = runCredentialCheck(h.site, h.conf, "probe")
    check credentialCheckOk(c)
    let hosts = @[EnrolledHost(hostId: h.credentialHost)]
    let r = runEvidenceCheck(inputsFor(sink, hosts, int64(epochTime() * 1000)))
    checkpoint render(r)
    check not r.alerts.anyIt(it.detector == "G34")
    check statusOf(r, h.credentialHost, "sink-credential") == "self-test"
    # Unannounced: a probe with no credential-probe record before it.
    let a = openAppender(h.site, h.conf)
    for op in ForbiddenOperation:
      discard waitFor(a.probeForbiddenOperation(op))
    a.close()
    let r2 = runEvidenceCheck(inputsFor(sink, hosts, int64(epochTime() * 1000)))
    check r2.alerts.anyIt(it.detector == "G34")

removeDir(root)
