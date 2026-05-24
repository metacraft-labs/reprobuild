import std/[options, os, tables, unittest]

import repro_hcr_agent

const
  SupportProfile = "macos-arm64-direct-hcr-in-codetracer-v1"
  FunctionName = "repro_hcr_process_target_entry"

when defined(macosx) and defined(arm64):
  import std/posix

  proc sysIcacheInvalidate(start: pointer; len: csize_t) {.
    importc: "sys_icache_invalidate", header: "<libkern/OSCacheControl.h>".}

  type EntryProc = proc(): cint {.cdecl.}

  proc ptrFromAddress(address: uint64): pointer =
    cast[pointer](uint(address))

  proc mmapFailed(p: pointer): bool =
    cast[int](p) == -1

  proc hostPageSize(): int =
    let value = sysconf(SC_PAGESIZE)
    if value <= 0:
      raiseOSError(osLastError(), "sysconf(SC_PAGESIZE) failed")
    int(value)

  proc requireMprotect(address: uint64; size: int; protection: cint;
                       context: string) =
    if mprotect(ptrFromAddress(address), size, protection) != 0:
      raiseOSError(osLastError(), "mprotect failed for " & context)

  proc allocateExecutableFunction(bytes: openArray[byte]):
      tuple[address: uint64; size: int] =
    let pageSize = hostPageSize()
    let mapped = mmap(nil, pageSize, PROT_READ or PROT_WRITE,
      MAP_PRIVATE or MAP_ANONYMOUS, -1, 0)
    if mmapFailed(mapped):
      raiseOSError(osLastError(), "mmap failed for process HCR test function")
    if bytes.len > 0:
      copyMem(mapped, unsafeAddr bytes[0], bytes.len)
      sysIcacheInvalidate(mapped, csize_t(bytes.len))
    result = (addressFromPointer(mapped), pageSize)
    try:
      requireMprotect(result.address, result.size, PROT_READ or PROT_EXEC,
        "process HCR test function")
    except CatchableError:
      discard munmap(mapped, pageSize)
      raise

  suite "HCR process target runtime":
    test "agent runtime patches executable memory in the current process":
      let originalBytes = aarch64ReturnImmediateBytes(11)
      let code = allocateExecutableFunction(originalBytes)
      defer: discard munmap(ptrFromAddress(code.address), code.size)
      let entry = cast[EntryProc](ptrFromAddress(code.address))

      var target = initProcessTargetRuntime()
      target.addProcessTargetSymbol(FunctionName, code.address)
      defer: target.close()

      check entry() == 11

      let request = directPatchRequest(
        patchId = "patch-process-0001",
        supportProfile = SupportProfile,
        changedFunctions = [FunctionName],
        targetSymbols = [FunctionName],
        directPatchBytes = aarch64ReturnImmediateBytes(77),
        debugObjectBytes = [byte 0x7f, 0x45, 0x4c, 0x46],
        unwindMetadataBytes = minimalAarch64EhFrameTemplate(),
        sourceGenerationMap = [
          HcrSourceGenerationEntry(
            sourcePath: "tests/unit/t_hcr_agent_process_target.nim",
            generation: 1,
            snapshotDigest: "blake3-256:process-target-generation-1",
            lineTableDigest: "blake3-256:process-target-line-table-1")
        ])
      let applied = applyDirectPatchRequest(
        processRuntimeOps(target),
        request,
        registerDebugUnwind = false)

      check entry() == 77
      check applied.patchApplied.patchId == "patch-process-0001"
      check applied.patchApplied.changedFunctions == @[FunctionName]
      check applied.patchApplied.symbolGeneration == 1'u64
      check applied.patchApplied.oldCodeRetained
      check not applied.patchApplied.sharedLibraryPositivePath
      check applied.jitRegistration.isNone
      check applied.unwindRegistration.isNone
      check target.flushes.len == 2
      check target.retainedRegions.len == 1
      check target.symbolGenerations[FunctionName] == 1'u64

else:
  suite "HCR process target runtime":
    test "process target runtime is macOS arm64-only":
      skip()
