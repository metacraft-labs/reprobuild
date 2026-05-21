import std/[json, options]

import repro_hcr_agent/debug_unwind
import repro_hcr_agent/protocol
import repro_hcr_linker
import repro_hcr_linkgraph

type
  ResolveTargetSymbolProc* = proc(ctx: pointer; symbolName: string): uint64

  HcrAgentRuntimeOps* = object
    ctx*: pointer
    targetEnv*: TargetEnvironmentOps
    resolveTargetSymbol*: ResolveTargetSymbolProc

  HcrAgentApplyResult* = object
    patchApplied*: HcrPatchApplied
    transactionEvidence*: PatchTransactionEvidence
    jitRegistration*: Option[JitRegistrationEvidence]
    unwindRegistration*: Option[UnwindRegistrationEvidence]

proc bytesOf(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc digestSourceGenerationMap*(entries: openArray[HcrSourceGenerationEntry]):
    string =
  var serialized = newJArray()
  for entry in entries:
    serialized.add %*{
      "sourcePath": entry.sourcePath,
      "generation": entry.generation,
      "snapshotDigest": entry.snapshotDigest,
      "lineTableDigest": entry.lineTableDigest
    }
  byteDigest(bytesOf($serialized))

proc requirePayloadDigest(name: string; payload: HcrProtocolPayload) =
  if payload.bytes.len == 0:
    raise newException(ValueError, name & " payload is empty")
  let actual = byteDigest(payload.bytes)
  if payload.digest != actual:
    raise newException(ValueError,
      name & " payload digest mismatch: expected " & payload.digest &
        ", got " & actual)

proc requireRuntime(runtime: HcrAgentRuntimeOps) =
  if runtime.resolveTargetSymbol.isNil:
    raise newException(ValueError, "HCR agent runtime has no symbol resolver")
  if runtime.targetEnv.readTargetBytes.isNil or
      runtime.targetEnv.allocatePatchMemory.isNil or
      runtime.targetEnv.writePatchBytes.isNil or
      runtime.targetEnv.setExecutableProtection.isNil or
      runtime.targetEnv.flushInstructionCache.isNil or
      runtime.targetEnv.installTrampoline.isNil or
      runtime.targetEnv.publishSymbolGeneration.isNil or
      runtime.targetEnv.retainOldPatchRegion.isNil:
    raise newException(ValueError, "HCR agent runtime has incomplete target ops")

proc applyDirectPatchRequest*(runtime: HcrAgentRuntimeOps;
                              request: HcrPatchRequest;
                              nopSledBytes = 16'u32;
                              registerDebugUnwind = true):
                              HcrAgentApplyResult =
  runtime.requireRuntime()
  if request.schemaId.len > 0 and request.schemaId != HcrPatchRequestSchemaId:
    raise newException(ValueError,
      "unsupported HCR patch request schema: " & request.schemaId)
  if request.mode != hpmDirect:
    raise newException(ValueError, "only direct HCR patch requests are accepted")
  if request.patchId.len == 0:
    raise newException(ValueError, "HCR patch request has empty patch id")
  if request.supportProfile.len == 0:
    raise newException(ValueError, "HCR patch request has empty support profile")
  if request.changedFunctions.len != 1:
    raise newException(ValueError,
      "direct HCR runtime currently requires exactly one changed function")
  requirePayloadDigest("directPatchPayload", request.directPatchPayload)
  requirePayloadDigest("debugObjectPayload", request.debugObjectPayload)
  requirePayloadDigest("unwindMetadataPayload", request.unwindMetadataPayload)
  if request.sourceGenerationMap.len == 0:
    raise newException(ValueError, "HCR patch request has no source generations")

  let functionName = request.changedFunctions[0]
  let targetSymbol =
    if request.targetSymbols.len > 0:
      request.targetSymbols[0]
    else:
      functionName
  let targetEntryAddress =
    runtime.resolveTargetSymbol(runtime.ctx, targetSymbol)
  if targetEntryAddress == 0:
    raise newException(ValueError, "target symbol resolved to address 0: " &
      targetSymbol)

  let plan = directPatchPlanFromBytes(functionName,
    request.directPatchPayload.bytes,
    supportProfile = request.supportProfile,
    snapshotId = request.patchId)
  let tx = patchTransactionFromPlan(plan, functionName,
    targetEntryAddress, nopSledBytes)
  result.transactionEvidence = applyPatchTransaction(runtime.targetEnv, tx)

  if registerDebugUnwind:
    result.jitRegistration =
      some(registerJitDebugObject(request.debugObjectPayload.bytes))
    result.unwindRegistration =
      some(registerDynamicEhFrame(request.unwindMetadataPayload.bytes,
        result.transactionEvidence.patchAddress,
        result.transactionEvidence.patchSize))
    result.transactionEvidence.debuggerUnwindRegistered =
      result.jitRegistration.get().success and result.unwindRegistration.get().called

  result.patchApplied = HcrPatchApplied(
    patchId: request.patchId,
    changedFunctions: request.changedFunctions,
    symbolGeneration: result.transactionEvidence.symbolGeneration,
    debugObjectDigest: request.debugObjectPayload.digest,
    unwindMetadataDigest: request.unwindMetadataPayload.digest,
    sourceGenerationMapDigest:
      digestSourceGenerationMap(request.sourceGenerationMap),
    oldCodeRetained: result.transactionEvidence.retainedRegionAddresses.len > 0,
    sharedLibraryPositivePath:
      result.transactionEvidence.sharedLibraryPositivePath)
