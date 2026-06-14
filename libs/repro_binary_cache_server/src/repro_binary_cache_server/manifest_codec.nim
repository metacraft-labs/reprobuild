## ReproOS-Generations-And-Foreign-Packages A2 — manifest codec.
##
## Encodes ``BinaryCacheManifest`` records into a version-tagged
## envelope and back. The shape is fixed-schema enough to belong on the
## SSZ side of ``Binary-Caches.md`` § "Payload objects" encoding policy
## (CBOR is reserved for the dynamic-metadata payload objects that will
## land in A2.5). The hand-rolled encoder follows the same pattern as
## ``libs/repro_peer_cache/src/repro_peer_cache/codec.nim`` so the
## fuzzing surface stays narrow.
##
## ## Envelope layout
##
##   magic[4]               "RBC1"            (BinaryCacheEnvelopeMagic)
##   formatVersion u16-le   == 1              (BinaryCacheFormatVersion)
##   reserved u16-le        0                 (alignment + future flags)
##   entryKeyDigest[32]     BLAKE3-256(key)   (redundant; tamper sentinel)
##   keyBlock               length-prefixed canonical CacheEntryKey
##   payloadsBlock          length-prefixed seq[PayloadObject]
##   realizedPrefixDigest[32]
##   depReferencesBlock     length-prefixed seq[Blake3Hash]
##   relocationPolicy u8
##   createdAtUnix i64-le
##   producerPubKey[65]     ECDSA-P256 uncompressed
##   signature[64]          ECDSA-P256 raw r||s
##
## The signed payload is everything UP TO ``signature``. ``signature``
## itself is the last 64 bytes; the verifier slices the buffer there.

import std/[strutils]

import blake3
import ../../../repro_peer_cache/src/repro_peer_cache/auth as peerAuth

import ./types
import ./key

# ---------------------------------------------------------------------------
# Errors.
# ---------------------------------------------------------------------------

type
  BinaryCacheCodecError* = object of CatchableError
    ## Raised on any malformed envelope or version mismatch.

  BinaryCacheSignatureError* = object of CatchableError
    ## Raised on a manifest whose signature does not verify against the
    ## embedded producer pubkey.

# ---------------------------------------------------------------------------
# Little-endian primitives.
# ---------------------------------------------------------------------------

proc writeU8(buf: var seq[byte]; v: uint8) =
  buf.add(v)

proc writeU16LE(buf: var seq[byte]; v: uint16) =
  buf.add(byte(v and 0xff'u16))
  buf.add(byte((v shr 8) and 0xff'u16))

proc writeU32LE(buf: var seq[byte]; v: uint32) =
  for shift in countup(0, 24, 8):
    buf.add(byte((v shr uint32(shift)) and 0xff'u32))

proc writeI64LE(buf: var seq[byte]; v: int64) =
  let u = cast[uint64](v)
  for shift in countup(0, 56, 8):
    buf.add(byte((u shr uint64(shift)) and 0xff'u64))

proc writeU64LE(buf: var seq[byte]; v: uint64) =
  for shift in countup(0, 56, 8):
    buf.add(byte((v shr uint64(shift)) and 0xff'u64))

proc writeString(buf: var seq[byte]; v: string) =
  writeU32LE(buf, uint32(v.len))
  for ch in v:
    buf.add(byte(ch))

proc writeDigest(buf: var seq[byte]; d: Blake3Hash) =
  for b in d:
    buf.add(b)

proc writeBytes(buf: var seq[byte]; src: openArray[byte]) =
  for b in src:
    buf.add(b)

# ---------------------------------------------------------------------------
# Cursor-style readers.
# ---------------------------------------------------------------------------

template ensureBytes(remaining: int; need: int; what: string) =
  if remaining < need:
    raise newException(BinaryCacheCodecError,
      "manifest truncated reading " & what & ": need " & $need &
      " bytes, have " & $remaining)

proc readU8(buf: openArray[byte]; pos: var int): uint8 =
  ensureBytes(buf.len - pos, 1, "u8")
  result = buf[pos]
  inc pos

proc readU16LE(buf: openArray[byte]; pos: var int): uint16 =
  ensureBytes(buf.len - pos, 2, "u16")
  result = uint16(buf[pos]) or (uint16(buf[pos + 1]) shl 8)
  inc pos, 2

proc readU32LE(buf: openArray[byte]; pos: var int): uint32 =
  ensureBytes(buf.len - pos, 4, "u32")
  result = 0'u32
  for i in 0 ..< 4:
    result = result or (uint32(buf[pos + i]) shl uint32(i * 8))
  inc pos, 4

proc readI64LE(buf: openArray[byte]; pos: var int): int64 =
  ensureBytes(buf.len - pos, 8, "i64")
  var raw = 0'u64
  for i in 0 ..< 8:
    raw = raw or (uint64(buf[pos + i]) shl uint64(i * 8))
  inc pos, 8
  result = cast[int64](raw)

proc readU64LE(buf: openArray[byte]; pos: var int): uint64 =
  ensureBytes(buf.len - pos, 8, "u64")
  result = 0'u64
  for i in 0 ..< 8:
    result = result or (uint64(buf[pos + i]) shl uint64(i * 8))
  inc pos, 8

proc readString(buf: openArray[byte]; pos: var int): string =
  let n = int(readU32LE(buf, pos))
  ensureBytes(buf.len - pos, n, "string payload")
  result = newString(n)
  for i in 0 ..< n:
    result[i] = char(buf[pos + i])
  inc pos, n

proc readDigest(buf: openArray[byte]; pos: var int): Blake3Hash =
  ensureBytes(buf.len - pos, 32, "Blake3Hash")
  for i in 0 ..< 32:
    result[i] = buf[pos + i]
  inc pos, 32

proc readPubKey(buf: openArray[byte]; pos: var int): peerAuth.PublicKeyBytes =
  ensureBytes(buf.len - pos, peerAuth.P256PubLen, "ECDSA-P256 pubkey")
  for i in 0 ..< peerAuth.P256PubLen:
    result[i] = buf[pos + i]
  inc pos, peerAuth.P256PubLen

proc readSignature(buf: openArray[byte]; pos: var int): peerAuth.SignatureBytes =
  ensureBytes(buf.len - pos, peerAuth.P256SigLen, "ECDSA-P256 signature")
  for i in 0 ..< peerAuth.P256SigLen:
    result[i] = buf[pos + i]
  inc pos, peerAuth.P256SigLen

# ---------------------------------------------------------------------------
# PayloadObject + CacheEntryKey sub-encoders.
# ---------------------------------------------------------------------------

proc encodePayload(buf: var seq[byte]; p: PayloadObject) =
  writeU8(buf, uint8(ord(p.kind)))
  writeU8(buf, uint8(ord(p.compression)))
  writeU64LE(buf, p.declaredSize)
  writeU64LE(buf, p.uncompressedSize)
  writeDigest(buf, p.digest)
  writeString(buf, p.name)

proc decodePayload(buf: openArray[byte]; pos: var int): PayloadObject =
  let kindByte = readU8(buf, pos)
  if kindByte > uint8(ord(high(PayloadKind))):
    raise newException(BinaryCacheCodecError,
      "manifest payload-kind tag out of range: " & $kindByte)
  result.kind = PayloadKind(kindByte)
  let compByte = readU8(buf, pos)
  if compByte > uint8(ord(high(CompressionKind))):
    raise newException(BinaryCacheCodecError,
      "manifest compression tag out of range: " & $compByte)
  result.compression = CompressionKind(compByte)
  result.declaredSize = readU64LE(buf, pos)
  result.uncompressedSize = readU64LE(buf, pos)
  result.digest = readDigest(buf, pos)
  result.name = readString(buf, pos)

proc encodeCacheEntryKeyBlock(buf: var seq[byte]; k: CacheEntryKey) =
  let payload = encodeCacheEntryKey(k)
  writeU32LE(buf, uint32(payload.len))
  writeBytes(buf, payload)

proc decodeCacheEntryKey(payload: openArray[byte]): CacheEntryKey =
  ## Inverse of ``key.encodeCacheEntryKey``. Kept here (rather than in
  ## ``key.nim``) because it shares the cursor-readers with the rest
  ## of the manifest codec and is only consumed by the codec on the
  ## manifest-decode path.
  var pos = 0
  let v = readU16LE(payload, pos)
  if v != BinaryCacheFormatVersion:
    raise newException(BinaryCacheCodecError,
      "CacheEntryKey format version mismatch: got " & $v &
      ", expected " & $BinaryCacheFormatVersion)
  result.packageName = readString(payload, pos)
  result.packageVersion = readString(payload, pos)
  let optCount = int(readU32LE(payload, pos))
  result.selectedOptions = newSeqOfCap[(string, string)](optCount)
  for _ in 0 ..< optCount:
    let k = readString(payload, pos)
    let v = readString(payload, pos)
    result.selectedOptions.add((k, v))
  result.platform.cpu = readString(payload, pos)
  result.platform.os = readString(payload, pos)
  result.platform.abi = readString(payload, pos)
  result.platform.libcVariant = readString(payload, pos)
  result.toolchain.name = readString(payload, pos)
  result.toolchain.version = readString(payload, pos)
  result.toolchain.hostLdSoAbi = readString(payload, pos)
  result.toolchain.extraFingerprint = readString(payload, pos)
  result.depClosureDigest = readDigest(payload, pos)
  result.providerRevision = readString(payload, pos)
  if pos != payload.len:
    raise newException(BinaryCacheCodecError,
      "CacheEntryKey block has trailing bytes: pos=" & $pos &
      " len=" & $payload.len)

# ---------------------------------------------------------------------------
# Whole-manifest encode.
# ---------------------------------------------------------------------------

proc encodeUnsignedPrefix(m: BinaryCacheManifest): seq[byte] =
  ## Everything up to (but not including) the signature field. The
  ## bytes signed by the producer key.
  result = newSeqOfCap[byte](512)
  # Magic.
  for ch in BinaryCacheEnvelopeMagic:
    result.add(byte(ch))
  # Format version + reserved padding.
  writeU16LE(result, m.formatVersion)
  writeU16LE(result, 0'u16)
  # Tamper sentinel: BLAKE3-256 of the canonical key encoding.
  writeDigest(result, cacheEntryKeyDigest(m.entryKey))
  # CacheEntryKey block.
  encodeCacheEntryKeyBlock(result, m.entryKey)
  # Payload object list.
  writeU32LE(result, uint32(m.payloads.len))
  for p in m.payloads:
    encodePayload(result, p)
  # Realized prefix digest.
  writeDigest(result, m.realizedPrefixDigest)
  # Dep refs.
  writeU32LE(result, uint32(m.depReferences.len))
  for d in m.depReferences:
    writeDigest(result, d)
  # Relocation policy.
  writeU8(result, uint8(ord(m.relocationPolicy)))
  # Timestamp.
  writeI64LE(result, m.createdAtUnix)
  # Producer pubkey.
  for b in m.producerPubKey:
    result.add(b)

proc encodeManifest*(m: BinaryCacheManifest): seq[byte] =
  ## Full envelope including the trailing signature.
  result = encodeUnsignedPrefix(m)
  for b in m.signature:
    result.add(b)

# ---------------------------------------------------------------------------
# Whole-manifest decode.
# ---------------------------------------------------------------------------

proc decodeManifest*(buf: openArray[byte]): BinaryCacheManifest =
  if buf.len < BinaryCacheEnvelopeMagic.len + 4 + peerAuth.P256SigLen:
    raise newException(BinaryCacheCodecError,
      "manifest envelope too short: " & $buf.len & " bytes")
  for i, ch in BinaryCacheEnvelopeMagic:
    if buf[i] != byte(ch):
      raise newException(BinaryCacheCodecError,
        "manifest envelope magic mismatch at byte " & $i)
  var pos = BinaryCacheEnvelopeMagic.len
  result.formatVersion = readU16LE(buf, pos)
  if result.formatVersion != BinaryCacheFormatVersion:
    raise newException(BinaryCacheCodecError,
      "manifest format version mismatch: got " &
      $result.formatVersion & ", expected " & $BinaryCacheFormatVersion)
  discard readU16LE(buf, pos)        # reserved padding
  let declaredKeyDigest = readDigest(buf, pos)
  let keyBlockLen = int(readU32LE(buf, pos))
  ensureBytes(buf.len - pos, keyBlockLen, "CacheEntryKey block")
  var keyBlock = newSeq[byte](keyBlockLen)
  for i in 0 ..< keyBlockLen:
    keyBlock[i] = buf[pos + i]
  inc pos, keyBlockLen
  result.entryKey = decodeCacheEntryKey(keyBlock)
  # Tamper sentinel: keyDigest must match the re-derived digest.
  let recomputedKeyDigest = cacheEntryKeyDigest(result.entryKey)
  if recomputedKeyDigest != declaredKeyDigest:
    raise newException(BinaryCacheCodecError,
      "manifest CacheEntryKey digest mismatch (envelope tampered?)")
  let payloadCount = int(readU32LE(buf, pos))
  result.payloads = newSeqOfCap[PayloadObject](payloadCount)
  for _ in 0 ..< payloadCount:
    result.payloads.add(decodePayload(buf, pos))
  result.realizedPrefixDigest = readDigest(buf, pos)
  let depCount = int(readU32LE(buf, pos))
  result.depReferences = newSeqOfCap[Blake3Hash](depCount)
  for _ in 0 ..< depCount:
    result.depReferences.add(readDigest(buf, pos))
  let policyByte = readU8(buf, pos)
  if policyByte > uint8(ord(high(RelocationPolicy))):
    raise newException(BinaryCacheCodecError,
      "manifest relocation-policy tag out of range: " & $policyByte)
  result.relocationPolicy = RelocationPolicy(policyByte)
  result.createdAtUnix = readI64LE(buf, pos)
  result.producerPubKey = readPubKey(buf, pos)
  result.signature = readSignature(buf, pos)
  if pos != buf.len:
    raise newException(BinaryCacheCodecError,
      "manifest envelope has trailing bytes: pos=" & $pos &
      " len=" & $buf.len)

# ---------------------------------------------------------------------------
# Sign / verify on top of the existing peer-cache ``auth.nim`` primitives.
# ---------------------------------------------------------------------------

proc signManifest*(kp: peerAuth.PeerKeypair;
                   m: var BinaryCacheManifest) =
  ## Populates ``m.producerPubKey`` + ``m.signature`` in place. Idempotent
  ## under the strict invariant that the caller did not mutate ``m`` in
  ## between calls.
  m.formatVersion = BinaryCacheFormatVersion
  m.producerPubKey = kp.publicKey
  # Re-encode the prefix WITH the now-populated pubkey, then sign.
  let prefix = encodeUnsignedPrefix(m)
  m.signature = peerAuth.signMessage(kp, prefix)

proc verifyManifest*(m: BinaryCacheManifest): bool =
  ## Returns ``true`` iff the embedded signature verifies against the
  ## embedded ``producerPubKey`` over the canonical unsigned prefix.
  ##
  ## A trust-anchor allowlist is enforced separately by the higher-level
  ## ``server.nim`` handler — this proc only does the cryptographic
  ## check.
  let prefix = encodeUnsignedPrefix(m)
  result = peerAuth.verifySignature(m.producerPubKey, prefix, m.signature)

proc verifyManifestOrRaise*(m: BinaryCacheManifest) =
  if not verifyManifest(m):
    raise newException(BinaryCacheSignatureError,
      "binary-cache manifest signature verification failed " &
      "(producer pubkey may not match or envelope was tampered)")
