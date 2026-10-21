## The hash-chained, append-only audit log (spec §"Audit").
##
## Each record names the digest of the one before it, so removing,
## reordering or editing any record breaks verification at that point. The
## host appends a record BEFORE making the decision's effect visible
## (I-AGT-6), and, when the log has a file, the record is on disk before
## `append` returns.

import std/os

import cbor

import ./[types, canonical]

type
  AuditRecord* = object
    seq*: uint64
    prevDigest*: Digest32
    time*: int64
    sessionId*: string
    provider*: string
    family*: string
    kind*: string
    decision*: string
      ## `allowed`, `refused`, or an event name (`grant`, `revoke`,
      ## `approve`, `reject`, `consume`, `cancel`, `suspend`, `recover`,
      ## `result`).
    reason*: string
    planId*: string     ## hex, or ""
    intentId*: string   ## hex, or ""
    approvalId*: string
    grant*: string
    resultDigest*: string ## hex, or ""

  AuditLog* = ref object
    records*: seq[AuditRecord]
    digests: seq[Digest32]
    path: string ## "" for an in-memory log

proc encodeRecord*(r: AuditRecord): seq[byte] =
  encodeDeterministic(cMap([
    tp("seq", cUInt(r.seq)),
    tp("prev", cDigest(r.prevDigest)),
    tp("time", cUInt(uint64(max(r.time, 0)))),
    tp("session", cText(r.sessionId)),
    tp("provider", cText(r.provider)),
    tp("family", cText(r.family)),
    tp("kind", cText(r.kind)),
    tp("decision", cText(r.decision)),
    tp("reason", cText(r.reason)),
    tp("plan", cText(r.planId)),
    tp("intent", cText(r.intentId)),
    tp("approval", cText(r.approvalId)),
    tp("grant", cText(r.grant)),
    tp("result", cText(r.resultDigest))]))

proc decodeAuditRecord*(bytes: openArray[byte]): AuditRecord =
  let v = canonical.decodeRecord(bytes)
  v.requireOnlyKeys(["seq", "prev", "time", "session", "provider", "family",
                     "kind", "decision", "reason", "plan", "intent",
                     "approval", "grant", "result"])
  template t(k: string): string = asText(v.field(k), "audit " & k)
  result.seq = asUInt(v.field("seq"), "audit seq")
  result.prevDigest = asDigest(v.field("prev"), "audit prev")
  result.time = int64(asUInt(v.field("time"), "audit time"))
  result.sessionId = t("session")
  result.provider = t("provider")
  result.family = t("family")
  result.kind = t("kind")
  result.decision = t("decision")
  result.reason = t("reason")
  result.planId = t("plan")
  result.intentId = t("intent")
  result.approvalId = t("approval")
  result.grant = t("grant")
  result.resultDigest = t("result")

proc recordDigest*(r: AuditRecord): Digest32 =
  id(AuditContext, encodeRecord(r))

proc newAuditLog*(path = ""): AuditLog =
  ## A log, empty or loaded from `path`. A file that does not verify is
  ## refused (`audit-corrupt`): the host must not extend a broken chain.
  result = AuditLog(path: path)
  if path.len == 0 or not fileExists(path):
    return
  let data = readFile(path)
  var pos = 0
  var prev: Digest32
  while pos < data.len:
    if pos + 4 > data.len:
      refuse(arAuditCorrupt, "truncated frame header")
    let n = (uint32(ord(data[pos])) shl 24) or
            (uint32(ord(data[pos + 1])) shl 16) or
            (uint32(ord(data[pos + 2])) shl 8) or uint32(ord(data[pos + 3]))
    pos += 4
    if int(n) > data.len - pos:
      refuse(arAuditCorrupt, "truncated record")
    let rec =
      try: decodeAuditRecord(data[pos ..< pos + int(n)].toBytes)
      except AgentRefusal as e: refuse(arAuditCorrupt, e.msg)
    pos += int(n)
    if rec.seq != uint64(result.records.len) or rec.prevDigest != prev:
      refuse(arAuditCorrupt, "chain broken at record " & $result.records.len)
    prev = recordDigest(rec)
    result.records.add rec
    result.digests.add prev

proc head*(log: AuditLog): Digest32 =
  if log.digests.len > 0: log.digests[^1] else: default(Digest32)

proc append*(log: AuditLog; r: AuditRecord): uint64 =
  ## Append `r` (its `seq` and `prevDigest` are assigned here) and return
  ## its sequence number. With a file, the frame is flushed before
  ## returning.
  var rec = r
  rec.seq = uint64(log.records.len)
  rec.prevDigest = log.head
  let bytes = encodeRecord(rec)
  if log.path.len > 0:
    createDir(log.path.parentDir)
    let f = open(log.path, fmAppend)
    try:
      let n = uint32(bytes.len)
      f.write(char((n shr 24) and 0xff), char((n shr 16) and 0xff),
              char((n shr 8) and 0xff), char(n and 0xff))
      f.write(bytes.toStr)
      f.flushFile()
    finally:
      f.close()
  log.records.add rec
  log.digests.add id(AuditContext, bytes)
  rec.seq

proc verify*(records: seq[AuditRecord]): int =
  ## Index of the first record that breaks the chain, or -1 when the whole
  ## sequence verifies.
  var prev: Digest32
  for i, r in records:
    if r.seq != uint64(i) or r.prevDigest != prev:
      return i
    prev = recordDigest(r)
  -1

proc verify*(log: AuditLog): bool = verify(log.records) == -1
