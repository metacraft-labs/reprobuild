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

proc addU16Le(outp: var seq[byte]; value: uint16) =
  outp.add(byte(value and 0xff'u16))
  outp.add(byte((value shr 8) and 0xff'u16))

proc addU64Le(outp: var seq[byte]; value: uint64) =
  for shift in [0, 8, 16, 24, 32, 40, 48, 56]:
    outp.add(byte((value shr shift) and 0xff'u64))

proc addString(outp: var seq[byte]; value: string) =
  for ch in value:
    outp.add(byte(ord(ch)))

proc framedPayload(domain: HashDomain; payload: openArray[byte]): seq[byte] =
  let tag = domainTag(domain)
  result = newSeqOfCap[byte](FrameMagic.len + 2 + tag.len + 8 + payload.len)
  result.addString(FrameMagic)
  result.addU16Le(uint16(tag.len))
  result.addString(tag)
  result.addU64Le(uint64(payload.len))
  result.add(payload)

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
    bytes: blake3.digest(framedPayload(domain, payload)))

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
