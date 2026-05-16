import repro_hcr_linkgraph
import repro_hcr_linker/types
import repro_hcr_linker/trampoline

proc operation(kind: PatchOperationKind; name: string; address: uint64;
               byteCount: uint64; protection: TargetProtection;
               commitMutation = false): PatchTransactionOperation =
  PatchTransactionOperation(
    kind: kind,
    name: name,
    address: address,
    byteCount: byteCount,
    protection: protection,
    commitMutation: commitMutation
  )

proc directPatchPlanFromBytes*(functionName: string; patchBytes: openArray[byte];
                               supportProfile = "m27-macos-arm64-direct-trampoline";
                               snapshotId = "m27-minimal-target"):
                               PatchPlanEvidence =
  result.schemaId = "reprobuild.hcr.patch-plan-evidence.v1"
  result.supportProfile = supportProfile
  result.targetSnapshotId = snapshotId
  result.changedFunctions = @[functionName]
  result.plannedSectionBytes = @[
    PlannedSectionBytes(
      functionName: functionName,
      sectionName: "__TEXT,__text",
      byteCount: uint64(patchBytes.len),
      rawDigest: byteDigest(patchBytes),
      normalizedDigest: byteDigest(patchBytes),
      bytes: @patchBytes
    )
  ]
  result.requiredTargetSymbols = @[]
  result.unsupportedFallbackReasons = @[]
  result.mutatesTarget = false
  result.targetMutationOperations = 0
  result.sharedLibraryPositivePath = false

proc patchTransactionFromPlan*(plan: PatchPlanEvidence; functionName: string;
                               targetEntryAddress: uint64;
                               nopSledBytes: uint32): PatchTransaction =
  if plan.sharedLibraryPositivePath:
    raise newException(ValueError, "shared-library patch plans cannot drive direct M27 transactions")
  for section in plan.plannedSectionBytes:
    if section.functionName == functionName:
      if section.bytes.len == 0:
        raise newException(ValueError, "patch plan has empty planned bytes")
      return PatchTransaction(
        schemaId: "reprobuild.hcr.patch-transaction.v1",
        transactionId: plan.targetSnapshotId & ":" & functionName,
        functionName: functionName,
        targetEntryAddress: targetEntryAddress,
        nopSledBytes: nopSledBytes,
        patchPlan: plan,
        patchBytes: section.bytes
      )
  raise newException(ValueError, "patch plan has no planned bytes for " & functionName)

proc applyPatchTransaction*(env: TargetEnvironmentOps;
                            tx: PatchTransaction): PatchTransactionEvidence =
  if tx.patchBytes.len == 0:
    raise newException(ValueError, "patch transaction has no patch bytes")
  if tx.nopSledBytes < 4:
    raise newException(ValueError, "patch transaction needs at least a 4-byte patchable sled")
  if tx.patchPlan.sharedLibraryPositivePath:
    raise newException(ValueError, "shared-library patch plans cannot be committed through direct transaction")

  result.schemaId = "reprobuild.hcr.patch-transaction-evidence.v1"
  result.transactionId = tx.transactionId
  result.supportProfile = tx.patchPlan.supportProfile
  result.functionName = tx.functionName
  result.patchSize = uint64(tx.patchBytes.len)
  result.sharedLibraryPositivePath = false
  result.debuggerUnwindRegistered = false

  let patchRegion = env.allocatePatchMemory(env.ctx, tx.targetEntryAddress,
    tx.patchBytes.len)
  result.patchAddress = patchRegion.base
  result.operations.add operation(pokAllocatePatchMemory, "allocate-patch-memory",
    patchRegion.base, patchRegion.size, patchRegion.protection)

  env.writePatchBytes(env.ctx, patchRegion, tx.patchBytes)
  result.operations.add operation(pokWritePatchBytes, "write-patch-bytes",
    patchRegion.base, uint64(tx.patchBytes.len), patchRegion.protection)

  let executablePatchRegion = env.setExecutableProtection(env.ctx, patchRegion)
  result.operations.add operation(pokSetExecutableProtection,
    "set-patch-memory-executable", executablePatchRegion.base,
    executablePatchRegion.size, executablePatchRegion.protection)

  env.flushInstructionCache(env.ctx, executablePatchRegion.base, tx.patchBytes.len)
  result.operations.add operation(pokFlushInstructionCache,
    "flush-patch-instruction-cache", executablePatchRegion.base,
    uint64(tx.patchBytes.len), executablePatchRegion.protection)

  result.trampoline = aarch64BranchImm26(tx.targetEntryAddress,
    executablePatchRegion.base, tx.nopSledBytes)
  result.oldEntryBytes = env.readTargetBytes(env.ctx, tx.targetEntryAddress,
    result.trampoline.bytes.len)
  let installedOldBytes = env.installTrampoline(env.ctx, tx.functionName,
    tx.targetEntryAddress, result.trampoline)
  if installedOldBytes != result.oldEntryBytes:
    raise newException(ValueError, "target changed between transaction preparation and commit")
  result.operations.add operation(pokInstallTrampoline, "install-trampoline",
    tx.targetEntryAddress, uint64(result.trampoline.bytes.len), tpReadExec,
    commitMutation = true)

  env.flushInstructionCache(env.ctx, tx.targetEntryAddress,
    result.trampoline.bytes.len)
  result.operations.add operation(pokFlushInstructionCache,
    "flush-trampoline-instruction-cache", tx.targetEntryAddress,
    uint64(result.trampoline.bytes.len), tpReadExec, commitMutation = true)

  result.symbolGeneration = env.publishSymbolGeneration(env.ctx, tx.functionName,
    executablePatchRegion.base, uint64(tx.patchBytes.len))
  result.operations.add operation(pokPublishSymbolGeneration,
    "publish-symbol-generation", executablePatchRegion.base,
    uint64(tx.patchBytes.len), executablePatchRegion.protection,
    commitMutation = true)

  let retained = env.retainOldPatchRegion(env.ctx, tx.functionName,
    tx.targetEntryAddress, result.oldEntryBytes)
  result.retainedRegionAddresses.add retained.base
  result.operations.add operation(pokRetainOldPatchRegion,
    "retain-old-patch-region", retained.base, retained.size,
    retained.protection, commitMutation = true)

  result.preparationComplete = true
  result.commitComplete = true
