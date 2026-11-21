## Every detector of threat model §9 that the add-on implements, tripped by
## its control through the code that produces its record on a host, shipped
## through the real shipping run to a real Evidence sink, and turned into
## an alert by the off-host check (DET-4) -- and silence told apart from
## "nothing detected" (DET-5). The unit half of
## ``e2e_addon_detectors_positive_controls``, whose controls are the
## threat model's own (a manifest signed by an unanchored key, a planted
## ``/etc/shadow`` resource set, a reboot after a ledger link changed, ...)
## run in a VM.
##
## Hosts: ``host-a`` is tripped by every control (DET-AO-3's through the
## egress observer's check, from a counted destination); ``host-b`` is healthy and
## must come out live-idle with no alert; ``host-c`` was enrolled and never
## shipped anything.
##
## Falsifying builds:
## ``check-silence-as-idle`` (a silent detector reported as idle: the
## silence step goes red), ``check-skips-attestation`` (DET-AO-9 never
## compares: the attestation step goes red), ``lag-detector-disabled``
## (DET-AO-10: the lag step goes red), ``tick-records-no-detection`` (no
## record for a tick's outcome: the per-detector step goes red).
##
## Mocks: none. Real records from the procs the units run, a real sink
## (``addon_evidence_fixture``), real signed manifests.

import std/[os, sequtils, strutils, times, unittest]

import repro_infra
import repro_peer_cache/auth as peerAuth
import repro_peer_cache/evidence
import repro_deploy_agent/agent
import repro_deploy_agent/manifest
import repro_deploy_agent/tick_status

import repro_addon/agent_record
import repro_addon/agent_split
import repro_addon/apt_hook
import repro_addon/egress_observer
import repro_addon/attestation
import repro_addon/evidence as addonEvidence
import repro_addon/evidence_check
import repro_addon/evidence_ship
import repro_addon/reassert
import repro_addon/store_verify

import ./addon_evidence_fixture

let root = getTempDir() / ("addon-evidence-det-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

let producer = peerAuth.generateKeypair()
let manifestsDir = root / "published"
createDir(manifestsDir)
writeFile(root / "deploy-signers.anchors",
          peerAuth.publicKeyHex(producer.publicKey) & "\n")

proc publish(target: string; seqNo: uint64; text: string;
             issuedAgo = 0'i64; maxAge = 3600'u64): DeployManifest =
  result = DeployManifest(target: target, sequence: seqNo,
    deploymentId: target & "-" & $seqNo, profileText: text,
    issuedAt: uint64(getTime().toUnix() - issuedAgo), maxAgeSeconds: maxAge,
    closureDigests: @[ClosureDigest(actionId: "svc",
                                    digest: "blake3:" & "7".repeat(64))])
  signManifest(producer, result)
  writeFile(manifestsDir / (target & "-" & $seqNo & ".rdm"),
            cast[string](encodeManifest(result)))

proc bootstrapHost(h: HostFixture) =
  ## Generation 0 and the first record, as bootstrap leaves them.
  createDir(h.evidence.stateDir / "addon")
  writeFile(h.evidence.stateDir / "addon" / BootstrapEvidenceName,
    "{\"binarySha256\":\"" & "ab".repeat(32) & "\"}\n")
  layGeneration(h.evidence.stateDir, "g0", "ledger 0\n", "")
  discard recordEvidence(EvidenceEvent(detector: edBootstrap,
    category: ecAudit, trigger: "bootstrap", attest: true), h.evidence)

proc applyFrom(h: HostFixture; gen: string; m: DeployManifest) =
  layGeneration(h.evidence.stateDir, gen, "ledger " & gen & "\n",
                m.profileText, recordOf(m))
  discard recordEvidence(EvidenceEvent(detector: edApply, category: ecAudit,
    trigger: "applied", kind: "apply", attest: true), h.evidence)

proc tick(h: HostFixture; kind: AgentOutcomeKind; target: string;
          seqNo = 0'u64; message = ""; errorCode = "";
          ctx = AgentApplyContext()) =
  recordTickEvidence(RecordedTick(outcome: AgentOutcome(kind: kind,
    target: target, sequence: seqNo, message: message, errorCode: errorCode)),
    ctx, h.evidence)

proc ship(h: HostFixture) =
  let r = runEvidenceShip(h.site, h.conf, h.evidence.host, forceHeartbeat = true)
  doAssert r.error == "", r.error

proc alertsOf(r: CheckReport; host, det: string): seq[Alert] =
  r.alerts.filterIt(it.host == host and it.detector == det)

proc statusOf(r: CheckReport; host, det: string): string =
  for s in r.statuses:
    if s.host == host and s.detector == det: return s.status
  "absent"

suite "the add-on's detectors, from control to off-host alert":
  let sink = startSink(root)
  let a = newHost(root, "host-a", sink)
  let b = newHost(root, "host-b", sink)
  let c = newHost(root, "host-c", sink)
  for h in [a, b, c]: sink.enrol(h)
  let m1 = publish("h1", 1, "profile one\n")
  discard publish("h1", 2, "profile two\n", issuedAgo = 7200, maxAge = 3600)
  let mb = publish("h2", 1, "profile b\n")

  # host-b: healthy. Bootstrapped, applied the producer's latest, ticking.
  bootstrapHost(b)
  applyFrom(b, "g1", mb)
  b.tick(aoConverged, "h2", 1)
  recordEgressCheck(EgressCheck(present: true), b.evidence, 30_000)
  recordStoreVerify(StoreVerifyReport(), defaultStoreVerifySite(b.evidence.stateDir).withEvidence(b.evidence))
  recordReassertEvidence(ReassertReport(status: "ok"), b.evidence.stateDir,
    atBoot = true, site = b.evidence, bootIdPath = b.site.bootIdPath)
  b.ship()

  # host-a: every control.
  bootstrapHost(a)
  applyFrom(a, "g1", m1)
  writeFile(a.site.dpkgLog, "2026-11-04 10:00:00 startup archives unpack\n")
  a.tick(aoApplied, "h1", 1)
  recordStoreVerify(StoreVerifyReport(), defaultStoreVerifySite(a.evidence.stateDir).withEvidence(a.evidence))
  a.tick(aoRejected, "h1", message = "signed by an unanchored key")        # DET-AO-1
  recordEgressCheck(EgressCheck(present: true,                            # DET-AO-3
    refused: @[("1.1.1.1", 1'i64)], fresh: @[("1.1.1.1", 1'i64)]),
    a.evidence, 30_000)
  var refused = AgentApplyContext(refusal: "EAddOnManagementPath: /etc/shadow",
                                  refusalPayload: "resource /etc/shadow\n")
  a.tick(aoApplyFailed, "h1", 2, refused.refusal, ctx = refused)          # DET-AO-2
  recordReassertEvidence(ReassertReport(status: "drift",
    findings: @["drift: staticLink /etc/repro/static: points at nothing"]),
    a.evidence.stateDir, atBoot = true, site = a.evidence,
    bootIdPath = a.site.bootIdPath)                                       # DET-AO-4
  a.tick(aoApplyFailed, "h1", 2, "EAddOnStoreChanged: the store changed " &
         "between the switch's realise step and its flip")               # DET-AO-5
  discard runAfterDpkgCli(a.evidence.stateDir / "no-ledger-here",
    logPath = a.root / "apt-hook.log", site = a.evidence,
    dpkgLog = a.site.dpkgLog)                                             # DET-AO-6
  a.tick(aoRolledBack, "h1", 2, "health check failed", "rolled_back")     # DET-AO-7
  a.tick(aoStale, "h1", 2, "older than its maximum age", "stale_manifest") # DET-AO-10
  # DET-AO-9: an operator's local apply on the agent-managed host.
  layGeneration(a.evidence.stateDir, "g2", "ledger g2\n", "local edit\n")
  discard recordEvidence(EvidenceEvent(detector: edApply, category: ecAudit,
    trigger: "applied", kind: "apply", attest: true), a.evidence)
  # ... and g1 rewritten underneath, attested again.
  writeFile(generationDir(a.evidence.stateDir, "g1") / GenerationLedgerName,
            "rewritten\n")
  discard recordEvidence(EvidenceEvent(detector: edReassert, category: ecAudit,
    trigger: "ok", attest: true, attestGeneration: "g1"), a.evidence)
  a.ship()

  let inputs = CheckInputs(storeDir: sink.storeDir,
    hosts: @[EnrolledHost(hostId: a.credentialHost, target: "h1"),
             EnrolledHost(hostId: b.credentialHost, target: "h2"),
             EnrolledHost(hostId: c.credentialHost, target: "h3")],
    manifests: loadPublishedManifests(manifestsDir,
      peerAuth.loadTrustAnchors(root / "deploy-signers.anchors")),
    publishedArtefacts: @["ab".repeat(32)],
    nowMs: int64(epochTime() * 1000), silenceFactor: 3)
  let now = runEvidenceCheck(inputs)
  checkpoint render(now)

  test "each control trips its detector's alert":
    for (det, trig) in [("DET-AO-1", "addon-manifest-refused"),
                        ("DET-AO-2", "addon-staging-refused"),
                        ("DET-AO-3", "egress-refused"),
                        ("DET-AO-4", "drift"),
                        ("DET-AO-5", "store-changed"),
                        ("DET-AO-6", "hook-finding"),
                        ("DET-AO-7", "rolled-back"),
                        ("DET-AO-10", "stale-manifest")]:
      checkpoint det & " " & trig
      check now.alertsOf(a.credentialHost, det).anyIt(it.trigger == trig)

  test "the apply-side refusal carries the staged bytes (EVID-1)":
    var found = false
    for e in sink.entries():
      if e.record.trigger == "addon-staging-refused":
        check cast[string](e.record.payload) == "resource /etc/shadow\n"
        found = true
    check found

  test "DET-AO-9: a locally applied generation and a rewritten one are flagged":
    check now.alertsOf(a.credentialHost, "DET-AO-9").anyIt(
      it.trigger == "unpublished-generation" and "g2" in it.detail)
    check now.alertsOf(a.credentialHost, "DET-AO-9").anyIt(
      it.trigger == "generation-changed" and "g1" in it.detail)

  test "DET-AO-9: an attestation that does not verify is flagged":
    # A record whose statement was altered after it was signed (what a
    # writer without the attestation key can produce at best).
    let att = attestFields(a.evidence)
    check att.error == ""
    var fields: seq[(string, string)]
    for (k, v) in att.fields:
      fields.add((k, if k == "attestation": v.replace("sequence=0",
                                                       "sequence=1") else: v))
    let ev = EvidenceEvent(detector: edAgentTick, category: ecHeartbeat,
                           kind: "tick")
    writeOutboxRecord(a.site.outbox, toRecord(ev, fields & @[
      ("intervalMs", "330000")]), "tick")
    a.ship()
    let r = runEvidenceCheck(inputs)
    check r.alertsOf(a.credentialHost, "DET-AO-9").anyIt(
      it.trigger == "attestation-invalid")

  test "DET-AO-10: a host behind the producer past the maximum age lags":
    check now.alertsOf(a.credentialHost, "DET-AO-10").anyIt(it.trigger == "lag")
    check now.alertsOf(b.credentialHost, "DET-AO-10").len == 0

  test "nothing detected is live-idle, with no alert at all":
    check now.alerts.filterIt(it.host == b.credentialHost).len == 0
    for det in ["addon-agent-tick", "addon-evidence-ship", "addon-egress",
                "addon-store", "addon-reassert",
                "addon-apt-hook", "addon-manifest", "addon-apply-refusal",
                "addon-store", "addon-rollback", "addon-freshness"]:
      checkpoint det
      check now.statusOf(b.credentialHost, det) == "live-idle"
    check now.statusOf(a.credentialHost, "addon-manifest") == "live-detecting"

  test "a host that never reported is never-reported, not idle":
    check now.statusOf(c.credentialHost, "addon-agent-tick") == "never-reported"
    check now.statusOf(c.credentialHost, "addon-evidence-ship") == "never-reported"
    check now.statusOf(c.credentialHost, "addon-egress") == "never-reported"
    check now.alertsOf(c.credentialHost, "DET-AO-8").len == 4

  test "silence: the same healthy host, later, with nothing new, is silent":
    var later = inputs
    later.nowMs = inputs.nowMs + 10 * 330_000
    let r = runEvidenceCheck(later)
    check r.statusOf(b.credentialHost, "addon-agent-tick") == "silent"
    check r.statusOf(b.credentialHost, "addon-evidence-ship") == "silent"
    check r.statusOf(b.credentialHost, "addon-manifest") == "silent"
    # The store verification's interval is six hours: still live here.
    check r.statusOf(b.credentialHost, "addon-store") == "live-idle"
    check r.alertsOf(b.credentialHost, "DET-AO-8").anyIt(it.trigger == "silent")

  test "a detector's status agrees with its own silence alert (F4)":
    # host-b: dpkg ran after bootstrap and the apt hook never recorded it.
    writeFile(b.site.dpkgLog, "2099-01-01 00:00:00 startup packages configure\n")
    discard runEvidenceShip(b.site, b.conf, "host-b", forceHeartbeat = true)
    var later = inputs
    # Past the record's grace (two heartbeats), within the shipping
    # heartbeat's own silence (three): shipping is alive, the hook is not.
    later.nowMs = inputs.nowMs + 750_000
    let r = runEvidenceCheck(later)
    check r.statusOf(b.credentialHost, "addon-evidence-ship") == "live-idle"
    check r.alertsOf(b.credentialHost, "DET-AO-8").anyIt(
      it.trigger == "apt-hook-silent")
    check r.statusOf(b.credentialHost, "addon-apt-hook") == "silent"

  sink.server.stop()

removeDir(root)
