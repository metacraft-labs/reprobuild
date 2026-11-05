## The command line of `repro-evidence-sink` (the Evidence zone's sink and
## the add-on's off-host detectors), as a library so its parsing can be
## tested against the published user guide (A11 drill, finding D2).
##
##   repro-evidence-sink serve --dir D --identity DIR --anchors DIR
##                             --checkpoint-key DIR
##                             [--bind ADDR] [--port N] [--revoked FILE]
##                             [--retention-seconds N] [--ready-file F]
##                             [--segment-max-entries N]
##       Accepts appends (and only appends) from hosts whose host CA is in
##       the anchor directory (re-read for every connection; `--revoked`
##       lists host ids refused at their next frame). `--identity` holds the
##       sink's own host CA (`host-ca.crt`, minted on first start; copy it to
##       every host as its sink CA). `--checkpoint-key` holds the
##       checkpoint-signing key and must not be inside `--dir`. Deletes
##       segments past retention on its own. It also appends the sink
##       operator's acknowledgements (`ack`, below) from
##       `<dir>/operator-inbox/`, under the sink's own host id, and writes
##       that id to `<dir>/sink-host` so the check can tell them apart.
##   repro-evidence-sink verify   --dir D --checkpoint-pub CERT
##                                [--receipt FILE ...] [--live]
##   repro-evidence-sink liveness --dir D [--silence-factor N] [--expect FILE]
##   repro-evidence-sink read     --dir D
##       one line per entry (operator use)
##   repro-evidence-sink payload  --dir D --seq N [--out FILE]
##       the captured payload of record N (EVID-1): its length and SHA-256,
##       then its bytes between markers, every byte outside printable ASCII
##       written `\xNN` -- the payload is hostile data (RESP-3) and is never
##       written raw to a terminal; `--out` writes the raw bytes to FILE
##       (created 0600, never overwritten).
##   repro-evidence-sink ack      --dir D --seq N --operator NAME
##                                --reason TEXT [--wait-seconds N]
##       records that the detection at sink sequence N was handled: an
##       append-only record in the store, written by the running sink under
##       its own id. `addon-check` then lists the alert as handled instead
##       of alerting on it. The acknowledged record itself stays.
##   repro-evidence-sink addon-check --dir D --hosts FILE
##                                [--manifests DIR --deploy-signers FILE]
##                                [--published-artefacts SHA256SUMS]
##                                [--silence-factor N] [--now-ms MS]
##                                [--update-hosts]
##       the ReproOS add-on's off-host detectors over the store. Exit 0 with
##       no alert, 1 with one or more (handled alerts do not count).
##
## Every option takes its value as `--name=value` or `--name value`.
## The read-side commands open the store directory directly: reading is
## local to the sink host by design (EVID-3). There is no network read.

import std/[asyncdispatch, os, posix, strutils, tables, times]

import nimcrypto/[hash, sha2]

import repro_peer_cache
import repro_peer_cache/auth as peerAuth
import repro_peer_cache/evidence_record

import ./evidence_check
import ./mutations

type
  SinkCommand* = object
    verb*: string
    dir*, identityDir*, anchorsDir*, readyFile*: string
    hostsPath*, manifestsDir*, signersPath*, artefactsPath*: string
    keyDir*, checkpointPub*, revokedPath*, expectPath*: string
    receipts*: seq[string]
    live*, updateHosts*: bool
    bindAddr*: string
    port*: int
    retention*: int64
    silenceFactor*: int
    segmentMaxEntries*: int
    nowMs*: int64
    seqNo*: uint64
    outPath*: string
    operator*, reason*: string
    waitSeconds*: int

  SinkUsageError* = object of CatchableError

const
  SinkVerbs* = ["serve", "verify", "liveness", "read", "payload", "ack",
                "addon-check"]
  SinkFlags = ["live", "update-hosts"]
    ## The options that take no value.
  SinkOptions = ["dir", "identity", "anchors", "bind", "port",
    "retention-seconds", "ready-file", "silence-factor", "segment-max-entries",
    "checkpoint-key", "checkpoint-pub", "receipt", "revoked", "expect", "hosts",
    "manifests", "deploy-signers", "published-artefacts", "now-ms", "seq",
    "out", "operator", "reason", "wait-seconds"]
  OperatorInboxName* = "operator-inbox"
  SinkHostName* = "sink-host"
  SinkOperatorDetector* = "sink-operator"

proc usageText*(): string =
  "usage: repro-evidence-sink " & SinkVerbs.join("|") & " --dir=DIR " &
    "[options]  (every option as --name=value or --name value; see " &
    "docs/user-guide/addon-evidence.md)"

proc parseSinkCommand*(args: openArray[string]): SinkCommand =
  ## The command ``args`` names. Raises ``SinkUsageError`` with the reason.
  result = SinkCommand(bindAddr: "127.0.0.1",
    retention: int64(DefaultRetentionSeconds), silenceFactor: 3,
    segmentMaxEntries: DefaultSegmentMaxEntries, waitSeconds: 30)
  var i = 0
  proc num(name, v: string): int64 =
    try: parseBiggestInt(v)
    except ValueError:
      raise newException(SinkUsageError, "--" & name & " needs a number, not " &
        (if v.len > 0: v else: "nothing"))
  while i < args.len:
    let a = args[i]
    if a.startsWith("--"):
      var name = a[2 .. ^1]
      var value = ""
      var hasValue = false
      let sep = name.find({'=', ':'})
      if sep >= 0:
        value = name[sep + 1 .. ^1]
        name = name[0 ..< sep]
        hasValue = true
      if name in SinkFlags:
        if hasValue:
          raise newException(SinkUsageError, "--" & name & " takes no value")
      elif name in SinkOptions:
        if not hasValue:
          when mutated("sink-cli-equals-only"):
            # FALSIFYING BUILD: the old parser, which read `--dir D` as an
            # empty --dir followed by a stray argument.
            raise newException(SinkUsageError, "--" & name & " needs =VALUE")
          else:
            if i + 1 >= args.len or args[i + 1].startsWith("--"):
              raise newException(SinkUsageError, "--" & name & " needs a value")
            inc i
            value = args[i]
      else:
        raise newException(SinkUsageError, "unknown option --" & name)
      case name
      of "dir": result.dir = value
      of "identity": result.identityDir = value
      of "anchors": result.anchorsDir = value
      of "bind": result.bindAddr = value
      of "port": result.port = int(num(name, value))
      of "retention-seconds": result.retention = num(name, value)
      of "ready-file": result.readyFile = value
      of "silence-factor": result.silenceFactor = int(num(name, value))
      of "segment-max-entries": result.segmentMaxEntries = int(num(name, value))
      of "checkpoint-key": result.keyDir = value
      of "checkpoint-pub": result.checkpointPub = value
      of "receipt": result.receipts.add(value)
      of "revoked": result.revokedPath = value
      of "expect": result.expectPath = value
      of "live": result.live = true
      of "hosts": result.hostsPath = value
      of "manifests": result.manifestsDir = value
      of "deploy-signers": result.signersPath = value
      of "published-artefacts": result.artefactsPath = value
      of "now-ms": result.nowMs = num(name, value)
      of "update-hosts": result.updateHosts = true
      of "seq": result.seqNo = uint64(num(name, value))
      of "out": result.outPath = value
      of "operator": result.operator = value
      of "reason": result.reason = value
      of "wait-seconds": result.waitSeconds = int(num(name, value))
      else: discard
    else:
      if result.verb.len > 0:
        raise newException(SinkUsageError, "unexpected argument " & a)
      result.verb = a
    inc i
  if result.verb notin SinkVerbs:
    raise newException(SinkUsageError, (if result.verb.len == 0: "no command"
      else: "unknown command " & result.verb))
  if result.dir.len == 0:
    raise newException(SinkUsageError, "--dir is required")
  case result.verb
  of "serve":
    if result.identityDir.len == 0 or result.anchorsDir.len == 0 or
        result.keyDir.len == 0:
      raise newException(SinkUsageError, "serve needs --identity, --anchors " &
        "and --checkpoint-key")
  of "verify":
    if result.checkpointPub.len == 0:
      raise newException(SinkUsageError, "verify needs --checkpoint-pub CERT " &
        "(the checkpoint key's certificate, pinned out of band; never read " &
        "from the store)")
  of "payload":
    if result.seqNo == 0'u64:
      raise newException(SinkUsageError, "payload needs --seq N")
  of "ack":
    if result.seqNo == 0'u64 or result.operator.len == 0 or
        result.reason.len == 0:
      raise newException(SinkUsageError, "ack needs --seq N, --operator NAME " &
        "and --reason TEXT")
  of "addon-check":
    if result.hostsPath.len == 0 or
        (result.manifestsDir.len > 0) != (result.signersPath.len > 0):
      raise newException(SinkUsageError, "addon-check needs --hosts FILE, " &
        "and --manifests DIR needs --deploy-signers FILE")
  else: discard

# ---------------------------------------------------------------------------
# The sink operator's acknowledgements (D4).
# ---------------------------------------------------------------------------

proc ackRecord*(seqNo: uint64; operator, reason: string;
                nowMs: int64): EvidenceRecord =
  newEvidenceRecord(ecAudit, SinkOperatorDetector, "acknowledged",
    [("acknowledges", $seqNo), ("operator", operator), ("reason", reason)],
    nowMs = nowMs)

proc processOperatorInbox*(store: EvidenceStore; sink: PeerId;
                           inbox: string): int =
  ## Append each acknowledgement an operator dropped into ``inbox``
  ## (``<seq>\n<operator>\n<reason>`` per file) under the sink's own id, then
  ## delete the file. The sink is the store's only writer, so this runs in
  ## it. Returns how many were appended.
  if not dirExists(inbox): return
  var names: seq[string]
  for kind, p in walkDir(inbox):
    if kind == pcFile and p.endsWith(".ack"): names.add(p)
  for p in names:
    try:
      let lines = readFile(p).splitLines()
      if lines.len >= 3:
        let n = parseBiggestUInt(lines[0].strip()).uint64
        discard store.appendRecord(sink, lrDaemon,
          ackRecord(n, lines[1].strip(), lines[2 .. ^1].join(" ").strip(),
                    int64(epochTime() * 1000)))
        inc result
    except CatchableError:
      discard           # a malformed request is dropped, not appended
    try: removeFile(p) except OSError: discard

proc sinkHostOf*(dir: string): string =
  try: readFile(dir / SinkHostName).strip().toLowerAscii()
  except IOError, OSError: ""

# ---------------------------------------------------------------------------
# A record's payload, shown as hostile data (D3).
# ---------------------------------------------------------------------------

proc escapePayload*(bytes: openArray[byte]): string =
  ## Printable ASCII and newlines as they are; every other byte ``\xNN``
  ## (and a backslash ``\\``), so a payload cannot drive the terminal it is
  ## read on.
  const hexd = "0123456789abcdef"
  when mutated("sink-payload-unescaped"):
    # FALSIFYING BUILD: the payload's bytes as they are.
    for b in bytes: result.add(char(b))
    return
  for b in bytes:
    let c = char(b)
    if c == '\\': result.add("\\\\")
    elif c == '\n' or (b >= 0x20 and b < 0x7f): result.add(c)
    else:
      result.add("\\x")
      result.add(hexd[int(b) shr 4])
      result.add(hexd[int(b) and 15])

proc renderPayload*(e: EvidenceEntry): string =
  let p = e.record.payload
  let digest = ($sha256.digest(p)).toLowerAscii()
  result = "seq " & $e.seq & " " & e.record.detector & " " & e.record.trigger &
    " payload " & $p.len & " bytes sha256 " & digest & "\n" &
    "----- BEGIN UNTRUSTED PAYLOAD (hostile data; non-printable bytes " &
    "escaped) -----\n" & escapePayload(p)
  if result.len > 0 and result[^1] != '\n': result.add("\n")
  result.add("----- END UNTRUSTED PAYLOAD -----\n")

proc entryAt(dir: string; seqNo: uint64): tuple[found: bool; e: EvidenceEntry] =
  for e in readEvidenceStore(dir):
    if e.seq == seqNo: return (true, e)

# ---------------------------------------------------------------------------
# The command.
# ---------------------------------------------------------------------------

proc runSinkCli*(args: openArray[string]): int =
  var c: SinkCommand
  try: c = parseSinkCommand(args)
  except SinkUsageError as e:
    stderr.writeLine("repro-evidence-sink: " & e.msg)
    stderr.writeLine(usageText())
    return 2
  case c.verb
  of "serve":
    if isWildcard(c.bindAddr):
      stderr.writeLine("repro-evidence-sink: refusing wildcard bind " &
        c.bindAddr & " (FLOW-6)")
      return 2
    let identity = loadOrCreateHostIdentity(c.identityDir / "host-ca.crt",
      c.identityDir / "host-ca.key")
    let anchors = loadTrustAnchorDir(c.anchorsDir)
    let store = openEvidenceStore(c.dir, c.keyDir, c.retention,
                                  c.segmentMaxEntries)
    writeFile(c.dir / SinkHostName, $identity.hostId & "\n")
    let inbox = c.dir / OperatorInboxName
    createDir(inbox)
    discard posix.chmod(inbox.cstring, Mode(0o700))
    let sink = newEvidenceSinkServer(store, identity, anchors, c.bindAddr,
      Port(c.port), anchorsDir = c.anchorsDir, revokedPath = c.revokedPath)
    sink.start()
    if c.readyFile.len > 0:
      writeFile(c.readyFile & ".tmp", c.bindAddr & ":" & $int(sink.listenPort) &
        "\n" & $identity.hostId & "\n")
      moveFile(c.readyFile & ".tmp", c.readyFile)
    stdout.writeLine("evidence sink listening on " & c.bindAddr & ":" &
      $int(sink.listenPort) & " host=" & $identity.hostId)
    stdout.flushFile()
    let retentionCheck = int(min(60_000'i64, max(1_000'i64, c.retention * 250)))
    while true:
      try: poll(200) except ValueError: sleep(200)
      sink.tick(retentionCheck)
      discard processOperatorInbox(store, identity.hostId, inbox)
  of "verify":
    var parsed: seq[SinkReceipt] = @[]
    for path in c.receipts:
      for line in readFile(path).splitLines:
        if line.strip().len > 0: parsed.add(decodeReceipt(line))
    let report = verifyEvidenceStore(c.dir,
      checkpointPublicKeyFromCert(c.checkpointPub), parsed,
      allowUnanchoredTail = c.live)
    stdout.writeLine("entries=" & $report.entries & " checkpoints=" &
      $report.checkpoints & " unanchored_tail=" & $report.unanchoredTail &
      " receipts=" & $report.receiptsChecked & " ok=" & $report.ok &
      (if report.ok: "" else: " reason=" & report.reason))
    return (if report.ok: 0 else: 1)
  of "liveness":
    let expected = if c.expectPath.len > 0: loadExpectedDetectors(c.expectPath)
                   else: @[]
    for row in livenessReport(c.dir, int64(epochTime() * 1000),
        c.silenceFactor, expected):
      stdout.writeLine($row.hostId & " " & row.detector & " " & $row.status &
        " detections=" & $row.detections & " interval_ms=" & $row.intervalMs &
        " last_heartbeat_ms=" & $row.lastHeartbeatMs)
    return 0
  of "read":
    for e in readEvidenceStore(c.dir):
      var line = $e.seq & " " & $e.receivedAtMs & " " & $e.kind & " " &
        $e.senderHostId & "/" & $e.senderRole
      if e.kind == ekRecord:
        line.add(" " & describe(e.record))
        if e.record.payload.len > 0:
          line.add(" payload=" & $e.record.payload.len & "B (repro-evidence-" &
            "sink payload --dir=" & c.dir & " --seq=" & $e.seq & ")")
      stdout.writeLine(line)
    return 0
  of "payload":
    let (found, e) = entryAt(c.dir, c.seqNo)
    if not found or e.kind != ekRecord:
      stderr.writeLine("repro-evidence-sink payload: no record at sequence " &
        $c.seqNo)
      return 1
    if c.outPath.len > 0:
      let fd = posix.open(c.outPath.cstring, O_WRONLY or O_CREAT or O_EXCL or
        O_CLOEXEC, Mode(0o600))
      if fd < 0:
        stderr.writeLine("repro-evidence-sink payload: cannot create " &
          c.outPath & " (it must not exist)")
        return 1
      let p = e.record.payload
      if p.len > 0: discard posix.write(fd, unsafeAddr p[0], p.len)
      discard posix.close(fd)
    stdout.write(renderPayload(e))
    return 0
  of "ack":
    let (found, e) = entryAt(c.dir, c.seqNo)
    if not found or not (e.kind == ekRefusedVerb or
        (e.kind == ekRecord and e.record.category == ecDetection)):
      stderr.writeLine("repro-evidence-sink ack: sequence " & $c.seqNo &
        " is not a detection in the store")
      return 1
    let inbox = c.dir / OperatorInboxName
    if not dirExists(inbox):
      stderr.writeLine("repro-evidence-sink ack: no " & inbox &
        " (is the sink running on this store?)")
      return 1
    let name = inbox / ($c.seqNo & "-" & $getCurrentProcessId() & ".ack")
    writeFile(name & ".tmp", $c.seqNo & "\n" & c.operator & "\n" &
      c.reason.replace("\n", " ") & "\n")
    moveFile(name & ".tmp", name)
    let deadline = epochTime() + float(c.waitSeconds)
    while epochTime() < deadline:
      for x in readEvidenceStore(c.dir):
        if x.kind == ekRecord and x.record.detector == SinkOperatorDetector and
            x.record.field("acknowledges") == $c.seqNo and
            x.record.field("operator") == c.operator:
          stdout.writeLine("acknowledged sequence " & $c.seqNo &
            " as record " & $x.seq)
          return 0
      sleep(250)
    stderr.writeLine("repro-evidence-sink ack: the sink did not record it " &
      "within " & $c.waitSeconds & " s; is it running on " & c.dir & "?")
    return 1
  of "addon-check":
    var inp = CheckInputs(storeDir: c.dir, silenceFactor: c.silenceFactor,
      nowMs: (if c.nowMs > 0: c.nowMs else: int64(epochTime() * 1000)),
      sinkHostId: sinkHostOf(c.dir))
    inp.hosts = parseHosts(readFile(c.hostsPath))
    if c.updateHosts:
      let enrolled = enrolFromStore(inp.hosts, c.dir)
      inp.hosts = enrolled.hosts
      if enrolled.changed:
        writeFile(c.hostsPath & ".tmp", renderHosts(inp.hosts))
        moveFile(c.hostsPath & ".tmp", c.hostsPath)
    if c.manifestsDir.len > 0:
      inp.manifests = loadPublishedManifests(c.manifestsDir,
        peerAuth.loadTrustAnchors(c.signersPath))
    if c.artefactsPath.len > 0:
      inp.publishedArtefacts = loadPublishedArtefacts(c.artefactsPath)
    let report = runEvidenceCheck(inp)
    stdout.write(render(report))
    return (if report.alerts.len > 0: 1 else: 0)
  else:
    stderr.writeLine(usageText())
    return 2
