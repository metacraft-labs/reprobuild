## NPC-M10 verification `test_npc_m10_evidence_sink_is_append_only`
## (threat model G28; EVID-2, EVID-3).
##
## The catalog's writers ship their records to the evidence sink: here the
## generator host (its captured refusals, `capture.evidenceRecordOf`) and
## the detector host (a scrub finding). Each appends with its own
## credential, and the sink keeps the catalog's fields (package, digests,
## where the bytes came from) through its ingest redaction. With the same
## credential, reading, listing and deleting are each refused by the sink
## (and the refusal is itself chained), and every appended record is still
## there afterwards. Changing one byte of a past record in a copy of the
## store breaks the chain check; the untouched store verifies.
##
## The sink is the real binary, run as its own process, over TLS with real
## host CAs (`m7_test_pki`). That the deployed sink is off-host is a
## property of the deployment, not of this test.
##
## Falsifying mutation (recorded in the plan): giving the writer's
## credential delete scope lets it erase a record, and fails the test.

import std/[asyncdispatch, os, strutils, unittest]

import repro_nimble_generator/capture
import repro_nimble_fetch/detectors

import ./npc_sink_fixtures

suite "NPC-M10: the evidence sink is append-only for the catalog's writers":

  test "append succeeds; read, list and delete fail; a changed byte breaks the chain":
    var s = startNpcSink("npc-m10-sink", @["generator-host"])
    defer: s.stop()
    let generatorHost = s.writers[0]
    let gen = s.appenderFor(generatorHost)
    let det = s.appender()
    let tree = "5e" & repeat("0", 62)
    let refusal = CaptureRecord(class: ccDigestMismatch, package: "victim",
      expected: tree, observed: "77" & repeat("1", 62),
      source: "mirror https://mirror.invalid/nimble/sources/5e/" & tree &
        ".tar", detail: "the tree hashes to another digest", at: 1_790_000_000)
    gen.append(evidenceRecordOf(refusal))
    det.append(newEvidenceRecord(ecDetection, ScrubDetector, "scrub-mismatch",
      [("digest", tree), ("observedDigest", "99" & repeat("2", 62))]))
    check gen.drain()
    check det.drain()

    proc catalogRecords(): int =
      for e in s.sink.sinkEntries():
        if e.kind == ekRecord and e.record.detector in
            [CaptureDetector, ScrubDetector]:
          inc result
    check catalogRecords() == 2
    var kept = false
    for e in s.sink.sinkEntries():
      if e.kind == ekRecord and e.record.detector == CaptureDetector:
        check e.senderHostId == generatorHost.identity.hostId
        check e.record.trigger == "digest-mismatch"
        check e.record.field("package") == "victim"
        check e.record.field("digest") == tree
        check e.record.field("bytesFrom") == refusal.source
        kept = true
    check kept

    # Each writer's own credential: no read, no list, no delete.
    for (who, app) in [("generator", gen), ("detector", det)]:
      for op in [foRead, foList, foDelete]:
        let outcome = waitFor app.probeForbiddenOperation(op)
        checkpoint who & " " & $op & ": " & $outcome & " " & app.lastError
        check outcome == poRefused
    check catalogRecords() == 2
    var refusedVerbs = 0
    for e in s.sink.sinkEntries():
      if e.kind == ekRefusedVerb: inc refusedVerbs
    check refusedVerbs == 6
    check verifyEvidenceStore(s.sink.dir, sinkCheckpointKey(s.sink)).ok

    # One changed byte in a past record, in a copy: the chain check fails.
    let copy = s.base / "tampered"
    copyDir(s.sink.dir, copy)
    let segment = listSegments(copy)[0]
    var bytes = readFile(segment)
    let at = bytes.find("victim")
    check at >= 0
    bytes[at] = 'V'
    writeFile(segment, bytes)
    check not verifyEvidenceStore(copy, sinkCheckpointKey(s.sink)).ok
    gen.close()
    det.close()
