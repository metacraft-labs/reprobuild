## DET-AO-10 under a re-signing producer (A11 audit finding F1; threat model
## §9 DET-AO-10, G32). A host that has been behind a sequence for longer
## than that sequence's maximum age lags, however often the producer
## re-signed the sequence since (spec §9.2 expects it to): the lag counts
## from when the producer FIRST published the oldest sequence above the
## host's. A host that applied the latest sequence does not lag, even when
## that sequence was first published long ago.
##
## From the auditor's probe (``t_a11audit_lag_resigned``), made permanent.
##
## Falsifying build: ``lag-from-newest-copy`` -- the age of the newest copy
## of the latest sequence, which the re-signature resets: red.
##
## Mocks: none (a real sink, real records, real signed manifests).

import std/[os, sequtils, strutils, times, unittest]

import repro_peer_cache/auth as peerAuth
import repro_deploy_agent/agent
import repro_deploy_agent/manifest
import repro_deploy_agent/tick_status
import repro_peer_cache/evidence

import repro_addon/agent_split
import repro_addon/attestation
import repro_addon/evidence as addonEvidence
import repro_addon/evidence_check
import repro_addon/evidence_ship

import ./addon_evidence_fixture

let root = getTempDir() / ("addon-lag-resigned-" & $getCurrentProcessId())
removeDir(root)
createDir(root)
let producer = peerAuth.generateKeypair()
let published = root / "published"
createDir(published)
writeFile(root / "signers", peerAuth.publicKeyHex(producer.publicKey) & "\n")

proc publish(name: string; seqNo: uint64; issuedAgo: int64): DeployManifest =
  result = DeployManifest(target: "h1", sequence: seqNo,
    deploymentId: "h1-" & $seqNo, profileText: "p" & $seqNo & "\n",
    issuedAt: uint64(getTime().toUnix() - issuedAgo), maxAgeSeconds: 3600)
  signManifest(producer, result)
  writeFile(published / name, cast[string](encodeManifest(result)))

proc hostAt(sink: SinkFixture; name: string; m: DeployManifest): HostFixture =
  result = newHost(root, name, sink)
  sink.enrol(result)
  createDir(result.evidence.stateDir / "addon")
  writeFile(result.evidence.stateDir / "addon" / BootstrapEvidenceName, "{}\n")
  layGeneration(result.evidence.stateDir, "g0", "ledger 0\n", "")
  discard recordEvidence(EvidenceEvent(detector: edBootstrap,
    category: ecAudit, trigger: "bootstrap", attest: true), result.evidence)
  layGeneration(result.evidence.stateDir, "g1", "ledger g1\n", m.profileText,
                recordOf(m))
  # A frozen host still ticks: its fetch selects nothing new.
  recordTickEvidence(RecordedTick(outcome: AgentOutcome(kind: aoSourceError,
    target: "h1", sequence: m.sequence, message: "source unreachable")),
    AgentApplyContext(), result.evidence)
  doAssert runEvidenceShip(result.site, result.conf, name,
                           forceHeartbeat = true).error == ""

suite "DET-AO-10 counts from the first publication":
  let sink = startSink(root)
  let m1 = publish("1.rdm", 1, 3 * 86400)
  let m2first = publish("2-first.rdm", 2, 2 * 86400)
  let m2now = publish("2-resigned.rdm", 2, 0)
  let frozen = hostAt(sink, "frozen", m1)
  let current = hostAt(sink, "current", m2now)
  let r = runEvidenceCheck(CheckInputs(storeDir: sink.storeDir,
    hosts: @[EnrolledHost(hostId: frozen.credentialHost, target: "h1"),
             EnrolledHost(hostId: current.credentialHost, target: "h1")],
    manifests: loadPublishedManifests(published,
      peerAuth.loadTrustAnchors(root / "signers")),
    nowMs: int64(epochTime() * 1000), silenceFactor: 3))
  checkpoint render(r)
  discard m2first

  test "a host two days behind a re-signed sequence lags":
    check r.alerts.anyIt(it.host == frozen.credentialHost and
      it.detector == "DET-AO-10" and it.trigger == "lag")

  test "a host at the latest sequence does not, however old its first copy":
    check not r.alerts.anyIt(it.host == current.credentialHost and
      it.detector == "DET-AO-10")

  sink.server.stop()

removeDir(root)
