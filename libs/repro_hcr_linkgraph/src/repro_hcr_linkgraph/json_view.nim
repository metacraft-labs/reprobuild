import std/[json]

import repro_hcr_linkgraph/types
import repro_hcr_linkgraph/analysis

proc `%`*(kind: SectionKind): JsonNode = newJString($kind)
proc `%`*(kind: SymbolKind): JsonNode = newJString($kind)
proc `%`*(severity: UnsupportedSeverity): JsonNode = newJString($severity)
proc `%`*(support: RelocationSupport): JsonNode = newJString($support)
proc `%`*(kind: FunctionChangeKind): JsonNode = newJString($kind)

proc linkGraphJson*(graph: LinkGraph): JsonNode =
  result = newJObject()
  result["schemaId"] = newJString(graph.schemaId)
  result["sourcePath"] = newJString(graph.sourcePath)
  result["arch"] = newJString(graph.arch)
  result["hasDebugFacts"] = newJBool(graph.hasDebugFacts)
  result["hasUnwindFacts"] = newJBool(graph.hasUnwindFacts)
  var sections = newJArray()
  for section in graph.sections:
    sections.add %*{
      "id": section.id,
      "name": section.sectionFullName,
      "size": section.size,
      "kind": $section.kind,
      "relocationCount": section.relocationIds.len
    }
  result["sections"] = sections
  var symbols = newJArray()
  for symbol in graph.symbols:
    symbols.add %*{
      "id": symbol.id,
      "name": symbol.name,
      "kind": $symbol.kind,
      "sectionId": symbol.sectionId,
      "address": symbol.address,
      "size": symbol.size,
      "defined": symbol.isDefined
    }
  result["symbols"] = symbols
  var relocations = newJArray()
  for relocation in graph.relocations:
    relocations.add %*{
      "id": relocation.id,
      "sectionId": relocation.sectionId,
      "offset": relocation.offset,
      "kind": relocation.kindName,
      "target": relocation.targetName,
      "pcrel": relocation.pcrel,
      "lengthBytes": relocation.lengthBytes,
      "extern": relocation.isExtern,
      "addend": relocation.addend
    }
  result["relocations"] = relocations
  var unsupported = newJArray()
  for feature in graph.unsupportedFeatures:
    unsupported.add %*{
      "feature": feature.feature,
      "severity": $feature.severity,
      "sectionId": feature.sectionId,
      "relocationId": feature.relocationId,
      "reason": feature.reason
    }
  result["unsupportedFeatures"] = unsupported

proc diffJson*(diff: FunctionDiffSet): JsonNode =
  result = newJObject()
  result["schemaId"] = newJString(diff.schemaId)
  var functions = newJArray()
  for entry in diff.functions:
    functions.add %*{
      "name": entry.name,
      "kind": $entry.kind,
      "oldRawDigest": entry.oldRawDigest,
      "newRawDigest": entry.newRawDigest,
      "oldNormalizedDigest": entry.oldNormalizedDigest,
      "newNormalizedDigest": entry.newNormalizedDigest,
      "rawBytesEqual": entry.rawBytesEqual,
      "normalizedBytesEqual": entry.normalizedBytesEqual,
      "relocationSignaturesEqual": entry.relocationSignaturesEqual
    }
  result["functions"] = functions

proc patchPlanJson*(plan: PatchPlanEvidence): JsonNode =
  result = newJObject()
  result["schemaId"] = newJString(plan.schemaId)
  result["supportProfile"] = newJString(plan.supportProfile)
  result["targetSnapshotId"] = newJString(plan.targetSnapshotId)
  result["changedFunctions"] = %plan.changedFunctions
  result["requiredTargetSymbols"] = %plan.requiredTargetSymbols
  result["unsupportedFallbackReasons"] = %plan.unsupportedFallbackReasons
  result["mutatesTarget"] = newJBool(plan.mutatesTarget)
  result["targetMutationOperations"] = newJInt(plan.targetMutationOperations)
  result["sharedLibraryPositivePath"] = newJBool(plan.sharedLibraryPositivePath)
  var bytes = newJArray()
  for section in plan.plannedSectionBytes:
    bytes.add %*{
      "functionName": section.functionName,
      "sectionName": section.sectionName,
      "byteCount": section.byteCount,
      "rawDigest": section.rawDigest,
      "normalizedDigest": section.normalizedDigest,
      "bytesHex": bytesHex(section.bytes)
    }
  result["plannedSectionBytes"] = bytes
  var decisions = newJArray()
  for decision in plan.relocationDecisions:
    decisions.add %*{
      "relocationId": decision.relocationId,
      "functionName": decision.functionName,
      "sectionName": decision.sectionName,
      "offsetWithinFunction": decision.offsetWithinFunction,
      "kindName": decision.kindName,
      "targetName": decision.targetName,
      "support": $decision.support,
      "reason": decision.reason,
      "requiresTargetSymbol": decision.requiresTargetSymbol,
      "targetAddress": decision.targetAddress
    }
  result["relocationDecisions"] = decisions
