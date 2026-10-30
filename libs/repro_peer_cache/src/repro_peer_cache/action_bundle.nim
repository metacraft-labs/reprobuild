## Action-cache bundle codec — Peer-Cache M1.
##
## When the engine consults the peer cache for an action-cache miss, the
## reply has to carry BOTH the metadata record (inputs, outputs,
## fingerprints) AND the raw output blob bytes — otherwise the next
## action-cache lookup will hit `aclMissNoOutputPayload` because the
## CAS has the record but not the blobs it points at. This module
## wraps `ActionResultRecord` + the matching CAS blob payloads in a
## single self-describing byte string so the
## `PeerCacheActionCacheReader` blob-digest interface can carry the
## whole thing as one payload.
##
## Wire shape (little-endian, no padding):
##
##   magic       4 bytes  ASCII "RPAB" (Reprobuild Peer Action Bundle)
##   version     u16      currently 1
##   recordLen   u32      number of bytes in `recordBytes`
##   recordBytes recordLen bytes — output of `encodeActionResultRecord`
##   blobCount   u32      number of blob payloads (must match
##                        record.outputs.len when outputPayloadKind ==
##                        opkCasBlobs; zero otherwise)
##   for each blob (in record.outputs order):
##     blobLen   u32      payload size in bytes (must match
##                        record.outputs[i].blob.sizeBytes)
##     blobBytes blobLen bytes — raw CAS payload, digest validated by
##                        the reader on decode

import std/tables

from repro_core/codec import elementCountFits
import repro_hash
import repro_local_store
import repro_cas_store

import ./memo_store
import ./two_phase
import ./types

type
  ActionBundle* = object
    ## Serialisable bundle of an `ActionResultRecord` + every CAS blob
    ## it references. Materialised on the producer side from the local
    ## store; carried over the peer-cache wire as a single
    ## `BlobDigest`-keyed payload; decoded on the consumer side back
    ## into a record + the byte payloads that need to be `storeBlob`'d
    ## before the next `lookupActionResult` call.
    record*: ActionResultRecord
    blobs*: seq[seq[byte]]
      ## Order matches `record.outputs`. Empty when
      ## `record.outputPayloadKind == opkMetadataOnly`.

const
  ActionBundleMagic = "RPAB"
  ActionBundleVersion = 1'u16

proc writeU16Le(dst: var seq[byte]; value: uint16) =
  dst.add(byte(value and 0xff))
  dst.add(byte((value shr 8) and 0xff))

proc writeU32Le(dst: var seq[byte]; value: uint32) =
  dst.add(byte(value and 0xff))
  dst.add(byte((value shr 8) and 0xff))
  dst.add(byte((value shr 16) and 0xff))
  dst.add(byte((value shr 24) and 0xff))

proc readU16Le(src: openArray[byte]; pos: var int): uint16 =
  if pos + 2 > src.len:
    raise newException(ValueError, "truncated u16 in action bundle")
  result = uint16(src[pos]) or (uint16(src[pos + 1]) shl 8)
  pos += 2

proc readU32Le(src: openArray[byte]; pos: var int): uint32 =
  if pos + 4 > src.len:
    raise newException(ValueError, "truncated u32 in action bundle")
  result = uint32(src[pos]) or (uint32(src[pos + 1]) shl 8) or
           (uint32(src[pos + 2]) shl 16) or (uint32(src[pos + 3]) shl 24)
  pos += 4

proc encodeActionBundle*(bundle: ActionBundle): seq[byte] =
  ## Serialises `bundle` to the wire shape described above. The blob
  ## payloads are expected to round-trip byte-for-byte; the consumer
  ## verifies each payload's CAS digest against the record's blob ref
  ## on decode.
  result = @[]
  for ch in ActionBundleMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(ActionBundleVersion)
  let recordBytes = encodeActionResultRecord(bundle.record)
  result.writeU32Le(uint32(recordBytes.len))
  for b in recordBytes:
    result.add(b)
  result.writeU32Le(uint32(bundle.blobs.len))
  for payload in bundle.blobs:
    result.writeU32Le(uint32(payload.len))
    for b in payload:
      result.add(b)

proc decodeActionBundle*(payload: openArray[byte]): ActionBundle =
  ## Inverse of `encodeActionBundle`. Raises `ValueError` on truncated
  ## or magic/version mismatches; the caller (peer-cache reader bridge)
  ## treats those the same as a peer-cache miss and falls through to a
  ## rebuild.
  if payload.len < 6:
    raise newException(ValueError, "truncated action bundle")
  for i in 0 ..< 4:
    if payload[i] != byte(ord(ActionBundleMagic[i])):
      raise newException(ValueError, "unknown action bundle magic")
  var pos = 4
  let version = readU16Le(payload, pos)
  if version != ActionBundleVersion:
    raise newException(ValueError,
      "unsupported action bundle version: " & $version)
  let recordLen = int(readU32Le(payload, pos))
  if pos + recordLen > payload.len:
    raise newException(ValueError, "truncated action bundle record")
  var recordBytes = newSeq[byte](recordLen)
  for i in 0 ..< recordLen:
    recordBytes[i] = payload[pos + i]
  pos += recordLen
  result.record = decodeActionResultRecord(recordBytes)
  let blobCountRaw = readU32Le(payload, pos)
  # Every blob is at least its u32 length prefix; refuse a count the
  # remaining bytes cannot hold before it sizes the blob list.
  if not elementCountFits(blobCountRaw, payload.len - pos, 4):
    raise newException(ValueError,
      "action bundle element count exceeds remaining bytes")
  let blobCount = int(blobCountRaw)
  result.blobs = newSeq[seq[byte]](blobCount)
  for i in 0 ..< blobCount:
    let blobLen = int(readU32Le(payload, pos))
    if pos + blobLen > payload.len:
      raise newException(ValueError, "truncated action bundle blob")
    var blob = newSeq[byte](blobLen)
    for j in 0 ..< blobLen:
      blob[j] = payload[pos + j]
    pos += blobLen
    result.blobs[i] = blob
  if pos != payload.len:
    raise newException(ValueError, "trailing bytes in action bundle")

# ---------------------------------------------------------------------------
# Bridging helpers: turn a `ContentDigest` (the engine's
# `action.weakFingerprint`) into a `BlobDigest` that the peer-cache wire
# can carry, and vice versa. The peer-cache identity is BLAKE3-256 by
# spec; the engine's weak fingerprint is also a 32-byte digest, so the
# mapping is a straight byte copy. The result is NOT the BLAKE3 of the
# bundle bytes — it's a stable lookup key derived from the action's
# weak fingerprint that producer and consumer can both compute without
# materialising the bundle first.
# ---------------------------------------------------------------------------

proc actionBundleKey*(weakFingerprint: ContentDigest): BlobDigest =
  ## Derives the peer-cache WeakFingerprint key from the engine's local
  ## `weakFingerprint` (a straight byte copy; both are 32-byte digests).
  ##
  ## Distributed-Execution M0: this key is used ONLY on the memoization
  ## plane (`mkGetSelectorsRequest` and the memo store). It is NOT a content
  ## digest of anything, so it must never be handed to `requestFetch` /
  ## `mkFetchRequest`: the content plane rejects any payload whose BLAKE3
  ## differs from the requested digest and marks the serving peer suspect,
  ## which is exactly what happened when bundles were fetched under this key.
  blobDigestFromBytes(weakFingerprint.bytes)

proc contentHashForBundleBlob(blob: CasBlobRef): ContentHash =
  toContentHash(blob.digest.bytes)

proc materializeActionBundle*(cas: LocalCas;
                              record: ActionResultRecord): ActionBundle =
  ## Reads every output blob payload referenced by `record` from the
  ## local CAS into memory and returns the bundle ready for encoding.
  ## Used by the publisher path on the producer side.
  result.record = record
  result.blobs = @[]
  if record.outputPayloadKind != opkCasBlobs:
    return
  for output in record.outputs:
    result.blobs.add(cas.readBlob(output.blob))

proc materializeActionBundle*(cas: CasStore;
                              record: ActionResultRecord): ActionBundle =
  ## R11 CAS-backed variant used by the build engine after M9.R.82. The
  ## ActionResultRecord shape is unchanged: its CasBlobRef digest bytes are the
  ## raw BLAKE3 key used by repro_cas_store.
  result.record = record
  result.blobs = @[]
  if record.outputPayloadKind != opkCasBlobs:
    return
  for output in record.outputs:
    let payload = cas.casGet(contentHashForBundleBlob(output.blob))
    if uint64(payload.len) != output.blob.sizeBytes:
      raise newException(CacheIntegrityError,
        "CAS size mismatch for " & digestHex(output.blob.digest))
    result.blobs.add(payload)

proc installActionBundle*(cas: LocalCas; cache: var ActionCache;
                          bundle: ActionBundle):
                          tuple[ok: bool; reason: string] {.gcsafe.} =
  ## Verifies the decoded `bundle`'s output blob digests against the
  ## record's references, writes each blob into the local CAS, then
  ## appends the record to the local action cache. Returns `(true, "")`
  ## on success; on a verification failure returns `(false, <reason>)`
  ## and leaves the local store untouched (we abort before writing the
  ## record so the next `lookupActionResult` still misses cleanly).
  if bundle.record.outputPayloadKind == opkCasBlobs:
    if bundle.blobs.len != bundle.record.outputs.len:
      return (false,
        "bundle blob count " & $bundle.blobs.len &
        " does not match record outputs " & $bundle.record.outputs.len)
    for i, payload in bundle.blobs:
      let stored = cas.storeBlob(payload)
      if stored.digest != bundle.record.outputs[i].blob.digest:
        return (false,
          "bundle blob digest mismatch for output " &
          bundle.record.outputs[i].path)
      if stored.sizeBytes != bundle.record.outputs[i].blob.sizeBytes:
        return (false,
          "bundle blob size mismatch for output " &
          bundle.record.outputs[i].path)
  cache.appendActionResultRecord(bundle.record)
  (true, "")

proc installActionBundle*(cas: var CasStore; cache: var ActionCache;
                          bundle: ActionBundle):
                          tuple[ok: bool; reason: string] {.gcsafe.} =
  ## R11 CAS-backed install path. Writes decoded bundle payloads into the same
  ## ``cas/blake3`` layout that action-cache lookup verification and restore
  ## use, then appends the record only after every payload has matched.
  if bundle.record.outputPayloadKind == opkCasBlobs:
    if bundle.blobs.len != bundle.record.outputs.len:
      return (false,
        "bundle blob count " & $bundle.blobs.len &
        " does not match record outputs " & $bundle.record.outputs.len)
    for i, payload in bundle.blobs:
      let stored = cas.casPut(payload)
      if stored != contentHashForBundleBlob(bundle.record.outputs[i].blob):
        return (false,
          "bundle blob digest mismatch for output " &
          bundle.record.outputs[i].path)
      if uint64(payload.len) != bundle.record.outputs[i].blob.sizeBytes:
        return (false,
          "bundle blob size mismatch for output " &
          bundle.record.outputs[i].path)
  cache.appendActionResultRecord(bundle.record)
  (true, "")

# ---------------------------------------------------------------------------
# Distributed-Execution M0: install a two-phase lookup result.
# ---------------------------------------------------------------------------

proc installTwoPhaseBundle*(cas: var CasStore; cache: var ActionCache;
                            bundle: TwoPhaseBundle;
                            localWeak: ContentDigest;
                            policy: FileFingerprintPolicy;
                            ctx: TwoPhaseContext):
                            tuple[ok: bool; reason: string] {.gcsafe.} =
  ## Installs the result of `two_phase.fetchTwoPhase` into the local CAS and
  ## action cache so the engine's retry `lookupActionResult` hits.
  ##
  ## The peer's record is the PRODUCER's: its paths may be `$WORKSPACE`
  ## markers, its input fingerprints carry the producer's metadata, and its
  ## weak/strong fingerprints are the producer's LOCAL ones. None of that can
  ## be appended as-is. What the lookup established is that every input the
  ## execution observed has the same content here, so the record is re-keyed
  ## for this host:
  ##
  ##   1. paths rebased onto this workspace root;
  ##   2. every input re-observed HERE under the consumer action's own
  ##      policy, and its identity checked once more against what the lookup
  ##      computed (an input edited between lookup and install fails the
  ##      install instead of pairing old outputs with new content);
  ##   3. weak fingerprint replaced by the consumer action's, strong
  ##      fingerprint recomputed from the re-observed inputs.
  ##
  ## Output blobs are verified against the record's digests and sizes as
  ## they are written. Nothing is appended unless every step succeeds, so a
  ## failed install leaves the next lookup missing cleanly.
  var entry: MemoEntry
  var normalized: ActionResultRecord
  var decodingRecord = false
  try:
    entry = decodeMemoEntry(bundle.entryBytes)
    decodingRecord = true
    normalized = decodeActionResultRecord(entry.recordBytes)
  except CatchableError as err:
    let newer =
      if decodingRecord: actionRecordIsNewerFormat(entry.recordBytes)
      else: memoEntryIsNewerFormat(bundle.entryBytes)
    if newer.newer:
      return (false, "the " & (if decodingRecord: "record" else: "memo entry") &
        " is in a newer format (version " & $newer.version &
        ") than this build reads")
    return (false, "malformed memo entry: " & err.msg)
  # Campaign M17 (Edge-Derived-Identities.md §3.6 rider of 2026-10-27): a
  # record from another host that may not cross hosts -- made under
  # `ffpTimestamp`, not graded Level 0 by its producer (or not graded at
  # all, as an older producer's entry is), or naming no observed input -- is
  # refused before anything is written, whoever sent it and whatever the
  # lookup that handed it here decided. The reason names the policy or the
  # level.
  # Campaign M17 chunk 2: an entry from before the published-trace record
  # (versions 1-3) is refused here too, naming its version, and the rule
  # judges the evidence source its issuer signed as well as the level.
  let ruleRefusal = memoEntryRefusal(entry, normalized)
  if ruleRefusal.len > 0:
    return (false, "refused a record from another host: " & ruleRefusal)
  let pathSet = pathSetOf(normalized, ctx)
  if digestOf(bundle.pathSetBytes) != entry.pathSetDigest:
    return (false, "path set blob does not match the entry's digest")
  try:
    if decodePeerPathSet(bundle.pathSetBytes) != pathSet:
      return (false, "path set blob disagrees with the entry's record")
  except CatchableError as err:
    return (false, "malformed path set blob: " & err.msg)
  if bundle.identities.len != pathSet.len:
    return (false, "identity count " & $bundle.identities.len &
      " does not match path set size " & $pathSet.len)
  if normalized.outputPayloadKind != opkCasBlobs or
      bundle.blobs.len != normalized.outputs.len:
    return (false, "bundle blob count " & $bundle.blobs.len &
      " does not match record outputs " & $normalized.outputs.len)
  var record: ActionResultRecord
  try:
    record = rebaseRecord(normalized, ctx)
  except CatchableError as err:
    return (false, "rebase failed: " & err.msg)
  # Step 2: re-observe and re-check every input.
  var expected = initTable[string, string]()
  for i, entry in pathSet:
    expected[entry] = bundle.identities[i]
  var inputs: seq[FileFingerprint] = @[]
  for i, input in record.inputs:
    let entry = pathSetEntryOf(normalized.inputs[i], ctx)
    let wanted = expected.getOrDefault(entry, "")
    let location = recordedInputLocation(ctx.cwd, input.path)
    let id = observedIdentity(location,
      membershipTrackedDirectory(input.metadata))
    if id != wanted:
      return (false, "input changed since lookup: " & input.path)
    var fresh =
      try:
        if membershipTrackedDirectory(input.metadata):
          observeEnumeratedDirectory(location, policy)
        else:
          observeFile(location, policy)
      except CatchableError as err:
        return (false, "cannot observe input " & input.path & ": " & err.msg)
    fresh.path = input.path
    inputs.add(fresh)
  record.inputs = inputs
  record.policy = policy
  record.weakFingerprint = localWeak
  try:
    record.strongFingerprint = computeStrongFingerprint(localWeak,
      record.inputs, record.envInputs)
  except CatchableError as err:
    return (false, "cannot fingerprint installed record: " & err.msg)
  # The PathSet blob (already verified against the entry above) and the
  # output payloads, digest- and size-checked as they land.
  if cas.casPut(bundle.pathSetBytes) != toContentHash(bytes(entry.pathSetDigest)):
    return (false, "CAS stored the path set blob under another digest")
  for i, payload in bundle.blobs:
    let output = record.outputs[i]
    if uint64(payload.len) != output.blob.sizeBytes:
      return (false, "bundle blob size mismatch for output " & output.path)
    let stored = cas.casPut(payload)
    if stored != contentHashForBundleBlob(output.blob):
      return (false, "bundle blob digest mismatch for output " & output.path)
  cache.appendActionResultRecord(record)
  (true, "")
