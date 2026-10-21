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

import ./types

const
  MemoEntryMagic = "RPME"
  MemoEntryVersion = 1'u16
  MemoEntryExt = ".rpme"
  MemoStoreLayoutDir = "v1"
  PathSetMagic = "RPPS"
  PathSetVersion = 1'u16
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
  for ch in MemoEntryMagic:
    result.add(byte(ord(ch)))
  result.putU16(MemoEntryVersion)
  result.putDigest(entry.weakFingerprint)
  result.putDigest(entry.pathSetDigest)
  result.putDigest(entry.strongFingerprint)
  result.putU32(uint32(entry.recordBytes.len))
  for b in entry.recordBytes:
    result.add(b)
  result.putU32(uint32(entry.outputDigests.len))
  for d in entry.outputDigests:
    result.putDigest(d)

proc decodeMemoEntryHeader(data: openArray[byte]):
    tuple[weak, pathSet, strong: BlobDigest; pos: int] =
  checkMagic(data, MemoEntryMagic, "memo entry")
  var pos = MemoEntryMagic.len
  let version = getU16(data, pos, "memo entry version")
  if version != MemoEntryVersion:
    raise newException(PeerMemoStoreError,
      "unsupported memo entry version " & $version)
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

proc writeMemoEntry*(store: PeerMemoStore; entry: MemoEntry): bool
    {.discardable.} =
  ## Persists `entry` under its own `(weak, strong)` file. Returns `true`
  ## when the file was newly created, `false` when an entry for the same
  ## selector already existed (it is left untouched: a strong fingerprint
  ## names one execution's observed inputs, so a second writer for the same
  ## selector describes the same computation and BuildXL's cache-convergence
  ## rule says the first published result stands).
  let path = store.entryPath(entry.weakFingerprint, entry.strongFingerprint)
  if fileExists(path):
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
