## The attestation key and generation 0 outlive the sink's retention (A11
## audit finding F6; threat model §9 DET-AO-9). The sink deletes old
## segments, the host's bootstrap record among them. ``--update-hosts``
## (``enrolFromStore``) writes the key and generation 0 into the hosts file
## the first time the bootstrap record shows them; after the record is gone
## the check still verifies every attestation, and a host whose key was
## never enrolled raises ONE alert, not one per record.
##
## Reproduction of the finding first: with the enrolment ignored
## (falsifying build ``check-forgets-enrolled-key``) the healthy host
## floods with DET-AO-9 alerts after retention: red.
##
## Mocks: none (a real sink with a short retention and tiny segments).

import std/[os, sequtils, strutils, times, unittest]

import repro_peer_cache/evidence

import repro_addon/attestation
import repro_addon/evidence as addonEvidence
import repro_addon/evidence_check
import repro_addon/evidence_ship

import ./addon_evidence_fixture

let root = getTempDir() / ("addon-retention-" & $getCurrentProcessId())
removeDir(root)
createDir(root)

suite "the attestation key outlives retention":
  let sink = startSink(root, segmentMaxEntries = 4, retentionSeconds = 1)
  let h = newHost(root, "h", sink)
  sink.enrol(h)
  createDir(h.evidence.stateDir / "addon")
  writeFile(h.evidence.stateDir / "addon" / BootstrapEvidenceName, "{}\n")
  layGeneration(h.evidence.stateDir, "g0", "ledger 0\n", "")
  discard recordEvidence(EvidenceEvent(detector: edBootstrap,
    category: ecAudit, trigger: "bootstrap", attest: true), h.evidence)
  doAssert runEvidenceShip(h.site, h.conf, "h", forceHeartbeat = true).error == ""
  var hosts = @[EnrolledHost(hostId: h.credentialHost)]
  let enrolled = enrolFromStore(hosts, sink.storeDir)

  test "the first check enrols the key and generation 0":
    check enrolled.changed
    check enrolled.hosts[0].attestationKey == h.attestationKey
    check enrolled.hosts[0].generation0 == "g0"
    check parseHosts(renderHosts(enrolled.hosts))[0].attestationKey ==
      h.attestationKey

  # Enough records to close several segments, then retention.
  for i in 0 ..< 12:
    discard recordEvidence(EvidenceEvent(detector: edReassert,
      category: ecAudit, trigger: "ok", attest: true), h.evidence)
    doAssert runEvidenceShip(h.site, h.conf, "h").error == ""
  sleep(2500)
  discard sink.server.store.enforceRetention()
  let gone = not readEvidenceStore(sink.storeDir).anyIt(
    it.kind == ekRecord and it.record.detector == "addon-bootstrap")

  test "retention deleted the bootstrap record (the finding's premise)":
    check gone

  test "with the enrolled key, the healthy host raises no DET-AO-9":
    let r = runEvidenceCheck(CheckInputs(storeDir: sink.storeDir,
      hosts: enrolled.hosts, nowMs: int64(epochTime() * 1000)))
    checkpoint render(r)
    check not r.alerts.anyIt(it.detector == "DET-AO-9")

  test "without one, a single alert instead of one per record":
    let r = runEvidenceCheck(CheckInputs(storeDir: sink.storeDir,
      hosts: @[EnrolledHost(hostId: h.credentialHost)],
      nowMs: int64(epochTime() * 1000)))
    check r.alerts.filterIt(it.detector == "DET-AO-9").len == 1
    check r.alerts.anyIt(it.trigger == "attestation-key-unenrolled")

  sink.server.stop()

removeDir(root)
