## What generation 0 renders for the Evidence sink (spec §10.4) and which
## record each deploy-agent tick leaves (threat model §9).
##
## * The shipping unit runs with no capability, reaches the sink's address
##   only, and cannot see the attestation key, the recipient key, the
##   secrets or the store; the path unit starts it the moment a record is
##   written; the timer heartbeats. A host bootstrapped without a sink has
##   none of these objects and keeps its generation 0 byte for byte.
## * Every tick outcome that threat model §9 names maps to its detector.
##
## Falsifying builds: ``evidence-path-rate-limited`` (the burst step),
## ``evidence-ship-unrestricted-egress`` and
## ``evidence-ship-sees-agent-keys`` (the confinement steps go red),
## ``tick-records-no-detection`` (the tick's detection is not written: the
## record step goes red).
##
## Mocks: none; rendered units are checked as text, their enforcement is
## the VM gates'.

import std/[os, sequtils, strutils, unittest]

import repro_peer_cache/evidence

import repro_deploy_agent/agent
import repro_deploy_agent/tick_status

import repro_addon/agent_split
import repro_addon/evidence as addonEvidence
import repro_addon/generation0

import ./addon_evidence_fixture

let root = getTempDir() / ("addon-evidence-units-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

const Exe = "/repro/store/prefixes/repro-addon/x/bin/repro"

let ev = EvidenceUnitsInputs(sinkAddress: "10.0.2.100", sinkPort: 7443,
  sinkCaPem: "-----BEGIN CERTIFICATE-----\nx\n-----END CERTIFICATE-----\n",
  sinkHostId: "a".repeat(64), heartbeatSec: 60)
let agentIn = AgentUnitsInputs(target: "h1",
  sources: @["http://10.0.2.2:8080/h1/latest.rdm"],
  allowedAddresses: @["10.0.2.2"], pollIntervalSec: 30)

suite "generation 0 with an Evidence sink":
  test "the shipping unit: no capabilities, the sink's address only, keys hidden":
    let u = evidenceShipUnit(Exe, ev)
    check "ExecStart=" & Exe & " system addon evidence-ship\n" in u
    check "CapabilityBoundingSet=\n" in u
    check "NoNewPrivileges=yes\n" in u
    check "ProtectSystem=strict\n" in u
    check "IPAddressDeny=any\n" in u
    check "IPAddressAllow=10.0.2.100\n" in u
    check "/var/lib/repro/agent" in u
    for line in u.splitLines():
      if line.startsWith("InaccessiblePaths=") and "-/run/repro" in line:
        check "-/var/lib/repro/agent" in line
      if line.startsWith("ReadWritePaths="):
        check line == "ReadWritePaths=" & EvidenceStateDir & " " &
          EvidenceOutboxPath
  test "a burst of records cannot rate-limit the shipping units (F2)":
    check "StartLimitIntervalSec=0\n" in evidenceShipUnit(Exe, ev)
    check "TriggerLimitIntervalSec=0\n" in evidenceShipPathUnit()
  test "the store verification runs after boot, idle, bounded":
    let u = storeVerifyUnit(Exe)
    check "IOSchedulingClass=idle\n" in u
    check "PrivateNetwork=yes\n" in u
    check "OnBootSec=2min\n" in storeVerifyTimer()
  test "the path unit watches the outbox; the timer heartbeats":
    check ("DirectoryNotEmpty=" & EvidenceOutboxPath) in evidenceShipPathUnit()
    check ("Unit=" & EvidenceShipUnit) in evidenceShipPathUnit()
    check "OnUnitActiveSec=60s\n" in evidenceShipTimer(ev)
  test "evidence.conf names the sink and the intervals the check expects":
    let c = renderEvidenceConf(ev, agentIn)
    check "sink = 10.0.2.100:7443\n" in c
    check "heartbeat-interval = 60\n" in c
    check "tick-interval = 60\n" in c           # 30 s poll + 30 s delay
    check "tick-interval = 0\n" in renderEvidenceConf(ev, AgentUnitsInputs())
  test "the objects are there only with a sink; without one, nothing changes":
    let base = Gen0Inputs(reproExe: Exe, agent: AgentUnitsInputs(
      target: "h1", sources: agentIn.sources, allowedAddresses: @["10.0.2.2"]))
    var with = base
    with.evidence = ev
    var paths: seq[string]
    for o in generation0Objects(with): paths.add(o.path)
    for p in [EvidenceConfPath, EvidenceSinkCaPath, unitPath(EvidenceShipUnit),
              unitPath(EvidenceShipPathUnit), unitPath(EvidenceShipTimer)]:
      check p in paths
    let without = generation0Objects(base)
    for o in without:
      check o.path notin [EvidenceConfPath, EvidenceSinkCaPath]
      check "evidence" notin o.unit
    # The default poll interval renders the timer as it always was.
    check "OnUnitActiveSec=5min\n" in agentFetchTimer(base.agent)
    check "OnUnitActiveSec=30s\n" in agentFetchTimer(agentIn)

suite "a tick's records":
  let sink = startSink(root)
  let h = newHost(root, "host-t", sink)
  test "each outcome threat model §9 names maps to its detector":
    proc det(k: AgentOutcomeKind; code = ""; msg = "";
             ctx = AgentApplyContext()): string =
      let d = tickDetection(RecordedTick(outcome: AgentOutcome(kind: k,
        errorCode: code, message: msg)), ctx)
      if d.found: $d.detector & "/" & d.trigger else: ""
    check det(aoRejected) == "addon-manifest/addon-manifest-refused"
    check det(aoAmbiguous) == "addon-manifest/addon-manifest-refused"
    check det(aoSecretsFailed) == "addon-manifest/sealed-section-failed"
    check det(aoApplyFailed, ctx = AgentApplyContext(refusal: "x")) ==
      "addon-apply-refusal/addon-staging-refused"
    check det(aoApplyFailed, ctx = AgentApplyContext(refusal: "x",
      refusalRecorded: true)) == ""
    check det(aoApplyFailed, msg = "EAddOnStoreChanged: ...") ==
      "addon-store/store-changed"
    check det(aoRolledBack, "rolled_back") == "addon-rollback/rolled-back"
    check det(aoRolledBack, "quarantined") == "addon-rollback/quarantined"
    check det(aoPaused) == "addon-rollback/paused"
    check det(aoStale) == "addon-freshness/stale-manifest"
    for k in [aoWaiting, aoConverged, aoApplied, aoSourceError]:
      check det(k) == ""
    check tickDetection(RecordedTick(raised: true), AgentApplyContext()).found
  test "a refused tick leaves its detection and its heartbeat in the outbox":
    recordTickEvidence(RecordedTick(outcome: AgentOutcome(kind: aoRejected,
      target: "h1", message: "unanchored")), AgentApplyContext(), h.evidence)
    var kinds: seq[string]
    for p in outboxEntries(h.site.outbox): kinds.add(p.splitFile.name)
    check kinds.len == 2
    check kinds.anyIt("addon-manifest-refused" in it)
    check kinds.anyIt(it.endsWith("-tick"))
  sink.server.stop()

removeDir(root)
