## The Evidence zone: an append-only, tamper-evident, off-host sink and the
## write-only appender workers use — Distributed-Execution M7
## (deployment-security-architecture.md EVID-2, EVID-3, EVID-6, DET-5,
## DET-6, HOST-7).
##
## THE SINK IS A SINK, NOT A SERVICE (EVID-3). Its wire vocabulary has
## exactly two request verbs, both appends:
##
##   vAppend       one record          -> vAck{seq, receivedAtMs}
##   vAppendBatch  up to 1024 records  -> vAck{lastSeq, receivedAtMs}
##
## There is no read, list, query or delete verb, so a worker's credential is
## write-only by construction (EVID-2: "cannot list, read, or delete"): the
## attacker's own traffic to the sink is unerasable. Any other verb is itself
## recorded — as a `ekRefusedVerb` entry naming the sender — and the
## connection is closed, because probing the sink is exactly the
## reconnaissance it exists to capture. Reading happens only through the
## local store API below (`readEvidenceStore`, `verifyEvidenceStore`,
## `livenessReport`), run by the sink's operator or an investigating agent on
## the sink host, never over the network.
##
## WHO SENT IT is stamped by the SINK from the appender's verified TLS leaf
## (`identity.nim`), never taken from the record: a compromised worker cannot
## file evidence under another host's name. WHEN is stamped too — the sink's
## receipt clock beside the sender's (HOST-7).
##
## APPEND-ONLY AND TAMPER-EVIDENT ARE TWO PROPERTIES (EVID-2):
##
## * append-only — segment files are opened `O_APPEND` and never rewritten;
##   nothing in this module truncates or edits an entry. On a fleet sink the
##   storage layer adds its own guarantee (the NixOS module sets the
##   append-only attribute; `Distributed-Execution-Threat-Model.md` records
##   where that is not yet deployed);
## * tamper-evident — every entry carries the BLAKE3 of its predecessor and
##   of itself (a hash chain), and after EVERY accepted batch the sink signs
##   the chain head with its checkpoint key (`ekCheckpoint`) and returns the
##   signed head to the appender as its acknowledgement — a RECEIPT
##   (`SinkReceipt`). So no acknowledged entry is ever "after the last
##   checkpoint" (the unanchored tail the review found, threat model G28),
##   and the appenders hold signed heads outside the sink host:
##   `verifyEvidenceStore` given a receipt proves the store still holds that
##   entry with that hash, so truncating the store back to an earlier
##   checkpoint — invisible from the store alone — is detected.
##   The checkpoint key lives in its OWN directory (`--checkpoint-key`),
##   never beside the data, and `verify` takes the public key from the
##   operator (`--checkpoint-pub`), never from the store.
##
## RETENTION WITH AUTOMATED DELETION (EVID-6). Closed segments whose newest
## entry is older than the retention period are deleted by the sink itself on
## its timer. Before deleting, it appends an `ekRetention` entry naming the
## deleted range and the hash of the last deleted entry, so the chain stays
## verifiable from that anchor and the deletion is itself on the record.
##
## HEARTBEATS (DET-5). A detector that has gone silent because its host died
## and a fleet in which nothing happened look the same unless every detector
## reports that it is alive. `EvidenceAppender.registerDetector` sends a
## heartbeat per detector on its interval; `livenessReport` classifies each
## (host, detector) as live-idle, live-detecting or SILENT.

import std/[asyncdispatch, asyncnet, algorithm, nativesockets, net, options,
            os, sets, strutils, tables, times]

import blake3
from repro_core/codec import elementCountFits

import ./auth
import ./evidence_record
import ./identity
import ./pki
import ./secret_key
import ./tls
import ./types

export evidence_record

const
  EntryMagic = "EVE1"
  EntryDomain = "reprobuild/evidence/entry/v1\x00"
  CheckpointDomain = "reprobuild/evidence/checkpoint/v1\x00"
  SegmentPrefix = "seg-"
  SegmentSuffix = ".evl"
  CheckpointInterval* = 64
    ## Records between checkpoints when appending directly (a batch from an
    ## appender is always followed by one).
  SinkBackpressureMaxWaitMs = 30_000
  DefaultSegmentMaxEntries* = 4_096
  DefaultRetentionSeconds* = 30 * 86_400
    ## EVID-6 default: thirty days, then automated deletion.
  MaxFrameBytes = 1024 * 1024
  MaxBatchRecords = 1_024
  SinkRatePerSecond = SinkRecordsPerSecondPerSender
  SinkBurst = SinkBurstPerSender

  vAppend = 1'u8
  vAppendBatch = 2'u8
  vAck = 3'u8

type
  EntryKind* = enum
    ekRecord = "record"
    ekCheckpoint = "checkpoint"
    ekRetention = "retention"
    ekRefusedVerb = "refused-verb"

  EvidenceEntry* = object
    seq*: uint64
    receivedAtMs*: int64
    senderHostId*: PeerId
    senderRole*: LeafRole
    kind*: EntryKind
    prevHash*: array[32, byte]
    body*: seq[byte]
    entryHash*: array[32, byte]
    record*: EvidenceRecord
      ## Decoded body when `kind == ekRecord`.

  EvidenceStore* = ref object
    ## The sink's on-disk store. Single writer (the sink process).
    dir*: string
    keyDir*: string
      ## Where the checkpoint key lives — NOT inside `dir`.
    signer*: SecretKey
      ## The checkpoint-signing key (`<keyDir>/sink-checkpoint.key`).
    nextSeq*: uint64
    headHash*: array[32, byte]
    segmentMaxEntries*: int
    retentionSeconds*: int64
    currentSegment: string
    currentSegmentEntries: int
    sinceCheckpoint: int

  EvidenceSinkServer* = ref object
    store*: EvidenceStore
    listenAddr*: string
    listenPort*: Port
    identity*: HostIdentity
    leaf*: LeafCredential
    anchors*: TrustAnchorSet
    anchorsDir*: string
      ## Re-read for every new connection: removing a worker's CA from the
      ## directory de-authorizes it at its next connection (threat model
      ## G17); `revokedPath` ends an open one at its next frame.
    revokedPath*: string
    listener: AsyncSocket
    running*: bool
    buckets: Table[string, tuple[tokens: float; lastMs: int64]]
    appendedCount*: int
    refusedVerbCount*: int
    rejectedHandshakes*: int
    expiredConnections*: int
    revokedConnections*: int
    backpressureWaits*: int
    lastRetentionMs: int64
    clock*: proc(): int64 {.gcsafe, closure.}
      ## Unix milliseconds; nil = the system clock (test seam, G15).

  SinkReceipt* = object
    ## What the sink returns for an accepted batch: the chain head after it,
    ## signed with the checkpoint key. Appenders keep the latest one; given
    ## to `verifyEvidenceStore` it proves the store was not truncated or
    ## rewritten behind that head (threat model G28).
    headSeq*: uint64
    headHash*: array[32, byte]
    signature*: SignatureBytes
    receivedAtMs*: int64

  VerifyReport* = object
    ok*: bool
    entries*: int
    checkpoints*: int
    unanchoredTail*: int
      ## Entries after the last signed checkpoint. Not zero only when the
      ## sink stopped between appending a batch and signing it; `verify`
      ## fails on it unless told the store is being inspected live.
    receiptsChecked*: int
    firstBadSeq*: int64
    reason*: string

  LivenessStatus* = enum
    lsLiveIdle = "live-idle"
    lsLiveDetecting = "live-detecting"
    lsSilent = "silent"
    lsNeverReported = "never-reported"
      ## An EXPECTED (host, detector) with no heartbeat at all: a host that
      ## never connected, a role that failed to register (threat model
      ## G22). Distinct from silent, which once was alive.

  DetectorLiveness* = object
    hostId*: PeerId
    detector*: string
    intervalMs*: int64
    lastHeartbeatMs*: int64
    detections*: int
    lastDetectionMs*: int64
    status*: LivenessStatus

  EvidenceStoreError* = object of CatchableError

proc nowMsE(): int64 =
  int64(epochTime() * 1000.0)

# ---------------------------------------------------------------------------
# Entry codec.
# ---------------------------------------------------------------------------

proc putU32(dst: var seq[byte]; v: uint32) =
  for s in countup(0, 24, 8): dst.add(byte((v shr uint32(s)) and 0xff))

proc putU64(dst: var seq[byte]; v: uint64) =
  for s in countup(0, 56, 8): dst.add(byte((v shr uint64(s)) and 0xff))

proc getU32(data: openArray[byte]; pos: var int): uint32 =
  if pos + 4 > data.len:
    raise newException(EvidenceStoreError, "truncated evidence entry")
  for i in 0 ..< 4: result = result or (uint32(data[pos + i]) shl uint32(8 * i))
  pos += 4

proc getU64(data: openArray[byte]; pos: var int): uint64 =
  if pos + 8 > data.len:
    raise newException(EvidenceStoreError, "truncated evidence entry")
  for i in 0 ..< 8: result = result or (uint64(data[pos + i]) shl uint64(8 * i))
  pos += 8

proc get32(data: openArray[byte]; pos: var int): array[32, byte] =
  if pos + 32 > data.len:
    raise newException(EvidenceStoreError, "truncated evidence entry")
  for i in 0 ..< 32: result[i] = data[pos + i]
  pos += 32

proc entryPrefix(e: EvidenceEntry): seq[byte] =
  ## Everything the entry hash covers, in wire order.
  for ch in EntryMagic: result.add(byte(ord(ch)))
  result.putU64(e.seq)
  result.putU64(cast[uint64](e.receivedAtMs))
  for b in bytes(e.senderHostId): result.add(b)
  result.add(byte(ord(e.senderRole)))
  result.add(byte(ord(e.kind)))
  for b in e.prevHash: result.add(b)
  result.putU32(uint32(e.body.len))
  result.add(e.body)

proc computeEntryHash(e: EvidenceEntry): array[32, byte] =
  var msg: seq[byte] = @[]
  for ch in EntryDomain: msg.add(byte(ord(ch)))
  msg.add(entryPrefix(e))
  blake3.digest(msg)

proc encodeEntry(e: EvidenceEntry): seq[byte] =
  result = entryPrefix(e)
  for b in e.entryHash: result.add(b)

proc decodeEntryAt(data: openArray[byte]; pos: var int): EvidenceEntry =
  if pos + EntryMagic.len > data.len:
    raise newException(EvidenceStoreError, "truncated evidence entry")
  for i, ch in EntryMagic:
    if data[pos + i] != byte(ord(ch)):
      raise newException(EvidenceStoreError, "bad evidence entry magic")
  pos += EntryMagic.len
  result.seq = getU64(data, pos)
  result.receivedAtMs = cast[int64](getU64(data, pos))
  result.senderHostId = peerIdFromBytes(get32(data, pos))
  if pos + 2 > data.len:
    raise newException(EvidenceStoreError, "truncated evidence entry")
  let role = int(data[pos]); let kind = int(data[pos + 1])
  pos += 2
  if role > ord(high(LeafRole)) or kind > ord(high(EntryKind)):
    raise newException(EvidenceStoreError, "bad evidence entry tag")
  result.senderRole = LeafRole(role)
  result.kind = EntryKind(kind)
  result.prevHash = get32(data, pos)
  let n = int(getU32(data, pos))
  if n > MaxFrameBytes or pos + n > data.len:
    raise newException(EvidenceStoreError, "truncated evidence entry body")
  result.body = data[pos ..< pos + n]
  pos += n
  result.entryHash = get32(data, pos)
  if result.kind == ekRecord:
    result.record = decodeEvidenceRecord(result.body)

# ---------------------------------------------------------------------------
# Store.
# ---------------------------------------------------------------------------

proc segmentPath(store: EvidenceStore; firstSeq: uint64): string =
  store.dir / "segments" / (SegmentPrefix & align($firstSeq, 20, '0') &
    SegmentSuffix)

proc listSegments*(dir: string): seq[string] =
  let segDir = dir / "segments"
  if not dirExists(segDir):
    return @[]
  for kind, path in walkDir(segDir):
    let name = extractFilename(path)
    if kind == pcFile and name.startsWith(SegmentPrefix) and
        name.endsWith(SegmentSuffix):
      result.add(path)
  result.sort(system.cmp[string])

proc readSegment(path: string): seq[EvidenceEntry] =
  let raw = readFile(path)
  var data = newSeq[byte](raw.len)
  if raw.len > 0:
    copyMem(addr data[0], unsafeAddr raw[0], raw.len)
  var pos = 0
  while pos < data.len:
    result.add(decodeEntryAt(data, pos))

proc readEvidenceStore*(dir: string): seq[EvidenceEntry] =
  ## Every entry, in order. LOCAL access only: this is the operator's /
  ## investigator's read path (EVID-3), never exposed over the network.
  for path in listSegments(dir):
    result.add(readSegment(path))

proc insideDir(child, parent: string): bool =
  let c = normalizedPath(absolutePath(child))
  let p = normalizedPath(absolutePath(parent))
  c == p or c.startsWith(p & "/")

proc loadOrCreateSinkSigner(keyDir: string): SecretKey =
  let certPath = keyDir / "sink-checkpoint.crt"
  let keyPath = keyDir / "sink-checkpoint.key"
  if not (fileExists(certPath) and fileExists(keyPath)):
    createDir(keyDir)
    setFilePermissions(keyDir, {fpUserRead, fpUserWrite, fpUserExec})
    var kp = generateKeypair()
    var cert = generateSelfSignedCert(kp, subjectCn = "repro-evidence-sink",
      validityDays = 3650)
    writeCertAndKey(cert, certPath, keyPath)
    secureZeroVar(cert.keypair.privateKey)
    return newSecretKey(kp)
  var ck = loadCertAndKey(certPath, keyPath)
  result = newSecretKey(ck.keypair)

proc sinkCheckpointCertPath*(keyDir: string): string =
  keyDir / "sink-checkpoint.crt"

proc checkpointPublicKeyFromCert*(certPath: string): PublicKeyBytes =
  ## The key `verifyEvidenceStore` checks checkpoints against, from a
  ## certificate the operator pinned OUT OF BAND (a copy taken when the
  ## sink was provisioned) — never from the store directory itself.
  certPublicKey(certPemToDer(readFile(certPath)))

proc appendCheckpoint*(store: EvidenceStore; nowMs = 0'i64) {.gcsafe.}

proc openEvidenceStore*(dir, keyDir: string;
                        retentionSeconds = int64(DefaultRetentionSeconds);
                        segmentMaxEntries = DefaultSegmentMaxEntries):
                        EvidenceStore =
  ## Opens (creating) the store and recovers the chain head from the last
  ## segment. Refuses to open a store whose last segment does not decode —
  ## appending to a damaged chain would bury the damage. `keyDir` holds the
  ## checkpoint key and must not be inside `dir` (threat model G28).
  if keyDir.len == 0 or insideDir(keyDir, dir) or insideDir(dir, keyDir):
    raise newException(EvidenceStoreError,
      "the checkpoint key directory must be separate from the evidence " &
      "store (" & keyDir & " vs " & dir & ")")
  createDir(dir / "segments")
  result = EvidenceStore(dir: dir, keyDir: keyDir,
    signer: loadOrCreateSinkSigner(keyDir),
    segmentMaxEntries: max(1, segmentMaxEntries),
    retentionSeconds: retentionSeconds)
  let segments = listSegments(dir)
  if segments.len > 0:
    let last = segments[^1]
    let entries = readSegment(last)
    result.currentSegment = last
    result.currentSegmentEntries = entries.len
    if entries.len > 0:
      result.nextSeq = entries[^1].seq + 1
      result.headHash = entries[^1].entryHash
    else:
      let name = extractFilename(last)
      result.nextSeq = parseBiggestUInt(name[SegmentPrefix.len ..<
        name.len - SegmentSuffix.len])
    if entries.len > 0 and entries[^1].kind != ekCheckpoint:
      # The sink stopped between appending and signing. Sign the head now
      # (a recovery checkpoint): whatever was acknowledged before was
      # covered by its own receipt, which the appender holds.
      result.appendCheckpoint()

proc appendRaw(store: EvidenceStore; e: var EvidenceEntry) =
  ## Assigns seq/prevHash/hash and appends with O_APPEND semantics.
  e.seq = store.nextSeq
  e.prevHash = store.headHash
  e.entryHash = computeEntryHash(e)
  if store.currentSegment.len == 0 or
      store.currentSegmentEntries >= store.segmentMaxEntries:
    store.currentSegment = store.segmentPath(e.seq)
    store.currentSegmentEntries = 0
  let bytes = encodeEntry(e)
  var f: File
  if not open(f, store.currentSegment, fmAppend):
    raise newException(EvidenceStoreError,
      "cannot open evidence segment " & store.currentSegment)
  try:
    if bytes.len > 0:
      discard f.writeBuffer(unsafeAddr bytes[0], bytes.len)
    f.flushFile()
  finally:
    f.close()
  inc store.currentSegmentEntries
  store.nextSeq = e.seq + 1
  store.headHash = e.entryHash

proc checkpointMessage(seqNo: uint64; head: array[32, byte]): seq[byte] =
  for ch in CheckpointDomain: result.add(byte(ord(ch)))
  result.putU64(seqNo)
  for b in head: result.add(b)

proc appendCheckpointReceipt*(store: EvidenceStore;
                              nowMs = 0'i64): SinkReceipt {.gcsafe.}

proc appendCheckpoint*(store: EvidenceStore; nowMs = 0'i64) {.gcsafe.} =
  ## Signs the current chain head. Called after every appender batch, every
  ## `CheckpointInterval` direct entries, on retention, and on shutdown.
  discard store.appendCheckpointReceipt(nowMs)

proc appendCheckpointReceipt*(store: EvidenceStore;
                              nowMs = 0'i64): SinkReceipt {.gcsafe.} =
  ## `appendCheckpoint`, returning the signed head as a receipt.
  if store.nextSeq == 0:
    return
  let headSeq = store.nextSeq - 1
  let head0 = store.headHash
  var sig: SignatureBytes
  withKeypair(store.signer, kp):
    sig = signMessage(kp, checkpointMessage(headSeq, store.headHash))
  var body: seq[byte] = @[]
  body.putU64(headSeq)
  for b in store.headHash: body.add(b)
  for b in sig: body.add(b)
  var e = EvidenceEntry(receivedAtMs: if nowMs == 0: nowMsE() else: nowMs,
    kind: ekCheckpoint, body: body)
  store.appendRaw(e)
  store.sinceCheckpoint = 0
  result = SinkReceipt(headSeq: headSeq, headHash: head0, signature: sig,
    receivedAtMs: e.receivedAtMs)

proc appendEntry*(store: EvidenceStore; kind: EntryKind; sender: PeerId;
                  role: LeafRole; body: seq[byte]; nowMs = 0'i64): uint64 =
  ## Appends one entry stamped with the SINK's receipt time. Returns its seq.
  var e = EvidenceEntry(receivedAtMs: if nowMs == 0: nowMsE() else: nowMs,
    senderHostId: sender, senderRole: role, kind: kind, body: body)
  store.appendRaw(e)
  result = e.seq
  inc store.sinceCheckpoint
  if store.sinceCheckpoint >= CheckpointInterval:
    store.appendCheckpoint(e.receivedAtMs)

proc appendRecord*(store: EvidenceStore; sender: PeerId; role: LeafRole;
                   record: EvidenceRecord; nowMs = 0'i64): uint64 =
  ## Re-applies the redaction allow-list on ingest (a compromised sender
  ## can send anything) and appends.
  store.appendEntry(ekRecord, sender, role,
    encodeEvidenceRecord(redact(record)), nowMs)

proc enforceRetention*(store: EvidenceStore; nowMs = 0'i64): int =
  ## Deletes closed segments whose newest entry is older than the retention
  ## period, recording each deletion first. Returns segments deleted.
  let at = if nowMs == 0: nowMsE() else: nowMs
  let cutoff = at - store.retentionSeconds * 1000
  for path in listSegments(store.dir):
    if path == store.currentSegment:
      break
    let entries = readSegment(path)
    if entries.len == 0:
      removeFile(path)
      inc result
      continue
    if entries[^1].receivedAtMs >= cutoff:
      break
    var body: seq[byte] = @[]
    body.putU64(entries[0].seq)
    body.putU64(entries[^1].seq)
    for b in entries[^1].entryHash: body.add(b)
    discard store.appendEntry(ekRetention, default(PeerId), lrLegacy, body, at)
    removeFile(path)
    inc result
  if result > 0:
    store.appendCheckpoint(at)

proc verifyReceipt*(receipt: SinkReceipt; checkpointKey: PublicKeyBytes): bool =
  ## Whether `receipt` was signed by the sink's checkpoint key.
  verifySignature(checkpointKey,
    checkpointMessage(receipt.headSeq, receipt.headHash), receipt.signature)

proc verifyEvidenceStore*(dir: string; checkpointKey: PublicKeyBytes;
                          receipts: openArray[SinkReceipt] = [];
                          allowUnanchoredTail = false): VerifyReport =
  ## Walks the whole store: every entry's hash, the chain linkage, and every
  ## checkpoint signature under `checkpointKey`. A chain that starts after a
  ## retention deletion must start at an entry whose `prevHash` a later
  ## retention entry vouches for. Every `receipt` an appender kept must be
  ## signed by `checkpointKey` and name an entry the store still holds with
  ## exactly that hash (or one a retention record covers): a store
  ## truncated or rewritten behind an acknowledged head fails here
  ## (threat model G28). Entries after the last checkpoint fail
  ## verification unless `allowUnanchoredTail` (a live inspection).
  result = VerifyReport(ok: true, firstBadSeq: -1)
  var entries: seq[EvidenceEntry]
  try:
    entries = readEvidenceStore(dir)
  except CatchableError as err:
    return VerifyReport(ok: false, firstBadSeq: -1,
      reason: "store does not decode: " & err.msg)
  var vouched = initHashSet[array[32, byte]]()
  for e in entries:
    if e.kind == ekRetention and e.body.len >= 48:
      var h: array[32, byte]
      for i in 0 ..< 32: h[i] = e.body[16 + i]
      vouched.incl(h)
  var prev: array[32, byte]
  var havePrev = false
  var sinceCheckpoint = 0
  for e in entries:
    if computeEntryHash(e) != e.entryHash:
      return VerifyReport(ok: false, entries: result.entries,
        firstBadSeq: int64(e.seq),
        reason: "entry " & $e.seq & " does not match its hash")
    if havePrev:
      if e.prevHash != prev:
        return VerifyReport(ok: false, entries: result.entries,
          firstBadSeq: int64(e.seq),
          reason: "entry " & $e.seq & " does not chain to its predecessor")
    else:
      var zero: array[32, byte]
      if e.prevHash != zero and e.prevHash notin vouched:
        return VerifyReport(ok: false, entries: 0, firstBadSeq: int64(e.seq),
          reason: "the oldest entry " & $e.seq & " chains to a hash no " &
            "retention record vouches for")
    if e.kind == ekCheckpoint:
      if e.body.len != 8 + 32 + 64:
        return VerifyReport(ok: false, entries: result.entries,
          firstBadSeq: int64(e.seq), reason: "malformed checkpoint")
      var p = 0
      let headSeq = getU64(e.body, p)
      var head: array[32, byte]
      for i in 0 ..< 32: head[i] = e.body[8 + i]
      var sig: SignatureBytes
      for i in 0 ..< 64: sig[i] = e.body[40 + i]
      # The first surviving entry after a retention deletion may itself be a
      # checkpoint: its head is then its (vouched-for) predecessor.
      let expectedHead = if havePrev: prev else: e.prevHash
      if head != expectedHead or headSeq + 1 != e.seq:
        return VerifyReport(ok: false, entries: result.entries,
          firstBadSeq: int64(e.seq),
          reason: "checkpoint " & $e.seq & " does not name the chain head")
      if not verifySignature(checkpointKey,
          checkpointMessage(headSeq, head), sig):
        return VerifyReport(ok: false, entries: result.entries,
          firstBadSeq: int64(e.seq),
          reason: "checkpoint " & $e.seq & " signature does not verify")
      inc result.checkpoints
      sinceCheckpoint = 0
    else:
      inc sinceCheckpoint
    prev = e.entryHash
    havePrev = true
    inc result.entries
  result.unanchoredTail = sinceCheckpoint
  if sinceCheckpoint > 0 and not allowUnanchoredTail:
    return VerifyReport(ok: false, entries: result.entries,
      checkpoints: result.checkpoints, unanchoredTail: sinceCheckpoint,
      firstBadSeq: -1, reason: $sinceCheckpoint & " entries after the last " &
        "signed checkpoint: they could have been rewritten undetected")
  var bySeq = initTable[uint64, array[32, byte]]()
  for e in entries:
    bySeq[e.seq] = e.entryHash
  var retainedThrough = 0'u64
  var anyRetention = false
  for e in entries:
    if e.kind == ekRetention and e.body.len >= 16:
      var p = 8
      let lastDeleted = getU64(e.body, p)
      anyRetention = true
      if lastDeleted > retainedThrough: retainedThrough = lastDeleted
  for r in receipts:
    if not verifyReceipt(r, checkpointKey):
      return VerifyReport(ok: false, entries: result.entries,
        checkpoints: result.checkpoints, firstBadSeq: int64(r.headSeq),
        reason: "receipt for entry " & $r.headSeq & " is not signed by the " &
          "checkpoint key")
    if bySeq.hasKey(r.headSeq):
      if bySeq[r.headSeq] != r.headHash:
        return VerifyReport(ok: false, entries: result.entries,
          checkpoints: result.checkpoints, firstBadSeq: int64(r.headSeq),
          reason: "entry " & $r.headSeq & " was rewritten: its hash is not " &
            "the one the sink acknowledged")
    elif not (anyRetention and r.headSeq <= retainedThrough):
      return VerifyReport(ok: false, entries: result.entries,
        checkpoints: result.checkpoints, firstBadSeq: int64(r.headSeq),
        reason: "the store no longer holds acknowledged entry " &
          $r.headSeq & ": it was truncated")
    inc result.receiptsChecked

type
  ExpectedDetector* = tuple[hostId: PeerId; detector: string]

proc loadExpectedDetectors*(path: string): seq[ExpectedDetector] =
  ## `<64-hex host id> <detector>` per line, `#` comments: the detectors
  ## the operator expects to hear from (threat model G22).
  for raw in readFile(path).splitLines:
    let line = raw.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let parts = line.splitWhitespace()
    if parts.len != 2 or parts[0].len != 64:
      raise newException(ValueError, path & ": expected '<host id> <detector>'")
    var raw32: array[32, byte]
    for i in 0 ..< 32:
      raw32[i] = byte(parseHexInt(parts[0][2 * i .. 2 * i + 1]))
    result.add((peerIdFromBytes(raw32), parts[1]))

proc livenessReport*(dir: string; nowMs: int64;
                     silenceFactor = 3;
                     expected: openArray[ExpectedDetector] = []):
                     seq[DetectorLiveness] =
  ## DET-5: per (host, detector), when it last said it was alive and what it
  ## reported. SILENT once `silenceFactor` heartbeat intervals have passed
  ## without one — distinct from live-idle (heartbeats, no detections).
  ## Every `expected` detector with no heartbeat at all gets a row too,
  ## NEVER-REPORTED: a detector that never came up must be visible, not an
  ## absent row (threat model G22).
  var table = initOrderedTable[string, DetectorLiveness]()
  for e in readEvidenceStore(dir):
    if e.kind != ekRecord:
      continue
    let key = $e.senderHostId & "/" & e.record.detector
    var row = table.getOrDefault(key, DetectorLiveness(
      hostId: e.senderHostId, detector: e.record.detector))
    case e.record.category
    of ecHeartbeat:
      row.lastHeartbeatMs = e.receivedAtMs
      try: row.intervalMs = parseBiggestInt(e.record.field("intervalMs"))
      except ValueError: discard
    of ecDetection:
      inc row.detections
      row.lastDetectionMs = e.receivedAtMs
    of ecAudit:
      discard
    table[key] = row
  var reported = initHashSet[string]()
  for key, row in table.mpairs:
    if row.intervalMs <= 0:
      continue  # never heartbeated: see `expected` below
    let silentAfter = row.intervalMs * int64(silenceFactor)
    row.status =
      if nowMs - row.lastHeartbeatMs > silentAfter: lsSilent
      elif row.detections > 0: lsLiveDetecting
      else: lsLiveIdle
    reported.incl(key)
    result.add(row)
  for (host, detector) in expected:
    let key = $host & "/" & detector
    if key in reported:
      continue
    var row = table.getOrDefault(key, DetectorLiveness(hostId: host,
      detector: detector))
    row.status = lsNeverReported
    result.add(row)

# ---------------------------------------------------------------------------
# Framing over TLS.
# ---------------------------------------------------------------------------

proc recvExact(conn: TlsConn; n: int;
               idle = false): Future[seq[byte]] {.async.} =
  var got = ""
  while got.len < n:
    let chunk = await tls.recv(conn, n - got.len,
      idleTimeoutMs = (if idle and got.len == 0: 0 else: 60_000))
    if chunk.len == 0:
      return @[]
    got.add(chunk)
  result = newSeq[byte](n)
  for i in 0 ..< n: result[i] = byte(ord(got[i]))

proc sendSinkFrame(conn: TlsConn; verb: uint8; body: seq[byte]) {.async.} =
  var frame: seq[byte] = @[]
  frame.putU32(uint32(body.len + 1))
  frame.add(verb)
  frame.add(body)
  await tls.send(conn, frame)

proc readSinkFrame(conn: TlsConn; idle = false):
    Future[tuple[ok: bool; verb: uint8; body: seq[byte]]] {.async.} =
  let header = await recvExact(conn, 4, idle)
  if header.len != 4:
    return (false, 0'u8, @[])
  var p = 0
  let n = int(getU32(header, p))
  if n < 1 or n > MaxFrameBytes:
    return (false, 0'u8, @[])
  let rest = await recvExact(conn, n)
  if rest.len != n:
    return (false, 0'u8, @[])
  return (true, rest[0], rest[1 .. ^1])

proc exchangeProofs(conn: TlsConn; ours: LeafCredential;
                    anchors: TrustAnchorSet; nowSec: int64):
                    Future[VerifiedLeaf] {.async.} =
  ## Both ends send their leaf DER and verify the other's against the key
  ## the TLS handshake authenticated (see `identity.nim`).
  await sendSinkFrame(conn, 0'u8, ours.cert.certDer)
  let theirs = await readSinkFrame(conn)
  if not theirs.ok or theirs.verb != 0'u8:
    return VerifiedLeaf(ok: false, reason: "no identity proof")
  return verifyLeaf(theirs.body, anchors, nowSec,
    expectedPublicKey = remotePublicKey(conn))

# ---------------------------------------------------------------------------
# Sink server.
# ---------------------------------------------------------------------------

proc nowMsS(sink: EvidenceSinkServer): int64 =
  if sink.clock.isNil: nowMsE() else: sink.clock()

proc newEvidenceSinkServer*(store: EvidenceStore; identity: HostIdentity;
                            anchors: TrustAnchorSet; listenAddr: string;
                            listenPort = Port(0); anchorsDir = "";
                            revokedPath = ""): EvidenceSinkServer =
  EvidenceSinkServer(store: store, identity: identity,
    leaf: mintLeaf(identity, lrDaemon), anchors: anchors,
    anchorsDir: anchorsDir, revokedPath: revokedPath,
    listenAddr: listenAddr, listenPort: listenPort,
    buckets: initTable[string, tuple[tokens: float; lastMs: int64]]())

proc bucketKey(host: PeerId; role: LeafRole): string =
  $host & "/" & $role

proc takeTokens(sink: EvidenceSinkServer; key: string; n: int): bool =
  let now = sink.nowMsS()
  var b = sink.buckets.getOrDefault(key, (SinkBurst, now))
  b.tokens = min(SinkBurst,
    b.tokens + float(max(0'i64, now - b.lastMs)) / 1000.0 * SinkRatePerSecond)
  b.lastMs = now
  result = b.tokens >= float(n)
  if result:
    b.tokens -= float(n)
  sink.buckets[key] = b

proc isRevoked(sink: EvidenceSinkServer; host: PeerId): bool =
  ## Re-read on every frame: a revocation takes effect on the revoked
  ## host's next frame, not its next connection (threat model G17). An
  ## unreadable list revokes everyone (fail closed).
  if sink.revokedPath.len == 0 or not fileExists(sink.revokedPath):
    return false
  for raw in (try: readFile(sink.revokedPath) except IOError: "*").splitLines:
    let line = raw.strip()
    if line == "*" or line == $host:
      return true
  false

proc currentAnchors(sink: EvidenceSinkServer): TrustAnchorSet =
  if sink.anchorsDir.len == 0:
    return sink.anchors
  try:
    result = loadTrustAnchorDir(sink.anchorsDir)
    sink.anchors = result
  except CatchableError:
    result = TrustAnchorSet()

proc recordRefusal(sink: EvidenceSinkServer; who: VerifiedLeaf; verb: uint8) =
  ## A refused frame is itself evidence, signed into the chain at once (no
  ## entry is ever left after the last checkpoint).
  discard sink.store.appendEntry(ekRefusedVerb, who.hostId, who.role, @[verb])
  discard sink.store.appendCheckpointReceipt()

proc handleSinkConnection(sink: EvidenceSinkServer;
                          sock: AsyncSocket) {.async.} =
  if sink.leaf.needsRenewal:
    sink.leaf = mintLeaf(sink.identity, lrDaemon)
  let anchors = sink.currentAnchors()
  let connOpt = await wrapServerSocket(sock, sink.leaf.cert.certDer,
    sink.leaf.key, anchors)
  if connOpt.isNone:
    inc sink.rejectedHandshakes
    try: sock.close() except CatchableError: discard
    return
  let conn = connOpt.get()
  try:
    let who = await exchangeProofs(conn, sink.leaf, anchors,
      sink.nowMsS() div 1000)
    if not who.ok:
      inc sink.rejectedHandshakes
      return
    let key = bucketKey(who.hostId, who.role)
    while sink.running:
      let frame = await readSinkFrame(conn, idle = true)
      if not frame.ok:
        break
      # The appender's credential is judged on every frame: a connection
      # does not outlive its leaf (G15), nor a revocation (G17).
      if sink.nowMsS() div 1000 - LeafClockSkewSeconds >= who.notAfter:
        inc sink.expiredConnections
        break
      if sink.isRevoked(who.hostId):
        inc sink.revokedConnections
        sink.recordRefusal(who, frame.verb)
        break
      case frame.verb
      of vAppend, vAppendBatch:
        var bodies: seq[seq[byte]] = @[]
        if frame.verb == vAppend:
          bodies.add(frame.body)
        else:
          var p = 0
          let rawCount = getU32(frame.body, p)
          # Each record is at least its u32 length (repro_core/codec).
          if not elementCountFits(rawCount, frame.body.len - p, 4) or
              int(rawCount) > MaxBatchRecords:
            break
          let count = int(rawCount)
          for _ in 0 ..< count:
            let n = int(getU32(frame.body, p))
            if n > MaxEncodedRecordBytes or p + n > frame.body.len:
              raise newException(EvidenceStoreError, "bad batch")
            bodies.add(frame.body[p ..< p + n])
            p += n
        # Over its budget the sender is SLOWED, not refused (G18): its
        # records wait for tokens and the acknowledgement waits with them,
        # so the appender's own queue absorbs the excess and nothing it
        # sent is lost here. A sender over budget for longer than
        # `SinkBackpressureMaxWaitMs` is disconnected (and that is
        # recorded); it re-sends after reconnecting.
        let waitStart = sink.nowMsS()
        var admitted = sink.takeTokens(key, bodies.len)
        while not admitted and sink.running and
            sink.nowMsS() - waitStart < SinkBackpressureMaxWaitMs:
          inc sink.backpressureWaits
          await sleepAsync(50)
          admitted = sink.takeTokens(key, bodies.len)
        if not admitted:
          sink.recordRefusal(who, frame.verb)
          break
        for body in bodies:
          let record = decodeEvidenceRecord(body)
          discard sink.store.appendRecord(who.hostId, who.role, record)
          inc sink.appendedCount
        # Every accepted batch ends with a signed checkpoint, returned as
        # the receipt (G28).
        let receipt = sink.store.appendCheckpointReceipt()
        var ack: seq[byte] = @[]
        ack.putU64(receipt.headSeq)
        ack.putU64(cast[uint64](receipt.receivedAtMs))
        ack.add(receipt.headHash)
        ack.add(receipt.signature)
        await sendSinkFrame(conn, vAck, ack)
      else:
        # Read / list / delete / anything else: not in the vocabulary.
        inc sink.refusedVerbCount
        sink.recordRefusal(who, frame.verb)
        break
  except CatchableError:
    discard
  finally:
    try: await tls.close(conn) except CatchableError: discard

proc acceptLoop(sink: EvidenceSinkServer) {.async.} =
  while sink.running:
    var client: AsyncSocket
    try:
      client = await sink.listener.accept()
    except CatchableError:
      break
    asyncCheck handleSinkConnection(sink, client)

proc start*(sink: EvidenceSinkServer) =
  sink.listener = newAsyncSocket()
  sink.listener.setSockOpt(OptReuseAddr, true)
  sink.listener.bindAddr(sink.listenPort, sink.listenAddr)
  sink.listenPort = getLocalAddr(sink.listener.getFd(), Domain.AF_INET)[1]
  sink.listener.listen()
  sink.running = true
  sink.lastRetentionMs = nowMsE()
  asyncCheck acceptLoop(sink)

proc tick*(sink: EvidenceSinkServer; retentionCheckIntervalMs = 60_000) =
  ## Housekeeping: automated retention deletion on its interval.
  let now = nowMsE()
  if now - sink.lastRetentionMs >= retentionCheckIntervalMs:
    sink.lastRetentionMs = now
    try: discard sink.store.enforceRetention(now)
    except CatchableError: discard

proc stop*(sink: EvidenceSinkServer) =
  if not sink.running:
    return
  sink.running = false
  try: sink.listener.close() except CatchableError: discard
  try: sink.store.appendCheckpoint()
  except CatchableError: discard

# ---------------------------------------------------------------------------
# Appender (the worker side). Write-only by construction: it can only send
# the two append verbs.
# ---------------------------------------------------------------------------

const
  AppenderUnhealthyAfterMs* = 5_000
    ## A queue that has waited this long without an acknowledgement (or a
    ## sink never reached) makes the appender unhealthy (`healthy`).

type
  EvidenceAppender* = ref object
    endpoint*: Endpoint
    leafProvider*: LeafProvider
    anchors*: TrustAnchorSet
      ## The SINK's own CA only (`<tls dir>/evidence-sink.crt`): the
      ## appender talks to the sink it was provisioned with, not to any
      ## host this node trusts as a peer (threat model G28).
    expectedSink*: PeerId
      ## When set, the sink's verified host id must be exactly this.
    conn: TlsConn
    connLeafNotAfter: int64
    queue: seq[seq[byte]]
    flushing: Future[void]
    maxQueue*: int
    appended*: int
      ## Records acknowledged by the sink.
    dropped*: int
      ## Records discarded: the queue was full (the sink unreachable or over
      ## its budget), or one record could never fit a sink frame. The NEWEST
      ## record is the one dropped, so the earliest evidence of an attack is
      ## kept; the count reaches the sink as an `evidence-dropped` detection
      ## as soon as it accepts appends again, and the node's status file.
    droppedReported: int
    closed: bool
    lastError*: string
    detectors*: seq[tuple[name: string; intervalMs: int; lastMs: int64;
                          probed: bool]]
    pid: int
    lastReceipt*: SinkReceipt
      ## The sink's signed head after the latest acknowledged batch.
    receipts*: int
    lastAckMs*: int64
    firstPendingMs: int64
    everConnected*: bool
    connDownSinceMs: int64
      ## When the connection to the sink last went away (0 while it is up).
      ## `healthy` is false once it has been down for
      ## `AppenderUnhealthyAfterMs`, whether or not anything is queued.
    lastConnectAttemptMs: int64
    receiptPath*: string
      ## When set, every receipt is also written here (atomically), so the
      ## signed head survives this process (`repro-evidence-sink verify
      ## --receipt`).

proc newEvidenceAppender*(endpoint: Endpoint; leafProvider: LeafProvider;
                          anchors: TrustAnchorSet;
                          maxQueue = 100_000;
                          expectedSink = default(PeerId)): EvidenceAppender =
  EvidenceAppender(endpoint: endpoint, leafProvider: leafProvider,
    anchors: anchors, maxQueue: maxQueue, pid: getCurrentProcessId(),
    expectedSink: expectedSink)

proc parseSinkEndpoint*(spec: string): Endpoint =
  let colon = spec.rfind(':')
  if colon <= 0:
    raise newException(ValueError, "evidence sink must be host:port: " & spec)
  initEndpoint(spec[0 ..< colon], Port(parseInt(spec[colon + 1 .. ^1])))

proc encodeReceipt*(r: SinkReceipt): string =
  ## One line: `<seq> <head hex> <signature hex> <received ms>`.
  const H = "0123456789abcdef"
  proc hex(b: openArray[byte]): string =
    for x in b:
      result.add(H[int(x) shr 4]); result.add(H[int(x) and 0xf])
  $r.headSeq & " " & hex(r.headHash) & " " & hex(r.signature) & " " &
    $r.receivedAtMs

proc decodeReceipt*(line: string): SinkReceipt =
  let parts = line.strip().splitWhitespace()
  if parts.len != 4 or parts[1].len != 64 or parts[2].len != 128:
    raise newException(ValueError, "not an evidence receipt: " & line)
  result.headSeq = parseBiggestUInt(parts[0])
  for i in 0 ..< 32:
    result.headHash[i] = byte(parseHexInt(parts[1][2 * i .. 2 * i + 1]))
  for i in 0 ..< 64:
    result.signature[i] = byte(parseHexInt(parts[2][2 * i .. 2 * i + 1]))
  result.receivedAtMs = parseBiggestInt(parts[3])

proc markDown(a: EvidenceAppender) =
  if a.connDownSinceMs == 0:
    a.connDownSinceMs = nowMsE()

proc connect(a: EvidenceAppender): Future[bool] {.async.} =
  a.lastConnectAttemptMs = nowMsE()
  let sock = newAsyncSocket()
  try:
    await sock.connect(a.endpoint.host, a.endpoint.port)
  except CatchableError as err:
    a.lastError = "connect: " & err.msg
    try: sock.close() except CatchableError: discard
    return false
  let leaf = a.leafProvider()
  if leaf.key.isNil or not leaf.key.available:
    a.lastError = "this process holds no usable leaf for the evidence sink"
    try: sock.close() except CatchableError: discard
    return false
  let connOpt = await wrapClientSocket(sock, a.endpoint.host,
    leaf.cert.certDer, leaf.key, a.anchors)
  if connOpt.isNone:
    a.lastError = "TLS handshake with the evidence sink failed"
    try: sock.close() except CatchableError: discard
    return false
  let who = await exchangeProofs(connOpt.get(), leaf, a.anchors,
    getTime().toUnix)
  if not who.ok:
    a.lastError = "evidence sink identity: " & who.reason
    try: await tls.close(connOpt.get()) except CatchableError: discard
    return false
  var zero: PeerId
  if a.expectedSink != zero and who.hostId != a.expectedSink:
    a.lastError = "the evidence sink is host " & $who.hostId &
      ", not the pinned sink " & $a.expectedSink
    try: await tls.close(connOpt.get()) except CatchableError: discard
    return false
  a.conn = connOpt.get()
  a.connLeafNotAfter = leaf.cert.notAfter
  a.everConnected = true
  a.connDownSinceMs = 0
  return true

proc rotateIfExpiring(a: EvidenceAppender) {.async.} =
  ## G15: reconnect before the leaf this connection was opened with
  ## expires (the sink would end the connection at that point anyway).
  if a.conn.isNil or a.connLeafNotAfter == 0:
    return
  if a.connLeafNotAfter - getTime().toUnix > 300:
    return
  let conn = a.conn
  a.conn = nil
  a.markDown()
  try: await tls.close(conn) except CatchableError: discard

proc storeReceipt(a: EvidenceAppender) =
  if a.receiptPath.len == 0:
    return
  try:
    let tmp = a.receiptPath & ".tmp"
    writeFile(tmp, encodeReceipt(a.lastReceipt) & "\n")
    moveFile(tmp, a.receiptPath)
  except CatchableError:
    discard

proc flushOnce(a: EvidenceAppender) {.async.} =
  await a.rotateIfExpiring()
  if a.conn.isNil and a.queue.len == 0 and a.everConnected and
      not a.closed and nowMsE() - a.lastConnectAttemptMs >= 1_000:
    # Idle and disconnected (the sink ended the connection, or it was
    # rotated, with nothing queued): reconnect now rather than at the next
    # record, so `healthy` reflects whether the sink is reachable.
    discard await a.connect()
  while a.queue.len > 0 and not a.closed:
    if a.conn.isNil:
      if not await a.connect():
        return
    # The batch is bounded by BYTES as well as by count: the sink refuses a
    # frame over `MaxFrameBytes` without an acknowledgement, and a head batch
    # it can never accept would be resent forever while every later
    # detection queued behind it. `append` guarantees one record fits.
    var n = 0
    var bytes = 1 + 4
    while n < a.queue.len and n < MaxBatchRecords and
        bytes + 4 + a.queue[n].len <= MaxFrameBytes:
      bytes += 4 + a.queue[n].len
      inc n
    var body: seq[byte] = @[]
    body.putU32(uint32(n))
    for i in 0 ..< n:
      body.putU32(uint32(a.queue[i].len))
      body.add(a.queue[i])
    # Hold this flush's own reference: `close` may clear `a.conn` while the
    # flush is suspended, and the error path below must never close a nil
    # connection (that crashed the process with SIGSEGV).
    let conn = a.conn
    try:
      await sendSinkFrame(conn, vAppendBatch, body)
      let ack = await readSinkFrame(conn)
      if not ack.ok or ack.verb != vAck or ack.body.len != 8 + 8 + 32 + 64:
        raise newException(EvidenceStoreError, "no acknowledgement")
      var p = 0
      var receipt = SinkReceipt(headSeq: getU64(ack.body, p))
      receipt.receivedAtMs = cast[int64](getU64(ack.body, p))
      for i in 0 ..< 32: receipt.headHash[i] = ack.body[p + i]
      p += 32
      for i in 0 ..< 64: receipt.signature[i] = ack.body[p + i]
      a.lastReceipt = receipt
      inc a.receipts
      a.lastAckMs = nowMsE()
      a.storeReceipt()
      a.queue = a.queue[n .. ^1]
      a.appended += n
      a.firstPendingMs = if a.queue.len > 0: nowMsE() else: 0
      if a.dropped > a.droppedReported:
        # The sink is accepting again: tell it how much it never received.
        let lost = a.dropped - a.droppedReported
        a.droppedReported = a.dropped
        var notice = newEvidenceRecord(ecDetection, "evidence-appender",
          "evidence-dropped", [("count", $lost)])
        notice.senderTimeMs = nowMsE()
        notice.senderPid = int32(a.pid)
        a.queue.add(encodeEvidenceRecord(redact(notice)))
    except CatchableError as err:
      a.lastError = "append: " & err.msg
      try: await tls.close(conn) except CatchableError: discard
      if a.conn == conn:
        a.conn = nil
        a.markDown()
      return

proc kick(a: EvidenceAppender) =
  if a.flushing.isNil or a.flushing.finished:
    a.flushing = a.flushOnce()

proc append*(a: EvidenceAppender; record: EvidenceRecord) =
  ## Redacts, encodes and ships at once (DET-6: no local-only buffer an
  ## attacker can truncate before it leaves; the queue exists only for the
  ## seconds a sink is unreachable). Never raises.
  if a.isNil:
    return
  try:
    var r = record
    if r.senderTimeMs == 0: r.senderTimeMs = nowMsE()
    if r.senderPid == 0: r.senderPid = int32(a.pid)
    let encoded = encodeEvidenceRecord(redact(r))
    if encoded.len > MaxEncodedRecordBytes or
        1 + 4 + 4 + encoded.len > MaxFrameBytes:
      # The sink would refuse it on every attempt.
      inc a.dropped
      a.lastError = "record of " & $encoded.len & " bytes exceeds the sink's limit"
    elif a.queue.len >= a.maxQueue:
      # Drop the newest, never shift the queue: a flush in flight holds an
      # index into it, and the oldest records are the earliest evidence.
      inc a.dropped
      a.lastError = "evidence queue full (" & $a.maxQueue & " records)"
    else:
      if a.queue.len == 0: a.firstPendingMs = nowMsE()
      a.queue.add(encoded)
    a.kick()
  except CatchableError as err:
    a.lastError = err.msg

proc drain*(a: EvidenceAppender; timeoutMs = 5_000): bool =
  ## Blocks (driving the dispatcher) until the queue is empty or the
  ## timeout passes. For synchronous shutdown paths and tests.
  if a.isNil:
    return true
  let deadline = nowMsE() + timeoutMs
  while a.queue.len > 0 and nowMsE() < deadline:
    a.kick()
    try: poll(20) except ValueError: sleep(20)
  a.queue.len == 0

proc pending*(a: EvidenceAppender): int =
  ## Records queued but not yet acknowledged by the sink.
  if a.isNil: 0 else: a.queue.len

proc healthy*(a: EvidenceAppender; nowMs = 0'i64): bool =
  ## Whether evidence is leaving this host: the sink has been reached, the
  ## connection to it has not been down for longer than
  ## `AppenderUnhealthyAfterMs` (queue or no queue — an idle appender
  ## without a connection is not shipping anything), and nothing has waited
  ## for an acknowledgement longer than that. The worker role refuses to
  ## execute goals while this is false (fail closed, threat model G28).
  ##
  ## A connection the sink dropped while nothing was being sent is noticed
  ## at the next record — at most one heartbeat interval on a node with
  ## registered detectors (`tickHeartbeats`).
  if a.isNil or a.closed or not a.everConnected:
    return false
  let at = if nowMs == 0: nowMsE() else: nowMs
  if a.conn.isNil and a.connDownSinceMs > 0 and
      at - a.connDownSinceMs > AppenderUnhealthyAfterMs:
    return false
  if a.queue.len > 0 and a.firstPendingMs > 0 and
      at - a.firstPendingMs > AppenderUnhealthyAfterMs:
    return false
  # Disconnected with records waiting: not shipping. Disconnected with
  # nothing waiting: only within the grace above (a reconnect under way).
  not a.conn.isNil or a.queue.len == 0

proc registerDetector*(a: EvidenceAppender; name: string; intervalMs: int;
                       probed = false) =
  ## DET-5: `name` will heartbeat every `intervalMs`. A `probed` detector
  ## does NOT heartbeat on the timer: it heartbeats only when its owner
  ## proved it working (`heartbeat`), so a dead detector goes silent even
  ## while the appender lives (threat model G22).
  if a.isNil:
    return
  for d in a.detectors:
    if d.name == name:
      return
  a.detectors.add((name, max(50, intervalMs), 0'i64, probed))

proc heartbeat*(a: EvidenceAppender; name: string;
                fields: openArray[(string, string)] = []) =
  ## One heartbeat for a `probed` detector, after its self-test passed.
  if a.isNil:
    return
  for d in a.detectors.mitems:
    if d.name == name:
      d.lastMs = nowMsE()
      a.append(newEvidenceRecord(ecHeartbeat, name, "",
        @[("intervalMs", $d.intervalMs)] & @fields))
      return

proc tickHeartbeats*(a: EvidenceAppender; nowMs = 0'i64) =
  if a.isNil:
    return
  let at = if nowMs == 0: nowMsE() else: nowMs
  for d in a.detectors.mitems:
    if d.probed:
      continue
    if at - d.lastMs >= d.intervalMs:
      d.lastMs = at
      a.append(newEvidenceRecord(ecHeartbeat, d.name, "",
        [("intervalMs", $d.intervalMs)], nowMs = at))
  if a.queue.len > 0 or a.conn.isNil:
    a.kick()

proc reporter*(a: EvidenceAppender): DetectionReporter =
  ## A `DetectionReporter` bound to this appender.
  let app = a
  result = proc(record: EvidenceRecord) {.gcsafe, closure.} =
    {.cast(gcsafe).}:
      app.append(record)

proc close*(a: EvidenceAppender) =
  ## Stops the appender: a flush in flight finishes its current round trip
  ## (or fails) and does not reconnect.
  if a.isNil:
    return
  a.closed = true
  if a.conn.isNil:
    return
  let conn = a.conn
  a.conn = nil
  try: waitFor tls.close(conn) except CatchableError: discard

proc sendRawVerbForTesting*(a: EvidenceAppender; verb: uint8;
                            body: seq[byte]): Future[bool] {.async.} =
  ## Test seam for the write-only property: sends an arbitrary verb (a
  ## "read", "list" or "delete" attempt) with the worker's real credential
  ## and reports whether the sink answered anything. The sink's contract is
  ## that it never does.
  if a.conn.isNil:
    if not await a.connect():
      return false
  try:
    await sendSinkFrame(a.conn, verb, body)
    let reply = await readSinkFrame(a.conn)
    result = reply.ok
  except CatchableError:
    result = false
  try: await tls.close(a.conn) except CatchableError: discard
  a.conn = nil
  a.markDown()
