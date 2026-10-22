## Evidence records and their redaction — Distributed-Execution M7
## (deployment-security-architecture.md DET-2, DET-5, DET-6, EVID-1, EVID-6).
##
## One `EvidenceRecord` is one fact a worker reports to the off-host Evidence
## sink (`evidence.nim`): a per-message audit line (FLOW-2), a detector firing
## (DET-*), or a detector heartbeat (DET-5). The worker builds records; the
## sink stamps who sent them and when it received them, and chains them.
##
## REDACTION IS AN ALLOW-LIST (EVID-6). What this campaign captures can
## contain a developer's uncommitted source: a working-tree snapshot is
## shipped to workers by design (M1), and a poisoned blob may BE a source
## file. So `redact` keeps only:
##
## * fields whose NAME is in `EvidenceFieldAllowList`, each value truncated to
##   `MaxFieldValueBytes`. A field added next year is dropped by
##   construction until someone decides it belongs here — the reasoning
##   `infra/services/api-gateway/audit.nix` gives for its own audit list;
## * payload bytes only for triggers in `PayloadCaptureTriggers` — the ones
##   whose payload is protocol METADATA (a memo entry, a refused control
##   frame, a goal request), truncated to `MaxCapturedPayloadBytes`. Every
##   other trigger keeps the payload's BLAKE3 digest and size and nothing
##   else, so a blob that failed verification is identified without its
##   bytes (which may be source) ever leaving the worker.
##
## The sink applies `redact` again on ingest: a worker that has been
## compromised can send whatever it likes, and the store must still hold
## only allow-listed content.

import std/[os, strutils, times]
when defined(posix):
  import std/posix

import blake3
from repro_core/codec import elementCountFits

import ./types

const
  EvidenceRecordMagic = "EVRC"
  EvidenceRecordVersion = 1'u16
  MaxNameBytes* = 64
  MaxFieldValueBytes* = 2_048
  MaxFields* = 48
  MaxCapturedPayloadBytes* = 64 * 1024
  MaxEncodedRecordBytes* = 160 * 1024
  SinkRecordsPerSecondPerSender* = 4_000.0
  SinkBurstPerSender* = 20_000.0
    ## What the evidence sink records per second from one sender (a host
    ## and leaf role), and the burst it absorbs before it applies
    ## backpressure (`evidence.nim`). The Boundary gates are sized to fit
    ## inside it (`boundary.auditBudgetIsConsistent`, threat model G18).

  EvidenceFieldAllowList* = [
    "peer", "peerAddress", "leafRole", "messageKind", "refusal", "reason",
    "digest", "observedDigest", "size", "weakFingerprint",
    "strongFingerprint", "pathSetDigest", "issuer", "issuedAt", "goalNode",
    "path", "argv", "leaseId", "operation", "destination", "exe",
    "expectedTree", "observedTree", "intervalMs", "count", "role",
    "descriptorDigest", "snapshotDigest", "listen", "detectorVersion",
    "host", "pid", "exitCode", "layer", "direction", "suppressed",
    "syscall", "probe", "receiptSeq", "receiptHead", "workerHost",
    "keyId", "certificateSerial", "signal", "limit"]
    ## The only field names a record may carry (EVID-6). Deliberately no
    ## free-form "data"/"body"/"env" field: an environment can hold
    ## credentials, a body can hold source.

  PayloadCaptureTriggers* = [
    "memo-issuer-unbound", "memo-attestation-invalid",
    "memo-attestation-expired",
    "memo-selector-mismatch", "selector-validation-failed",
    "frame-refused", "goal-argv-not-derivable", "goal-path-outside-snapshot",
    "goal-descriptor-unbound", "goal-schema-invalid"]
    ## Triggers whose payload is protocol metadata and is captured
    ## (EVID-1: the payload, not only the fact). A blob-digest mismatch is
    ## NOT here: its payload may be a source file.

type
  EvidenceCategory* = enum
    ecAudit = "audit"
    ecDetection = "detection"
    ecHeartbeat = "heartbeat"

  EvidenceRecord* = object
    category*: EvidenceCategory
    detector*: string
      ## Which detector produced it (`boundary-gate`, `peer-cache-content`,
      ## `peer-cache-memo`, `goal-receiver`, `lease-supervisor`,
      ## `certificate-issuance`, `peer-suspicion`).
    trigger*: string
      ## What tripped (`blob-digest-mismatch`, `memo-issuer-unbound`, …), or
      ## the message kind for an audit record, or "" for a heartbeat.
    senderTimeMs*: int64
      ## The SENDER's clock. The sink records its own receipt time beside it
      ## (HOST-7: a compromised host's clock is a timeline it writes).
    senderPid*: int32
    fields*: seq[(string, string)]
    payload*: seq[byte]
      ## Captured bytes, after redaction (possibly empty).
    payloadDigest*: BlobDigest
      ## BLAKE3-256 of the payload as OBSERVED, before redaction — so a
      ## redacted payload is still identified.
    payloadSize*: uint64

  EvidenceRecordError* = object of CatchableError

  DetectionReporter* = proc(record: EvidenceRecord) {.gcsafe, closure.}
    ## Where a detector hands a record (the wiring binds it to an
    ## `EvidenceAppender`). Must not raise.

proc field*(record: EvidenceRecord; name: string): string =
  for (k, v) in record.fields:
    if k == name:
      return v
  ""

proc digestOfBytes(data: openArray[byte]): BlobDigest =
  blobDigestFromBytes(blake3.digest(data))

proc newEvidenceRecord*(category: EvidenceCategory; detector, trigger: string;
                        fields: openArray[(string, string)] = [];
                        payload: openArray[byte] = [];
                        nowMs = 0'i64; pid = 0): EvidenceRecord =
  ## A record with the payload digest and size computed from `payload` as
  ## given. Redaction happens in `redact` (the appender calls it).
  result = EvidenceRecord(category: category, detector: detector,
    trigger: trigger, senderTimeMs: nowMs, senderPid: int32(pid),
    fields: @fields, payload: @payload,
    payloadDigest: digestOfBytes(payload), payloadSize: uint64(payload.len))

proc truncateUtf8(s: string; maxBytes: int): string =
  if s.len <= maxBytes:
    return s
  var cut = maxBytes
  # Do not split a UTF-8 sequence.
  while cut > 0 and (ord(s[cut]) and 0xC0) == 0x80:
    dec cut
  s[0 ..< cut]

proc redact*(record: EvidenceRecord): EvidenceRecord =
  ## The allow-listed form of `record` (see the module doc). Idempotent.
  result = record
  result.detector = truncateUtf8(record.detector, MaxNameBytes)
  result.trigger = truncateUtf8(record.trigger, MaxNameBytes)
  result.fields = @[]
  for (k, v) in record.fields:
    if k in EvidenceFieldAllowList and result.fields.len < MaxFields:
      result.fields.add((k, truncateUtf8(v, MaxFieldValueBytes)))
  if record.trigger in PayloadCaptureTriggers:
    if record.payload.len > MaxCapturedPayloadBytes:
      result.payload = record.payload[0 ..< MaxCapturedPayloadBytes]
  else:
    result.payload = @[]

# ---------------------------------------------------------------------------
# Codec. Little-endian, length-prefixed, every count bounded on decode.
# ---------------------------------------------------------------------------

proc putU16(dst: var seq[byte]; v: uint16) =
  dst.add(byte(v and 0xff)); dst.add(byte(v shr 8))

proc putU32(dst: var seq[byte]; v: uint32) =
  for s in countup(0, 24, 8): dst.add(byte((v shr uint32(s)) and 0xff))

proc putU64(dst: var seq[byte]; v: uint64) =
  for s in countup(0, 56, 8): dst.add(byte((v shr uint64(s)) and 0xff))

proc putStr(dst: var seq[byte]; s: string) =
  dst.putU32(uint32(s.len))
  for ch in s: dst.add(byte(ord(ch)))

proc need(data: openArray[byte]; pos, n: int) =
  if n < 0 or pos + n > data.len:
    raise newException(EvidenceRecordError, "truncated evidence record")

proc getU16(data: openArray[byte]; pos: var int): uint16 =
  need(data, pos, 2)
  result = uint16(data[pos]) or (uint16(data[pos + 1]) shl 8)
  pos += 2

proc getU32(data: openArray[byte]; pos: var int): uint32 =
  need(data, pos, 4)
  for i in 0 ..< 4: result = result or (uint32(data[pos + i]) shl uint32(8 * i))
  pos += 4

proc getU64(data: openArray[byte]; pos: var int): uint64 =
  need(data, pos, 8)
  for i in 0 ..< 8: result = result or (uint64(data[pos + i]) shl uint64(8 * i))
  pos += 8

proc getStr(data: openArray[byte]; pos: var int; maxLen: int): string =
  let n = int(getU32(data, pos))
  if n > maxLen:
    raise newException(EvidenceRecordError, "evidence string too long: " & $n)
  need(data, pos, n)
  result = newString(n)
  for i in 0 ..< n: result[i] = char(data[pos + i])
  pos += n

proc getCount(data: openArray[byte]; pos: var int; minimumBytes: int): int =
  ## An element count, bounded BEFORE anything is sized or looped over by
  ## it: each element takes at least `minimumBytes` (repro_core/codec).
  let raw = getU32(data, pos)
  if not elementCountFits(raw, data.len - pos, minimumBytes):
    raise newException(EvidenceRecordError, "evidence record element count exceeds remaining bytes")
  int(raw)

proc encodeEvidenceRecord*(record: EvidenceRecord): seq[byte] =
  for ch in EvidenceRecordMagic: result.add(byte(ord(ch)))
  result.putU16(EvidenceRecordVersion)
  result.add(byte(ord(record.category)))
  result.putStr(record.detector)
  result.putStr(record.trigger)
  result.putU64(cast[uint64](record.senderTimeMs))
  result.putU32(cast[uint32](record.senderPid))
  result.putU32(uint32(record.fields.len))
  for (k, v) in record.fields:
    result.putStr(k)
    result.putStr(v)
  for b in bytes(record.payloadDigest): result.add(b)
  result.putU64(record.payloadSize)
  result.putU32(uint32(record.payload.len))
  result.add(record.payload)

proc decodeEvidenceRecord*(data: openArray[byte]): EvidenceRecord =
  ## Strict decode: every length bounded, no trailing bytes.
  if data.len > MaxEncodedRecordBytes:
    raise newException(EvidenceRecordError, "evidence record too large")
  need(data, 0, EvidenceRecordMagic.len)
  for i, ch in EvidenceRecordMagic:
    if data[i] != byte(ord(ch)):
      raise newException(EvidenceRecordError, "not an evidence record")
  var pos = EvidenceRecordMagic.len
  if getU16(data, pos) != EvidenceRecordVersion:
    raise newException(EvidenceRecordError, "unsupported evidence version")
  need(data, pos, 1)
  let cat = int(data[pos]); inc pos
  if cat < ord(low(EvidenceCategory)) or cat > ord(high(EvidenceCategory)):
    raise newException(EvidenceRecordError, "bad evidence category")
  result.category = EvidenceCategory(cat)
  result.detector = getStr(data, pos, MaxNameBytes)
  result.trigger = getStr(data, pos, MaxNameBytes)
  result.senderTimeMs = cast[int64](getU64(data, pos))
  result.senderPid = cast[int32](getU32(data, pos))
  let n = getCount(data, pos, 8)     # key and value, a u32 each
  if n > MaxFields:
    raise newException(EvidenceRecordError, "too many evidence fields")
  for _ in 0 ..< n:
    let k = getStr(data, pos, MaxNameBytes)
    let v = getStr(data, pos, MaxFieldValueBytes)
    result.fields.add((k, v))
  need(data, pos, 32)
  var raw: array[32, byte]
  for i in 0 ..< 32: raw[i] = data[pos + i]
  pos += 32
  result.payloadDigest = blobDigestFromBytes(raw)
  result.payloadSize = getU64(data, pos)
  let plen = int(getU32(data, pos))
  if plen > MaxCapturedPayloadBytes:
    raise newException(EvidenceRecordError, "evidence payload too large")
  need(data, pos, plen)
  result.payload = data[pos ..< pos + plen]
  pos += plen
  if pos != data.len:
    raise newException(EvidenceRecordError, "trailing bytes after record")

proc describe*(record: EvidenceRecord): string =
  ## One line for logs and diagnostics.
  var parts = @[$record.category, record.detector]
  if record.trigger.len > 0: parts.add(record.trigger)
  for (k, v) in record.fields:
    parts.add(k & "=" & v.replace("\n", " "))
  parts.join(" ")

# ---------------------------------------------------------------------------
# Local detection and audit logs — the TRUSTED profile's EVID-6.
#
# A trusted node has no evidence sink (threat model §3a), so its detections
# and audit lines stay on the host: the worker's `<state>/worker/detections.log`
# and a peer-cache node's `<state>/peer-cache-detections.log` and
# `<state>/peer-cache-audit.log`. They describe goals run on a developer's
# uncommitted source (asset 3), so the same EVID-6 rules the sink keeps apply
# here, in the same code:
#
# * SCOPE: one line per detection (or, for the audit log, per admitted
#   frame) — the trigger, the detector and the allow-listed fields; never a
#   payload byte.
# * REDACTION, AS AN ALLOW-LIST: every line is `describe(redact(record))` —
#   only fields named in `EvidenceFieldAllowList`, each truncated to
#   `MaxFieldValueBytes`; a field nobody listed (an environment value, a
#   body) is dropped by construction (`localLogEntry`).
# * READERS: the node's own OS user. Each file is created `0600` (an
#   existing file is reset to `0600` before every append); nothing serves
#   it over the network.
# * RETENTION WITH AUTOMATED DELETION: the active file is rotated to
#   `<path>.1` once it exceeds `maxBytes` or its first entry is older than
#   `rotateAfterSeconds`; at most `generations` rotated files are kept; a
#   rotated file whose NEWEST entry (its mtime) is older than
#   `retentionSeconds` is deleted. `sweepLocalLog` applies the age rules
#   without a new entry (the node calls it on a timer), so a quiet node's
#   old entries are deleted too: an entry lives at most
#   `retentionSeconds + rotateAfterSeconds` plus one sweep interval.
# ---------------------------------------------------------------------------

type
  LocalLogPolicy* = object
    maxBytes*: int64
      ## Rotate the active file before it would grow beyond this.
    rotateAfterSeconds*: int64
      ## Rotate the active file once its FIRST entry is this old.
    generations*: int
      ## Rotated files kept (`<path>.1` newest … `<path>.N` oldest).
    retentionSeconds*: int64
      ## A rotated file whose newest entry is older than this is deleted.

const
  LocalLogRetentionSeconds* = 30'i64 * 86_400
    ## The same thirty days the evidence sink keeps (`evidence.nim`
    ## `DefaultRetentionSeconds`).
  DefaultLocalLogPolicy* = LocalLogPolicy(maxBytes: 2'i64 * 1024 * 1024,
    rotateAfterSeconds: 86_400, generations: 32,
    retentionSeconds: LocalLogRetentionSeconds)

proc localLogEntry*(record: EvidenceRecord): string =
  ## The line body a local log stores for `record`: the allow-listed form
  ## (`redact`), described on one line. No payload byte is ever written.
  describe(redact(record))

proc localLogNow(nowS: int64): int64 =
  if nowS != 0: nowS else: getTime().toUnix

proc firstEntrySeconds(path: string): int64 =
  ## The timestamp that starts the file's first line; -1 when the file is
  ## absent, empty or not in this format (then it counts as old).
  var f: File
  if not open(f, path, fmRead):
    return -1
  defer: f.close()
  var buf = newString(32)
  let got = f.readBuffer(addr buf[0], buf.len)
  buf.setLen(got)
  let sp = buf.find(' ')
  if sp <= 0:
    return -1
  try: parseBiggestInt(buf[0 ..< sp]) except ValueError: -1

proc generationPath(path: string; i: int): string = path & "." & $i

proc rotateLocalLog(path: string; policy: LocalLogPolicy) =
  let gens = max(policy.generations, 1)
  let oldest = generationPath(path, gens)
  if fileExists(oldest):
    removeFile(oldest)
  for i in countdown(gens - 1, 1):
    let src = generationPath(path, i)
    if fileExists(src):
      moveFile(src, generationPath(path, i + 1))
  if fileExists(path):
    moveFile(path, generationPath(path, 1))

proc sweepLocalLog*(path: string; policy = DefaultLocalLogPolicy;
                    nowS = 0'i64): int =
  ## Applies the age rules to the log at `path` (see the section doc):
  ## rotates the active file when its first entry is older than
  ## `rotateAfterSeconds`, and deletes every rotated file whose newest
  ## entry is older than `retentionSeconds`. Returns the files deleted.
  ## Never raises.
  let now = localLogNow(nowS)
  try:
    if fileExists(path):
      let first = firstEntrySeconds(path)
      if first < 0 or now - first >= policy.rotateAfterSeconds:
        rotateLocalLog(path, policy)
    for i in 1 .. max(policy.generations, 1):
      let g = generationPath(path, i)
      if not fileExists(g):
        continue
      let newest = getLastModificationTime(g).toUnix
      if now - newest >= policy.retentionSeconds:
        removeFile(g)
        inc result
  except CatchableError:
    discard

proc appendLocalLog*(path, body: string; policy = DefaultLocalLogPolicy;
                     nowS = 0'i64) =
  ## Appends `<unix seconds> <body>` to the owner-only log at `path`,
  ## rotating first when the entry would push it past `maxBytes`, and
  ## applying the age rules (`sweepLocalLog`). `body` must already be the
  ## allow-listed form (`localLogEntry`). Never raises.
  let now = localLogNow(nowS)
  let line = $now & " " & body.replace("\n", " ") & "\n"
  try:
    if fileExists(path) and
        getFileSize(path) + int64(line.len) > policy.maxBytes:
      rotateLocalLog(path, policy)
    discard sweepLocalLog(path, policy, now)
    when defined(posix):
      let fd = posix.open(path.cstring,
        O_WRONLY or O_APPEND or O_CREAT or O_CLOEXEC, Mode(0o600))
      if fd < 0:
        return
      defer: discard posix.close(fd)
      discard fchmod(fd, Mode(0o600))
      var off = 0
      while off < line.len:
        let n = posix.write(fd, unsafeAddr line[off], line.len - off)
        if n <= 0:
          break
        off += n
    else:
      let f = open(path, fmAppend)
      defer: f.close()
      f.write(line)
  except CatchableError:
    discard
