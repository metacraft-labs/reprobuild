## The `RBSL` ("Reprobuild System Log") append-only audit log (M69 —
## System-Profile-And-Infra-Apply.md "Logging And Auditability").
##
## Every apply writes `<system-state-dir>/generations/<id>/log/apply.log`
## as an append-only sequence of RBSL records, one per operation. The
## log records, per the spec:
##
##   - timestamp
##   - operation kind (create / update / destroy / refresh / observe)
##   - resource address
##   - driver outcome (success / fail / partial)
##   - diagnostic bytes on failure
##   - pre-op and post-op observed state digests
##
## Each record is its own self-delimiting RBSL envelope so the log
## can be APPENDED to without rewriting earlier records, and a reader
## (`repro system audit`) walks the file record by record. A record
## with a bad checksum stops the walk with `EAuditLogCorrupt` —
## truncation of the LAST record (a crash mid-write) is reported but
## the preceding records are still readable.
##
## Per-record on-disk shape (little-endian throughout):
##
##   offset 0  : magic         4 bytes ASCII "RBSL"
##   offset 4  : schemaVersion u16 LE
##   offset 6  : bodyLength    u32 LE
##   offset 10 : body          bodyLength bytes
##   trailing  : checksum      32 bytes BLAKE3-256
##
## Body field order (audited, NO extras):
##
##   1. timestamp        i64 LE
##   2. operationKind    length-prefixed UTF-8
##   3. resourceAddress  length-prefixed UTF-8
##   4. outcome          length-prefixed UTF-8
##   5. diagnostic       length-prefixed UTF-8 (empty unless failure)
##   6. preDigestHex     length-prefixed UTF-8
##   7. postDigestHex    length-prefixed UTF-8
##   8. restartNeeded    u8 bool
##
## Schema version 2 appends two fields AFTER `restartNeeded`:
##
##   9. recordClass      length-prefixed UTF-8
##  10. fingerprintHex   length-prefixed UTF-8
##
## `recordClass` is the load-bearing discriminator between the TWO
## populations an apply converges (see `AuditClass*` below). Before v2
## the log carried only the live-state population, so the build-action
## half of an apply — which `repro infra apply` counts in its
## applied / no-op summary — was invisible to the audit trail: a
## generation's log accounted for a strict SUBSET of the resources the
## summary counted, and a benign build-fingerprint change could not be
## told apart from a live-state convergence regression.
##
## Backward compatibility: the writer always emits v2, the reader
## accepts v1 AND v2. A v1 record decodes with `recordClass` defaulted
## to `AuditClassLiveState` (correct — v1 could only describe live
## state) and an empty `fingerprintHex`, so previously-written
## generations under `<state-dir>/generations/` stay readable by
## `repro system audit` and by the planner's drift baseline.

import std/[os]

import blake3
import repro_core

import ./errors

const
  AuditMagic* = "RBSL"
  AuditSchemaVersion*: uint16 = 2
    ## The version the writer emits. See `AuditMinReadableVersion`.
  AuditMinReadableVersion*: uint16 = 1
    ## The oldest version the reader accepts. v1 logs written by an
    ## earlier `repro infra apply` remain readable.
  AuditHeaderSize = 4 + 2 + 4
  AuditTrailerSize = 32

  AuditClassLiveState* = "live-state"
    ## A record describing a live-state system resource: the thing the
    ## planner observes, the driver converges, and whose pre/post
    ## observed-state digests are meaningful.
  AuditClassBuildAction* = "build-action"
    ## A record describing a build-action EDGE. An edge is a cache
    ## decision (hit / substitute / local build), NOT a state
    ## transition, so it carries NO pre/post observed-state digest —
    ## those fields are empty by construction and must not be read as
    ## "the digest did not change". Its diagnosable identity is
    ## `resourceAddress` (the build-graph action id) plus
    ## `fingerprintHex`.

type
  AuditRecord* = object
    timestamp*: int64
    operationKind*: string
    resourceAddress*: string
    outcome*: string                 ## "applied" | "no-op" | "drift" | ...
    diagnostic*: string
    preDigestHex*: string
      ## Live-state only. ALWAYS empty for `AuditClassBuildAction` —
      ## a build edge has no observed pre-state, and synthesising one
      ## would blur the two populations this field set exists to keep
      ## apart.
    postDigestHex*: string
      ## Live-state only; see `preDigestHex`.
    restartNeeded*: bool
    recordClass*: string
      ## `AuditClassLiveState` | `AuditClassBuildAction`. The explicit
      ## discriminator between the two populations an apply converges.
      ## Empty on decode ONLY if a future version writes it empty; a
      ## v1 record decodes as `AuditClassLiveState`.
    fingerprintHex*: string
      ## `AuditClassBuildAction` only: the edge's cache fingerprint
      ## (hex). Empty for live-state records. This is what makes a
      ## PERMANENTLY-missing edge diagnosable — comparing the value
      ## across consecutive generations' logs shows whether the edge
      ## re-keys every apply (fingerprint churn) or keys stably and
      ## misses for another reason.

proc isBuildActionRecord*(rec: AuditRecord): bool =
  ## True for the build-action-edge population. Readers that reason
  ## about OBSERVED SYSTEM STATE (drift baselines, pre/post digest
  ## comparisons) must exclude these — an edge has no observed state.
  rec.recordClass == AuditClassBuildAction

proc isLiveStateRecord*(rec: AuditRecord): bool =
  ## True for the live-state population. A v1 record (no class on the
  ## wire) is live-state, so the default answer is the safe one.
  not rec.isBuildActionRecord()

# ---------------------------------------------------------------------------
# Single-record encode / decode.
# ---------------------------------------------------------------------------

proc encodeAuditRecord*(rec: AuditRecord): seq[byte] =
  var body: seq[byte]
  body.writeU64Le(uint64(rec.timestamp))
  body.writeString(rec.operationKind)
  body.writeString(rec.resourceAddress)
  body.writeString(rec.outcome)
  body.writeString(rec.diagnostic)
  body.writeString(rec.preDigestHex)
  body.writeString(rec.postDigestHex)
  body.add(if rec.restartNeeded: 1'u8 else: 0'u8)
  # v2 tail. An empty `recordClass` normalises to live-state so a
  # caller that builds an AuditRecord without naming the class keeps
  # the pre-v2 meaning instead of writing an unclassified record.
  body.writeString(
    if rec.recordClass.len > 0: rec.recordClass else: AuditClassLiveState)
  body.writeString(rec.fingerprintHex)
  result = newSeqOfCap[byte](AuditHeaderSize + body.len + AuditTrailerSize)
  for ch in AuditMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(AuditSchemaVersion)
  result.writeU32Le(uint32(body.len))
  for b in body:
    result.add(b)
  let checksum = blake3.digest(result)
  for b in checksum:
    result.add(b)

proc decodeAuditRecordAt*(bytes: openArray[byte]; start: int):
    tuple[rec: AuditRecord; nextOffset: int] =
  ## Decode the RBSL record starting at `start`; return it and the
  ## offset of the next record. Strict — a bad magic / version /
  ## length / checksum raises `EAuditLogCorrupt`.
  if start + AuditHeaderSize + AuditTrailerSize > bytes.len:
    raiseAuditLogCorrupt("record",
      "record at offset " & $start & " is truncated")
  for i in 0 ..< 4:
    if bytes[start + i] != byte(ord(AuditMagic[i])):
      raiseAuditLogCorrupt("magic",
        "expected '" & AuditMagic & "' at offset " & $start)
  var pos = start + 4
  let version = readU16Le(bytes, pos)
  if version < AuditMinReadableVersion or version > AuditSchemaVersion:
    raiseAuditLogCorrupt("schemaVersion",
      "unsupported RBSL version " & $version)
  let bodyLen = int(readU32Le(bytes, pos))
  let bodyEnd = pos + bodyLen
  if bodyEnd + AuditTrailerSize > bytes.len:
    raiseAuditLogCorrupt("bodyLength",
      "record body length " & $bodyLen & " overruns the file")
  var prefix = newSeqOfCap[byte](bodyEnd - start)
  for i in start ..< bodyEnd:
    prefix.add(bytes[i])
  let expected = blake3.digest(prefix)
  for i in 0 ..< 32:
    if bytes[bodyEnd + i] != expected[i]:
      raiseAuditLogCorrupt("trailingChecksum",
        "BLAKE3-256 checksum mismatch in the record at offset " & $start)
  var rec: AuditRecord
  rec.timestamp = int64(readU64Le(bytes, pos))
  rec.operationKind = readString(bytes, pos)
  rec.resourceAddress = readString(bytes, pos)
  rec.outcome = readString(bytes, pos)
  rec.diagnostic = readString(bytes, pos)
  rec.preDigestHex = readString(bytes, pos)
  rec.postDigestHex = readString(bytes, pos)
  if pos >= bytes.len:
    raiseAuditLogCorrupt("restartNeeded", "truncated record")
  rec.restartNeeded = bytes[pos] != 0
  inc pos
  if version >= 2:
    rec.recordClass = readString(bytes, pos)
    rec.fingerprintHex = readString(bytes, pos)
  else:
    # A v1 record predates the build-action half of the audit trail;
    # every v1 record describes live state.
    rec.recordClass = AuditClassLiveState
    rec.fingerprintHex = ""
  if pos != bodyEnd:
    raiseAuditLogCorrupt("body",
      "trailing bytes after the audited field set in the record at " &
      "offset " & $start)
  (rec: rec, nextOffset: bodyEnd + AuditTrailerSize)

# ---------------------------------------------------------------------------
# Append-only file writer.
# ---------------------------------------------------------------------------

proc appendAuditRecord*(logPath: string; rec: AuditRecord) =
  ## Append one RBSL record to the log, creating it (and its parent
  ## directory) if missing. The append is a single `write` of a
  ## fully-formed, checksummed record — a crash leaves at most the
  ## last record truncated, and the reader reports that without
  ## losing the earlier records.
  let parent = parentDir(logPath)
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
  let bytes = encodeAuditRecord(rec)
  var s = newString(bytes.len)
  for i, b in bytes:
    s[i] = char(b)
  var f: File
  if not open(f, logPath, fmAppend):
    raiseAuditLogCorrupt("file", "could not open the audit log for append: " &
      logPath)
  defer: close(f)
  f.write(s)

# ---------------------------------------------------------------------------
# Whole-log reader (`repro system audit`).
# ---------------------------------------------------------------------------

type
  AuditReadResult* = object
    records*: seq[AuditRecord]
    truncatedTail*: bool
      ## True when the file ends with a partial record (a crash
      ## mid-write). The complete records before it are still valid.

proc readAuditLog*(logPath: string): AuditReadResult =
  ## Walk the log record by record. A genuinely CORRUPT record (bad
  ## checksum on a record that is fully present) raises; a TRUNCATED
  ## final record is reported via `truncatedTail` without raising, so
  ## a crash-interrupted apply still has a readable audit trail.
  if not fileExists(logPath):
    return                              # empty result
  let raw = readFile(logPath)
  var bytes = newSeq[byte](raw.len)
  for i, ch in raw:
    bytes[i] = byte(ord(ch))
  var pos = 0
  while pos < bytes.len:
    # A complete record needs at least the header + trailer.
    if pos + AuditHeaderSize + AuditTrailerSize > bytes.len:
      result.truncatedTail = true
      break
    # Peek the declared body length to know if the whole record is
    # present before attempting a strict decode.
    var peek = pos + 4
    let version = readU16Le(bytes, peek)
    if version < AuditMinReadableVersion or version > AuditSchemaVersion:
      raiseAuditLogCorrupt("schemaVersion",
        "unsupported RBSL version " & $version & " at offset " & $pos)
    let bodyLen = int(readU32Le(bytes, peek))
    if pos + AuditHeaderSize + bodyLen + AuditTrailerSize > bytes.len:
      result.truncatedTail = true
      break
    let (rec, nextOffset) = decodeAuditRecordAt(bytes, pos)
    result.records.add(rec)
    pos = nextOffset
