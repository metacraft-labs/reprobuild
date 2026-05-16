import repro_hcr_linker/types

const
  Aarch64Nop = 0xd503201f'u32
  Aarch64Ret = 0xd65f03c0'u32
  Aarch64MovzW0 = 0x52800000'u32
  Aarch64Branch = 0x14000000'u32
  Aarch64BranchMask = 0xfc000000'u32
  Aarch64Imm26Mask = 0x03ffffff'u32

proc writeU32Le(outp: var seq[byte]; value: uint32) =
  outp.add byte(value and 0xff'u32)
  outp.add byte((value shr 8) and 0xff'u32)
  outp.add byte((value shr 16) and 0xff'u32)
  outp.add byte((value shr 24) and 0xff'u32)

proc readU32Le*(bytes: openArray[byte]; offset = 0): uint32 =
  if offset < 0 or offset + 4 > bytes.len:
    raise newException(ValueError, "truncated uint32")
  uint32(bytes[offset]) or (uint32(bytes[offset + 1]) shl 8) or
    (uint32(bytes[offset + 2]) shl 16) or
    (uint32(bytes[offset + 3]) shl 24)

proc aarch64ReturnImmediateBytes*(value: int): seq[byte] =
  if value < 0 or value > 0xffff:
    raise newException(ValueError, "AArch64 movz fixture immediate is outside uint16")
  writeU32Le(result, Aarch64MovzW0 or (uint32(value) shl 5))
  writeU32Le(result, Aarch64Ret)

proc aarch64PatchableReturnBytes*(value: int; sledNops: int): seq[byte] =
  if sledNops < 1:
    raise newException(ValueError, "patchable fixture requires at least one NOP")
  for _ in 0 ..< sledNops:
    writeU32Le(result, Aarch64Nop)
  result.add aarch64ReturnImmediateBytes(value)

proc isAarch64Nop*(word: uint32): bool =
  word == Aarch64Nop

proc isAarch64Ret*(word: uint32): bool =
  word == Aarch64Ret

proc decodeAarch64MovzW0Immediate*(word: uint32; value: var int): bool =
  if (word and 0xffe0001f'u32) != Aarch64MovzW0:
    return false
  value = int((word shr 5) and 0xffff'u32)
  true

proc aarch64BranchImm26*(sourceAddress, destinationAddress: uint64;
                         nopSledBytes: uint32): TrampolinePlan =
  if nopSledBytes < 4:
    raise newException(ValueError, "AArch64 B imm26 trampoline requires a 4-byte sled")
  let displacement = int64(destinationAddress) - int64(sourceAddress)
  if displacement mod 4 != 0:
    raise newException(ValueError, "AArch64 branch target is not 4-byte aligned")
  let words = displacement div 4
  if words < -(1'i64 shl 25) or words > (1'i64 shl 25) - 1:
    raise newException(ValueError, "AArch64 B imm26 target is out of range")
  let encoded = Aarch64Branch or uint32(words and int64(Aarch64Imm26Mask))
  result = TrampolinePlan(
    kind: tkAarch64BranchImm26,
    sourceAddress: sourceAddress,
    destinationAddress: destinationAddress,
    displacementBytes: displacement,
    bytes: @[]
  )
  writeU32Le(result.bytes, encoded)

proc decodeAarch64BranchImm26Destination*(sourceAddress: uint64;
                                          bytes: openArray[byte]): uint64 =
  let word = readU32Le(bytes)
  if (word and Aarch64BranchMask) != Aarch64Branch:
    raise newException(ValueError, "bytes do not encode an AArch64 B imm26 branch")
  let imm26 = word and Aarch64Imm26Mask
  var signedWords = int64(imm26)
  if (imm26 and 0x02000000'u32) != 0:
    signedWords -= 1'i64 shl 26
  uint64(int64(sourceAddress) + signedWords * 4)
