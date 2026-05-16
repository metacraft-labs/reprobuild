import std/[strutils]

import repro_hcr_linkgraph/types

const
  MachO64Magic = 0xfeedfacf'u32
  CpuTypeArm64 = 0x0100000c'i32
  MhObject = 0x1'u32
  LcSegment64 = 0x19'u32
  LcSymtab = 0x2'u32
  NStab = 0xe0'u8
  NType = 0x0e'u8
  NSect = 0x0e'u8

proc readU8(data: string; pos: int): uint8 =
  if pos < 0 or pos >= data.len:
    raise newException(ValueError, "truncated Mach-O byte")
  uint8(ord(data[pos]))

proc readU32Le(data: string; pos: int): uint32 =
  if pos + 4 > data.len:
    raise newException(ValueError, "truncated Mach-O uint32")
  result = uint32(readU8(data, pos)) or
    (uint32(readU8(data, pos + 1)) shl 8) or
    (uint32(readU8(data, pos + 2)) shl 16) or
    (uint32(readU8(data, pos + 3)) shl 24)

proc readI32Le(data: string; pos: int): int32 =
  cast[int32](readU32Le(data, pos))

proc readU64Le(data: string; pos: int): uint64 =
  uint64(readU32Le(data, pos)) or (uint64(readU32Le(data, pos + 4)) shl 32)

proc readFixedCString(data: string; pos, size: int): string =
  if pos + size > data.len:
    raise newException(ValueError, "truncated Mach-O fixed string")
  for i in 0 ..< size:
    let ch = data[pos + i]
    if ch == '\0':
      break
    result.add(ch)

proc readCString(data: string; pos, limit: int): string =
  if pos < 0 or pos >= limit or limit > data.len:
    return ""
  var i = pos
  while i < limit and data[i] != '\0':
    result.add(data[i])
    inc i

proc sectionFullName(section: SectionFact): string =
  section.segmentName & "," & section.name

proc sectionKind(segmentName, sectionName: string; flags: uint32): SectionKind =
  if segmentName == "__DWARF" or sectionName.startsWith("__debug"):
    return skDebug
  if sectionName in ["__compact_unwind", "__eh_frame"]:
    return skUnwind
  if segmentName == "__TEXT" and
      (flags and (0x8000_0000'u32 or 0x0000_0400'u32)) != 0'u32:
    return skCode
  if segmentName in ["__DATA", "__DATA_CONST"]:
    return skData
  skOther

proc relocationKindName*(typeCode: uint8): string =
  case typeCode
  of 0: "ARM64_RELOC_UNSIGNED"
  of 1: "ARM64_RELOC_SUBTRACTOR"
  of 2: "ARM64_RELOC_BRANCH26"
  of 3: "ARM64_RELOC_PAGE21"
  of 4: "ARM64_RELOC_PAGEOFF12"
  of 5: "ARM64_RELOC_GOT_LOAD_PAGE21"
  of 6: "ARM64_RELOC_GOT_LOAD_PAGEOFF12"
  of 7: "ARM64_RELOC_POINTER_TO_GOT"
  of 8: "ARM64_RELOC_TLVP_LOAD_PAGE21"
  of 9: "ARM64_RELOC_TLVP_LOAD_PAGEOFF12"
  of 10: "ARM64_RELOC_ADDEND"
  else: "ARM64_RELOC_UNKNOWN_" & $typeCode

proc signExtend24(value: uint32): int64 =
  let masked = value and 0x00ff_ffff'u32
  if (masked and 0x0080_0000'u32) != 0'u32:
    int64(int32(masked or 0xff00_0000'u32))
  else:
    int64(masked)

proc bytesFrom(data: string; offset: uint64; size: uint64): seq[byte] =
  if offset > uint64(data.len) or offset + size > uint64(data.len):
    raise newException(ValueError, "section data outside Mach-O file")
  result = newSeq[byte](int(size))
  for i in 0 ..< int(size):
    result[i] = byte(ord(data[int(offset) + i]))

proc parseMachOArm64Object*(path: string): LinkGraph =
  let data = readFile(path)
  if data.len < 32:
    raise newException(ValueError, "file too small for Mach-O header")
  if readU32Le(data, 0) != MachO64Magic:
    raise newException(ValueError, "expected little-endian Mach-O 64-bit object")
  if readI32Le(data, 4) != CpuTypeArm64:
    raise newException(ValueError, "expected arm64 Mach-O object")
  if readU32Le(data, 12) != MhObject:
    raise newException(ValueError, "expected relocatable Mach-O object")

  result.schemaId = "reprobuild.hcr.linkgraph.v1"
  result.sourcePath = path
  result.format = ofMachO64Arm64
  result.arch = "mach-o/arm64"

  let ncmds = int(readU32Le(data, 16))
  var commandOffset = 32
  var symoff = 0'u32
  var nsyms = 0'u32
  var stroff = 0'u32
  var strsize = 0'u32

  for _ in 0 ..< ncmds:
    let cmd = readU32Le(data, commandOffset)
    let cmdsize = int(readU32Le(data, commandOffset + 4))
    if cmdsize < 8 or commandOffset + cmdsize > data.len:
      raise newException(ValueError, "invalid Mach-O load command size")

    if cmd == LcSegment64:
      let segmentName = readFixedCString(data, commandOffset + 8, 16)
      let nsects = int(readU32Le(data, commandOffset + 64))
      var sectionOffset = commandOffset + 72
      for _ in 0 ..< nsects:
        let sectionName = readFixedCString(data, sectionOffset, 16)
        let sectionSegment = readFixedCString(data, sectionOffset + 16, 16)
        let address = readU64Le(data, sectionOffset + 32)
        let size = readU64Le(data, sectionOffset + 40)
        let fileOffset = uint64(readU32Le(data, sectionOffset + 48))
        let alignmentPower = readU32Le(data, sectionOffset + 52)
        let reloff = readU32Le(data, sectionOffset + 56)
        let nreloc = readU32Le(data, sectionOffset + 60)
        let flags = readU32Le(data, sectionOffset + 64)
        let id = result.sections.len
        var section = SectionFact(
          id: id,
          segmentName: if sectionSegment.len > 0: sectionSegment else: segmentName,
          name: sectionName,
          address: address,
          size: size,
          fileOffset: fileOffset,
          alignmentPower: alignmentPower,
          flags: flags,
          kind: sectionKind(if sectionSegment.len > 0: sectionSegment else: segmentName,
                            sectionName, flags),
          data: bytesFrom(data, fileOffset, size)
        )
        if section.kind == skDebug:
          result.hasDebugFacts = true
        if section.kind == skUnwind:
          result.hasUnwindFacts = true

        for relocIndex in 0 ..< int(nreloc):
          let entryOffset = int(reloff) + relocIndex * 8
          let rawAddress = readU32Le(data, entryOffset)
          let rawInfo = readU32Le(data, entryOffset + 4)
          let relocationId = result.relocations.len
          let scattered = (rawAddress and 0x8000_0000'u32) != 0'u32
          let symbolNum = int(rawInfo and 0x00ff_ffff'u32)
          let typeCode = uint8((rawInfo shr 28) and 0xf'u32)
          let addend =
            if typeCode == 10 and not scattered: signExtend24(rawInfo and 0x00ff_ffff'u32)
            else: 0'i64
          result.relocations.add RelocationFact(
            id: relocationId,
            sectionId: id,
            offset: rawAddress and 0x7fff_ffff'u32,
            typeCode: typeCode,
            kindName: relocationKindName(typeCode),
            pcrel: ((rawInfo shr 24) and 1'u32) != 0'u32,
            lengthBytes: uint8(1 shl int((rawInfo shr 25) and 0x3'u32)),
            isExtern: ((rawInfo shr 27) and 1'u32) != 0'u32,
            symbolIndex: symbolNum,
            addend: addend,
            scattered: scattered
          )
          section.relocationIds.add relocationId
          if scattered:
            result.unsupportedFeatures.add UnsupportedFeatureFact(
              feature: "mach-o-scattered-relocation",
              severity: usReject,
              sectionId: id,
              relocationId: relocationId,
              reason: "M26 parser records but does not support scattered relocations"
            )
        result.sections.add section
        sectionOffset += 80

    elif cmd == LcSymtab:
      symoff = readU32Le(data, commandOffset + 8)
      nsyms = readU32Le(data, commandOffset + 12)
      stroff = readU32Le(data, commandOffset + 16)
      strsize = readU32Le(data, commandOffset + 20)

    commandOffset += cmdsize

  if nsyms == 0 or strsize == 0:
    raise newException(ValueError, "Mach-O object lacks a symbol table")

  let stringLimit = int(stroff + strsize)
  for i in 0 ..< int(nsyms):
    let entryOffset = int(symoff) + i * 16
    let strx = readU32Le(data, entryOffset)
    let ntype = readU8(data, entryOffset + 4)
    let nsect = int(readU8(data, entryOffset + 5))
    let nvalue = readU64Le(data, entryOffset + 8)
    let rawName = if strx == 0: "" else: readCString(data, int(stroff + strx), stringLimit)
    let sectionId = nsect - 1
    let defined = (ntype and NType) == NSect and sectionId >= 0 and sectionId < result.sections.len
    var kind = sykOther
    if (ntype and NStab) != 0'u8:
      kind = sykOther
    elif not defined:
      kind = sykUndefined
    elif result.sections[sectionId].kind == skCode and rawName.len > 0 and
        not rawName.startsWith("ltmp") and not rawName.startsWith("L"):
      kind = sykFunction
    elif result.sections[sectionId].kind == skData:
      kind = sykData
    elif rawName.startsWith("ltmp"):
      kind = sykSection

    result.symbols.add SymbolFact(
      id: i,
      name: rawName,
      rawName: rawName,
      kind: kind,
      sectionId: if defined: sectionId else: -1,
      address: nvalue,
      size: 0,
      isExternal: (ntype and 0x01'u8) != 0'u8,
      isDefined: defined
    )

  for relocationIndex in 0 ..< result.relocations.len:
    var relocation = result.relocations[relocationIndex]
    if relocation.typeCode == 10:
      relocation.targetName = "$addend"
    elif relocation.isExtern:
      if relocation.symbolIndex >= 0 and relocation.symbolIndex < result.symbols.len:
        relocation.targetName = result.symbols[relocation.symbolIndex].name
      else:
        relocation.targetName = "$invalid-symbol-" & $relocation.symbolIndex
    elif relocation.symbolIndex > 0 and relocation.symbolIndex <= result.sections.len:
      relocation.targetName = sectionFullName(result.sections[relocation.symbolIndex - 1])
    else:
      relocation.targetName = "$unknown-section-" & $relocation.symbolIndex
    result.relocations[relocationIndex] = relocation

  var symbolsBySection: seq[seq[int]] = newSeq[seq[int]](result.sections.len)
  for symbol in result.symbols:
    if symbol.kind == sykFunction and symbol.sectionId >= 0:
      symbolsBySection[symbol.sectionId].add symbol.id
  for sectionId in 0 ..< symbolsBySection.len:
    for i in 0 ..< symbolsBySection[sectionId].len:
      for j in i + 1 ..< symbolsBySection[sectionId].len:
        if result.symbols[symbolsBySection[sectionId][j]].address <
            result.symbols[symbolsBySection[sectionId][i]].address:
          swap symbolsBySection[sectionId][i], symbolsBySection[sectionId][j]
    for index, symbolId in symbolsBySection[sectionId]:
      let start = result.symbols[symbolId].address
      let endAddress =
        if index + 1 < symbolsBySection[sectionId].len:
          result.symbols[symbolsBySection[sectionId][index + 1]].address
        else:
          result.sections[sectionId].address + result.sections[sectionId].size
      if endAddress > start:
        result.symbols[symbolId].size = endAddress - start

  if result.hasDebugFacts:
    result.unsupportedFeatures.add UnsupportedFeatureFact(
      feature: "debug-info-registration",
      severity: usFallbackRequired,
      sectionId: -1,
      relocationId: -1,
      reason: "M26 records DWARF facts but does not register debug metadata"
    )
  else:
    result.unsupportedFeatures.add UnsupportedFeatureFact(
      feature: "debug-info-absent",
      severity: usInfo,
      sectionId: -1,
      relocationId: -1,
      reason: "object has no debug sections"
    )

  if result.hasUnwindFacts:
    result.unsupportedFeatures.add UnsupportedFeatureFact(
      feature: "unwind-registration",
      severity: usFallbackRequired,
      sectionId: -1,
      relocationId: -1,
      reason: "M26 records unwind facts but does not register unwind metadata"
    )
  else:
    result.unsupportedFeatures.add UnsupportedFeatureFact(
      feature: "unwind-info-absent",
      severity: usInfo,
      sectionId: -1,
      relocationId: -1,
      reason: "object has no unwind section"
    )
