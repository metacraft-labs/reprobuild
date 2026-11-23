import std/[strutils]

type
  CodecFamily* = enum
    cfFixedSchemaEnvelope
    cfCborDynamicMetadata
    cfJsonInspectionView

  EnvelopeErrorKind* = enum
    eeMalformed
    eeUnknownMagic
    eeUnsupportedVersion
    eeUnknownType

  EnvelopeError* = object of CatchableError
    kind*: EnvelopeErrorKind

  EnvelopeTypeId* = distinct uint16

  EnvelopeHeader* = object
    magic*: array[4, byte]
    version*: uint16
    typeId*: EnvelopeTypeId
    payloadLength*: uint32

  BinaryCodecPolicy* = object
    fixedSchemaFamily*: CodecFamily
    dynamicMetadataFamily*: CodecFamily
    jsonPersistent*: bool

const DefaultBinaryCodecPolicy* = BinaryCodecPolicy(
  fixedSchemaFamily: cfFixedSchemaEnvelope,
  dynamicMetadataFamily: cfCborDynamicMetadata,
  jsonPersistent: false)

proc raiseEnvelopeError*(kind: EnvelopeErrorKind; message: string) {.noreturn.} =
  var err = newException(EnvelopeError, message)
  err.kind = kind
  raise err

proc writeU16Le*(outp: var seq[byte]; value: uint16) =
  outp.add(byte(value and 0xff'u16))
  outp.add(byte((value shr 8) and 0xff'u16))

proc writeU32Le*(outp: var seq[byte]; value: uint32) =
  for shift in [0, 8, 16, 24]:
    outp.add(byte((value shr shift) and 0xff'u32))

proc writeU64Le*(outp: var seq[byte]; value: uint64) =
  for shift in [0, 8, 16, 24, 32, 40, 48, 56]:
    outp.add(byte((value shr shift) and 0xff'u64))

proc readU16Le*(bytes: openArray[byte]; pos: var int): uint16 =
  if pos + 2 > bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated uint16")
  result = uint16(bytes[pos]) or (uint16(bytes[pos + 1]) shl 8)
  pos += 2

proc readU32Le*(bytes: openArray[byte]; pos: var int): uint32 =
  if pos + 4 > bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated uint32")
  for i in 0 ..< 4:
    result = result or (uint32(bytes[pos + i]) shl (8 * i))
  pos += 4

proc readU64Le*(bytes: openArray[byte]; pos: var int): uint64 =
  if pos + 8 > bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated uint64")
  for i in 0 ..< 8:
    result = result or (uint64(bytes[pos + i]) shl (8 * i))
  pos += 8

proc elementCountFits*(count: uint32; remaining: int;
                       minimumBytes: int = 1): bool =
  ## Validate untrusted counts before narrowing or allocating. Division avoids
  ## overflow even when a caller supplies a large encoded element size.
  remaining >= 0 and minimumBytes > 0 and
    uint64(count) <= uint64(remaining) div uint64(minimumBytes) and
    uint64(count) <= uint64(high(int))

proc readElementCount*(bytes: openArray[byte]; pos: var int;
                       minimumBytes: int = 1): int =
  ## Each encoded element must consume at least ``minimumBytes`` bytes.
  ## Callers with their own error type can instead use ``elementCountFits``.
  let count = readU32Le(bytes, pos)
  if not elementCountFits(count, bytes.len - pos, minimumBytes):
    raiseEnvelopeError(eeMalformed, "element count exceeds remaining bytes")
  int(count)

proc writeString*(outp: var seq[byte]; value: string) =
  outp.writeU32Le(uint32(value.len))
  for ch in value:
    outp.add(byte(ord(ch)))

proc readString*(bytes: openArray[byte]; pos: var int): string =
  let length = int(readU32Le(bytes, pos))
  if pos + length > bytes.len:
    raiseEnvelopeError(eeMalformed, "truncated string")
  result = newString(length)
  for i in 0 ..< length:
    result[i] = char(bytes[pos + i])
  pos += length

proc toBytes*(text: string): seq[byte] =
  result = newSeqOfCap[byte](text.len)
  for ch in text:
    result.add(byte(ord(ch)))

proc fromBytes*(bytes: openArray[byte]): string =
  result = newString(bytes.len)
  for i, b in bytes:
    result[i] = char(b)

proc hexBytes*(bytes: openArray[byte]): string =
  result = newStringOfCap(bytes.len * 2)
  for b in bytes:
    result.add(toHex(int(b), 2).toLowerAscii())
