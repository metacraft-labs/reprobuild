## The A11 code review's fourth round (reprobuild-pm ``issues/2026-11-07-*``
## at ``d68b9806``, ``70695a7e``, ``e667522f``) and §13 decision 62, held at
## unit level through the real code: the record redaction, the uninstall's
## store-evidence gate, the sink's command line, the hosts file, and the
## off-host check over the real in-process sink.
##
## 1. A custody record names its trusted source ``recoveredFrom``; a
##    ``source`` field never passes the redaction (threat model I3).
## 2. Decision 56's refusal: a real sink receives the records and does not
##    acknowledge them (the host's credential is revoked), and
##    ``--discard-store-evidence`` is refused, nothing discarded; enrolled,
##    the revocation lifted, the same records are acknowledged and the
##    discard goes ahead.
## 3. Decision 62's override: ``--discard-unacknowledged-store-evidence``
##    discards only after a signed local record naming every object is
##    written; ``verify-discard-record`` accepts it with the enrolled key and
##    refuses another key or a changed byte.
## 4. Sequence 0 is a sequence: ``ack --seq 0`` and ``payload --seq 0``
##    parse, ``retired@0:<id>`` is a retirement and is written back.
## 5. A tick heartbeat at sequence 0 is a beat before a containment.
## 6. A containment statement made more than 10 minutes from its receipt is
##    refused as stale; a fresh one after it is honoured.
##
## Falsifying builds (each turns its own case red): ``allow-source-field``
## (1), ``uninstall-skips-ack-refusal`` (2), ``override-unrecorded``,
## ``override-signs-other-bytes`` and ``override-empty-signature`` (3; the
## record is checked through ``repro system addon verify-discard-record``,
## §13 decision 64),
## ``seq-zero-sentinel`` (4, 5), ``containment-skew-ignored`` (6).
##
## Mocks: case 3's ``ship`` is a stub answering "not acknowledged" (the
## override's record is what it holds; case 2 ships to a real sink that
## receives the records and does not acknowledge them). Nothing else.

import std/[json, options, os, sequtils, strutils, times, unittest]

import repro_peer_cache/evidence
import repro_peer_cache/evidence_record
import repro_peer_cache/types
import repro_deploy_agent/agent
import repro_deploy_agent/tick_status

import repro_addon/agent_split
import repro_addon/cli
import repro_addon/attestation
import repro_addon/containment
import repro_addon/evidence as addonEvidence
import repro_addon/evidence_check
import repro_addon/evidence_ship
import repro_addon/evidence_sink_cli
import repro_addon/store_custody
import repro_addon/tick_evidence
import repro_addon/uninstall

import ./addon_evidence_fixture

let root = getTempDir() / ("a11-round4-" & $getCurrentProcessId())
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

proc leaveAside(site: CustodySite; name: string): string =
  let obj = site.storeRoot / "prefixes" / "x" / name
  createDir(obj)
  writeFile(obj / "f", "altered\n")
  moveAside(site, obj)

proc notAcknowledged(): tuple[ok: bool; why: string] =
  (false, "1 record(s) still queued: the sink did not acknowledge")

proc statusOf(r: CheckReport; host, det: string): string =
  for s in r.statuses:
    if s.host == host and s.detector == det: return s.status
  "absent"

suite "the A11 code review's fourth round":
  test "1: a custody record's trusted source passes as recoveredFrom, never as source":
    let r = redact(newEvidenceRecord(ecDetection, "addon-store",
      "store-recovered", [("recoveredFrom", "the switch's plan"),
                          ("source", "int main(){}")]))
    check r.field("recoveredFrom") == "the switch's plan"
    check r.field("source") == ""

  test "2: the sink receives the records but does not acknowledge them: discarding is refused":
    # A real sink and a real shipping run. The host is enrolled and its
    # credential proves, but the sink holds it revoked: the sink reads the
    # append frame carrying the records, records the refusal in its chain,
    # and sends no receipt -- so the outbox keeps the records.
    let sink = startSink(root / "ack2")
    defer: sink.server.stop()
    let h = newHost(root / "ack2", "revoked", sink)
    sink.enrol(h)
    let revoked = root / "ack2" / "revoked-hosts"
    writeFile(revoked, h.credentialHost & "\n")
    sink.server.revokedPath = revoked
    var site = scratchSite("ack2site").withEvidence(h.evidence)
    let aside = leaveAside(site, "1-a")
    let ship = proc (): tuple[ok: bool; why: string] =
      shipAndConfirm(h.site, "revoked")
    let g = storeEvidenceGate(site,
      UninstallOptions(discardStoreEvidence: true), ship,
      overrideDir = root / "ack2" / "log")
    checkpoint g.errors.join("\n")
    check g.pending.anyIt(it == aside)
    check g.errors.anyIt("has not acknowledged" in it)
    check g.errors.anyIt(it == "nothing was removed")
    check g.overrideRecord.len == 0
    check not dirExists(root / "ack2" / "log")
    check dirExists(aside)
    # The sink received the append (its refusal is in the chain) and
    # appended none of the records.
    check sink.entries().anyIt(it.kind == ekRefusedVerb and
                               $it.senderHostId == h.credentialHost)
    check not sink.entries().anyIt(it.kind == ekRecord)
    # No longer revoked, the same records are acknowledged: no refusal.
    writeFile(revoked, "")
    let ok = storeEvidenceGate(site,
      UninstallOptions(discardStoreEvidence: true), ship,
      overrideDir = root / "ack2" / "log")
    checkpoint ok.errors.join("\n")
    check ok.errors.len == 0
    check sink.entries().anyIt(it.kind == ekRecord and
                               it.record.field("evidence") == aside)

  test "3: the explicit override discards only after a signed record of each object":
    var site = scratchSite("over3")
    let key = root / "over3" / "attestation.key"
    let pub = ensureAttestationKey(key).publicKeyHex
    site.evidence.attestationKey = key
    let aside = leaveAside(site, "1-a")
    let g = storeEvidenceGate(site,
      UninstallOptions(discardUnacknowledgedStoreEvidence: true),
      notAcknowledged, overrideDir = root / "over3" / "log")
    check g.errors.len == 0
    check g.overrideRecord.len > 0 and fileExists(g.overrideRecord)
    let doc = parseJson(readFile(g.overrideRecord))
    check doc["objects"].getElems().mapIt(it.getStr()).anyIt(it == aside)
    check "did not acknowledge" in doc["why"].getStr()
    check g.overrideRecordText == readFile(g.overrideRecord)
    # Decision 64: verified through the operator's command, against the
    # enrolled key, over exactly the bytes the file holds.
    check runAddonCli(@["verify-discard-record", g.overrideRecord,
                        "--key", pub]) == 0
    # Another key, or one byte changed, does not verify.
    check runAddonCli(@["verify-discard-record", g.overrideRecord,
                        "--key", "04" & "ab".repeat(64)]) == 1
    let tampered = root / "over3" / "tampered.json"
    writeFile(tampered, readFile(g.overrideRecord).replace(aside, aside & "x"))
    copyFile(g.overrideRecord & DiscardRecordSigExt, tampered & DiscardRecordSigExt)
    check runAddonCli(@["verify-discard-record", tampered, "--key", pub]) == 1

  test "4: sequence 0 is a sequence for the sink's commands and the hosts file":
    let ack = parseSinkCommand(["ack", "--dir", "d", "--seq", "0", "--alert",
      "DET-AO-2/apply-refused", "--operator", "alice", "--reason", "r"])
    check ack.seqNo == some(0'u64)
    let pay = parseSinkCommand(["payload", "--dir", "d", "--seq", "0"])
    check pay.seqNo == some(0'u64)
    let a = "aa".repeat(32)
    let b = "bb".repeat(32)
    let hosts = parseHosts(a & " t - - retired@0:" & b & "\n" & b & " t\n")
    check hosts[0].retiredAt == some(0'u64)
    check ("retired@0:" & b) in renderHosts(hosts)
    var sink = startSink(root / "s4")
    defer: sink.server.stop()
    let r = runEvidenceCheck(CheckInputs(storeDir: sink.storeDir,
      hosts: hosts, nowMs: int64(epochTime() * 1000), silenceFactor: 3))
    check statusOf(r, a, "host") == "retired"

  test "5: a tick heartbeat at sequence 0 is a beat before a containment":
    let sink = startSink(root / "s5")
    defer: sink.server.stop()
    writeFile(sink.storeDir / SinkHostName, sink.hostId & "\n")
    let h = newHost(root / "s5", "zero", sink)
    sink.enrol(h)
    createDir(h.evidence.stateDir / "addon")
    layGeneration(h.evidence.stateDir, "g0", "ledger 0\n", "")
    recordTickEvidence(RecordedTick(outcome: AgentOutcome(kind: aoConverged,
      target: "t")), AgentApplyContext(), h.evidence)
    discard runEvidenceShip(h.site, h.conf, "zero")
    check sink.entries()[0].seq == 0'u64 and
          sink.entries()[0].record.detector == "addon-agent-tick"
    discard recordContainmentAs(h.evidence, h.credentialHost, "contain",
      "alice", "drill", nextContainmentSequence(h.evidence.stateDir))
    discard runEvidenceShip(h.site, h.conf, "zero")
    let r = runEvidenceCheck(CheckInputs(storeDir: sink.storeDir,
      hosts: @[EnrolledHost(hostId: h.credentialHost, target: "t",
                            attestationKey: h.attestationKey)],
      nowMs: int64(epochTime() * 1000) + 3_600_000, silenceFactor: 3,
      sinkHostId: sinkHostOf(sink.storeDir)))
    checkpoint render(r)
    check statusOf(r, h.credentialHost, "addon-agent-tick") == "contained"

  test "6: a containment made over 10 minutes from its receipt is stale":
    let sink = startSink(root / "s6")
    defer: sink.server.stop()
    writeFile(sink.storeDir / SinkHostName, sink.hostId & "\n")
    let h = newHost(root / "s6", "skew", sink)
    sink.enrol(h)
    createDir(h.evidence.stateDir / "addon")
    layGeneration(h.evidence.stateDir, "g0", "ledger 0\n", "")
    recordTickEvidence(RecordedTick(outcome: AgentOutcome(kind: aoConverged,
      target: "t")), AgentApplyContext(), h.evidence)
    discard runEvidenceShip(h.site, h.conf, "skew")
    let now = int64(epochTime() * 1000)
    # The host clock is 20 minutes behind.
    discard recordContainmentAs(h.evidence, h.credentialHost, "contain",
      "alice", "drill", nextContainmentSequence(h.evidence.stateDir),
      atMs = now - 20 * 60_000)
    discard runEvidenceShip(h.site, h.conf, "skew")
    let hosts = @[EnrolledHost(hostId: h.credentialHost, target: "t",
                               attestationKey: h.attestationKey)]
    proc run6(): CheckReport =
      runEvidenceCheck(CheckInputs(storeDir: sink.storeDir, hosts: hosts,
        nowMs: int64(epochTime() * 1000) + 3_600_000, silenceFactor: 3,
        sinkHostId: sinkHostOf(sink.storeDir)))
    let r1 = run6()
    checkpoint render(r1)
    check r1.alerts.anyIt(it.trigger == "containment-stale")
    check statusOf(r1, h.credentialHost, "addon-agent-tick") != "contained"
    # The clock corrected, contain again: honoured.
    discard recordContainmentAs(h.evidence, h.credentialHost, "contain",
      "alice", "again", nextContainmentSequence(h.evidence.stateDir))
    discard runEvidenceShip(h.site, h.conf, "skew")
    check statusOf(run6(), h.credentialHost, "addon-agent-tick") == "contained"

removeDir(root)
