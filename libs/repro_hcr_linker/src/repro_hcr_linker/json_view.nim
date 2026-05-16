import std/json

import repro_hcr_linkgraph
import repro_hcr_linker/types

proc `%`*(protection: TargetProtection): JsonNode = newJString($protection)
proc `%`*(kind: TargetRegionKind): JsonNode = newJString($kind)
proc `%`*(kind: TrampolineKind): JsonNode = newJString($kind)
proc `%`*(kind: PatchOperationKind): JsonNode = newJString($kind)

proc trampolineJson*(trampoline: TrampolinePlan): JsonNode =
  %*{
    "kind": $trampoline.kind,
    "sourceAddress": trampoline.sourceAddress,
    "destinationAddress": trampoline.destinationAddress,
    "displacementBytes": trampoline.displacementBytes,
    "bytesHex": bytesHex(trampoline.bytes)
  }

proc transactionEvidenceJson*(evidence: PatchTransactionEvidence): JsonNode =
  result = newJObject()
  result["schemaId"] = newJString(evidence.schemaId)
  result["transactionId"] = newJString(evidence.transactionId)
  result["supportProfile"] = newJString(evidence.supportProfile)
  result["functionName"] = newJString(evidence.functionName)
  result["preparationComplete"] = newJBool(evidence.preparationComplete)
  result["commitComplete"] = newJBool(evidence.commitComplete)
  result["patchAddress"] = newJInt(BiggestInt(evidence.patchAddress))
  result["patchSize"] = newJInt(BiggestInt(evidence.patchSize))
  result["trampoline"] = trampolineJson(evidence.trampoline)
  result["oldEntryBytesHex"] = newJString(bytesHex(evidence.oldEntryBytes))
  result["retainedRegionAddresses"] = %evidence.retainedRegionAddresses
  result["symbolGeneration"] = newJInt(BiggestInt(evidence.symbolGeneration))
  result["sharedLibraryPositivePath"] =
    newJBool(evidence.sharedLibraryPositivePath)
  result["debuggerUnwindRegistered"] =
    newJBool(evidence.debuggerUnwindRegistered)
  var operations = newJArray()
  for op in evidence.operations:
    operations.add %*{
      "kind": $op.kind,
      "name": op.name,
      "address": op.address,
      "byteCount": op.byteCount,
      "protection": $op.protection,
      "commitMutation": op.commitMutation
    }
  result["operations"] = operations
