import blake3
import gxhash
import xxh3
import repro_hash/types

const FrameMagic = "reprobuild.hash.v1\0"

proc domainTag(domain: HashDomain): string =
  case domain
  of hdCasContent: "cas-content"
  of hdActionFingerprint: "action-fingerprint"
  of hdLocalInvalidation: "local-invalidation"
  of hdMetadataEnvelope: "metadata-envelope"

# FRAME LAYOUT (unchanged, and not free to change: it is the fingerprint).
#
#   FrameMagic | u16le(tag.len) | tag | u64le(payload.len) | payload
#
# The three `put*` helpers below write that layout into an already-sized
# buffer at a cursor. They replaced per-byte `add` loops which paid a bounds
# check and a capacity check for every byte of magic, tag, length AND
# payload. In a Time Profiler trace of warm zlib no-ops this module's
# `seq.add` was the single hottest LEAF frame in `repro-daemon` -- 297 of
# 4,236 daemon samples, 285 of them reached through `framedPayload` -- which
# is more than `stat` and `lstat` together (99 + 74) and more than twice
# `blake3_compress_in_place_portable` (132), the actual compression this
# frame exists to feed. Counters had not found it; a profile did.
#
# Priced directly, `-d:release`, over a 32B..16KiB payload mix, min of 9 runs
# per binary and 5 alternations between the two (spread under 2%):
#
#   casDigest  4.07 us -> 2.00 us per call  (-51%)
#   localHash  2.20 us -> 0.81 us per call  (-63%)
#
# That is a component measurement in a tight loop, so read it as the per-call
# ceiling, not as a build-time prediction.
#
# The emitted bytes are identical -- `putU16Le` / `putU64Le`
# keep the same little-endian shift order the `addU16Le` / `addU64Le` loops
# used, and `putString` / `putBytes` copy the source bytes in order, which is
# what `for ch in value: add(byte(ord(ch)))` did one byte at a time.

# Each `put*` advances `pos` by exactly what it wrote -- never by the width
# it was SUPPOSED to write. That distinction is load-bearing, and it is the
# one thing here that was ESTABLISHED by experiment rather than reasoned out.
#
# A pre-sized, positionally-filled buffer has a failure mode the `add`-based
# code it replaced did not: a field that emits one byte too few leaves a zero
# behind instead of producing a short seq. Measured, not assumed -- an earlier
# revision advanced `pos` by the field width regardless of what was written,
# and a mutation dropping the top byte of the u64 payload-length field then
# passed ALL 177 pinned digests, because no payload here is 2^56 bytes long
# and the byte it dropped was already zero. Restore the blind advance today
# and that mutation survives the corpus again; it is not a historical note.
#
# Accumulating only what was written is what closes it, and it closes it in
# the corpus rather than at the assert: a short field now SHIFTS every byte
# after it, so the frame -- and the digest over it -- changes, and the pinned
# rows catch it. Verified by deleting the `doAssert` below and re-running the
# same mutation: still caught.

proc putU16Le(dest: var seq[byte]; pos: var int; value: uint16) =
  for shift in [0, 8]:
    dest[pos] = byte((value shr shift) and 0xff'u16)
    inc pos

proc putU64Le(dest: var seq[byte]; pos: var int; value: uint64) =
  for shift in [0, 8, 16, 24, 32, 40, 48, 56]:
    dest[pos] = byte((value shr shift) and 0xff'u64)
    inc pos

proc putString(dest: var seq[byte]; pos: var int; value: string) =
  if value.len > 0:
    copyMem(addr dest[pos], unsafeAddr value[0], value.len)
    pos += value.len

proc putBytes(dest: var seq[byte]; pos: var int; value: openArray[byte]) =
  if value.len > 0:
    copyMem(addr dest[pos], unsafeAddr value[0], value.len)
    pos += value.len

proc framedPayload(domain: HashDomain; payload: openArray[byte]): seq[byte] =
  ## Materialises the frame. Only `localHash` needs this: its hash (`xxh3`)
  ## is exposed one-shot, over a contiguous buffer, with no streaming API.
  ## The BLAKE3 domains do NOT go through here -- see `framedDigest`.
  let tag = domainTag(domain)
  result = newSeq[byte](FrameMagic.len + 2 + tag.len + 8 + payload.len)
  var pos = 0
  result.putString(pos, FrameMagic)
  result.putU16Le(pos, uint16(tag.len))
  result.putString(pos, tag)
  result.putU64Le(pos, uint64(payload.len))
  result.putBytes(pos, payload)
  # `doAssert`, not `assert`: verified present in the linked binary under
  # `-d:release` AND `-d:danger`, where `assert` would be gone.
  #
  # It is a backstop, not the detector -- do not read it as the thing that
  # makes a short write safe. Every short-write mutation tried against it is
  # already caught by the pinned corpus without it (see the note above), and
  # the defect it cannot see is the one that motivated this file: a field
  # that writes its full width with the WRONG VALUE -- masking the top byte
  # of the length, say -- leaves `pos == result.len` true and every pinned
  # digest unchanged, because no payload here is 2^56 bytes. What this line
  # does buy is a cheap invariant over payloads the corpus never sees, at
  # one comparison per call.
  doAssert pos == result.len, "framed payload is short: " & $pos & " of " &
    $result.len

proc updateU16Le(hasher: blake3.Blake3Hasher; value: uint16) =
  var bytes: array[2, byte]
  bytes[0] = byte(value and 0xff'u16)
  bytes[1] = byte((value shr 8) and 0xff'u16)
  hasher.update(bytes)

proc updateU64Le(hasher: blake3.Blake3Hasher; value: uint64) =
  var bytes: array[8, byte]
  for shift in [0, 8, 16, 24, 32, 40, 48, 56]:
    bytes[shift div 8] = byte((value shr shift) and 0xff'u64)
  hasher.update(bytes)

proc framedDigest(domain: HashDomain;
                  payload: openArray[byte]): blake3.Blake3Digest =
  ## The in-memory twin of `framedFileDigest`: streams the SAME frame bytes
  ## into the hasher instead of concatenating them into a buffer first. The
  ## buffer it replaces existed only to be handed to the one-shot
  ## `blake3.digest`, and its payload half was a full copy of an array the
  ## caller already owned -- so every call paid an allocation plus a memmove
  ## of the entire payload before a single byte was compressed.
  ##
  ## Identical output is not a coincidence of BLAKE3: `repro_blake3_hash`
  ## (the one-shot entry point this replaces) is itself literally
  ## `hasher_init` + one `hasher_update` + `hasher_finalize`, so the only
  ## difference here is where the update boundaries fall, which BLAKE3
  ## absorbs by construction. `tests/unit/t_hash_policy_frame_bytes.nim`
  ## pins it against digests captured from the buffer-building version.
  let tag = domainTag(domain)
  var hasher = blake3.initHasher()
  defer:
    hasher.close()
  hasher.update(FrameMagic)
  hasher.updateU16Le(uint16(tag.len))
  hasher.update(tag)
  hasher.updateU64Le(uint64(payload.len))
  hasher.update(payload)
  hasher.finalize()

proc framedFileDigest(path: string; sizeBytes: uint64;
                      domain: HashDomain): blake3.Blake3Digest =
  let tag = domainTag(domain)
  var hasher = blake3.initHasher()
  defer:
    hasher.close()
  hasher.update(FrameMagic)
  hasher.updateU16Le(uint16(tag.len))
  hasher.update(tag)
  hasher.updateU64Le(sizeBytes)

  const ChunkSize = 1024 * 1024
  var file = open(path, fmRead)
  defer:
    file.close()
  var buffer = newSeq[byte](ChunkSize)
  var total = 0'u64
  while true:
    let n = file.readBuffer(addr buffer[0], buffer.len)
    if n <= 0:
      break
    total += uint64(n)
    hasher.update(addr buffer[0], n)
  if total != sizeBytes:
    raise newException(IOError, "file changed while hashing: " & path)
  hasher.finalize()

proc casDigest*(payload: openArray[byte];
                domain: HashDomain = hdCasContent): ContentDigest =
  if domain == hdLocalInvalidation:
    raise newException(ValueError, "local invalidation domain is not a CAS digest")
  ContentDigest(
    algorithm: haBlake3_256,
    domain: domain,
    bytes: framedDigest(domain, payload))

proc casFileDigest*(path: string; sizeBytes: uint64;
                    domain: HashDomain = hdCasContent): ContentDigest =
  if domain == hdLocalInvalidation:
    raise newException(ValueError, "local invalidation domain is not a CAS digest")
  ContentDigest(
    algorithm: haBlake3_256,
    domain: domain,
    bytes: framedFileDigest(path, sizeBytes, domain))

proc blake3DomainDigest*(payload: openArray[byte]; domain: HashDomain): ContentDigest =
  if domain == hdLocalInvalidation:
    raise newException(ValueError, "local invalidation is selected through localHash")
  casDigest(payload, domain)

proc localHashSelection*(): LocalHashSelection =
  if gxhash.isAvailable():
    LocalHashSelection(
      algorithm: haGxHash64,
      implementation: "gxhash",
      reason: "real GxHash implementation is available")
  else:
    LocalHashSelection(
      algorithm: haXxh3_64,
      implementation: "xxh3",
      reason: "GxHash unavailable: " & gxhash.unavailableReason())

proc localHash*(payload: openArray[byte]): LocalInvalidationHash =
  let framed = framedPayload(hdLocalInvalidation, payload)
  let selected = localHashSelection()
  case selected.algorithm
  of haGxHash64:
    raise newException(ValueError, "GxHash selected but no implementation is linked")
  of haXxh3_64:
    LocalInvalidationHash(
      algorithm: haXxh3_64,
      domain: hdLocalInvalidation,
      value: xxh3.value(xxh3.digest64(framed)))
  of haBlake3_256:
    raise newException(ValueError, "BLAKE3 is not a local invalidation hash")
