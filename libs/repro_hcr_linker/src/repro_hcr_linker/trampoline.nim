import std/strutils

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

const
  X86_64JmpRel32Opcode* = 0xe9'u8
  X86_64JmpRel32Bytes* = 5
  X86_64PublicationWindowBytes* = 8
  X86_64Nop* = 0x90'u8

proc x86_64JmpRel32*(windowAddress, destinationAddress: uint64;
                     nopSledBytes: uint32): TrampolinePlan =
  ## Encode the Linux x86_64 published trampoline of design §4.2.
  ##
  ## ``windowAddress`` is the naturally aligned 8-byte publication window, not
  ## the function entry: under ``-fcf-protection`` the entry holds ``endbr64``
  ## and the window sits further in. The displacement is measured from the end
  ## of the five-byte instruction, as the ISA specifies.
  if nopSledBytes < uint32(X86_64PublicationWindowBytes):
    raise newException(ValueError,
      "x86_64 E9 rel32 publication requires an 8-byte aligned NOP window")
  if (windowAddress and 7'u64) != 0:
    raise newException(ValueError,
      "x86_64 publication window is not 8-byte aligned: 0x" &
        toHex(windowAddress, 16))
  let displacement =
    int64(destinationAddress) - int64(windowAddress + uint64(X86_64JmpRel32Bytes))
  if displacement < low(int32).int64 or displacement > high(int32).int64:
    raise newException(ValueError, "x86_64 E9 rel32 target is out of range")
  let rel = uint32(cast[uint32](int32(displacement)))
  result = TrampolinePlan(
    kind: tkX86_64JmpRel32,
    sourceAddress: windowAddress,
    destinationAddress: destinationAddress,
    displacementBytes: displacement,
    bytes: @[X86_64JmpRel32Opcode]
  )
  result.bytes.add byte(rel and 0xff'u32)
  result.bytes.add byte((rel shr 8) and 0xff'u32)
  result.bytes.add byte((rel shr 16) and 0xff'u32)
  result.bytes.add byte((rel shr 24) and 0xff'u32)

proc x86_64PublishedWindowBytes*(plan: TrampolinePlan): seq[byte] =
  ## The full 8-byte word actually stored: ``E9 dd dd dd dd 90 90 90``.
  if plan.kind != tkX86_64JmpRel32:
    raise newException(ValueError,
      "publication window bytes are only defined for tkX86_64JmpRel32")
  result = plan.bytes
  while result.len < X86_64PublicationWindowBytes:
    result.add X86_64Nop

proc x86_64PublishedWindowWord*(plan: TrampolinePlan): uint64 =
  ## The same word as an integer, in the little-endian order the single aligned
  ## store writes it.
  let bytes = x86_64PublishedWindowBytes(plan)
  for i in countdown(X86_64PublicationWindowBytes - 1, 0):
    result = (result shl 8) or uint64(bytes[i])

proc decodeX86_64JmpRel32Destination*(windowAddress: uint64;
                                      bytes: openArray[byte]): uint64 =
  if bytes.len < X86_64JmpRel32Bytes:
    raise newException(ValueError, "truncated x86_64 E9 rel32 trampoline")
  if bytes[0] != X86_64JmpRel32Opcode:
    raise newException(ValueError, "bytes do not encode an x86_64 E9 rel32 jump")
  let rel = uint32(bytes[1]) or (uint32(bytes[2]) shl 8) or
    (uint32(bytes[3]) shl 16) or (uint32(bytes[4]) shl 24)
  let displacement = int64(cast[int32](rel))
  uint64(int64(windowAddress + uint64(X86_64JmpRel32Bytes)) + displacement)

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
