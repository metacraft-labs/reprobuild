import std/[os, tables]

import repro_hcr_agent/runtime
import repro_hcr_linker
import repro_hcr_linkgraph

when defined(macosx) and defined(arm64):
  import std/posix

  proc sysIcacheInvalidate(start: pointer; len: csize_t) {.
    importc: "sys_icache_invalidate", header: "<libkern/OSCacheControl.h>".}

type
  ProcessTargetSymbol* = object
    name*: string
    address*: uint64
    kind*: SymbolKind

  ProcessTargetRetainedRegion* = object
    functionName*: string
    entryAddress*: uint64
    bytes*: seq[byte]

  ProcessTargetFlushRecord* = object
    address*: uint64
    byteCount*: int

  ProcessTargetRuntime* = object
    symbols*: seq[ProcessTargetSymbol]
    symbolGenerations*: Table[string, uint64]
    allocatedRegions*: seq[TargetMemoryRegion]
    retainedRegions*: seq[ProcessTargetRetainedRegion]
    flushes*: seq[ProcessTargetFlushRecord]

proc addressFromPointer*(p: pointer): uint64 =
  uint64(cast[uint](p))

proc initProcessTargetRuntime*(
    symbols: openArray[ProcessTargetSymbol] = []): ProcessTargetRuntime =
  result.symbols = @symbols
  result.symbolGenerations = initTable[string, uint64]()

proc addProcessTargetSymbol*(target: var ProcessTargetRuntime;
                             name: string;
                             address: uint64;
                             kind = sykFunction) =
  if name.len == 0:
    raise newException(ValueError, "process target symbol name is empty")
  if address == 0:
    raise newException(ValueError, "process target symbol address is zero: " &
      name)
  for symbol in target.symbols.mitems:
    if symbol.name == name:
      symbol.address = address
      symbol.kind = kind
      return
  target.symbols.add ProcessTargetSymbol(
    name: name,
    address: address,
    kind: kind)

proc processTargetSymbolAddress*(target: ProcessTargetRuntime;
                                 name: string): uint64 =
  for symbol in target.symbols:
    if symbol.name == name:
      return symbol.address
  0

proc processResolveTargetSymbol(ctx: pointer; symbolName: string): uint64 =
  let target = cast[ptr ProcessTargetRuntime](ctx)
  target[].processTargetSymbolAddress(symbolName)

when defined(macosx) and defined(arm64):
  proc fail(message: string) {.noreturn.} =
    raise newException(ValueError, message)

  proc ptrFromAddress(address: uint64): pointer =
    cast[pointer](uint(address))

  proc mmapFailed(p: pointer): bool =
    cast[int](p) == -1

  proc hostPageSize(): int =
    let value = sysconf(SC_PAGESIZE)
    if value <= 0:
      fail("sysconf(SC_PAGESIZE) failed for process HCR target")
    int(value)

  proc pageStart(address: uint64; pageSize: int): uint64 =
    address and not(uint64(pageSize - 1))

  proc copyBytesFrom(address: uint64; byteCount: int): seq[byte] =
    if byteCount < 0:
      fail("cannot read a negative byte count from process target")
    result = newSeq[byte](byteCount)
    if byteCount > 0:
      copyMem(addr result[0], ptrFromAddress(address), byteCount)

  proc copyBytesTo(address: uint64; bytes: openArray[byte]) =
    if bytes.len > 0:
      copyMem(ptrFromAddress(address), unsafeAddr bytes[0], bytes.len)

  proc requireMprotect(address: uint64; size: int; protection: cint;
                       context: string) =
    if mprotect(ptrFromAddress(address), size, protection) != 0:
      raiseOSError(osLastError(), "mprotect failed for " & context)

  proc branchImm26Reachable(sourceAddress, destinationAddress: uint64): bool =
    if (destinationAddress and 0x3'u64) != 0:
      return false
    let displacement = int64(destinationAddress) - int64(sourceAddress)
    if displacement mod 4 != 0:
      return false
    let words = displacement div 4
    words >= -(1'i64 shl 25) and words <= (1'i64 shl 25) - 1

  proc tryMapPatchPage(hint: uint64; pageSize: int): uint64 =
    let mapped = mmap(ptrFromAddress(hint), pageSize,
      PROT_READ or PROT_WRITE, MAP_PRIVATE or MAP_ANONYMOUS, -1, 0)
    if mmapFailed(mapped):
      return 0
    addressFromPointer(mapped)

  proc unmapIfUnusable(address: uint64; pageSize: int) =
    if address != 0:
      discard munmap(ptrFromAddress(address), pageSize)

  proc mapPatchPageNear(nearAddress: uint64; pageSize: int): uint64 =
    let base = pageStart(nearAddress, pageSize)
    let maxPages = (128 * 1024 * 1024) div pageSize
    for distance in 1 .. maxPages:
      for direction in [1'i64, -1'i64]:
        let signedHint = int64(base) + direction * int64(distance * pageSize)
        if signedHint <= 0:
          continue
        let mapped = tryMapPatchPage(uint64(signedHint), pageSize)
        if mapped == 0:
          continue
        if branchImm26Reachable(nearAddress, mapped):
          return mapped
        unmapIfUnusable(mapped, pageSize)
    fail("could not allocate HCR patch memory within AArch64 B imm26 range")

  proc processReadTargetBytes(ctx: pointer; address: uint64;
                              byteCount: int): seq[byte] =
    discard ctx
    copyBytesFrom(address, byteCount)

  proc processAllocatePatchMemory(ctx: pointer; nearAddress: uint64;
                                  byteCount: int): TargetMemoryRegion =
    if byteCount <= 0:
      fail("process HCR patch allocation requires non-empty patch bytes")
    let target = cast[ptr ProcessTargetRuntime](ctx)
    let pageSize = hostPageSize()
    let pageCount = (byteCount + pageSize - 1) div pageSize
    if pageCount != 1:
      fail("process HCR target currently supports one-page direct patches")
    let mapped = mapPatchPageNear(nearAddress, pageSize)
    result = TargetMemoryRegion(
      id: "process-hcr-patch-page-" & $target[].allocatedRegions.len,
      base: mapped,
      size: uint64(pageSize),
      protection: tpReadWrite,
      kind: trkPatchCode)
    target[].allocatedRegions.add result

  proc processWritePatchBytes(ctx: pointer; region: TargetMemoryRegion;
                              bytes: seq[byte]) =
    discard ctx
    if region.protection != tpReadWrite:
      fail("process HCR patch bytes must be written while region is RW")
    if uint64(bytes.len) > region.size:
      fail("process HCR patch bytes exceed allocated region")
    copyBytesTo(region.base, bytes)

  proc processSetExecutableProtection(ctx: pointer;
                                      region: TargetMemoryRegion):
                                      TargetMemoryRegion =
    discard ctx
    requireMprotect(region.base, int(region.size), PROT_READ or PROT_EXEC,
      "process HCR patch page")
    result = region
    result.protection = tpReadExec

  proc processFlushInstructionCache(ctx: pointer; address: uint64;
                                    byteCount: int) =
    let target = cast[ptr ProcessTargetRuntime](ctx)
    if byteCount <= 0:
      fail("process HCR instruction-cache flush requires non-empty range")
    sysIcacheInvalidate(ptrFromAddress(address), csize_t(byteCount))
    target[].flushes.add ProcessTargetFlushRecord(
      address: address,
      byteCount: byteCount)

  proc processInstallTrampoline(ctx: pointer; functionName: string;
                                entryAddress: uint64;
                                trampoline: TrampolinePlan): seq[byte] =
    let target = cast[ptr ProcessTargetRuntime](ctx)
    let expectedAddress = target[].processTargetSymbolAddress(functionName)
    if expectedAddress == 0:
      fail("process HCR target has no symbol for trampoline: " & functionName)
    if expectedAddress != entryAddress:
      fail("process HCR trampoline entry mismatch for " & functionName)
    result = copyBytesFrom(entryAddress, trampoline.bytes.len)
    let pageSize = hostPageSize()
    let page = pageStart(entryAddress, pageSize)
    requireMprotect(page, pageSize, PROT_READ or PROT_WRITE,
      "process HCR original text page")
    copyBytesTo(entryAddress, trampoline.bytes)
    requireMprotect(page, pageSize, PROT_READ or PROT_EXEC,
      "process HCR original text page")

  proc processPublishSymbolGeneration(ctx: pointer; functionName: string;
                                      patchAddress: uint64;
                                      patchSize: uint64): uint64 =
    discard patchAddress
    discard patchSize
    let target = cast[ptr ProcessTargetRuntime](ctx)
    result = target[].symbolGenerations.getOrDefault(functionName, 0'u64) + 1
    target[].symbolGenerations[functionName] = result

  proc processRetainOldPatchRegion(ctx: pointer; functionName: string;
                                   entryAddress: uint64;
                                   oldEntryBytes: seq[byte]):
                                   TargetMemoryRegion =
    let target = cast[ptr ProcessTargetRuntime](ctx)
    target[].retainedRegions.add ProcessTargetRetainedRegion(
      functionName: functionName,
      entryAddress: entryAddress,
      bytes: oldEntryBytes)
    TargetMemoryRegion(
      id: "process-hcr-retained-entry-" & functionName,
      base: entryAddress,
      size: uint64(oldEntryBytes.len),
      protection: tpReadExec,
      kind: trkRetainedOldCode)

  proc close*(target: var ProcessTargetRuntime) =
    for region in target.allocatedRegions:
      discard munmap(ptrFromAddress(region.base), int(region.size))
    target.allocatedRegions.setLen(0)

  proc processTargetOps*(target: var ProcessTargetRuntime):
      TargetEnvironmentOps =
    TargetEnvironmentOps(
      ctx: addr target,
      readTargetBytes: processReadTargetBytes,
      allocatePatchMemory: processAllocatePatchMemory,
      writePatchBytes: processWritePatchBytes,
      setExecutableProtection: processSetExecutableProtection,
      flushInstructionCache: processFlushInstructionCache,
      installTrampoline: processInstallTrampoline,
      publishSymbolGeneration: processPublishSymbolGeneration,
      retainOldPatchRegion: processRetainOldPatchRegion)

else:
  proc close*(target: var ProcessTargetRuntime) =
    discard target

  proc processTargetOps*(target: var ProcessTargetRuntime):
      TargetEnvironmentOps =
    discard target
    raise newException(ValueError,
      "process HCR target currently requires macOS arm64")

proc processRuntimeOps*(target: var ProcessTargetRuntime): HcrAgentRuntimeOps =
  HcrAgentRuntimeOps(
    ctx: addr target,
    targetEnv: target.processTargetOps(),
    resolveTargetSymbol: processResolveTargetSymbol)
