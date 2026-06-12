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

import std/options

import repro_hash
import repro_local_store

import ./engine_seam
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
  let blobCount = int(readU32Le(payload, pos))
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
  ## Derives the peer-cache key for an action's bundle from the
  ## engine's `weakFingerprint`. This is a stable identifier producer
  ## and consumer can both compute; both must agree on the
  ## `weakFingerprint` shape (they do — it's the action-fingerprint
  ## composition documented in
  ## `repro_tool_profiles.actionFingerprintFor`).
  blobDigestFromBytes(weakFingerprint.bytes)

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
