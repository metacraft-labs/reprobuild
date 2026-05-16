import std/[strformat]

type
  M28PatchPacket* = object
    patchTemplateBytes*: seq[byte]
    debugObjectBytes*: seq[byte]
    unwindTemplateBytes*: seq[byte]

const
  M28PacketMagic* = "RBM28P01"

proc writeU32Le*(outp: var seq[byte]; value: uint32) =
  outp.add byte(value and 0xff'u32)
  outp.add byte((value shr 8) and 0xff'u32)
  outp.add byte((value shr 16) and 0xff'u32)
  outp.add byte((value shr 24) and 0xff'u32)

proc writeU64Le*(outp: var seq[byte]; value: uint64) =
  for shift in countup(0, 56, 8):
    outp.add byte((value shr shift) and 0xff'u64)

proc readU32Le*(bytes: openArray[byte]; offset: var int): uint32 =
  if offset < 0 or offset + 4 > bytes.len:
    raise newException(ValueError, "truncated uint32 in M28 patch packet")
  result = uint32(bytes[offset]) or
    (uint32(bytes[offset + 1]) shl 8) or
    (uint32(bytes[offset + 2]) shl 16) or
    (uint32(bytes[offset + 3]) shl 24)
  offset += 4

proc takeBytes(bytes: openArray[byte]; offset: var int; count: int): seq[byte] =
  if count < 0 or offset < 0 or offset + count > bytes.len:
    raise newException(ValueError, "truncated byte range in M28 patch packet")
  result = newSeq[byte](count)
  for i in 0 ..< count:
    result[i] = bytes[offset + i]
  offset += count

proc encodeM28PatchPacket*(packet: M28PatchPacket): seq[byte] =
  for ch in M28PacketMagic:
    result.add byte(ord(ch))
  writeU32Le(result, uint32(packet.patchTemplateBytes.len))
  writeU32Le(result, uint32(packet.debugObjectBytes.len))
  writeU32Le(result, uint32(packet.unwindTemplateBytes.len))
  result.add packet.patchTemplateBytes
  result.add packet.debugObjectBytes
  result.add packet.unwindTemplateBytes

proc parseM28PatchPacket*(bytes: openArray[byte]): M28PatchPacket =
  var offset = 0
  if bytes.len < M28PacketMagic.len:
    raise newException(ValueError, "truncated M28 patch packet magic")
  for ch in M28PacketMagic:
    if bytes[offset] != byte(ord(ch)):
      raise newException(ValueError, "invalid M28 patch packet magic")
    offset += 1
  let patchLen = int(readU32Le(bytes, offset))
  let debugLen = int(readU32Le(bytes, offset))
  let unwindLen = int(readU32Le(bytes, offset))
  result.patchTemplateBytes = takeBytes(bytes, offset, patchLen)
  result.debugObjectBytes = takeBytes(bytes, offset, debugLen)
  result.unwindTemplateBytes = takeBytes(bytes, offset, unwindLen)
  if offset != bytes.len:
    raise newException(ValueError, &"M28 patch packet has {bytes.len - offset} trailing bytes")

proc appendMovWideX16(outp: var seq[byte]; base: uint32; hw: uint32;
                      imm: uint16) =
  writeU32Le(outp, base or (hw shl 21) or (uint32(imm) shl 5) or 16'u32)

proc aarch64CallbackPatchTemplate*(returnValue: int): seq[byte] =
  if returnValue < 0 or returnValue > 0xffff:
    raise newException(ValueError, "M28 return value is outside uint16")
  writeU32Le(result, 0xa9bf7bfd'u32)
  writeU32Le(result, 0x910003fd'u32)
  appendMovWideX16(result, 0xd2800000'u32, 0, 0)
  appendMovWideX16(result, 0xf2800000'u32, 1, 0)
  appendMovWideX16(result, 0xf2800000'u32, 2, 0)
  appendMovWideX16(result, 0xf2800000'u32, 3, 0)
  writeU32Le(result, 0xd63f0200'u32)
  writeU32Le(result, 0x52800000'u32 or (uint32(returnValue) shl 5))
  writeU32Le(result, 0xa8c17bfd'u32)
  writeU32Le(result, 0xd65f03c0'u32)

proc relocateAarch64CallbackPatch*(templateBytes: openArray[byte];
                                   callbackAddress: uint64): seq[byte] =
  result = @templateBytes
  if result.len != 40:
    raise newException(ValueError, "unexpected M28 callback patch template size")
  for i in 0 .. 3:
    let imm = uint16((callbackAddress shr (i * 16)) and 0xffff'u64)
    let base = if i == 0: 0xd2800000'u32 else: 0xf2800000'u32
    var encoded: seq[byte] = @[]
    appendMovWideX16(encoded, base, uint32(i), imm)
    for j in 0 ..< 4:
      result[8 + i * 4 + j] = encoded[j]
