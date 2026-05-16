import repro_hcr_linker

when defined(macosx) and defined(arm64):
  import std/posix

  proc sysIcacheInvalidate(start: pointer; len: csize_t) {.
    importc: "sys_icache_invalidate", header: "<libkern/OSCacheControl.h>".}

type
  RealFlushRecord* = object
    address*: uint64
    byteCount*: int

  MinimalRealTarget* = object
    functionName*: string
    pageSize*: int
    arenaBase*: uint64
    arenaSize*: int
    targetEntryAddress*: uint64
    targetProtection*: TargetProtection
    patchAddress*: uint64
    patchAllocated*: bool
    patchProtection*: TargetProtection
    retainedOldEntryBytes*: seq[byte]
    symbolGeneration*: uint64
    publishedPatchAddress*: uint64
    lastTrampoline*: TrampolinePlan
    flushes*: seq[RealFlushRecord]

proc fail(message: string) {.noreturn.} =
  raise newException(ValueError, message)

when defined(macosx) and defined(arm64):
  type TargetFn = proc(): cint {.cdecl.}

  proc ptrFromAddress(address: uint64): pointer =
    cast[pointer](uint(address))

  proc addressFromPtr(p: pointer): uint64 =
    uint64(cast[uint](p))

  proc mmapFailed(p: pointer): bool =
    cast[int](p) == -1

  proc hostPageSize(): int =
    let value = sysconf(SC_PAGESIZE)
    if value <= 0:
      fail("sysconf(SC_PAGESIZE) failed in minimal HCR target")
    int(value)

  proc requireMprotect(address: uint64; size: int; protection: cint) =
    if mprotect(ptrFromAddress(address), size, protection) != 0:
      fail("mprotect failed in minimal HCR target")

  proc copyBytesTo(address: uint64; bytes: openArray[byte]) =
    if bytes.len > 0:
      copyMem(ptrFromAddress(address), unsafeAddr bytes[0], bytes.len)

  proc readBytesFrom(address: uint64; byteCount: int): seq[byte] =
    result = newSeq[byte](byteCount)
    if byteCount > 0:
      copyMem(addr result[0], ptrFromAddress(address), byteCount)

  proc initMinimalAarch64Target*(functionName: string;
                                 oldFunctionBytes: openArray[byte]):
                                 MinimalRealTarget =
    let pageSize = hostPageSize()
    let arena = mmap(nil, pageSize * 2, PROT_READ or PROT_WRITE,
      MAP_PRIVATE or MAP_ANONYMOUS, -1, 0)
    if mmapFailed(arena):
      fail("mmap failed for minimal HCR target")
    let base = addressFromPtr(arena)
    result = MinimalRealTarget(
      functionName: functionName,
      pageSize: pageSize,
      arenaBase: base,
      arenaSize: pageSize * 2,
      targetEntryAddress: base,
      targetProtection: tpReadWrite,
      patchAddress: base + uint64(pageSize),
      patchAllocated: false,
      patchProtection: tpNoAccess,
      symbolGeneration: 0,
      publishedPatchAddress: 0
    )
    copyBytesTo(result.targetEntryAddress, oldFunctionBytes)
    requireMprotect(result.targetEntryAddress, pageSize, PROT_READ or PROT_EXEC)
    result.targetProtection = tpReadExec
    if munmap(ptrFromAddress(result.patchAddress), pageSize) != 0:
      fail("munmap failed while preparing minimal HCR patch hole")

  proc close*(target: var MinimalRealTarget) =
    if target.arenaBase != 0:
      discard munmap(ptrFromAddress(target.targetEntryAddress), target.pageSize)
      if target.patchAllocated:
        discard munmap(ptrFromAddress(target.patchAddress), target.pageSize)
      target.arenaBase = 0

  proc callOriginalPointer*(target: MinimalRealTarget): int =
    let fn = cast[TargetFn](ptrFromAddress(target.targetEntryAddress))
    int(fn())

  proc realReadTargetBytes(ctx: pointer; address: uint64;
                           byteCount: int): seq[byte] =
    readBytesFrom(address, byteCount)

  proc realAllocatePatchMemory(ctx: pointer; nearAddress: uint64;
                               byteCount: int): TargetMemoryRegion =
    var target = cast[ptr MinimalRealTarget](ctx)
    if target[].patchAllocated:
      fail("minimal target supports one M27 patch allocation")
    if byteCount <= 0 or byteCount > target[].pageSize:
      fail("minimal target patch allocation exceeds one page")
    let displacement = int64(target[].patchAddress) - int64(nearAddress)
    if displacement <= 0 or displacement >= 0x0800_0000'i64:
      fail("minimal target patch page is outside AArch64 direct branch range")
    let patchMemory = mmap(ptrFromAddress(target[].patchAddress), target[].pageSize,
      PROT_READ or PROT_WRITE, MAP_PRIVATE or MAP_ANONYMOUS, -1, 0)
    if mmapFailed(patchMemory) or addressFromPtr(patchMemory) != target[].patchAddress:
      fail("mmap failed for minimal HCR patch page")
    target[].patchAllocated = true
    target[].patchProtection = tpReadWrite
    TargetMemoryRegion(
      id: "minimal-real-patch-page",
      base: target[].patchAddress,
      size: uint64(target[].pageSize),
      protection: tpReadWrite,
      kind: trkPatchCode
    )

  proc realWritePatchBytes(ctx: pointer; region: TargetMemoryRegion;
                           bytes: seq[byte]) =
    var target = cast[ptr MinimalRealTarget](ctx)
    if region.base != target[].patchAddress or target[].patchProtection != tpReadWrite:
      fail("minimal target patch writes require the RW patch page")
    copyBytesTo(region.base, bytes)

  proc realSetExecutableProtection(ctx: pointer; region: TargetMemoryRegion):
      TargetMemoryRegion =
    var target = cast[ptr MinimalRealTarget](ctx)
    if region.base != target[].patchAddress or target[].patchProtection != tpReadWrite:
      fail("minimal target can only make the current RW patch page executable")
    requireMprotect(region.base, int(region.size), PROT_READ or PROT_EXEC)
    target[].patchProtection = tpReadExec
    result = region
    result.protection = tpReadExec

  proc realFlushInstructionCache(ctx: pointer; address: uint64; byteCount: int) =
    var target = cast[ptr MinimalRealTarget](ctx)
    sysIcacheInvalidate(ptrFromAddress(address), csize_t(byteCount))
    target[].flushes.add RealFlushRecord(address: address, byteCount: byteCount)

  proc realInstallTrampoline(ctx: pointer; functionName: string;
                             entryAddress: uint64;
                             trampoline: TrampolinePlan): seq[byte] =
    var target = cast[ptr MinimalRealTarget](ctx)
    if functionName != target[].functionName:
      fail("minimal target trampoline symbol mismatch")
    if entryAddress != target[].targetEntryAddress:
      fail("minimal target trampoline entry mismatch")
    if target[].targetProtection != tpReadExec:
      fail("minimal target original code must be executable before commit")
    result = readBytesFrom(entryAddress, trampoline.bytes.len)
    requireMprotect(target[].targetEntryAddress, target[].pageSize,
      PROT_READ or PROT_WRITE)
    target[].targetProtection = tpReadWrite
    copyBytesTo(entryAddress, trampoline.bytes)
    requireMprotect(target[].targetEntryAddress, target[].pageSize,
      PROT_READ or PROT_EXEC)
    target[].targetProtection = tpReadExec
    target[].lastTrampoline = trampoline

  proc realPublishSymbolGeneration(ctx: pointer; functionName: string;
                                   patchAddress: uint64;
                                   patchSize: uint64): uint64 =
    var target = cast[ptr MinimalRealTarget](ctx)
    if functionName != target[].functionName:
      fail("minimal target publish symbol mismatch")
    discard patchSize
    target[].symbolGeneration += 1
    target[].publishedPatchAddress = patchAddress
    target[].symbolGeneration

  proc realRetainOldPatchRegion(ctx: pointer; functionName: string;
                                entryAddress: uint64;
                                oldEntryBytes: seq[byte]): TargetMemoryRegion =
    var target = cast[ptr MinimalRealTarget](ctx)
    if functionName != target[].functionName or entryAddress != target[].targetEntryAddress:
      fail("minimal target old-code retention mismatch")
    target[].retainedOldEntryBytes = oldEntryBytes
    TargetMemoryRegion(
      id: "minimal-real-retained-entry-bytes",
      base: target[].targetEntryAddress,
      size: uint64(oldEntryBytes.len),
      protection: tpReadExec,
      kind: trkRetainedOldCode
    )

  proc targetOps*(target: var MinimalRealTarget): TargetEnvironmentOps =
    TargetEnvironmentOps(
      ctx: addr target,
      readTargetBytes: realReadTargetBytes,
      allocatePatchMemory: realAllocatePatchMemory,
      writePatchBytes: realWritePatchBytes,
      setExecutableProtection: realSetExecutableProtection,
      flushInstructionCache: realFlushInstructionCache,
      installTrampoline: realInstallTrampoline,
      publishSymbolGeneration: realPublishSymbolGeneration,
      retainOldPatchRegion: realRetainOldPatchRegion
    )

else:
  proc initMinimalAarch64Target*(functionName: string;
                                 oldFunctionBytes: openArray[byte]):
                                 MinimalRealTarget =
    discard functionName
    discard oldFunctionBytes
    fail("minimal direct HCR target currently requires macOS arm64")

  proc close*(target: var MinimalRealTarget) =
    discard target

  proc callOriginalPointer*(target: MinimalRealTarget): int =
    discard target
    fail("minimal direct HCR target currently requires macOS arm64")

  proc targetOps*(target: var MinimalRealTarget): TargetEnvironmentOps =
    discard target
    fail("minimal direct HCR target currently requires macOS arm64")
