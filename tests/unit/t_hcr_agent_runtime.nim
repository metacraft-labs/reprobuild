import std/[options, unittest]

import repro_hcr_agent

const
  SupportProfile = "macos-arm64-direct-hcr-in-codetracer-v1"
  FunctionName = "reprobuild_hcr_patchable_value"
  TargetSymbol = "_reprobuild_hcr_patchable_value"

type
  FakeTarget = object
    entryAddress: uint64
    patchAddress: uint64
    oldEntryBytes: seq[byte]
    patchBytes: seq[byte]
    retainedBytes: seq[byte]
    symbolGeneration: uint64
    flushCount: int

proc fakeReadTargetBytes(ctx: pointer; address: uint64;
                         byteCount: int): seq[byte] =
  let target = cast[ptr FakeTarget](ctx)
  check address == target[].entryAddress
  result = target[].oldEntryBytes[0 ..< byteCount]

proc fakeAllocatePatchMemory(ctx: pointer; nearAddress: uint64;
                             byteCount: int): TargetMemoryRegion =
  let target = cast[ptr FakeTarget](ctx)
  check nearAddress == target[].entryAddress
  check byteCount > 0
  TargetMemoryRegion(
    id: "fake-patch-page",
    base: target[].patchAddress,
    size: 4096,
    protection: tpReadWrite,
    kind: trkPatchCode)

proc fakeWritePatchBytes(ctx: pointer; region: TargetMemoryRegion;
                         bytes: seq[byte]) =
  let target = cast[ptr FakeTarget](ctx)
  check region.base == target[].patchAddress
  target[].patchBytes = bytes

proc fakeSetExecutableProtection(ctx: pointer; region: TargetMemoryRegion):
    TargetMemoryRegion =
  discard ctx
  result = region
  result.protection = tpReadExec

proc fakeFlushInstructionCache(ctx: pointer; address: uint64; byteCount: int) =
  let target = cast[ptr FakeTarget](ctx)
  check address == target[].entryAddress or address == target[].patchAddress
  check byteCount > 0
  target[].flushCount.inc

proc fakeInstallTrampoline(ctx: pointer; functionName: string;
                           entryAddress: uint64;
                           trampoline: TrampolinePlan): seq[byte] =
  let target = cast[ptr FakeTarget](ctx)
  check functionName == FunctionName
  check entryAddress == target[].entryAddress
  check trampoline.destinationAddress == target[].patchAddress
  target[].oldEntryBytes[0 ..< trampoline.bytes.len]

proc fakePublishSymbolGeneration(ctx: pointer; functionName: string;
                                 patchAddress: uint64;
                                 patchSize: uint64): uint64 =
  let target = cast[ptr FakeTarget](ctx)
  check functionName == FunctionName
  check patchAddress == target[].patchAddress
  check patchSize == uint64(target[].patchBytes.len)
  target[].symbolGeneration.inc
  target[].symbolGeneration

proc fakeRetainOldPatchRegion(ctx: pointer; functionName: string;
                              entryAddress: uint64;
                              oldEntryBytes: seq[byte]): TargetMemoryRegion =
  let target = cast[ptr FakeTarget](ctx)
  check functionName == FunctionName
  check entryAddress == target[].entryAddress
  target[].retainedBytes = oldEntryBytes
  TargetMemoryRegion(
    id: "fake-retained-old-code",
    base: entryAddress,
    size: uint64(oldEntryBytes.len),
    protection: tpReadExec,
    kind: trkRetainedOldCode)

proc fakeResolveTargetSymbol(ctx: pointer; symbolName: string): uint64 =
  let target = cast[ptr FakeTarget](ctx)
  if symbolName == TargetSymbol or symbolName == FunctionName:
    target[].entryAddress
  else:
    0

proc runtimeOps(target: var FakeTarget): HcrAgentRuntimeOps =
  HcrAgentRuntimeOps(
    ctx: addr target,
    targetEnv: TargetEnvironmentOps(
      ctx: addr target,
      readTargetBytes: fakeReadTargetBytes,
      allocatePatchMemory: fakeAllocatePatchMemory,
      writePatchBytes: fakeWritePatchBytes,
      setExecutableProtection: fakeSetExecutableProtection,
      flushInstructionCache: fakeFlushInstructionCache,
      installTrampoline: fakeInstallTrampoline,
      publishSymbolGeneration: fakePublishSymbolGeneration,
      retainOldPatchRegion: fakeRetainOldPatchRegion),
    resolveTargetSymbol: fakeResolveTargetSymbol)

proc sampleTarget(): FakeTarget =
  FakeTarget(
    entryAddress: 0x1000_0000'u64,
    patchAddress: 0x1001_0000'u64,
    oldEntryBytes: @[byte 0x1f, 0x20, 0x03, 0xd5])

proc sampleRequest(): HcrPatchRequest =
  HcrPatchRequest(
    schemaId: HcrPatchRequestSchemaId,
    patchId: "patch-0001",
    supportProfile: SupportProfile,
    mode: hpmDirect,
    changedFunctions: @[FunctionName],
    targetSymbols: @[TargetSymbol],
    directPatchPayload: payload([byte 0x20, 0x00, 0x80, 0xd2]),
    debugObjectPayload: payload([byte 0x7f, 0x45, 0x4c, 0x46]),
    unwindMetadataPayload: payload([byte 0x10, 0x00, 0x00, 0x00]),
    sourceGenerationMap: @[
      HcrSourceGenerationEntry(
        sourcePath: "src/patchable.c",
        generation: 1,
        snapshotDigest: "blake3-256:source-generation-1",
        lineTableDigest: "blake3-256:line-table-1")
    ])

suite "HCR agent runtime":
  test "direct protocol patch request drives target transaction":
    var target = sampleTarget()
    let applied = applyDirectPatchRequest(
      runtimeOps(target),
      sampleRequest(),
      nopSledBytes = 16,
      registerDebugUnwind = false)

    check target.patchBytes == @[byte 0x20, 0x00, 0x80, 0xd2]
    check target.retainedBytes == @[byte 0x1f, 0x20, 0x03, 0xd5]
    check target.flushCount == 2
    check applied.transactionEvidence.preparationComplete
    check applied.transactionEvidence.commitComplete
    check applied.transactionEvidence.patchAddress == target.patchAddress
    check applied.patchApplied.patchId == "patch-0001"
    check applied.patchApplied.changedFunctions == @[FunctionName]
    check applied.patchApplied.symbolGeneration == 1'u64
    check applied.patchApplied.oldCodeRetained
    check not applied.patchApplied.sharedLibraryPositivePath
    check applied.patchApplied.debugObjectDigest ==
      sampleRequest().debugObjectPayload.digest
    check applied.patchApplied.unwindMetadataDigest ==
      sampleRequest().unwindMetadataPayload.digest
    check applied.patchApplied.sourceGenerationMapDigest.len > 0
    check applied.jitRegistration.isNone
    check applied.unwindRegistration.isNone

  test "runtime rejects unresolved target symbols":
    var target = sampleTarget()
    var request = sampleRequest()
    request.targetSymbols = @["_missing_symbol"]

    expect ValueError:
      discard applyDirectPatchRequest(
        runtimeOps(target), request, registerDebugUnwind = false)

  test "runtime validates payload digests before mutating target":
    var target = sampleTarget()
    var request = sampleRequest()
    request.directPatchPayload.digest = "blake3-256:wrong"

    expect ValueError:
      discard applyDirectPatchRequest(
        runtimeOps(target), request, registerDebugUnwind = false)
    check target.patchBytes.len == 0

  test "runtime currently rejects multi-function direct requests":
    var target = sampleTarget()
    var request = sampleRequest()
    request.changedFunctions.add "second_function"

    expect ValueError:
      discard applyDirectPatchRequest(
        runtimeOps(target), request, registerDebugUnwind = false)
