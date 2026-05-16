import std/[algorithm, sequtils, sets]

import repro_hash
import repro_hcr_linkgraph/types

proc hexByte(value: byte): string =
  const digits = "0123456789abcdef"
  result.add digits[int(value shr 4)]
  result.add digits[int(value and 0x0f)]

proc byteDigest*(bytes: openArray[byte]): string =
  let digest = casDigest(bytes, hdCasContent)
  "blake3-256:" & toHex(digest.bytes)

proc bytesHex*(bytes: openArray[byte]): string =
  for value in bytes:
    result.add hexByte(value)

proc sectionFullName*(section: SectionFact): string =
  section.segmentName & "," & section.name

proc findSymbolIndex*(graph: LinkGraph; name: string): int =
  for i, symbol in graph.symbols:
    if symbol.name == name:
      return i
  -1

proc findSymbol*(graph: LinkGraph; name: string): SymbolFact =
  let index = graph.findSymbolIndex(name)
  if index < 0:
    raise newException(ValueError, "symbol not found: " & name)
  graph.symbols[index]

proc functionSymbols*(graph: LinkGraph): seq[SymbolFact] =
  for symbol in graph.symbols:
    if symbol.kind == sykFunction and symbol.isDefined and symbol.size > 0:
      result.add symbol
  result.sort(proc(a, b: SymbolFact): int = cmp(a.name, b.name))

proc functionBytes*(graph: LinkGraph; symbol: SymbolFact): seq[byte] =
  if symbol.sectionId < 0 or symbol.sectionId >= graph.sections.len:
    return @[]
  let section = graph.sections[symbol.sectionId]
  if symbol.address < section.address:
    return @[]
  let offset = int(symbol.address - section.address)
  let size = int(symbol.size)
  if offset < 0 or offset + size > section.data.len:
    return @[]
  result = newSeq[byte](size)
  for i in 0 ..< size:
    result[i] = section.data[offset + i]

proc containsRelocation(symbol: SymbolFact; relocation: RelocationFact;
                        section: SectionFact): bool =
  if symbol.sectionId != relocation.sectionId:
    return false
  let relocAddress = section.address + uint64(relocation.offset)
  relocAddress >= symbol.address and relocAddress < symbol.address + symbol.size

proc relocationsForSymbol*(graph: LinkGraph; symbol: SymbolFact): seq[RelocationFact] =
  if symbol.sectionId < 0 or symbol.sectionId >= graph.sections.len:
    return @[]
  let section = graph.sections[symbol.sectionId]
  for relocation in graph.relocations:
    if containsRelocation(symbol, relocation, section):
      result.add relocation
  result.sort(proc(a, b: RelocationFact): int =
    let c = cmp(a.offset, b.offset)
    if c != 0: c else: cmp(int(a.typeCode), int(b.typeCode)))

proc relocationSignatures*(graph: LinkGraph; symbol: SymbolFact): seq[RelocationSignature] =
  if symbol.sectionId < 0 or symbol.sectionId >= graph.sections.len:
    return @[]
  let section = graph.sections[symbol.sectionId]
  for relocation in graph.relocationsForSymbol(symbol):
    result.add RelocationSignature(
      offsetWithinFunction: section.address + uint64(relocation.offset) - symbol.address,
      kindName: relocation.kindName,
      typeCode: relocation.typeCode,
      targetName: relocation.targetName,
      pcrel: relocation.pcrel,
      lengthBytes: relocation.lengthBytes,
      isExtern: relocation.isExtern,
      addend: relocation.addend
    )

proc normalizedFunctionBytes*(graph: LinkGraph; symbol: SymbolFact): seq[byte] =
  result = graph.functionBytes(symbol)
  if result.len == 0 or symbol.sectionId < 0:
    return
  let section = graph.sections[symbol.sectionId]
  for relocation in graph.relocationsForSymbol(symbol):
    let offset = int(section.address + uint64(relocation.offset) - symbol.address)
    let width = max(1, int(relocation.lengthBytes))
    for i in 0 ..< width:
      if offset + i >= 0 and offset + i < result.len:
        result[offset + i] = 0

proc functionByName(graph: LinkGraph): seq[(string, SymbolFact)] =
  for symbol in graph.functionSymbols:
    result.add (symbol.name, symbol)
  result.sort(proc(a, b: (string, SymbolFact)): int = cmp(a[0], b[0]))

proc sameSignatures(a, b: seq[RelocationSignature]): bool =
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i] != b[i]:
      return false
  true

proc diffFunctions*(oldGraph, newGraph: LinkGraph): FunctionDiffSet =
  result.schemaId = "reprobuild.hcr.function-diff.v1"
  let oldPairs = oldGraph.functionByName()
  let newPairs = newGraph.functionByName()
  var names = initHashSet[string]()
  for pair in oldPairs:
    names.incl pair[0]
  for pair in newPairs:
    names.incl pair[0]
  var sortedNames = toSeq(names)
  sortedNames.sort()

  for name in sortedNames:
    let oldIndex = oldGraph.findSymbolIndex(name)
    let newIndex = newGraph.findSymbolIndex(name)
    if oldIndex < 0:
      let newSym = newGraph.symbols[newIndex]
      let newRaw = newGraph.functionBytes(newSym)
      let newNorm = newGraph.normalizedFunctionBytes(newSym)
      result.functions.add FunctionDiff(
        name: name,
        kind: fckAdded,
        newRawDigest: byteDigest(newRaw),
        newNormalizedDigest: byteDigest(newNorm),
        rawBytesEqual: false,
        normalizedBytesEqual: false,
        relocationSignaturesEqual: false,
        newRelocations: newGraph.relocationSignatures(newSym)
      )
    elif newIndex < 0:
      let oldSym = oldGraph.symbols[oldIndex]
      let oldRaw = oldGraph.functionBytes(oldSym)
      let oldNorm = oldGraph.normalizedFunctionBytes(oldSym)
      result.functions.add FunctionDiff(
        name: name,
        kind: fckRemoved,
        oldRawDigest: byteDigest(oldRaw),
        oldNormalizedDigest: byteDigest(oldNorm),
        rawBytesEqual: false,
        normalizedBytesEqual: false,
        relocationSignaturesEqual: false,
        oldRelocations: oldGraph.relocationSignatures(oldSym)
      )
    else:
      let oldSym = oldGraph.symbols[oldIndex]
      let newSym = newGraph.symbols[newIndex]
      let oldRaw = oldGraph.functionBytes(oldSym)
      let newRaw = newGraph.functionBytes(newSym)
      let oldNorm = oldGraph.normalizedFunctionBytes(oldSym)
      let newNorm = newGraph.normalizedFunctionBytes(newSym)
      let oldRelocs = oldGraph.relocationSignatures(oldSym)
      let newRelocs = newGraph.relocationSignatures(newSym)
      let rawEqual = oldRaw == newRaw
      let normEqual = oldNorm == newNorm
      let sigEqual = sameSignatures(oldRelocs, newRelocs)
      let kind =
        if normEqual and sigEqual: fckUnchanged
        elif not sigEqual: fckRelocationSignatureChanged
        else: fckChangedCode
      result.functions.add FunctionDiff(
        name: name,
        kind: kind,
        oldRawDigest: byteDigest(oldRaw),
        newRawDigest: byteDigest(newRaw),
        oldNormalizedDigest: byteDigest(oldNorm),
        newNormalizedDigest: byteDigest(newNorm),
        rawBytesEqual: rawEqual,
        normalizedBytesEqual: normEqual,
        relocationSignaturesEqual: sigEqual,
        oldRelocations: oldRelocs,
        newRelocations: newRelocs
      )

proc changedFunctionNames*(diff: FunctionDiffSet): seq[string] =
  for entry in diff.functions:
    if entry.kind != fckUnchanged:
      result.add entry.name
