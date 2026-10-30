## Two-phase memoization store — Distributed-Execution M0.
##
## BuildXL separates a cache into a MEMOIZATION store and a CONTENT store
## (`references/buildxl/Public/Src/Cache/README.md`):
##
##   WeakFingerprint -> Selector{PathSet, StrongFingerprint} -> ContentHashList
##   ContentHash     -> bytes
##
## The content half of the peer cache already exists: it is the local CAS,
## served over `mkFetchRequest` / `mkFetchResponse` under the rule
## `BLAKE3-256(payload) == digest`. This module is the memoization half —
## the durable, on-disk record of which executions of which action this node
## can vouch for — plus the two content-addressed blob shapes the
## memoization plane points at (the PathSet blob and the memo entry).
##
## It is deliberately ignorant of the action-cache record format: a memo
## entry carries the producer's encoded `ActionResultRecord` as opaque bytes
## plus the output digests the record references, so this module (and the
## daemon that serves it) can answer selector and entry requests without
## linking `repro_local_store`. `two_phase.nim` is where those bytes are
## produced and interpreted.
##
## Layout under the store root (one directory per weak fingerprint, one file
## per selector — two executions of one action that observed different
## inputs therefore land in two files and can never clobber each other):
##
##   <root>/v1/<weakHex>/<strongHex>.rpme
##
## Every write is temp-file + atomic rename, so a reader in another process
## (the daemon serving peers while a CLI build publishes) sees either the
## previous state or the complete new entry.

import std/[algorithm, options, os, strutils]

import blake3
from repro_core/codec import elementCountFits
import repro_core/evidence_level
import repro_core/evidence_source

export evidence_level
export evidence_source

import ./types

const
  MemoEntryMagic = "RPME"
  MemoEntryVersion* = 4'u16
    ## v2 (Distributed-Execution M7) appends the issuer attestation. A v1
    ## entry still decodes — with an empty attestation, which every
    ## consumer refuses (`memo_attestation.nim`).
    ##
    ## v3 (campaign M17; Edge-Derived-Identities.md §3.4 item 1 and §3.6)
    ## adds one byte after the output digests: the monitor-evidence level of
    ## the execution, which the record frame cannot carry. The attestation
    ## covers it. An entry with no stated level (`elUnstated`) is written in
    ## the v2 layout, byte for byte, so a legacy entry re-encoded by this
    ## build is the entry its issuer signed; v1 and v2 entries decode with
    ## `elUnstated`, which every consumer of this build refuses.
    ##
    ## v4 (campaign M17 chunk 2: the published-trace record, Edge-Derived-
    ## Identities.md §3.1, with the same semantics as the portable memo's
    ## `rbpm-v2`) adds the EVIDENCE SOURCE after the level byte (u16 length,
    ## then its text: `monitored`, `format:<name>`, `builtin`, ...), and goes
    ## with path set v2 (`PathSetVersion`), whose entries keep declared
    ## inputs apart from observed ones, and with identities that carry each
    ## input's entry kind and executable bit and a published-digest-domain
    ## content digest (`two_phase.observedIdentity`). The attestation covers
    ## the source. A v4 entry STATES both level and source. Entries of
    ## versions 1-3 still decode, byte for byte as signed, so a node can say
    ## what it holds -- and every consumer of this build refuses them across
    ## hosts as pre-rbpm-v2 records (`two_phase.memoEntryRefusal`), a miss
    ## with a diagnostic.
  FirstPublishedTraceEntryVersion* = 4'u16
    ## The first entry version a consumer accepts from another host.
  MaxIssuerLeafBytes* = 8 * 1024
  MemoEntryExt = ".rpme"
  MemoStoreLayoutDir = "v1"
  PathSetMagic = "RPPS"
  PathSetVersion* = 2'u16
    ## v2 (campaign M17 chunk 2): entries are tagged with their ROLE as well as
    ## their access (`two_phase.pathSetEntryOf`), and the identities a strong
    ## fingerprint is computed over carry entry kind and executable bit. A v1
    ## path set (a pre-rbpm-v2 producer's) is refused with
    ## `LegacyPeerFormatError`: a miss, not a forgery.
  MemoAdvertDomain = "reprobuild/peer-cache/memo-weak/v1\x00"
    ## Domain prefix for the advertisement key of a weak fingerprint. The
    ## advertisement index is a flat set of 32-byte keys shared with CAS
    ## blob digests; hashing the weak fingerprint under a domain no blob
    ## payload starts with keeps the two populations from colliding.
  MaxPathSetEntries* = 1_000_000
    ## Decoder bound on PathSet entries (a hostile count field must not
    ## become a giant allocation).
  MaxMemoOutputs* = 1_000_000

type
  PeerMemoStoreError* = object of CatchableError
  LegacyPeerFormatError* = object of PeerMemoStoreError
    ## A path set in a format this build no longer reads across hosts (v1,
    ## before the published-trace record): well formed for its writer.

  PeerPathSet* = seq[string]
    ## The PATHS an execution observed, without their content: BuildXL's
    ## PathSet. Entries are the record's input names after workspace
    ## normalization (`$WORKSPACE/...` under portable caching), sorted and
    ## de-duplicated so the same observation always encodes to the same
    ## bytes and therefore the same content digest.

  MemoEntry* = object
    ## One selector's payload: what a peer hands back for
    ## `(weakFingerprint, strongFingerprint)`.
    weakFingerprint*: BlobDigest
    pathSetDigest*: BlobDigest
    strongFingerprint*: BlobDigest
    recordBytes*: seq[byte]
      ## The producer's `ActionResultRecord`, workspace-normalized and
      ## encoded with `repro_local_store.encodeActionResultRecord`.
    outputDigests*: seq[BlobDigest]
      ## CAS digests of every output blob the record references, in record
      ## order. Kept beside the record so the store can advertise them
      ## without decoding it.
    # Distributed-Execution M7 issuer binding (`memo_attestation.nim`): who
    # computed this execution, signed with their short-lived leaf. Carried
    # unchanged when a node re-serves an entry it fetched, so the record of
    # WHO published it survives every hop (and M8 can revoke by issuer).
    issuerHostId*: PeerId
    issuerLeafDer*: seq[byte]
    issuedAtUnix*: int64
    issuerSignature*: seq[byte]
    evidenceLevel*: EvidenceLevel
      ## Campaign M17: the monitor-evidence level the PRODUCER graded this
      ## execution at, signed by the issuer with the rest. Only `elComplete`
      ## is accepted by a consumer; `elUnstated` is what an entry from a
      ## producer older than the field reads as.
    evidenceSource*: EvidenceSource
      ## Campaign M17 chunk 2: where the execution's evidence came from
      ## (Edge-Derived-Identities.md §3.1), signed with the rest. Stated by
      ## every v4 entry; `eskUnstated` for an older entry.
    formatVersion*: uint16
      ## The version the entry was DECODED from (0 for an entry built in
      ## memory and not yet encoded). Not encoded itself: the encoder writes
      ## the layout the stated fields need (`encodeMemoEntry`).

  PeerMemoStore* = object
    root*: string

# ---------------------------------------------------------------------------
# Little-endian helpers (mirrors the codec; kept local so this module has no
# dependency on the frame codec).
# ---------------------------------------------------------------------------

proc putU16(dst: var seq[byte]; v: uint16) =
  dst.add(byte(v and 0xff))
  dst.add(byte((v shr 8) and 0xff))

proc putU32(dst: var seq[byte]; v: uint32) =
  for shift in countup(0, 24, 8):
    dst.add(byte((v shr uint32(shift)) and 0xff'u32))

proc putDigest(dst: var seq[byte]; d: BlobDigest) =
  for b in bytes(d):
    dst.add(b)

proc need(data: openArray[byte]; pos, n: int; what: string) =
  if n < 0 or pos + n > data.len:
    raise newException(PeerMemoStoreError, "truncated " & what)

proc getU16(data: openArray[byte]; pos: var int; what: string): uint16 =
  need(data, pos, 2, what)
  result = uint16(data[pos]) or (uint16(data[pos + 1]) shl 8)
  pos += 2

proc getU32(data: openArray[byte]; pos: var int; what: string): uint32 =
  need(data, pos, 4, what)
  for i in 0 ..< 4:
    result = result or (uint32(data[pos + i]) shl uint32(i * 8))
  pos += 4

proc getDigest(data: openArray[byte]; pos: var int; what: string): BlobDigest =
  need(data, pos, 32, what)
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = data[pos + i]
  pos += 32
  blobDigestFromBytes(raw)

proc checkMagic(data: openArray[byte]; magic: string; what: string) =
  need(data, 0, magic.len, what)
  for i, ch in magic:
    if data[i] != byte(ord(ch)):
      raise newException(PeerMemoStoreError, "bad magic in " & what)

proc digestOf*(payload: openArray[byte]): BlobDigest =
  ## The content-plane identity: plain BLAKE3-256 of the bytes, exactly the
  ## digest `mkFetchResponse` verification recomputes.
  blobDigestFromBytes(blake3.digest(payload))

proc digestFromHex*(hex: string): BlobDigest =
  if hex.len != 64:
    raise newException(PeerMemoStoreError, "digest hex must be 64 chars")
  var raw: array[32, byte]
  for i in 0 ..< 32:
    raw[i] = byte(parseHexInt(hex[2 * i .. 2 * i + 1]))
  blobDigestFromBytes(raw)

# ---------------------------------------------------------------------------
# Advertisement key.
# ---------------------------------------------------------------------------

proc memoAdvertKey*(weakFingerprint: BlobDigest): BlobDigest =
  ## The advertisement-index key announcing "I hold at least one selector
  ## for this weak fingerprint". It rides the same `mkAdvertise` /
  ## `mkAdvertiseV2` cuckoo filter as CAS blob digests, so a requester asks
  ## `findPeersWithBlob(memoAdvertKey(weak))` before sending
  ## `mkGetSelectorsRequest`.
  var payload: seq[byte] = @[]
  for ch in MemoAdvertDomain:
    payload.add(byte(ord(ch)))
  payload.putDigest(weakFingerprint)
  digestOf(payload)

# ---------------------------------------------------------------------------
# PathSet blob.
# ---------------------------------------------------------------------------

proc canonicalPathSet*(paths: openArray[string]): PeerPathSet =
  ## Sorted, de-duplicated copy of `paths` — the only form ever encoded.
  result = @paths
  result.sort(system.cmp[string])
  var i = 1
  while i < result.len:
    if result[i] == result[i - 1]:
      result.delete(i)
    else:
      inc i

proc encodePeerPathSet*(paths: openArray[string]): seq[byte] =
  ## Wire/disk shape:
  ##   "RPPS" u16 version u32 count { u32 len, utf8 bytes }*
  let canon = canonicalPathSet(paths)
  for ch in PathSetMagic:
    result.add(byte(ord(ch)))
  result.putU16(PathSetVersion)
  result.putU32(uint32(canon.len))
  for p in canon:
    result.putU32(uint32(p.len))
    for ch in p:
      result.add(byte(ord(ch)))

proc decodePeerPathSet*(data: openArray[byte]): PeerPathSet =
  checkMagic(data, PathSetMagic, "path set")
  var pos = PathSetMagic.len
  let version = getU16(data, pos, "path set version")
  if version == 1'u16:
    raise newException(LegacyPeerFormatError,
      "a version-1 path set, written before the published-trace record " &
      "(rbpm-v2): its entries do not separate declared from observed inputs")
  if version != PathSetVersion:
    raise newException(PeerMemoStoreError,
      "unsupported path set version " & $version)
  let rawCount = getU32(data, pos, "path set count")
  # Each entry is at least its u32 length.
  if not elementCountFits(rawCount, data.len - pos, 4):
    raise newException(PeerMemoStoreError,
      "path set count exceeds remaining bytes")
  let count = int(rawCount)
  if count > MaxPathSetEntries:
    raise newException(PeerMemoStoreError, "path set too large: " & $count)
  for _ in 0 ..< count:
    let n = int(getU32(data, pos, "path set entry length"))
    need(data, pos, n, "path set entry")
    var s = newString(n)
    for i in 0 ..< n:
      s[i] = char(data[pos + i])
    pos += n
    result.add(s)
  if pos != data.len:
    raise newException(PeerMemoStoreError, "trailing bytes after path set")
  if result != canonicalPathSet(result):
    # A non-canonical encoding would give the same observation two digests.
    raise newException(PeerMemoStoreError, "path set is not canonical")

# ---------------------------------------------------------------------------
# Two-phase strong fingerprint.
# ---------------------------------------------------------------------------

proc twoPhaseStrongFingerprint*(weakFingerprint, pathSetDigest: BlobDigest;
                                identities: openArray[string]): BlobDigest =
  ## `StrongFingerprint = H(WeakFingerprint || PathSetDigest ||
  ## ObservedInputDigests)`, Distributed-Execution M0 Catch #1.
  ##
  ## `identities[i]` is the observed identity of the i-th entry of the
  ## canonical PathSet — a content digest, or the marker for what stands
  ## there instead (absent / directory membership). Every field is length
  ## framed so no boundary can be forged by content. Both sides compute this
  ## from THEIR OWN filesystem: the producer at publish time, the consumer
  ## at lookup time; equality means every observed input has the same
  ## content at the same (workspace-relative) place.
  var payload: seq[byte] = @[]
  for ch in "RPSF":
    payload.add(byte(ord(ch)))
  payload.putDigest(weakFingerprint)
  payload.putDigest(pathSetDigest)
  payload.putU32(uint32(identities.len))
  for id in identities:
    payload.putU32(uint32(id.len))
    for ch in id:
      payload.add(byte(ord(ch)))
  digestOf(payload)

# ---------------------------------------------------------------------------
# Memo entry codec.
# ---------------------------------------------------------------------------

proc encodeMemoEntry*(entry: MemoEntry): seq[byte] =
  ## "RPME" u16 version weak[32] pathSet[32] strong[32]
  ## u32 recordLen record u32 outputCount {digest[32]}*
  ## [v3+: u8 evidenceLevel] [v4: u16 sourceLen source]
  ## u32 leafLen leaf i64 issuedAt issuer[32] u32 sigLen sig
  ##
  ## The layout is the one the STATED fields need, so an entry decoded from
  ## an older version re-encodes byte for byte as its issuer signed it: a
  ## stated source writes v4 (and needs a stated level); a stated level alone
  ## writes v3; neither writes v2.
  let stated = entry.evidenceLevel != elUnstated
  let sourced = entry.evidenceSource.kind != eskUnstated
  if sourced and not stated:
    raise newException(PeerMemoStoreError,
      "a memo entry that states its evidence source must state its level")
  for ch in MemoEntryMagic:
    result.add(byte(ord(ch)))
  result.putU16(if sourced: MemoEntryVersion elif stated: 3'u16 else: 2'u16)
  result.putDigest(entry.weakFingerprint)
  result.putDigest(entry.pathSetDigest)
  result.putDigest(entry.strongFingerprint)
  result.putU32(uint32(entry.recordBytes.len))
  for b in entry.recordBytes:
    result.add(b)
  result.putU32(uint32(entry.outputDigests.len))
  for d in entry.outputDigests:
    result.putDigest(d)
  if stated:
    result.add(evidenceLevelByte(entry.evidenceLevel))
  if sourced:
    let text = $entry.evidenceSource
    result.putU16(uint16(text.len))
    for ch in text:
      result.add(byte(ord(ch)))
  result.putU32(uint32(entry.issuerLeafDer.len))
  for b in entry.issuerLeafDer:
    result.add(b)
  for shift in countup(0, 56, 8):
    result.add(byte((cast[uint64](entry.issuedAtUnix) shr uint64(shift)) and
      0xff'u64))
  for b in bytes(entry.issuerHostId):
    result.add(b)
  result.putU32(uint32(entry.issuerSignature.len))
  for b in entry.issuerSignature:
    result.add(b)

proc memoEntryIsNewerFormat*(data: openArray[byte]):
    tuple[newer: bool; version: uint16] =
  ## Distributed-Execution M1: a memo entry with the right magic whose
  ## version is above `MemoEntryVersion` — what a NEWER node writes, well
  ## formed for its writer and unreadable here (a mixed-version fleet), as
  ## opposed to malformed or forged bytes. A consumer treats it as a plain
  ## miss without suspecting the peer that served it.
  if data.len < MemoEntryMagic.len + 2:
    return (false, 0'u16)
  for i, ch in MemoEntryMagic:
    if data[i] != byte(ord(ch)):
      return (false, 0'u16)
  let version = uint16(data[4]) or (uint16(data[5]) shl 8)
  (version > MemoEntryVersion, version)

proc decodeMemoEntryHeader(data: openArray[byte]):
    tuple[weak, pathSet, strong: BlobDigest; pos: int; version: uint16] =
  checkMagic(data, MemoEntryMagic, "memo entry")
  var pos = MemoEntryMagic.len
  let version = getU16(data, pos, "memo entry version")
  if version notin [1'u16, 2'u16, 3'u16, MemoEntryVersion]:
    raise newException(PeerMemoStoreError,
      "unsupported memo entry version " & $version)
  result.version = version
  result.weak = getDigest(data, pos, "memo entry weak fingerprint")
  result.pathSet = getDigest(data, pos, "memo entry path set digest")
  result.strong = getDigest(data, pos, "memo entry strong fingerprint")
  result.pos = pos

proc decodeMemoEntry*(data: openArray[byte]): MemoEntry =
  let header = decodeMemoEntryHeader(data)
  var pos = header.pos
  result.weakFingerprint = header.weak
  result.pathSetDigest = header.pathSet
  result.strongFingerprint = header.strong
  result.formatVersion = header.version
  let recordLen = int(getU32(data, pos, "memo entry record length"))
  need(data, pos, recordLen, "memo entry record")
  result.recordBytes = newSeq[byte](recordLen)
  for i in 0 ..< recordLen:
    result.recordBytes[i] = data[pos + i]
  pos += recordLen
  let rawOutputs = getU32(data, pos, "memo entry output count")
  if not elementCountFits(rawOutputs, data.len - pos, 32):
    raise newException(PeerMemoStoreError,
      "memo entry output count exceeds remaining bytes")
  let outputs = int(rawOutputs)
  if outputs > MaxMemoOutputs:
    raise newException(PeerMemoStoreError, "too many outputs: " & $outputs)
  need(data, pos, outputs * 32, "memo entry output digests")
  for _ in 0 ..< outputs:
    result.outputDigests.add(getDigest(data, pos, "memo entry output digest"))
  if header.version >= 3'u16:
    need(data, pos, 1, "memo entry evidence level")
    # A v3 entry STATES a level; the unstated byte is a v2 entry's to have.
    if not evidenceLevelFromByte(data[pos], result.evidenceLevel) or
        result.evidenceLevel == elUnstated:
      raise newException(PeerMemoStoreError,
        "memo entry carries an unknown evidence level " & $data[pos])
    pos += 1
  if header.version >= 4'u16:
    let sourceLen = int(getU16(data, pos, "memo entry evidence source length"))
    need(data, pos, sourceLen, "memo entry evidence source")
    var text = newString(sourceLen)
    for i in 0 ..< sourceLen:
      text[i] = char(data[pos + i])
    pos += sourceLen
    # A v4 entry STATES its source, as a v3 one states its level.
    if not parseEvidenceSource(text, result.evidenceSource) or
        result.evidenceSource.kind == eskUnstated:
      raise newException(PeerMemoStoreError,
        "memo entry carries an unknown evidence source '" & text & "'")
  if header.version >= 2'u16:
    let leafLen = int(getU32(data, pos, "memo entry issuer leaf length"))
    if leafLen > MaxIssuerLeafBytes:
      raise newException(PeerMemoStoreError, "issuer leaf too large")
    need(data, pos, leafLen, "memo entry issuer leaf")
    result.issuerLeafDer = newSeq[byte](leafLen)
    for i in 0 ..< leafLen:
      result.issuerLeafDer[i] = data[pos + i]
    pos += leafLen
    need(data, pos, 8, "memo entry issuance time")
    var t = 0'u64
    for i in 0 ..< 8:
      t = t or (uint64(data[pos + i]) shl uint64(8 * i))
    pos += 8
    result.issuedAtUnix = cast[int64](t)
    var raw: array[32, byte]
    need(data, pos, 32, "memo entry issuer")
    for i in 0 ..< 32:
      raw[i] = data[pos + i]
    pos += 32
    result.issuerHostId = peerIdFromBytes(raw)
    let sigLen = int(getU32(data, pos, "memo entry signature length"))
    if sigLen > 128:
      raise newException(PeerMemoStoreError, "issuer signature too large")
    need(data, pos, sigLen, "memo entry signature")
    result.issuerSignature = newSeq[byte](sigLen)
    for i in 0 ..< sigLen:
      result.issuerSignature[i] = data[pos + i]
    pos += sigLen
  if pos != data.len:
    raise newException(PeerMemoStoreError, "trailing bytes after memo entry")

proc selectorOf*(entry: MemoEntry): MemoSelector =
  MemoSelector(pathSetDigest: entry.pathSetDigest,
               strongFingerprint: entry.strongFingerprint)

# ---------------------------------------------------------------------------
# On-disk store.
# ---------------------------------------------------------------------------

proc openPeerMemoStore*(root: string): PeerMemoStore =
  ## Opens (lazily creating on first write) the memo store rooted at `root`.
  PeerMemoStore(root: root)

proc weakDir(store: PeerMemoStore; weak: BlobDigest): string =
  store.root / MemoStoreLayoutDir / $weak

proc entryPath(store: PeerMemoStore; weak, strong: BlobDigest): string =
  store.weakDir(weak) / ($strong & MemoEntryExt)

proc readBytesFile(path: string): seq[byte] =
  let raw = readFile(path)
  result = newSeq[byte](raw.len)
  if raw.len > 0:
    copyMem(addr result[0], unsafeAddr raw[0], raw.len)

proc writeMemoEntry*(store: PeerMemoStore; entry: MemoEntry;
                     replace = false): bool {.discardable.} =
  ## Persists `entry` under its own `(weak, strong)` file. Returns `true`
  ## when the file was newly created, `false` when an entry for the same
  ## selector already existed (it is left untouched: a strong fingerprint
  ## names one execution's observed inputs, so a second writer for the same
  ## selector describes the same computation and BuildXL's cache-convergence
  ## rule says the first published result stands). `replace` overwrites it
  ## — only for the issuer refreshing its own attestation of the same
  ## record (Distributed-Execution M7, threat model G15).
  let path = store.entryPath(entry.weakFingerprint, entry.strongFingerprint)
  if fileExists(path) and not replace:
    return false
  createDir(path.parentDir)
  let bytes = encodeMemoEntry(entry)
  let tmp = path & ".tmp." & $getCurrentProcessId()
  var text = newString(bytes.len)
  if bytes.len > 0:
    copyMem(addr text[0], unsafeAddr bytes[0], bytes.len)
  writeFile(tmp, text)
  try:
    moveFile(tmp, path)
  except OSError:
    try: removeFile(tmp) except OSError: discard
    raise
  true

proc readMemoEntryBytes*(store: PeerMemoStore;
                         weak, strong: BlobDigest): Option[seq[byte]] =
  ## The encoded entry for one selector, or `none`. Never raises: a missing
  ## or unreadable file is a miss.
  let path = store.entryPath(weak, strong)
  try:
    if not fileExists(path):
      return none(seq[byte])
    let bytes = readBytesFile(path)
    let header = decodeMemoEntryHeader(bytes)
    if header.weak != weak or header.strong != strong:
      # A file whose content disagrees with its name is not served.
      return none(seq[byte])
    some(bytes)
  except CatchableError:
    none(seq[byte])

proc readMemoEntry*(store: PeerMemoStore;
                    weak, strong: BlobDigest): Option[MemoEntry] =
  let raw = store.readMemoEntryBytes(weak, strong)
  if raw.isNone:
    return none(MemoEntry)
  try:
    some(decodeMemoEntry(raw.get()))
  except CatchableError:
    none(MemoEntry)

proc listSelectors*(store: PeerMemoStore; weak: BlobDigest): seq[MemoSelector] =
  ## Every selector stored for `weak`, ordered by strong fingerprint so the
  ## answer is deterministic. Never raises.
  let dir = store.weakDir(weak)
  try:
    if not dirExists(dir):
      return @[]
    var names: seq[string] = @[]
    for kind, path in walkDir(dir):
      if kind == pcFile and path.endsWith(MemoEntryExt):
        names.add(path)
    names.sort(system.cmp[string])
    for path in names:
      try:
        let header = decodeMemoEntryHeader(readBytesFile(path))
        if header.weak == weak and
            extractFilename(path) == $header.strong & MemoEntryExt:
          result.add(MemoSelector(pathSetDigest: header.pathSet,
                                  strongFingerprint: header.strong))
      except CatchableError:
        discard
  except CatchableError:
    discard

proc weakFingerprints*(store: PeerMemoStore): seq[BlobDigest] =
  ## Every weak fingerprint with at least one entry. Never raises.
  let base = store.root / MemoStoreLayoutDir
  try:
    if not dirExists(base):
      return @[]
    for kind, path in walkDir(base):
      if kind != pcDir:
        continue
      let name = extractFilename(path)
      if name.len != 64:
        continue
      try:
        let weak = digestFromHex(name)
        if store.listSelectors(weak).len > 0:
          result.add(weak)
      except CatchableError:
        discard
  except CatchableError:
    discard

proc advertisedKeys*(store: PeerMemoStore): seq[BlobDigest] =
  ## The advertisement set this store backs: one `memoAdvertKey` per weak
  ## fingerprint, plus every PathSet digest and output digest its entries
  ## reference (all of which live in the companion CAS and are servable
  ## over the content plane). Never raises.
  let base = store.root / MemoStoreLayoutDir
  try:
    if not dirExists(base):
      return @[]
    for kind, dir in walkDir(base):
      if kind != pcDir:
        continue
      var weakAdvertised = false
      for k2, path in walkDir(dir):
        if k2 != pcFile or not path.endsWith(MemoEntryExt):
          continue
        try:
          let entry = decodeMemoEntry(readBytesFile(path))
          if not weakAdvertised:
            result.add(memoAdvertKey(entry.weakFingerprint))
            weakAdvertised = true
          result.add(entry.pathSetDigest)
          for d in entry.outputDigests:
            result.add(d)
        except CatchableError:
          discard
  except CatchableError:
    discard
