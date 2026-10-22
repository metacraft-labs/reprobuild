## `repro-evidence-sink` — the Evidence zone of the Distributed-Execution
## worker pool (deployment-security-architecture.md EVID-2, EVID-3, EVID-6,
## DET-5). Its own binary rather than a `repro` verb for the reason the
## attestation agent is: it runs on a different host from the workers it
## records, and what its operator trusts is its dependency closure.
##
##   repro-evidence-sink serve --dir D --identity DIR --anchors DIR
##                             --checkpoint-key DIR
##                             [--bind ADDR] [--port N] [--revoked FILE]
##                             [--retention-seconds N] [--ready-file F]
##                             [--segment-max-entries N]
##       Accepts appends (and only appends) from workers whose host CA is in
##       the anchor directory (re-read for every connection; `--revoked`
##       lists host ids refused at their next frame). `--identity` holds the
##       sink's own host CA (`host-ca.crt`, minted on first start; copy it
##       to every worker as `<tls dir>/evidence-sink.crt` — the one CA its
##       appender trusts). `--checkpoint-key` holds the checkpoint-signing
##       key and must not be inside `--dir`; copy its
##       `sink-checkpoint.crt` somewhere the operator keeps it, for
##       `verify`. Deletes segments past retention on its own.
##
##   repro-evidence-sink verify   --dir D --checkpoint-pub CERT
##                                [--receipt FILE ...] [--live]
##       hash chain, checkpoint signatures, no unanchored tail (unless
##       `--live`), and every receipt an appender kept still present
##   repro-evidence-sink liveness --dir D [--silence-factor N]
##                                [--expect FILE]
##       per (host, detector) DET-5 status; `--expect` lists the
##       detectors that must exist (`never-reported` otherwise)
##   repro-evidence-sink read     --dir D     one line per entry (operator use)
##
## The three read-side commands open the store directory directly: reading
## is local to the sink host by design (EVID-3). There is no network read.

import std/[asyncdispatch, os, parseopt, strutils, times]

import repro_peer_cache

proc usage(): int =
  stderr.writeLine("usage: repro-evidence-sink serve|verify|liveness|read " &
    "--dir DIR [options]  (see the module documentation)")
  2

proc main(): int =
  var cmd = ""
  var dir, identityDir, anchorsDir, readyFile = ""
  var keyDir, checkpointPub, revokedPath, expectPath = ""
  var receipts: seq[string] = @[]
  var live = false
  var bindAddr = "127.0.0.1"
  var port = 0
  var retention = int64(DefaultRetentionSeconds)
  var silenceFactor = 3
  var segmentMaxEntries = DefaultSegmentMaxEntries
  var p = initOptParser(commandLineParams())
  for kind, key, val in p.getopt():
    case kind
    of cmdArgument:
      if cmd.len == 0: cmd = key else: return usage()
    of cmdLongOption, cmdShortOption:
      case key
      of "dir": dir = val
      of "identity": identityDir = val
      of "anchors": anchorsDir = val
      of "bind": bindAddr = val
      of "port": port = parseInt(val)
      of "retention-seconds": retention = parseBiggestInt(val)
      of "ready-file": readyFile = val
      of "silence-factor": silenceFactor = parseInt(val)
      of "segment-max-entries": segmentMaxEntries = parseInt(val)
      of "checkpoint-key": keyDir = val
      of "checkpoint-pub": checkpointPub = val
      of "receipt": receipts.add(val)
      of "revoked": revokedPath = val
      of "expect": expectPath = val
      of "live": live = true
      else: return usage()
    of cmdEnd: discard
  if dir.len == 0:
    return usage()
  case cmd
  of "serve":
    if identityDir.len == 0 or anchorsDir.len == 0 or keyDir.len == 0:
      return usage()
    if isWildcard(bindAddr):
      stderr.writeLine("repro-evidence-sink: refusing wildcard bind " &
        bindAddr & " (FLOW-6)")
      return 2
    let identity = loadOrCreateHostIdentity(identityDir / "host-ca.crt",
      identityDir / "host-ca.key")
    let anchors = loadTrustAnchorDir(anchorsDir)
    let store = openEvidenceStore(dir, keyDir, retention, segmentMaxEntries)
    let sink = newEvidenceSinkServer(store, identity, anchors, bindAddr,
      Port(port), anchorsDir = anchorsDir, revokedPath = revokedPath)
    sink.start()
    if readyFile.len > 0:
      writeFile(readyFile & ".tmp", bindAddr & ":" & $int(sink.listenPort) &
        "\n" & $identity.hostId & "\n")
      moveFile(readyFile & ".tmp", readyFile)
    stdout.writeLine("evidence sink listening on " & bindAddr & ":" &
      $int(sink.listenPort) & " host=" & $identity.hostId)
    stdout.flushFile()
    let retentionCheck = int(min(60_000'i64, max(1_000'i64, retention * 250)))
    while true:
      try: poll(200) except ValueError: sleep(200)
      sink.tick(retentionCheck)
  of "verify":
    if checkpointPub.len == 0:
      stderr.writeLine("repro-evidence-sink verify: --checkpoint-pub CERT " &
        "is required (the checkpoint key's certificate, pinned out of band; " &
        "never read from the store)")
      return 2
    var parsed: seq[SinkReceipt] = @[]
    for path in receipts:
      for line in readFile(path).splitLines:
        if line.strip().len > 0:
          parsed.add(decodeReceipt(line))
    let report = verifyEvidenceStore(dir,
      checkpointPublicKeyFromCert(checkpointPub), parsed,
      allowUnanchoredTail = live)
    stdout.writeLine("entries=" & $report.entries & " checkpoints=" &
      $report.checkpoints & " unanchored_tail=" & $report.unanchoredTail &
      " receipts=" & $report.receiptsChecked &
      " ok=" & $report.ok & (if report.ok: "" else: " reason=" & report.reason))
    return (if report.ok: 0 else: 1)
  of "liveness":
    let expected =
      if expectPath.len > 0: loadExpectedDetectors(expectPath)
      else: @[]
    for row in livenessReport(dir, int64(epochTime() * 1000), silenceFactor,
        expected):
      stdout.writeLine($row.hostId & " " & row.detector & " " & $row.status &
        " detections=" & $row.detections & " interval_ms=" & $row.intervalMs &
        " last_heartbeat_ms=" & $row.lastHeartbeatMs)
    return 0
  of "read":
    for e in readEvidenceStore(dir):
      var line = $e.seq & " " & $e.receivedAtMs & " " & $e.kind & " " &
        $e.senderHostId & "/" & $e.senderRole
      if e.kind == ekRecord:
        line.add(" " & describe(e.record))
      stdout.writeLine(line)
    return 0
  else:
    return usage()

when isMainModule:
  quit(main())
