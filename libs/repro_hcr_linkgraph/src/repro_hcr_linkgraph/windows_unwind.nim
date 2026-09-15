## Windows x86_64 patch-region layout for compiler-owned COFF unwind records.
##
## This is coordinator-side preparation. It copies code and `.xdata`, applies
## `.pdata` IMAGE_REL_AMD64_ADDR32NB relocations against one explicit region
## base, validates every UNWIND_INFO reference, and emits a sorted retained
## RUNTIME_FUNCTION table. The in-process registration itself lives in
## `repro_hcr_windows_unwind_cfg.h`.

import std/[algorithm, sequtils, sets]

import repro_hcr_linkgraph/types

type
  WindowsRuntimeFunction* = object
    beginAddress*: uint32
    endAddress*: uint32
    unwindData*: uint32

  WindowsUnwindLayout* = object
    schemaId*: string
    bytes*: seq[byte]
    functionTableOffset*: uint32
    functionTableCount*: uint32
    functions*: seq[WindowsRuntimeFunction]
    functionEntryOffsets*: seq[uint32]

proc alignUp(value, alignment: uint64): uint64 =
  if alignment == 0 or (alignment and (alignment - 1)) != 0:
    raise newException(ValueError, "alignment must be a non-zero power of two")
  if value > high(uint64) - (alignment - 1):
    raise newException(ValueError, "patch-region alignment overflow")
  (value + alignment - 1) and not (alignment - 1)

proc readU32Le(bytes: openArray[byte]; offset: int): uint32 =
  if offset < 0 or offset + 4 > bytes.len:
    raise newException(ValueError, "truncated Windows unwind uint32")
  uint32(bytes[offset]) or
    (uint32(bytes[offset + 1]) shl 8) or
    (uint32(bytes[offset + 2]) shl 16) or
    (uint32(bytes[offset + 3]) shl 24)

proc writeU32Le(bytes: var seq[byte]; offset: int; value: uint32) =
  if offset < 0 or offset + 4 > bytes.len:
    raise newException(ValueError, "Windows unwind uint32 write is out of range")
  for index in 0 ..< 4:
    bytes[offset + index] = byte((value shr (index * 8)) and 0xff'u32)

proc sectionForRva(offsets: openArray[uint64]; graph: LinkGraph;
                   rva: uint32): int =
  for sectionId, offset in offsets:
    if offset == high(uint64):
      continue
    let size = uint64(graph.sections[sectionId].data.len)
    if uint64(rva) >= offset and uint64(rva) < offset + size:
      return sectionId
  -1

proc buildCoffAmd64WindowsUnwindLayout*(graph: LinkGraph): WindowsUnwindLayout =
  if graph.format != ofCoffAmd64 or graph.arch != "coff/x86-64":
    raise newException(ValueError, "Windows unwind layout requires AMD64 COFF")
  var sectionOffsets = newSeqWith(graph.sections.len, high(uint64))
  var cursor = 0'u64
  var pdataSections: seq[int]
  var xdataSections: seq[int]
  var codeSections: seq[int]
  for section in graph.sections:
    if section.kind == skCode and section.data.len > 0:
      codeSections.add section.id
    elif section.name == ".xdata" and section.data.len > 0:
      xdataSections.add section.id
    elif section.name == ".pdata" and section.data.len > 0:
      pdataSections.add section.id
  if codeSections.len == 0:
    raise newException(ValueError, "unwind-metadata-missing-or-invalid: no code")
  if xdataSections.len == 0 or pdataSections.len == 0:
    raise newException(ValueError,
      "unwind-metadata-missing-or-invalid: COFF lacks .pdata or .xdata")
  for sectionId in codeSections:
    if graph.sections[sectionId].relocationIds.len != 0:
      raise newException(ValueError,
        "unwind-metadata-missing-or-invalid: code relocations must be " &
        "applied before Windows unwind layout")
  for sectionId in xdataSections:
    if graph.sections[sectionId].relocationIds.len != 0:
      raise newException(ValueError,
        "unwind-metadata-missing-or-invalid: .xdata relocations are outside " &
        "the HX-W-4 direct subset")

  for sectionId in codeSections & xdataSections & pdataSections:
    let section = graph.sections[sectionId]
    let declaredAlignment =
      if section.alignmentPower >= 31: 0'u64
      else: 1'u64 shl section.alignmentPower
    let minimumAlignment =
      if section.kind == skCode: 16'u64 else: 4'u64
    cursor = alignUp(cursor, max(declaredAlignment, minimumAlignment))
    if cursor > uint64(high(uint32)) or
        uint64(section.data.len) > uint64(high(uint32)) - cursor:
      raise newException(ValueError, "Windows patch region exceeds 32-bit RVA")
    sectionOffsets[sectionId] = cursor
    cursor += uint64(section.data.len)
  result.bytes = newSeq[byte](int(cursor))
  for sectionId, offset in sectionOffsets:
    if offset == high(uint64):
      continue
    for index, value in graph.sections[sectionId].data:
      result.bytes[int(offset) + index] = value

  for pdataId in pdataSections:
    let pdata = graph.sections[pdataId]
    if pdata.data.len mod 12 != 0:
      raise newException(ValueError,
        "unwind-metadata-missing-or-invalid: .pdata size is not a multiple of 12")
    if pdata.relocationIds.len != (pdata.data.len div 12) * 3:
      raise newException(ValueError,
        "unwind-metadata-missing-or-invalid: every .pdata field needs one relocation")
    var relocatedFields = initHashSet[uint32]()
    for relocationId in pdata.relocationIds:
      let relocation = graph.relocations[relocationId]
      if relocation.typeCode != 3'u8 or relocation.lengthBytes != 4 or
          relocation.pcrel:
        raise newException(ValueError,
          "unwind-metadata-missing-or-invalid: .pdata requires ADDR32NB")
      if relocation.offset mod 4'u32 != 0'u32 or
          relocation.offset >= uint32(pdata.data.len) or
          relocation.offset in relocatedFields:
        raise newException(ValueError,
          "unwind-metadata-missing-or-invalid: duplicate or misaligned .pdata field")
      relocatedFields.incl relocation.offset
      if relocation.symbolIndex < 0 or
          relocation.symbolIndex >= graph.symbols.len:
        raise newException(ValueError,
          "unwind-metadata-missing-or-invalid: .pdata symbol is invalid")
      let symbol = graph.symbols[relocation.symbolIndex]
      if not symbol.isDefined or symbol.sectionId < 0 or
          symbol.sectionId >= sectionOffsets.len or
          sectionOffsets[symbol.sectionId] == high(uint64):
        raise newException(ValueError,
          "unwind-metadata-missing-or-invalid: .pdata target is not retained")
      let value = int64(sectionOffsets[symbol.sectionId]) +
        int64(symbol.address) + relocation.addend
      if value < 0 or value > int64(high(uint32)):
        raise newException(ValueError,
          "unwind-metadata-missing-or-invalid: .pdata RVA overflows")
      writeU32Le(result.bytes,
        int(sectionOffsets[pdataId]) + int(relocation.offset), uint32(value))
    if result.functionTableCount != 0:
      raise newException(ValueError,
        "unwind-metadata-missing-or-invalid: multiple .pdata sections")
    result.functionTableOffset = uint32(sectionOffsets[pdataId])
    result.functionTableCount = uint32(pdata.data.len div 12)

  for index in 0 ..< int(result.functionTableCount):
    let offset = int(result.functionTableOffset) + index * 12
    result.functions.add WindowsRuntimeFunction(
      beginAddress: readU32Le(result.bytes, offset),
      endAddress: readU32Le(result.bytes, offset + 4),
      unwindData: readU32Le(result.bytes, offset + 8))
  result.functions.sort(proc(left, right: WindowsRuntimeFunction): int =
    cmp(left.beginAddress, right.beginAddress))
  for index, entry in result.functions:
    if entry.beginAddress >= entry.endAddress or
        uint64(entry.endAddress) > uint64(result.bytes.len):
      raise newException(ValueError,
        "unwind-metadata-missing-or-invalid: function range is invalid")
    if index > 0 and result.functions[index - 1].endAddress > entry.beginAddress:
      raise newException(ValueError,
        "unwind-metadata-missing-or-invalid: function ranges overlap")
    let xdataSection = sectionForRva(sectionOffsets, graph, entry.unwindData)
    if xdataSection < 0 or graph.sections[xdataSection].name != ".xdata":
      raise newException(ValueError,
        "unwind-metadata-missing-or-invalid: UNWIND_INFO is outside .xdata")
    let xdataLocal = int(uint64(entry.unwindData) - sectionOffsets[xdataSection])
    let xdata = graph.sections[xdataSection].data
    if xdataLocal + 4 > xdata.len or (xdata[xdataLocal] and 0x07'u8) != 1'u8:
      raise newException(ValueError,
        "unwind-metadata-missing-or-invalid: invalid UNWIND_INFO header")
    let slotCount = int(xdata[xdataLocal + 2])
    let paddedSlots = (slotCount + 1) and not 1
    let flags = xdata[xdataLocal] shr 3
    let trailing = if (flags and 0x04'u8) != 0: 12 else:
      (if (flags and 0x03'u8) != 0: 4 else: 0)
    if xdataLocal + 4 + paddedSlots * 2 + trailing > xdata.len:
      raise newException(ValueError,
        "unwind-metadata-missing-or-invalid: truncated UNWIND_INFO")
    result.functionEntryOffsets.add entry.beginAddress

  # RtlAddFunctionTable consumes the retained bytes, so write the validated
  # sorted order back into that exact table rather than sorting only evidence.
  for index, entry in result.functions:
    let offset = int(result.functionTableOffset) + index * 12
    writeU32Le(result.bytes, offset, entry.beginAddress)
    writeU32Le(result.bytes, offset + 4, entry.endAddress)
    writeU32Le(result.bytes, offset + 8, entry.unwindData)
  result.schemaId = "reprobuild.hcr.windows-unwind-layout.v1"
