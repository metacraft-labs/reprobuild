import repro_hcr_linker

type
  FakeMemoryRegion* = object
    id*: string
    base*: uint64
    size*: uint64
    protection*: TargetProtection
    kind*: TargetRegionKind
    bytes*: seq[byte]

  FakeSymbol* = object
    name*: string
    entryAddress*: uint64
    latestAddress*: uint64
    generation*: uint64

  FakeRetainedRegion* = object
    functionName*: string
    address*: uint64
    bytes*: seq[byte]

  FakeFlushRecord* = object
    address*: uint64
    byteCount*: int

  FakeTarget* = object
    pageSize*: int
    nextPatchIndex*: int
    regions*: seq[FakeMemoryRegion]
    symbols*: seq[FakeSymbol]
    retainedRegions*: seq[FakeRetainedRegion]
    flushes*: seq[FakeFlushRecord]
    trampolineWrites*: seq[TrampolinePlan]

proc pageAlign(value, pageSize: int): int =
  ((value + pageSize - 1) div pageSize) * pageSize

proc fail(message: string) {.noreturn.} =
  raise newException(ValueError, message)

proc findRegionIndex(target: FakeTarget; address: uint64; byteCount = 1): int =
  for index, region in target.regions:
    if address >= region.base and
        address + uint64(byteCount) <= region.base + region.size:
      return index
  -1

proc symbolIndex(target: FakeTarget; name: string): int =
  for index, symbol in target.symbols:
    if symbol.name == name:
      return index
  -1

proc checkWritable(region: FakeMemoryRegion) =
  if region.protection != tpReadWrite:
    fail("write requires tpReadWrite region: " & region.id)

proc checkWx(protection: TargetProtection) =
  if protection == tpReadWriteExec:
    fail("W^X violation: tpReadWriteExec is forbidden")

proc readBytes(target: FakeTarget; address: uint64; byteCount: int): seq[byte] =
  let index = target.findRegionIndex(address, byteCount)
  if index < 0:
    fail("read outside mapped fake target memory")
  let region = target.regions[index]
  let offset = int(address - region.base)
  result = newSeq[byte](byteCount)
  for i in 0 ..< byteCount:
    result[i] = region.bytes[offset + i]

proc writeBytes(target: var FakeTarget; address: uint64; bytes: openArray[byte]) =
  let index = target.findRegionIndex(address, bytes.len)
  if index < 0:
    fail("write outside mapped fake target memory")
  checkWritable(target.regions[index])
  let offset = int(address - target.regions[index].base)
  for i, value in bytes:
    target.regions[index].bytes[offset + i] = value

proc setProtection(target: var FakeTarget; address: uint64;
                   protection: TargetProtection) =
  checkWx(protection)
  let index = target.findRegionIndex(address)
  if index < 0:
    fail("protection change outside mapped fake target memory")
  target.regions[index].protection = protection

proc decodeReturnAt(target: FakeTarget; address: uint64): int =
  let bytes = target.readBytes(address, 32)
  let first = readU32Le(bytes)
  if (first and 0xfc000000'u32) == 0x14000000'u32:
    let destination = decodeAarch64BranchImm26Destination(address, bytes)
    return target.decodeReturnAt(destination)

  var pos = 0
  while pos + 4 <= bytes.len and isAarch64Nop(readU32Le(bytes, pos)):
    pos += 4
  if pos + 8 > bytes.len:
    fail("fake target function does not contain a modeled return sequence")
  var value = 0
  if not decodeAarch64MovzW0Immediate(readU32Le(bytes, pos), value):
    fail("fake target can only model movz w0,#imm; ret fixtures")
  if not isAarch64Ret(readU32Le(bytes, pos + 4)):
    fail("fake target modeled function lacks ret")
  value

proc initFakeTarget*(functionName: string; oldFunctionBytes: openArray[byte];
                     entryAddress = 0x1000_0000'u64): FakeTarget =
  result.pageSize = 4096
  let regionSize = pageAlign(max(oldFunctionBytes.len, 1), result.pageSize)
  var bytes = newSeq[byte](regionSize)
  for i, value in oldFunctionBytes:
    bytes[i] = value
  result.regions.add FakeMemoryRegion(
    id: "fake-original-text",
    base: entryAddress,
    size: uint64(regionSize),
    protection: tpReadExec,
    kind: trkOriginalText,
    bytes: bytes
  )
  result.symbols.add FakeSymbol(
    name: functionName,
    entryAddress: entryAddress,
    latestAddress: entryAddress,
    generation: 0
  )

proc entryAddress*(target: FakeTarget; functionName: string): uint64 =
  let index = target.symbolIndex(functionName)
  if index < 0:
    fail("unknown fake target symbol: " & functionName)
  target.symbols[index].entryAddress

proc latestAddress*(target: FakeTarget; functionName: string): uint64 =
  let index = target.symbolIndex(functionName)
  if index < 0:
    fail("unknown fake target symbol: " & functionName)
  target.symbols[index].latestAddress

proc symbolGeneration*(target: FakeTarget; functionName: string): uint64 =
  let index = target.symbolIndex(functionName)
  if index < 0:
    fail("unknown fake target symbol: " & functionName)
  target.symbols[index].generation

proc regionProtectionAt*(target: FakeTarget; address: uint64): TargetProtection =
  let index = target.findRegionIndex(address)
  if index < 0:
    fail("address outside fake target regions")
  target.regions[index].protection

proc callOriginalPointer*(target: FakeTarget; functionName: string): int =
  target.decodeReturnAt(target.entryAddress(functionName))

proc debugWriteBytes*(target: var FakeTarget; address: uint64;
                      bytes: openArray[byte]) =
  target.writeBytes(address, bytes)

proc debugSetProtection*(target: var FakeTarget; address: uint64;
                         protection: TargetProtection) =
  target.setProtection(address, protection)

proc fakeReadTargetBytes(ctx: pointer; address: uint64;
                         byteCount: int): seq[byte] =
  cast[ptr FakeTarget](ctx)[].readBytes(address, byteCount)

proc fakeAllocatePatchMemory(ctx: pointer; nearAddress: uint64;
                             byteCount: int): TargetMemoryRegion =
  var target = cast[ptr FakeTarget](ctx)
  let size = pageAlign(max(byteCount, 1), target[].pageSize)
  let base = nearAddress + 0x4000'u64 +
    uint64(target[].nextPatchIndex * target[].pageSize)
  let displacement = int64(base) - int64(nearAddress)
  if displacement <= 0 or displacement >= 0x0800_0000'i64:
    fail("fake target patch allocation is outside AArch64 direct-branch range")
  var bytes = newSeq[byte](size)
  let id = "fake-patch-" & $target[].nextPatchIndex
  target[].nextPatchIndex += 1
  target[].regions.add FakeMemoryRegion(
    id: id,
    base: base,
    size: uint64(size),
    protection: tpReadWrite,
    kind: trkPatchCode,
    bytes: bytes
  )
  TargetMemoryRegion(
    id: id,
    base: base,
    size: uint64(size),
    protection: tpReadWrite,
    kind: trkPatchCode
  )

proc fakeWritePatchBytes(ctx: pointer; region: TargetMemoryRegion;
                         bytes: seq[byte]) =
  cast[ptr FakeTarget](ctx)[].writeBytes(region.base, bytes)

proc fakeSetExecutableProtection(ctx: pointer; region: TargetMemoryRegion):
    TargetMemoryRegion =
  var target = cast[ptr FakeTarget](ctx)
  target[].setProtection(region.base, tpReadExec)
  result = region
  result.protection = tpReadExec

proc fakeFlushInstructionCache(ctx: pointer; address: uint64; byteCount: int) =
  var target = cast[ptr FakeTarget](ctx)
  if target[].findRegionIndex(address, byteCount) < 0:
    fail("instruction-cache flush outside mapped fake target memory")
  target[].flushes.add FakeFlushRecord(address: address, byteCount: byteCount)

proc fakeInstallTrampoline(ctx: pointer; functionName: string;
                           entryAddress: uint64;
                           trampoline: TrampolinePlan): seq[byte] =
  var target = cast[ptr FakeTarget](ctx)
  let symbolId = target[].symbolIndex(functionName)
  if symbolId < 0:
    fail("unknown fake target symbol during trampoline install: " & functionName)
  if target[].symbols[symbolId].entryAddress != entryAddress:
    fail("trampoline install entry address does not match symbol table")
  if target[].regionProtectionAt(entryAddress) != tpReadExec:
    fail("trampoline commit expects original text to start executable")
  result = target[].readBytes(entryAddress, trampoline.bytes.len)
  target[].setProtection(entryAddress, tpReadWrite)
  target[].writeBytes(entryAddress, trampoline.bytes)
  target[].setProtection(entryAddress, tpReadExec)
  target[].trampolineWrites.add trampoline

proc fakePublishSymbolGeneration(ctx: pointer; functionName: string;
                                 patchAddress: uint64;
                                 patchSize: uint64): uint64 =
  var target = cast[ptr FakeTarget](ctx)
  let index = target[].symbolIndex(functionName)
  if index < 0:
    fail("unknown fake target symbol during publish: " & functionName)
  discard patchSize
  target[].symbols[index].generation += 1
  target[].symbols[index].latestAddress = patchAddress
  target[].symbols[index].generation

proc fakeRetainOldPatchRegion(ctx: pointer; functionName: string;
                              entryAddress: uint64;
                              oldEntryBytes: seq[byte]): TargetMemoryRegion =
  var target = cast[ptr FakeTarget](ctx)
  let base = 0x2000_0000'u64 + uint64(target[].retainedRegions.len * 0x1000)
  target[].retainedRegions.add FakeRetainedRegion(
    functionName: functionName,
    address: base,
    bytes: oldEntryBytes
  )
  TargetMemoryRegion(
    id: "fake-retained-" & $target[].retainedRegions.len,
    base: base,
    size: uint64(oldEntryBytes.len),
    protection: tpReadExec,
    kind: trkRetainedOldCode
  )

proc targetOps*(target: var FakeTarget): TargetEnvironmentOps =
  TargetEnvironmentOps(
    ctx: addr target,
    readTargetBytes: fakeReadTargetBytes,
    allocatePatchMemory: fakeAllocatePatchMemory,
    writePatchBytes: fakeWritePatchBytes,
    setExecutableProtection: fakeSetExecutableProtection,
    flushInstructionCache: fakeFlushInstructionCache,
    installTrampoline: fakeInstallTrampoline,
    publishSymbolGeneration: fakePublishSymbolGeneration,
    retainOldPatchRegion: fakeRetainOldPatchRegion
  )
