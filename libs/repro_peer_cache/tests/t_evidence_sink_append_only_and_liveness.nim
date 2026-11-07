## Distributed-Execution M7: the Evidence zone's own guarantees
## (deployment-security-architecture.md EVID-2, EVID-3, EVID-6, DET-5,
## HOST-7).
##
##   * WRITE-ONLY: a worker's credential can append, and nothing else — a
##     "read", "list" or "delete" verb gets no answer, closes the connection,
##     and is itself recorded as a `refused-verb` entry naming the worker.
##   * WHO and WHEN are the sink's: the sender host is stamped from the
##     verified TLS leaf and the receipt time from the sink's clock.
##   * TAMPER-EVIDENT: the store verifies (hash chain + signed checkpoints),
##     and a single changed byte anywhere breaks verification.
##   * REDACTION IS AN ALLOW-LIST, applied again ON INGEST: a record sent
##     unredacted (a compromised worker need not run the appender's
##     redaction) is stored without its non-allow-listed fields and without
##     the payload of a non-capture trigger.
##   * RETENTION WITH AUTOMATED DELETION: closed segments older than the
##     retention period disappear on the sink's own timer, the deletion is
##     itself recorded, and what remains still verifies.
##   * DET-5: a detector that heartbeats is `live-idle`; one that also
##     reported is `live-detecting`; a dead worker's detector goes SILENT —
##     distinguishable from an idle fleet.
##
## MOCK POLICY — none: the sink binary, real TLS with host-CA leaves, the
## production appender.

import std/[asyncdispatch, options, os, strutils, times, unittest]

import repro_peer_cache

import ./m7_test_pki

proc pumpFor(ms: int) =
  let deadline = epochTime() + ms.float / 1000.0
  while epochTime() < deadline:
    try: poll(20) except ValueError: sleep(20)

proc leafProvider(n: TestNode): LeafProvider =
  let leaf = mintLeaf(n.identity, lrDaemon)
  result = proc(): LeafCredential {.gcsafe.} = leaf

suite "Distributed-Execution M7: the evidence sink":

  test "the sink is write-only, tamper-evident, redacts on ingest and expires":
    let base = normalizedPath(absolutePath(getTempDir() /
      ("repro-m7-sink-" & $getCurrentProcessId())))
    removeDir(base)
    createDir(base)
    let w = newTestNode(base, "worker")
    var sink = prepareEvidenceSink(base)
    sink.acceptsFrom(w)
    sink.startEvidenceSink(retentionSeconds = 3, segmentMaxEntries = 8)
    defer:
      stopEvidenceSink(sink)
      removeDir(base)
    let anchors = sinkAnchors(sink)
    let app = newEvidenceAppender(parseSinkEndpoint(sink.endpoint),
      leafProvider(w), anchors)
    for i in 0 ..< 20:
      app.append(newEvidenceRecord(ecAudit, "boundary-gate", "blob-fetch",
        [("peer", "p" & $i), ("size", $i)]))
    check app.drain()
    check app.appended == 20
    var entries = sink.sinkEntries()
    check entries.len >= 20
    for e in entries:
      if e.kind == ekRecord:
        check e.senderHostId == w.identity.hostId   # stamped by the sink
        check e.receivedAtMs > 0
    check verifyEvidenceStore(sink.dir, sinkCheckpointKey(sink)).ok

    # -- Write-only: read / list / delete get nothing, and are recorded -----
    for verb in [7'u8, 8'u8, 9'u8]:
      check not (waitFor app.sendRawVerbForTesting(verb, @[]))
    pumpFor(300)
    var refusedVerbs = 0
    for e in sink.sinkEntries():
      if e.kind == ekRefusedVerb and e.senderHostId == w.identity.hostId:
        inc refusedVerbs
    check refusedVerbs == 3

    # -- Redaction on ingest (an unredacted record sent raw) -----------------
    let raw = newEvidenceRecord(ecDetection, "peer-cache-content",
      "blob-digest-mismatch",
      [("peer", "x"), ("env", "AWS_SECRET_ACCESS_KEY=sk-live"),
       ("source", "int main(){}")], payload = toOpenArrayByte("int main(){}", 0, 11))
    discard waitFor app.sendRawVerbForTesting(1'u8, encodeEvidenceRecord(raw))
    pumpFor(300)
    var stored: EvidenceRecord
    var found = false
    for e in sink.sinkEntries():
      if e.kind == ekRecord and e.record.trigger == "blob-digest-mismatch":
        stored = e.record
        found = true
    check found
    check stored.field("peer") == "x"
    check stored.field("env") == ""          # not on the allow-list
    check stored.field("source") == ""
    check stored.payload.len == 0            # a blob may be source
    check stored.payloadSize == 12'u64       # still identified

    # -- Tamper evidence: one changed byte breaks verification --------------
    let segments = listSegments(sink.dir)
    check segments.len >= 2
    let copyDir = base / "tampered"
    copyDir(sink.dir, copyDir)
    let victim = listSegments(copyDir)[0]
    var bytes = readFile(victim)
    bytes[bytes.len div 2] = char(ord(bytes[bytes.len div 2]) xor 1)
    writeFile(victim, bytes)
    check not verifyEvidenceStore(copyDir,
      sinkCheckpointKey(sink)).ok

    # -- Retention: old closed segments are deleted by the sink itself ------
    let before = listSegments(sink.dir).len
    let deadline = epochTime() + 20.0
    while epochTime() < deadline and listSegments(sink.dir).len >= before:
      app.append(newEvidenceRecord(ecAudit, "boundary-gate", "keepalive"))
      discard app.drain()
      pumpFor(500)
    check listSegments(sink.dir).len < before
    var retained = false
    for e in sink.sinkEntries():
      if e.kind == ekRetention: retained = true
    check retained
    let afterRetention = verifyEvidenceStore(sink.dir, sinkCheckpointKey(sink))
    checkpoint("after retention: " & afterRetention.reason)
    check afterRetention.ok
    app.close()

  test "DET-6: records with captured payloads never jam the channel":
    # Forty `frame-refused` detections, each capturing ~60 KiB of the
    # refused frame (EVID-1), queued while the sink is not yet up — what a
    # peer sending malformed frames faster than one round trip produces. Their
    # sum is well past the sink's 1 MiB frame limit; a batch bounded only by
    # COUNT was refused without an acknowledgement and resent forever, so
    # every later detection queued behind it and nothing more ever arrived.
    let base = normalizedPath(absolutePath(getTempDir() /
      ("repro-m7-batch-" & $getCurrentProcessId())))
    removeDir(base)
    createDir(base)
    let w = newTestNode(base, "worker")
    var sink = prepareEvidenceSink(base)
    sink.acceptsFrom(w)
    sink.startEvidenceSink()
    defer:
      stopEvidenceSink(sink)
      removeDir(base)
    let app = newEvidenceAppender(parseSinkEndpoint(sink.endpoint),
      leafProvider(w), sinkAnchors(sink))
    # `append` only STARTS the connection; nothing progresses until the
    # dispatcher runs (`drain`), so all forty are queued for the first batch.
    let frame = newSeq[byte](60 * 1024)
    for i in 0 ..< 40:
      app.append(newEvidenceRecord(ecDetection, "boundary-gate",
        "frame-refused", [("peer", "p" & $i), ("refusal", "schema")],
        payload = frame))
    check app.pending == 40
    check app.drain(timeoutMs = 20_000)
    check app.appended == 40
    check app.dropped == 0
    var captured = 0
    for e in sink.sinkEntries():
      if e.kind == ekRecord and e.record.trigger == "frame-refused":
        check e.record.payload.len == frame.len
        inc captured
    check captured == 40
    app.close()

  test "DET-5: a dead worker's detector is silent, distinct from an idle one":
    let base = normalizedPath(absolutePath(getTempDir() /
      ("repro-m7-liveness-" & $getCurrentProcessId())))
    removeDir(base)
    createDir(base)
    let alive = newTestNode(base, "alive")
    let dying = newTestNode(base, "dying")
    var sink = prepareEvidenceSink(base)
    sink.acceptsFrom(alive)
    sink.acceptsFrom(dying)
    sink.startEvidenceSink()
    defer:
      stopEvidenceSink(sink)
      removeDir(base)
    let a = newEvidenceAppender(parseSinkEndpoint(sink.endpoint),
      leafProvider(alive), sinkAnchors(sink))
    let d = newEvidenceAppender(parseSinkEndpoint(sink.endpoint),
      leafProvider(dying), sinkAnchors(sink))
    for app in [a, d]:
      app.registerDetector("boundary-gate", 200)
      app.registerDetector("peer-cache-content", 200)
    var t = epochTime()
    while epochTime() - t < 1.5:
      a.tickHeartbeats()
      d.tickHeartbeats()
      pumpFor(50)
    a.append(newEvidenceRecord(ecDetection, "peer-cache-content",
      "blob-digest-mismatch", [("peer", "q")]))
    check a.drain()
    check d.drain()
    d.close()                      # the dying worker stops reporting
    t = epochTime()
    while epochTime() - t < 1.5:
      a.tickHeartbeats()
      pumpFor(50)
    check a.drain()
    let rows = livenessReport(sink.dir, int64(epochTime() * 1000))
    proc statusOf(host: PeerId; detector: string): Option[LivenessStatus] =
      ## none() when the sink has no row at all: a detector that never
      ## reached the sink is NOT the same observation as one that went
      ## silent, so a missing row must not satisfy a SILENT assertion.
      for r in rows:
        if r.hostId == host and r.detector == detector: return some(r.status)
      none(LivenessStatus)
    checkpoint($rows)
    check statusOf(alive.identity.hostId, "boundary-gate") == some(lsLiveIdle)
    check statusOf(alive.identity.hostId, "peer-cache-content") ==
      some(lsLiveDetecting)
    # The dying worker's detectors DID heartbeat before it stopped (its rows
    # exist), and are now SILENT.
    check statusOf(dying.identity.hostId, "boundary-gate") == some(lsSilent)
    check statusOf(dying.identity.hostId, "peer-cache-content") ==
      some(lsSilent)
    a.close()

  test "G28: the appender talks only to its pinned sink":
    # Two sinks, both under CAs the appender's anchor set trusts — the case
    # the host-id pin exists for (a trusted CA does not make a host the
    # sink). Pinned to the real sink and pointed at the other one, the
    # appender never ships a record there; pinned to the other one instead,
    # the same anchors, leaf and endpoint deliver (positive control: the pin
    # is the only thing that refused).
    let base = normalizedPath(absolutePath(getTempDir() /
      ("repro-m7-pin-" & $getCurrentProcessId())))
    removeDir(base)
    createDir(base)
    let w = newTestNode(base, "worker")
    var real = prepareEvidenceSink(base / "real")
    var other = prepareEvidenceSink(base / "other")
    real.acceptsFrom(w)
    other.acceptsFrom(w)
    real.startEvidenceSink()
    other.startEvidenceSink()
    defer:
      stopEvidenceSink(other)
      stopEvidenceSink(real)
      removeDir(base)
    check real.hostId != other.hostId
    let both = base / "both-anchors"
    createDir(both)
    copyFile(real.certPath, both / "real.crt")
    copyFile(other.certPath, both / "other.crt")
    let anchors = loadTrustAnchorDir(both)
    proc fromWorker(sink: SinkProcess): int =
      for e in sink.sinkEntries():
        if e.kind == ekRecord and e.senderHostId == w.identity.hostId and
            e.record.trigger == "pin-probe":
          inc result
    let pinnedElsewhere = newEvidenceAppender(parseSinkEndpoint(other.endpoint),
      leafProvider(w), anchors, expectedSink = real.hostId)
    pinnedElsewhere.append(newEvidenceRecord(ecDetection, "boundary-gate",
      "pin-probe", [("peer", "p")]))
    check not pinnedElsewhere.drain(timeoutMs = 3_000)
    checkpoint("pinned to the real sink: " & pinnedElsewhere.lastError)
    check "not the pinned sink" in pinnedElsewhere.lastError
    check not pinnedElsewhere.everConnected
    check not pinnedElsewhere.healthy()
    check pinnedElsewhere.appended == 0
    pumpFor(300)
    check fromWorker(other) == 0
    pinnedElsewhere.close()
    # Positive control.
    let pinnedThere = newEvidenceAppender(parseSinkEndpoint(other.endpoint),
      leafProvider(w), anchors, expectedSink = other.hostId)
    pinnedThere.append(newEvidenceRecord(ecDetection, "boundary-gate",
      "pin-probe", [("peer", "p")]))
    check pinnedThere.drain(timeoutMs = 10_000)
    check pinnedThere.healthy()
    pumpFor(300)
    check fromWorker(other) == 1
    pinnedThere.close()

  test "G28: a lost sink connection is unhealthy even with nothing queued":
    # The sink ends the connection (here: at a verb it refuses) while
    # nothing is queued. Before the fix `healthy` stayed true for as long as
    # nothing else was appended — evidence was not leaving the host, and the
    # worker role would have kept executing goals. Now it turns false once
    # the connection has been down for `AppenderUnhealthyAfterMs`, and an
    # idle appender reconnects on its own (`tickHeartbeats`).
    let base = normalizedPath(absolutePath(getTempDir() /
      ("repro-m7-down-" & $getCurrentProcessId())))
    removeDir(base)
    createDir(base)
    let w = newTestNode(base, "worker")
    var sink = prepareEvidenceSink(base)
    sink.acceptsFrom(w)
    sink.startEvidenceSink()
    defer:
      stopEvidenceSink(sink)
      removeDir(base)
    let app = newEvidenceAppender(parseSinkEndpoint(sink.endpoint),
      leafProvider(w), sinkAnchors(sink))
    app.append(newEvidenceRecord(ecAudit, "boundary-gate", "keepalive"))
    check app.drain()
    let later = int64(epochTime() * 1000) + AppenderUnhealthyAfterMs + 1_000
    check app.healthy(later)          # connected, nothing waiting
    check not (waitFor app.sendRawVerbForTesting(7'u8, @[]))
    check app.pending == 0
    check app.healthy()               # within the grace: a reconnect may follow
    check not app.healthy(int64(epochTime() * 1000) +
      AppenderUnhealthyAfterMs + 1_000)
    # The appender reconnects by itself, with nothing to send.
    var back = false
    let deadline = epochTime() + 10.0
    while not back and epochTime() < deadline:
      app.tickHeartbeats()
      pumpFor(100)
      back = app.healthy(int64(epochTime() * 1000) +
        AppenderUnhealthyAfterMs + 1_000)
    check back
    app.close()

  test "G28: records dropped while the sink was away are reported to it":
    # A full queue drops the NEWEST record and counts it; once the sink
    # accepts appends again, the appender tells it how many it never
    # received, as an `evidence-dropped` detection the sink stores.
    let base = normalizedPath(absolutePath(getTempDir() /
      ("repro-m7-dropped-" & $getCurrentProcessId())))
    removeDir(base)
    createDir(base)
    let w = newTestNode(base, "worker")
    var sink = prepareEvidenceSink(base)
    sink.acceptsFrom(w)
    sink.startEvidenceSink()
    let endpoint = sink.endpoint
    stopEvidenceSink(sink)            # away; it comes back on the same port
    defer:
      stopEvidenceSink(sink)
      removeDir(base)
    let app = newEvidenceAppender(parseSinkEndpoint(endpoint),
      leafProvider(w), sinkAnchors(sink), maxQueue = 5)
    for i in 0 ..< 8:
      app.append(newEvidenceRecord(ecAudit, "boundary-gate", "blob-fetch",
        [("peer", "p" & $i)]))
    check app.pending == 5
    check app.dropped == 3
    pumpFor(300)
    check app.appended == 0
    sink.startEvidenceSink()
    check sink.endpoint == endpoint
    var drained = false
    let deadline = epochTime() + 20.0
    while not drained and epochTime() < deadline:
      drained = app.drain(timeoutMs = 2_000)
    check drained
    check app.appended == 6           # the five kept, and the notice
    var notices: seq[EvidenceEntry]
    for e in sink.detections("evidence-dropped"):
      if e.senderHostId == w.identity.hostId:
        notices.add(e)
    check notices.len == 1
    if notices.len == 1:
      check notices[0].record.field("count") == "3"
      check notices[0].record.detector == "evidence-appender"
    app.close()
