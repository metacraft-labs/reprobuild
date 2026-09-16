## Windows x86_64 direct-patch bundle (HWG-M1).
##
## The protocol's `directPatchPayload.bytes` is profile-specific. For the
## Windows profile it carries the target PE/PDB identity and linked-image
## geometry beside a coordinator-prepared COFF code/unwind region. All fields
## are fixed-width little-endian and every variable range is bounded by the
## declared total before it is exposed to the in-process C agent.

import std/strutils

import repro_hcr_linkgraph/[analysis, coff, types, windows_symbols,
                            windows_unwind]

const
  WindowsDirectPatchMagic* = [
    byte 'R', byte 'H', byte 'W', byte 'D', byte 'P', byte '1', 0'u8, 0'u8]
  WindowsDirectPatchVersion* = 1'u16
  WindowsDirectPatchHeaderBytes* = 128'u16
  WindowsDirectPatchExpectedPaddingBytes* = 6
  WindowsDirectPatchMaxInstructionBytes* = 15

type
  WindowsDirectPatchBundle* = object
    targetIdentity*: WindowsPdbIdentity
    targetRva*: uint32
    firstInstructionLength*: uint32
    expectedPadding*: array[WindowsDirectPatchExpectedPaddingBytes, byte]
    expectedFirstInstruction*:
      array[WindowsDirectPatchMaxInstructionBytes, byte]
    regionBytes*: seq[byte]
    functionTableOffset*: uint32
    functionTableCount*: uint32
    functionEntryOffsets*: seq[uint32]
    replacementEntryOffset*: uint32

proc alignUp(value, alignment: int): int =
  if alignment <= 0 or (alignment and (alignment - 1)) != 0:
    raise newException(ValueError, "alignment must be a power of two")
  if value > high(int) - (alignment - 1):
    raise newException(ValueError, "Windows bundle alignment overflow")
  (value + alignment - 1) and not (alignment - 1)

proc putU16(bytes: var seq[byte]; offset: int; value: uint16) =
  if offset < 0 or offset + 2 > bytes.len:
    raise newException(ValueError, "Windows bundle uint16 write out of range")
  bytes[offset] = byte(value and 0xff'u16)
  bytes[offset + 1] = byte(value shr 8)

proc putU32(bytes: var seq[byte]; offset: int; value: uint32) =
  if offset < 0 or offset + 4 > bytes.len:
    raise newException(ValueError, "Windows bundle uint32 write out of range")
  for index in 0 ..< 4:
    bytes[offset + index] = byte((value shr (index * 8)) and 0xff'u32)

proc getU16(bytes: openArray[byte]; offset: int): uint16 =
  if offset < 0 or offset + 2 > bytes.len:
    raise newException(ValueError, "truncated Windows bundle uint16")
  uint16(bytes[offset]) or (uint16(bytes[offset + 1]) shl 8)

proc getU32(bytes: openArray[byte]; offset: int): uint32 =
  if offset < 0 or offset + 4 > bytes.len:
    raise newException(ValueError, "truncated Windows bundle uint32")
  uint32(bytes[offset]) or (uint32(bytes[offset + 1]) shl 8) or
    (uint32(bytes[offset + 2]) shl 16) or
    (uint32(bytes[offset + 3]) shl 24)

proc rangeOk(total, offset, count: int): bool =
  offset >= 0 and count >= 0 and offset <= total and count <= total - offset

proc sha256Bytes(bytes: openArray[byte]): array[32, byte] =
  ## Use the same compact C implementation as the in-process agent, so this
  ## digest crosses an implementation/language boundary instead of comparing a
  ## value with itself. The digest covers the prepared region, whose corruption
  ## is the executable-data hazard.
  when defined(windows):
    discard
  # `repro_hcr_agent` owns the in-process wire SHA implementation, but
  # linkgraph cannot depend upward on that library. This independent compact
  # implementation keeps bundle construction in the coordinator layer and is
  # checked against the C implementation by the end-to-end gate.
  const k: array[64, uint32] = [
    0x428a2f98'u32,0x71374491'u32,0xb5c0fbcf'u32,0xe9b5dba5'u32,
    0x3956c25b'u32,0x59f111f1'u32,0x923f82a4'u32,0xab1c5ed5'u32,
    0xd807aa98'u32,0x12835b01'u32,0x243185be'u32,0x550c7dc3'u32,
    0x72be5d74'u32,0x80deb1fe'u32,0x9bdc06a7'u32,0xc19bf174'u32,
    0xe49b69c1'u32,0xefbe4786'u32,0x0fc19dc6'u32,0x240ca1cc'u32,
    0x2de92c6f'u32,0x4a7484aa'u32,0x5cb0a9dc'u32,0x76f988da'u32,
    0x983e5152'u32,0xa831c66d'u32,0xb00327c8'u32,0xbf597fc7'u32,
    0xc6e00bf3'u32,0xd5a79147'u32,0x06ca6351'u32,0x14292967'u32,
    0x27b70a85'u32,0x2e1b2138'u32,0x4d2c6dfc'u32,0x53380d13'u32,
    0x650a7354'u32,0x766a0abb'u32,0x81c2c92e'u32,0x92722c85'u32,
    0xa2bfe8a1'u32,0xa81a664b'u32,0xc24b8b70'u32,0xc76c51a3'u32,
    0xd192e819'u32,0xd6990624'u32,0xf40e3585'u32,0x106aa070'u32,
    0x19a4c116'u32,0x1e376c08'u32,0x2748774c'u32,0x34b0bcb5'u32,
    0x391c0cb3'u32,0x4ed8aa4a'u32,0x5b9cca4f'u32,0x682e6ff3'u32,
    0x748f82ee'u32,0x78a5636f'u32,0x84c87814'u32,0x8cc70208'u32,
    0x90befffa'u32,0xa4506ceb'u32,0xbef9a3f7'u32,0xc67178f2'u32]
  proc rotr(value: uint32; bits: int): uint32 =
    (value shr uint32(bits)) or (value shl uint32(32 - bits))
  var data = @bytes
  let bitLength = uint64(data.len) * 8'u64
  data.add 0x80'u8
  while data.len mod 64 != 56:
    data.add 0'u8
  for shift in countdown(56, 0, 8):
    data.add byte((bitLength shr uint64(shift)) and 0xff'u64)
  var h = [0x6a09e667'u32,0xbb67ae85'u32,0x3c6ef372'u32,
           0xa54ff53a'u32,0x510e527f'u32,0x9b05688c'u32,
           0x1f83d9ab'u32,0x5be0cd19'u32]
  for blockOffset in countup(0, data.len - 64, 64):
    var w: array[64, uint32]
    for i in 0 ..< 16:
      w[i] = (uint32(data[blockOffset + i*4]) shl 24) or
        (uint32(data[blockOffset + i*4+1]) shl 16) or
        (uint32(data[blockOffset + i*4+2]) shl 8) or
        uint32(data[blockOffset + i*4+3])
    for i in 16 ..< 64:
      let s0 = rotr(w[i-15],7) xor rotr(w[i-15],18) xor (w[i-15] shr 3)
      let s1 = rotr(w[i-2],17) xor rotr(w[i-2],19) xor (w[i-2] shr 10)
      w[i] = w[i-16] + s0 + w[i-7] + s1
    var a=h[0]; var b=h[1]; var c=h[2]; var d=h[3]
    var e=h[4]; var f=h[5]; var g=h[6]; var hh=h[7]
    for i in 0 ..< 64:
      let s1=rotr(e,6) xor rotr(e,11) xor rotr(e,25)
      let ch=(e and f) xor ((not e) and g)
      let t1=hh+s1+ch+k[i]+w[i]
      let s0=rotr(a,2) xor rotr(a,13) xor rotr(a,22)
      let maj=(a and b) xor (a and c) xor (b and c)
      let t2=s0+maj
      hh=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2
    h[0]+=a; h[1]+=b; h[2]+=c; h[3]+=d
    h[4]+=e; h[5]+=f; h[6]+=g; h[7]+=hh
  for i in 0 ..< 8:
    result[i*4]=byte(h[i] shr 24); result[i*4+1]=byte(h[i] shr 16)
    result[i*4+2]=byte(h[i] shr 8); result[i*4+3]=byte(h[i])

proc encodeWindowsDirectPatchBundle*(
    bundle: WindowsDirectPatchBundle): seq[byte] =
  if bundle.targetRva < WindowsDirectPatchExpectedPaddingBytes.uint32:
    raise newException(ValueError, "target RVA has no six-byte pre-entry range")
  if bundle.firstInstructionLength < 2 or
      bundle.firstInstructionLength > WindowsDirectPatchMaxInstructionBytes.uint32:
    raise newException(ValueError, "unsupported Windows first-instruction length")
  if bundle.regionBytes.len == 0 or bundle.functionTableCount == 0 or
      bundle.functionEntryOffsets.len == 0:
    raise newException(ValueError, "Windows patch region is empty")
  if bundle.functionTableCount.uint64 > uint64(high(int)) or
      bundle.functionEntryOffsets.len != int(bundle.functionTableCount):
    raise newException(ValueError,
      "Windows function-table and entry counts differ")
  if bundle.replacementEntryOffset notin bundle.functionEntryOffsets:
    raise newException(ValueError,
      "replacement entry is absent from the prepared CFG entry set")
  let entriesOffset = int(WindowsDirectPatchHeaderBytes)
  let regionOffset = alignUp(entriesOffset +
    bundle.functionEntryOffsets.len * 4, 16)
  if bundle.regionBytes.len > high(int) - regionOffset or
      regionOffset > int(high(uint32)) or
      bundle.regionBytes.len > int(high(uint32)):
    raise newException(ValueError, "Windows patch bundle is too large")
  let total = regionOffset + bundle.regionBytes.len
  result = newSeq[byte](total)
  for index, value in WindowsDirectPatchMagic:
    result[index] = value
  putU16(result, 8, WindowsDirectPatchVersion)
  putU16(result, 10, WindowsDirectPatchHeaderBytes)
  putU32(result, 12, uint32(total))
  for index, value in bundle.targetIdentity.guid:
    result[16 + index] = value
  putU32(result, 32, bundle.targetIdentity.age)
  putU32(result, 36, bundle.targetRva)
  putU32(result, 40, bundle.firstInstructionLength)
  for index, value in bundle.expectedPadding:
    result[44 + index] = value
  for index, value in bundle.expectedFirstInstruction:
    result[52 + index] = value
  putU32(result, 68, uint32(regionOffset))
  putU32(result, 72, uint32(bundle.regionBytes.len))
  putU32(result, 76, bundle.functionTableOffset)
  putU32(result, 80, bundle.functionTableCount)
  putU32(result, 84, bundle.replacementEntryOffset)
  putU32(result, 88, uint32(entriesOffset))
  putU32(result, 92, uint32(bundle.functionEntryOffsets.len))
  let regionDigest = sha256Bytes(bundle.regionBytes)
  for index, value in regionDigest:
    result[96 + index] = value
  for index, value in bundle.functionEntryOffsets:
    putU32(result, entriesOffset + index * 4, value)
  for index, value in bundle.regionBytes:
    result[regionOffset + index] = value

proc decodeWindowsDirectPatchBundle*(
    bytes: openArray[byte]): WindowsDirectPatchBundle =
  if bytes.len < int(WindowsDirectPatchHeaderBytes):
    raise newException(ValueError, "windows-patch-bundle-invalid: truncated header")
  for index, value in WindowsDirectPatchMagic:
    if bytes[index] != value:
      raise newException(ValueError, "windows-patch-bundle-invalid: bad magic")
  if getU16(bytes, 8) != WindowsDirectPatchVersion or
      getU16(bytes, 10) != WindowsDirectPatchHeaderBytes or
      getU32(bytes, 12) != uint32(bytes.len):
    raise newException(ValueError,
      "windows-patch-bundle-invalid: version/header/length mismatch")
  for index in 0 ..< result.targetIdentity.guid.len:
    result.targetIdentity.guid[index] = bytes[16 + index]
  result.targetIdentity.age = getU32(bytes, 32)
  result.targetRva = getU32(bytes, 36)
  result.firstInstructionLength = getU32(bytes, 40)
  for index in 0 ..< result.expectedPadding.len:
    result.expectedPadding[index] = bytes[44 + index]
  for index in 0 ..< result.expectedFirstInstruction.len:
    result.expectedFirstInstruction[index] = bytes[52 + index]
  let regionOffset = int(getU32(bytes, 68))
  let regionSize = int(getU32(bytes, 72))
  result.functionTableOffset = getU32(bytes, 76)
  result.functionTableCount = getU32(bytes, 80)
  result.replacementEntryOffset = getU32(bytes, 84)
  let entriesOffset = int(getU32(bytes, 88))
  let entryCount = int(getU32(bytes, 92))
  if result.firstInstructionLength < 2 or
      result.firstInstructionLength > WindowsDirectPatchMaxInstructionBytes.uint32 or
      entryCount <= 0 or uint32(entryCount) != result.functionTableCount or
      not rangeOk(bytes.len, entriesOffset, entryCount * 4) or
      not rangeOk(bytes.len, regionOffset, regionSize) or
      regionOffset mod 16 != 0:
    raise newException(ValueError,
      "windows-patch-bundle-invalid: offsets/counts/geometry")
  for index in 0 ..< entryCount:
    result.functionEntryOffsets.add getU32(bytes, entriesOffset + index * 4)
  result.regionBytes = @bytes[regionOffset ..< regionOffset + regionSize]
  let actualDigest = sha256Bytes(result.regionBytes)
  for index, value in actualDigest:
    if bytes[96 + index] != value:
      raise newException(ValueError,
        "windows-patch-bundle-invalid: region digest mismatch")
  if result.replacementEntryOffset notin result.functionEntryOffsets:
    raise newException(ValueError,
      "windows-patch-bundle-invalid: replacement entry is not CFG-admitted")

proc buildWindowsDirectPatchBundle*(
    targetImage, targetPdb, targetSymbol, patchObject, patchSymbol: string;
    firstInstructionLength: uint32): WindowsDirectPatchBundle =
  let imageFacts = parsePeCodeViewFacts(targetImage)
  let pdbIdentity =
    try:
      parsePdbIdentity(targetPdb)
    except CatchableError as failure:
      raise newException(ValueError,
        "pdb-identity-unreadable: " & failure.msg)
  if imageFacts.identity != pdbIdentity:
    raise newException(ValueError, "pe-pdb-identity-mismatch")
  let target = resolveWindowsPdbFunction(targetImage, targetPdb, targetSymbol)
  if target.status != wprsOk or target.matchCount != 1 or
      target.rva < WindowsDirectPatchExpectedPaddingBytes.uint64 or
      target.rva > uint64(high(uint32)):
    raise newException(ValueError,
      "Windows target symbol did not resolve exactly once: " & target.reason)
  if firstInstructionLength < 2 or
      firstInstructionLength > WindowsDirectPatchMaxInstructionBytes.uint32:
    raise newException(ValueError, "unsupported Windows first-instruction length")
  let linked =
    try:
      readPeImageBytesAtRva(
        targetImage,
        target.rva - WindowsDirectPatchExpectedPaddingBytes.uint64,
        WindowsDirectPatchExpectedPaddingBytes +
          WindowsDirectPatchMaxInstructionBytes)
    except CatchableError as failure:
      raise newException(ValueError,
        "no-patchable-entry: six-byte pre-entry range is unavailable (" &
        failure.msg & ")")
  for index in 0 ..< result.expectedPadding.len:
    result.expectedPadding[index] = linked[index]
    if result.expectedPadding[index] != 0xcc'u8:
      raise newException(ValueError, "no-patchable-entry: pre-entry byte is not CC")
  for index in 0 ..< result.expectedFirstInstruction.len:
    result.expectedFirstInstruction[index] =
      linked[WindowsDirectPatchExpectedPaddingBytes + index]

  var coffFacts: CoffObjectFacts
  let graph = parseCoffAmd64Object(patchObject, coffFacts)
  let replacement = graph.findSymbol(patchSymbol)
  if not replacement.isDefined or replacement.kind != sykFunction:
    raise newException(ValueError, "COFF replacement symbol is not a function")
  let relocations = graph.relocationsForSymbol(replacement)
  if relocations.len != 0:
    var descriptions: seq[string]
    for relocation in relocations:
      descriptions.add relocation.kindName & "->" & relocation.targetName
    let detail = descriptions.join(", ")
    raise newException(ValueError, "edit-carries-relocations: " & detail)
  let layout = buildCoffAmd64WindowsUnwindLayout(graph)
  if layout.functionEntryOffsets.len != 1:
    raise newException(ValueError,
      "Windows direct v1 patch object must contain exactly one function")
  result.targetIdentity = imageFacts.identity
  result.targetRva = uint32(target.rva)
  result.firstInstructionLength = firstInstructionLength
  result.regionBytes = layout.bytes
  result.functionTableOffset = layout.functionTableOffset
  result.functionTableCount = layout.functionTableCount
  result.functionEntryOffsets = layout.functionEntryOffsets
  result.replacementEntryOffset = layout.functionEntryOffsets[0]
