import std/[algorithm, sequtils, sets]

import repro_hcr_linkgraph/types
import repro_hcr_linkgraph/analysis

proc targetAddress(snapshot: DeterministicTargetSnapshot; name: string;
                   address: var uint64): bool =
  for symbol in snapshot.symbols:
    if symbol.name == name:
      address = symbol.address
      return true
  false

proc ownerFunctionName*(graph: LinkGraph; relocation: RelocationFact): string =
  if relocation.sectionId < 0 or relocation.sectionId >= graph.sections.len:
    return ""
  let section = graph.sections[relocation.sectionId]
  for symbol in graph.functionSymbols:
    if symbol.sectionId == relocation.sectionId:
      let relocAddress = section.address + uint64(relocation.offset)
      if relocAddress >= symbol.address and relocAddress < symbol.address + symbol.size:
        return symbol.name
  ""

proc classifyElfRelocation(graph: LinkGraph; relocation: RelocationFact;
                           snapshot: DeterministicTargetSnapshot;
                           decision: var RelocationDecision) =
  ## x86_64 ELF relocation classification for the HLX-M1 profile.
  ##
  ## The supported-direct subset is deliberately narrow, and the narrowness is
  ## the point: a relocation this provider cannot apply correctly must produce
  ## a structured reason, not a plan that writes wrong bytes. Relocation
  ## *semantics* remain `Relocation-Processing.md`'s; this decides only what
  ## HLX-M1 will and will not carry.
  if relocation.sectionId < 0 or relocation.sectionId >= graph.sections.len:
    decision.reason =
      "relocation names a section index outside the object's section table"
    return
  if graph.sections[relocation.sectionId].kind != skCode:
    decision.reason = "HLX-M1 records " &
      $graph.sections[relocation.sectionId].kind &
      " relocation facts but does not apply them"
    return

  case relocation.typeCode
  of 2'u8, 4'u8:
    # R_X86_64_PC32 / R_X86_64_PLT32. A call or jump displacement relative to
    # the next instruction. Applicable once the patch body's address is known,
    # which is exactly what the provider allocates.
    decision.requiresTargetSymbol = true
    var address = 0'u64
    if not snapshot.targetAddress(relocation.targetName, address):
      decision.reason =
        "target symbol is absent from the deterministic target snapshot"
      return
    decision.targetAddress = address
    if not relocation.pcrel or relocation.lengthBytes != 4:
      decision.reason = relocation.kindName &
        " must be a 4-byte PC-relative field"
      return
    decision.support = rsSupportedDirect
    decision.reason = relocation.kindName &
      " direct displacement; the +-2 GiB reach check is deferred to patch-body " &
      "placement (HLX-M2 owns the island for targets outside it)"
  of 1'u8:
    # R_X86_64_64: an absolute 64-bit address. Applicable, and unlike the
    # 32-bit absolute forms it cannot overflow once the runtime address is
    # known.
    decision.requiresTargetSymbol = true
    var address = 0'u64
    if not snapshot.targetAddress(relocation.targetName, address):
      decision.reason =
        "target symbol is absent from the deterministic target snapshot"
      return
    decision.targetAddress = address
    if relocation.lengthBytes != 8:
      decision.reason = "R_X86_64_64 must be an 8-byte field"
      return
    decision.support = rsSupportedDirect
    decision.reason = "R_X86_64_64 absolute address"
  of 10'u8, 11'u8:
    decision.reason = relocation.kindName &
      " is a 32-bit absolute address; a PIE patch body is mapped far above " &
      "4 GiB, so the field cannot represent the runtime target"
  of 9'u8, 41'u8, 42'u8, 43'u8:
    decision.reason = relocation.kindName &
      " goes through the GOT; HLX-M1 allocates no GOT for a patch body, and " &
      "reusing the target's requires the entry to already exist"
  of 19'u8, 20'u8, 21'u8, 22'u8, 23'u8, 34'u8, 35'u8, 36'u8:
    decision.reason = relocation.kindName &
      " is a thread-local-storage relocation; TLS is outside the HLX-M1 profile"
  of 0'u8:
    decision.reason = "R_X86_64_NONE carries no fixup"
  else:
    decision.reason = relocation.kindName &
      " is outside the HLX-M1 supported-direct subset"

proc classifyRelocation*(graph: LinkGraph; relocation: RelocationFact;
                         snapshot: DeterministicTargetSnapshot): RelocationDecision =
  let section =
    if relocation.sectionId >= 0 and relocation.sectionId < graph.sections.len:
      graph.sections[relocation.sectionId]
    else:
      SectionFact(id: -1, name: "$invalid", segmentName: "$invalid")
  let functionName = graph.ownerFunctionName(relocation)
  let offsetWithin =
    if functionName.len > 0:
      let sym = graph.findSymbol(functionName)
      section.address + uint64(relocation.offset) - sym.address
    else:
      uint64(relocation.offset)

  result = RelocationDecision(
    relocationId: relocation.id,
    functionName: functionName,
    sectionName: section.sectionFullName,
    offsetWithinFunction: offsetWithin,
    kindName: relocation.kindName,
    targetName: relocation.targetName,
    support: rsUnsupported,
    reason: "unsupported relocation for M26 profile",
    requiresTargetSymbol: false,
    targetAddress: 0
  )

  if graph.format == ofElf64X86_64:
    classifyElfRelocation(graph, relocation, snapshot, result)
    return

  if relocation.scattered:
    result.reason = "scattered Mach-O relocations are rejected by M26"
    return

  if section.kind != skCode:
    result.reason = "M26 records " & $section.kind & " relocation facts but does not apply them"
    return

  if relocation.typeCode in {2'u8, 3'u8, 4'u8}:
    result.requiresTargetSymbol = true
    var address = 0'u64
    if not snapshot.targetAddress(relocation.targetName, address):
      result.reason = "target symbol is absent from deterministic target snapshot"
      return
    result.targetAddress = address
    case relocation.typeCode
    of 2:
      if not relocation.pcrel or relocation.lengthBytes != 4:
        result.reason = "ARM64 branch relocations must be pcrel long fields"
      else:
        result.support = rsSupportedDirect
        result.reason = "ARM64 BRANCH26 direct relocation; range check is deferred to target layout planning"
    of 3:
      if not relocation.pcrel or relocation.lengthBytes != 4:
        result.reason = "ARM64 PAGE21 relocations must be pcrel long fields"
      else:
        result.support = rsSupportedDirect
        result.reason = "ARM64 PAGE21 direct page relocation for M26 fixture profile"
    of 4:
      if relocation.lengthBytes != 4:
        result.reason = "ARM64 PAGEOFF12 relocations must be long fields"
      else:
        result.support = rsSupportedDirect
        result.reason = "ARM64 PAGEOFF12 direct page-offset relocation for M26 fixture profile"
    else:
      discard
    return

  if relocation.typeCode == 10:
    result.reason = "ARM64 ADDEND relocation pairing is recorded but not planned in M26"
  else:
    result.reason = "Mach-O arm64 relocation kind is outside the M26 supported-direct subset"

proc classifyRelocations*(graph: LinkGraph;
                          snapshot: DeterministicTargetSnapshot): seq[RelocationDecision] =
  for relocation in graph.relocations:
    result.add graph.classifyRelocation(relocation, snapshot)

proc patchPlan*(oldGraph, newGraph: LinkGraph;
                snapshot: DeterministicTargetSnapshot): PatchPlanEvidence =
  let diff = diffFunctions(oldGraph, newGraph)
  let classifications = classifyRelocations(newGraph, snapshot)
  var changed = initHashSet[string]()
  var required = initHashSet[string]()
  var fallback = initHashSet[string]()

  result.schemaId = "reprobuild.hcr.patch-plan-evidence.v1"
  # The Linux profile id is stated beside the M26 Mach-O one rather than
  # replacing it, so a plan says which platform's rules produced it.
  result.supportProfile =
    case newGraph.format
    of ofMachO64Arm64: "m26-macho64-arm64-object-facts"
    of ofElf64X86_64: "hlx-m1-elf64-x86-64-object-facts"
  result.targetSnapshotId = snapshot.snapshotId
  result.mutatesTarget = false
  result.targetMutationOperations = 0
  result.sharedLibraryPositivePath = false

  for feature in newGraph.unsupportedFeatures:
    if feature.severity in {usFallbackRequired, usReject}:
      fallback.incl feature.feature & ": " & feature.reason

  for entry in diff.functions:
    if entry.kind == fckUnchanged:
      continue
    changed.incl entry.name
    result.changedFunctions.add entry.name
    let symbol = newGraph.findSymbol(entry.name)
    let raw = newGraph.functionBytes(symbol)
    result.plannedSectionBytes.add PlannedSectionBytes(
      functionName: entry.name,
      sectionName: newGraph.sections[symbol.sectionId].sectionFullName,
      byteCount: uint64(raw.len),
      rawDigest: byteDigest(raw),
      normalizedDigest: byteDigest(newGraph.normalizedFunctionBytes(symbol)),
      bytes: raw
    )

  result.changedFunctions.sort()

  for decision in classifications:
    if decision.functionName.len == 0 or decision.functionName notin changed:
      continue
    result.relocationDecisions.add decision
    if decision.requiresTargetSymbol:
      required.incl decision.targetName
    if decision.support == rsUnsupported:
      fallback.incl decision.kindName & " at " & decision.sectionName &
        "+" & $decision.offsetWithinFunction & ": " & decision.reason

  result.requiredTargetSymbols = toSeq(required)
  result.requiredTargetSymbols.sort()
  result.unsupportedFallbackReasons = toSeq(fallback)
  result.unsupportedFallbackReasons.sort()
