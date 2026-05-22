## Pointer envelope writer/reader for `pointer.bin` (M62 —
## Home-Profile-Generations-And-State.md "Pointer Envelope").
##
## Binary on-disk shape (little-endian throughout):
##
##   offset 0   :  magic                       4 bytes ASCII "RBPT"
##                 (chosen to align with the existing RBCG/RBLP/RPRC
##                  family of binary envelopes; "RBPT" = "Reprobuild
##                  Pointer".)
##   offset 4   :  schemaVersion               u16 LE
##   offset 6   :  bodyLength                  u32 LE
##   offset 10  :  body                        bodyLength bytes
##   trailing   :  trailingChecksum            32 bytes BLAKE3-256
##                 (over the entire preceding magic+version+bodyLen+body)
##
## Body field order (per spec, audited set, NO additional fields):
##
##   1. generationId                       16 bytes
##   2. activationTimestamp                i64 LE (unix epoch seconds)
##   3. hostIdentity                       u32 LE length + UTF-8 bytes
##   4. intentSnapshotDigest               32 bytes (BLAKE3-256)
##   5. configurableGraphDigest            32 bytes (BLAKE3-256)
##   6. activationManifestDigest           32 bytes (BLAKE3-256)
##   7. realizedPrefixIds                  u32 LE count + count*32-byte digests
##
## The writer/reader are STRICT: any attempt to encode a record with
## extra fields, or to decode a file whose remaining bytes exceed the
## declared `bodyLength`, fails closed via `EPointerCorrupt`.
##
## CRITICAL: the on-disk file is the entire `pointer.bin` — no history
## file, no per-generation `files/` directory, no `intent-snapshot/`
## directory. The activation manifest, the RBCG, and the intent snapshot
## all live in the local CAS (referenced by their digests above).

import std/[os]

import blake3
import repro_core

import ./errors

const
  PointerMagic* = "RBPT"
  PointerSchemaVersion*: uint16 = 1
  GenerationIdSize* = 16
  DigestSize* = 32
  EnvelopeHeaderSize = 4 + 2 + 4    ## magic + version + bodyLen
  EnvelopeTrailerSize = 32          ## trailing checksum

type
  GenerationId* = array[GenerationIdSize, byte]
  Digest256* = array[DigestSize, byte]

  PointerEnvelope* = object
    ## In-memory representation of the audited pointer record.
    schemaVersion*: uint16
    generationId*: GenerationId
    activationTimestamp*: int64
    hostIdentity*: string
    intentSnapshotDigest*: Digest256
    configurableGraphDigest*: Digest256
    activationManifestDigest*: Digest256
    realizedPrefixIds*: seq[Digest256]

# ---------------------------------------------------------------------------
# Generation identity helper.
# ---------------------------------------------------------------------------

proc computeGenerationId*(intentSnapshotDigest: Digest256;
                          hostIdentity: string;
                          activationTimestamp: int64): GenerationId =
  ## Deterministic 16-byte identifier derived from the inputs documented
  ## in the spec ("Generation Identity"). At M62 we have no apply
  ## pipeline yet, so the helper is a convenience: the apply pipeline
  ## (M63) will replace it with a hash of the resolved RBCG bytes +
  ## resolved package set + intent snapshot + host identity.
  var buf: seq[byte] = @[]
  buf.writeString("reprobuild.home.generation.id.v1")
  for b in intentSnapshotDigest: buf.add(b)
  buf.writeString(hostIdentity)
  buf.writeU64Le(uint64(activationTimestamp))
  let full = blake3.digest(buf)
  for i in 0 ..< GenerationIdSize:
    result[i] = full[i]

# ---------------------------------------------------------------------------
# Encoding.
# ---------------------------------------------------------------------------

proc writeBytes(outp: var seq[byte]; data: openArray[byte]) =
  for b in data: outp.add(b)

proc encodeBody(envelope: PointerEnvelope): seq[byte] =
  for b in envelope.generationId: result.add(b)
  result.writeU64Le(uint64(envelope.activationTimestamp))
  result.writeString(envelope.hostIdentity)
  result.writeBytes(envelope.intentSnapshotDigest)
  result.writeBytes(envelope.configurableGraphDigest)
  result.writeBytes(envelope.activationManifestDigest)
  result.writeU32Le(uint32(envelope.realizedPrefixIds.len))
  for digest in envelope.realizedPrefixIds:
    result.writeBytes(digest)

proc encodePointer*(envelope: PointerEnvelope): seq[byte] =
  ## Serialize the audited field set to bytes. The schema-version field
  ## of the in-memory record is overwritten with the current schema
  ## version: the writer is the source of truth, callers that want a
  ## different schema must compose the bytes manually.
  let body = encodeBody(envelope)
  let bodyLen = uint32(body.len)
  result = newSeqOfCap[byte](
    EnvelopeHeaderSize + body.len + EnvelopeTrailerSize)
  for ch in PointerMagic:
    result.add(byte(ord(ch)))
  result.writeU16Le(PointerSchemaVersion)
  result.writeU32Le(bodyLen)
  result.writeBytes(body)
  let checksum = blake3.digest(result)
  result.writeBytes(checksum)

proc expectedPointerFileSize*(envelope: PointerEnvelope): int =
  ## Exact byte size of the on-disk file for this envelope. Gate 1 uses
  ## this to pin "no padding, no extras" against a known fixture.
  EnvelopeHeaderSize +
    GenerationIdSize +
    8 +                                # activationTimestamp i64
    4 + envelope.hostIdentity.len +    # length-prefixed UTF-8 host id
    DigestSize +                       # intentSnapshotDigest
    DigestSize +                       # configurableGraphDigest
    DigestSize +                       # activationManifestDigest
    4 + envelope.realizedPrefixIds.len * DigestSize +
    EnvelopeTrailerSize

# ---------------------------------------------------------------------------
# Atomic file writer.
# ---------------------------------------------------------------------------

proc bytesToString(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc stringToBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc writePointerFile*(pointerFilePath: string; envelope: PointerEnvelope) =
  ## Atomically writes the envelope to `pointerFilePath` via the
  ## standard tmp-then-rename protocol. The directory containing the
  ## final file must already exist.
  let bytes = encodePointer(envelope)
  let parent = parentDir(pointerFilePath)
  if parent.len > 0:
    createDir(extendedPath(parent))
  let tmpPath = pointerFilePath & ".tmp"
  writeFile(extendedPath(tmpPath), bytesToString(bytes))
  if fileExists(extendedPath(pointerFilePath)):
    removeFile(extendedPath(pointerFilePath))
  moveFile(extendedPath(tmpPath), extendedPath(pointerFilePath))

# ---------------------------------------------------------------------------
# Decoding.
# ---------------------------------------------------------------------------

proc readFixed(buf: openArray[byte]; pos: var int; n: int;
               filePath, field: string): seq[byte] =
  if pos + n > buf.len:
    raisePointerCorrupt(filePath, field,
      "expected " & $n & " bytes, only " & $(buf.len - pos) & " remaining")
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = buf[pos + i]
  pos += n

proc readDigest(buf: openArray[byte]; pos: var int;
                filePath, field: string): Digest256 =
  if pos + DigestSize > buf.len:
    raisePointerCorrupt(filePath, field,
      "expected " & $DigestSize & " bytes")
  for i in 0 ..< DigestSize:
    result[i] = buf[pos + i]
  pos += DigestSize

proc decodePointerBytes*(bytes: openArray[byte];
                        filePath = "<memory>"): PointerEnvelope =
  ## Strict reader: validates magic, schema version, body-length
  ## bounds, and the trailing BLAKE3 checksum BEFORE returning any
  ## field. Any inconsistency raises `EPointerCorrupt` with the
  ## offending field name.
  if bytes.len < EnvelopeHeaderSize + EnvelopeTrailerSize:
    raisePointerCorrupt(filePath, "envelope",
      "file is too short to be a pointer envelope (" & $bytes.len &
      " bytes)")
  for i in 0 ..< 4:
    if bytes[i] != byte(ord(PointerMagic[i])):
      raisePointerCorrupt(filePath, "magic",
        "expected '" & PointerMagic & "' magic")
  var pos = 4
  let version = readU16Le(bytes, pos)
  if version != PointerSchemaVersion:
    raisePointerCorrupt(filePath, "schemaVersion",
      "unsupported pointer schema version " & $version &
      " (this build understands " & $PointerSchemaVersion & ")")
  let bodyLen = int(readU32Le(bytes, pos))
  if pos + bodyLen + EnvelopeTrailerSize != bytes.len:
    raisePointerCorrupt(filePath, "bodyLength",
      "declared body length " & $bodyLen & " disagrees with file size " &
      $bytes.len)
  let bodyEnd = pos + bodyLen
  # Verify trailing checksum BEFORE parsing fields, so a corrupt body
  # is rejected outright.
  var prefix = newSeqOfCap[byte](bodyEnd)
  for i in 0 ..< bodyEnd:
    prefix.add(bytes[i])
  let expected = blake3.digest(prefix)
  for i in 0 ..< DigestSize:
    if bytes[bodyEnd + i] != expected[i]:
      raisePointerCorrupt(filePath, "trailingChecksum",
        "BLAKE3-256 trailing checksum mismatch")
  # Now decode the body. Field order MUST match `encodeBody`.
  let g = readFixed(bytes, pos, GenerationIdSize, filePath, "generationId")
  for i in 0 ..< GenerationIdSize:
    result.generationId[i] = g[i]
  result.schemaVersion = version
  result.activationTimestamp = int64(readU64Le(bytes, pos))
  let hostLen = int(readU32Le(bytes, pos))
  if pos + hostLen > bodyEnd:
    raisePointerCorrupt(filePath, "hostIdentity",
      "declared host-identity length overflows body")
  result.hostIdentity = newString(hostLen)
  for i in 0 ..< hostLen:
    result.hostIdentity[i] = char(bytes[pos + i])
  pos += hostLen
  result.intentSnapshotDigest = readDigest(bytes, pos, filePath,
    "intentSnapshotDigest")
  result.configurableGraphDigest = readDigest(bytes, pos, filePath,
    "configurableGraphDigest")
  result.activationManifestDigest = readDigest(bytes, pos, filePath,
    "activationManifestDigest")
  let prefixCount = int(readU32Le(bytes, pos))
  if pos + prefixCount * DigestSize > bodyEnd:
    raisePointerCorrupt(filePath, "realizedPrefixIds",
      "declared realized-prefix count " & $prefixCount & " overflows body")
  result.realizedPrefixIds = newSeq[Digest256](prefixCount)
  for i in 0 ..< prefixCount:
    result.realizedPrefixIds[i] = readDigest(bytes, pos, filePath,
      "realizedPrefixIds[" & $i & "]")
  if pos != bodyEnd:
    raisePointerCorrupt(filePath, "body",
      "trailing " & $(bodyEnd - pos) & " bytes after audited field set " &
      "(extras are forbidden by the audited schema)")

proc readPointerFile*(pointerFilePath: string): PointerEnvelope =
  if not fileExists(extendedPath(pointerFilePath)):
    raisePointerCorrupt(pointerFilePath, "file", "no such file")
  let raw = readFile(extendedPath(pointerFilePath))
  decodePointerBytes(stringToBytes(raw), pointerFilePath)

# ---------------------------------------------------------------------------
# Hex helpers (for `repro home history` and gate fixtures).
# ---------------------------------------------------------------------------

proc generationIdHex*(g: GenerationId): string =
  hexBytes(g)

proc digestHex*(d: Digest256): string =
  hexBytes(d)

# Local hex-nibble parser to avoid pulling in std/strutils' parseHexInt
# (which raises on the prefix variants we don't want here).
proc parseHexNibble(c: char): int =
  case c
  of '0' .. '9': int(ord(c) - ord('0'))
  of 'a' .. 'f': int(ord(c) - ord('a') + 10)
  of 'A' .. 'F': int(ord(c) - ord('A') + 10)
  else:
    raise newException(ValueError, "not a hex nibble: " & $c)

proc parseGenerationIdHex*(hex: string): GenerationId =
  ## Parse a 32-character lower-case hex string into a 16-byte
  ## generation id. Used by the CLI when looking up a generation by
  ## id from `<state-dir>/generations/<id>`.
  if hex.len != GenerationIdSize * 2:
    raise newException(ValueError,
      "expected " & $(GenerationIdSize * 2) & " hex chars, got " & $hex.len)
  for i in 0 ..< GenerationIdSize:
    let high = parseHexNibble(hex[2 * i])
    let low = parseHexNibble(hex[2 * i + 1])
    result[i] = byte((high shl 4) or low)
