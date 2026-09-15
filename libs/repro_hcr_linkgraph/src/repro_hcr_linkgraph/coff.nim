## PE/COFF x86_64 relocatable-object reader (HX-W-3).
##
## The parser consumes real MSVC-compatible COFF objects without invoking a
## text-dump tool. It preserves every relocation kind, captures each implicit
## addend from the original section bytes, and keeps REL32_1 ... REL32_5
## distinct. Structural defects raise: an unreadable table must never become an
## apparently valid graph with zero symbols or relocations.

import std/[strutils]
from repro_core/paths import extendedPath

import repro_hcr_linkgraph/types

const
  CoffMachineAmd64* = 0x8664'u16
  ImageScnCntCode = 0x0000_0020'u32
  ImageScnCntInitializedData = 0x0000_0040'u32
  ImageScnCntUninitializedData = 0x0000_0080'u32
  ImageScnLnkComdat = 0x0000_1000'u32
  ImageScnLnkNrelocOvfl = 0x0100_0000'u32
  ImageScnMemExecute = 0x2000_0000'u32
  ImageScnMemWrite = 0x8000_0000'u32
  ImageScnAlignMask = 0x00f0_0000'u32
  ImageSymClassExternal = 2'u8
  ImageSymClassStatic = 3'u8
  ImageSymClassWeakExternal = 105'u8
  ImageSymDtypeFunction = 0x20'u16

type
  CoffSymbolDetail* = object
    symbolIndex*: int
    typeCode*: uint16
    storageClass*: uint8
    auxiliaryCount*: uint8

  CoffObjectFacts* = object
    sectionCount*: int
    primarySymbolCount*: int
    auxiliarySymbolCount*: int
    relocationCount*: int
    implicitAddendCount*: int
    rel32VariantCount*: int
    comdatSectionCount*: int
    relocationOverflowSectionCount*: int
    symbolDetails*: seq[CoffSymbolDetail]

  CoffRelocationComputation* = object
    value*: int64
    widthBytes*: uint8
    pcBiasBytes*: uint8

  RawSection = object
    name: string
    virtualAddress: uint32
    rawSize: uint32
    rawOffset: uint32
    relocationOffset: uint32
    relocationCount: uint16
    characteristics: uint32

proc readU8(data: string; pos: int): uint8 =
  if pos < 0 or pos >= data.len:
    raise newException(ValueError, "truncated COFF byte at " & $pos)
  uint8(ord(data[pos]))

proc readU16Le(data: string; pos: int): uint16 =
  if pos < 0 or pos + 2 > data.len:
    raise newException(ValueError, "truncated COFF uint16 at " & $pos)
  uint16(readU8(data, pos)) or (uint16(readU8(data, pos + 1)) shl 8)

proc readI16Le(data: string; pos: int): int16 =
  cast[int16](readU16Le(data, pos))

proc readU32Le(data: string; pos: int): uint32 =
  if pos < 0 or pos + 4 > data.len:
    raise newException(ValueError, "truncated COFF uint32 at " & $pos)
  uint32(readU8(data, pos)) or
    (uint32(readU8(data, pos + 1)) shl 8) or
    (uint32(readU8(data, pos + 2)) shl 16) or
    (uint32(readU8(data, pos + 3)) shl 24)

proc readI32Le(data: string; pos: int): int32 =
  cast[int32](readU32Le(data, pos))

proc readU64Le(data: string; pos: int): uint64 =
  uint64(readU32Le(data, pos)) or (uint64(readU32Le(data, pos + 4)) shl 32)

proc readI64Le(data: string; pos: int): int64 =
  cast[int64](readU64Le(data, pos))

proc checkedRange(data: string; offset, size: uint64; what: string) =
  if offset > uint64(data.len) or size > uint64(data.len) - offset:
    raise newException(ValueError, what & " lies outside the COFF object")

proc bytesFrom(data: string; offset, size: uint64; what: string): seq[byte] =
  checkedRange(data, offset, size, what)
  result = newSeq[byte](int(size))
  for i in 0 ..< int(size):
    result[i] = byte(ord(data[int(offset) + i]))

proc fixedName(data: string; pos: int): string =
  if pos < 0 or pos + 8 > data.len:
    raise newException(ValueError, "truncated COFF eight-byte name")
  for i in 0 ..< 8:
    if data[pos + i] == '\0':
      break
    result.add data[pos + i]

proc stringTableName(data: string; stringBase, stringSize: int;
                     offset: uint32): string =
  if offset < 4'u32 or int(offset) >= stringSize:
    raise newException(ValueError,
      "COFF string-table offset " & $offset & " is outside the table")
  let start = stringBase + int(offset)
  let limit = stringBase + stringSize
  var cursor = start
  while cursor < limit and data[cursor] != '\0':
    result.add data[cursor]
    inc cursor
  if cursor >= limit:
    raise newException(ValueError,
      "COFF string-table entry is not NUL-terminated")

proc sectionName(data: string; pos, stringBase, stringSize: int): string =
  let short = fixedName(data, pos)
  if not short.startsWith("/"):
    return short
  if short.len == 1:
    raise newException(ValueError, "empty COFF long section-name offset")
  var offset: int
  try:
    offset = parseInt(short[1 .. ^1])
  except ValueError:
    raise newException(ValueError,
      "unsupported COFF long section-name encoding: " & short)
  if offset < 0 or uint64(offset) > uint64(high(uint32)):
    raise newException(ValueError, "COFF section-name offset overflows uint32")
  stringTableName(data, stringBase, stringSize, uint32(offset))

proc symbolName(data: string; pos, stringBase, stringSize: int): string =
  if readU32Le(data, pos) == 0'u32:
    return stringTableName(data, stringBase, stringSize,
                           readU32Le(data, pos + 4))
  fixedName(data, pos)

proc coffSectionKind(name: string; characteristics: uint32): SectionKind =
  if name.startsWith(".debug$"):
    return skDebug
  if name in [".pdata", ".xdata"]:
    return skUnwind
  if (characteristics and (ImageScnCntCode or ImageScnMemExecute)) != 0'u32:
    return skCode
  if (characteristics and (ImageScnCntInitializedData or
      ImageScnCntUninitializedData or ImageScnMemWrite)) != 0'u32:
    return skData
  skOther

proc alignmentPower(characteristics: uint32): uint32 =
  let encoded = (characteristics and ImageScnAlignMask) shr 20
  if encoded == 0'u32: 0'u32 else: encoded - 1'u32

proc coffRelocationKindName*(typeCode: uint16): string =
  case typeCode
  of 0x0000: "IMAGE_REL_AMD64_ABSOLUTE"
  of 0x0001: "IMAGE_REL_AMD64_ADDR64"
  of 0x0002: "IMAGE_REL_AMD64_ADDR32"
  of 0x0003: "IMAGE_REL_AMD64_ADDR32NB"
  of 0x0004: "IMAGE_REL_AMD64_REL32"
  of 0x0005: "IMAGE_REL_AMD64_REL32_1"
  of 0x0006: "IMAGE_REL_AMD64_REL32_2"
  of 0x0007: "IMAGE_REL_AMD64_REL32_3"
  of 0x0008: "IMAGE_REL_AMD64_REL32_4"
  of 0x0009: "IMAGE_REL_AMD64_REL32_5"
  of 0x000a: "IMAGE_REL_AMD64_SECTION"
  of 0x000b: "IMAGE_REL_AMD64_SECREL"
  of 0x000c: "IMAGE_REL_AMD64_SECREL7"
  of 0x000d: "IMAGE_REL_AMD64_TOKEN"
  of 0x000e: "IMAGE_REL_AMD64_SREL32"
  of 0x000f: "IMAGE_REL_AMD64_PAIR"
  of 0x0010: "IMAGE_REL_AMD64_SSPAN32"
  else: "IMAGE_REL_AMD64_UNKNOWN_" & $typeCode

proc coffRelocationWidthBytes*(typeCode: uint16): uint8 =
  case typeCode
  of 0x0001: 8'u8
  of 0x0002 .. 0x0009, 0x000b, 0x000e, 0x0010: 4'u8
  of 0x000a: 2'u8
  of 0x000c: 1'u8
  else: 0'u8

proc coffRelocationIsPcRelative*(typeCode: uint16): bool =
  typeCode >= 0x0004'u16 and typeCode <= 0x0009'u16

proc coffRel32PcBiasBytes*(typeCode: uint16): uint8 =
  if not coffRelocationIsPcRelative(typeCode):
    raise newException(ValueError,
      coffRelocationKindName(typeCode) & " is not a REL32 relocation")
  uint8(4 + int(typeCode) - 4)

proc coffAmd64RelocationValue*(relocation: RelocationFact;
                              symbolAddress, placeAddress,
                              imageBase: uint64): CoffRelocationComputation =
  ## Compute the value written into a COFF relocation field. The parser has
  ## already captured `A` from the original bytes, so this proc never consults
  ## a buffer which a caller may have normalized or overwritten.
  result.widthBytes = relocation.lengthBytes
  case relocation.typeCode
  of 1'u8:
    result.value = cast[int64](symbolAddress) + relocation.addend
  of 2'u8:
    result.value = cast[int64](symbolAddress) + relocation.addend
  of 3'u8:
    result.value = cast[int64](symbolAddress) - cast[int64](imageBase) +
      relocation.addend
  of 4'u8 .. 9'u8:
    result.pcBiasBytes = coffRel32PcBiasBytes(uint16(relocation.typeCode))
    result.value = cast[int64](symbolAddress) + relocation.addend -
      cast[int64](placeAddress) - int64(result.pcBiasBytes)
  else:
    raise newException(ValueError,
      relocation.kindName & " has no HX-W-3 address computation")

proc parseCoffAmd64Object*(path: string; facts: var CoffObjectFacts): LinkGraph =
  let data = readFile(extendedPath(path))
  facts = CoffObjectFacts()
  if data.len < 20:
    raise newException(ValueError, "file too small for a COFF header: " & path)
  if readU16Le(data, 0) == 0'u16 and readU16Le(data, 2) == 0xffff'u16:
    raise newException(ValueError,
      "COFF bigobj is outside the HX-W-3 object profile: " & path)
  let machine = readU16Le(data, 0)
  if machine != CoffMachineAmd64:
    raise newException(ValueError,
      "expected IMAGE_FILE_MACHINE_AMD64 (0x8664), got 0x" &
      toHex(machine) & ": " & path)
  let sectionCount = int(readU16Le(data, 2))
  let symbolTableOffset = int(readU32Le(data, 8))
  let symbolCount = int(readU32Le(data, 12))
  let optionalHeaderSize = int(readU16Le(data, 16))
  if optionalHeaderSize != 0:
    raise newException(ValueError,
      "expected a relocatable COFF object with no optional header: " & path)
  if sectionCount <= 0:
    raise newException(ValueError, "COFF object has no sections: " & path)
  if symbolTableOffset <= 0 or symbolCount <= 0:
    raise newException(ValueError,
      "COFF object has no symbol table; zero symbols is not a valid patch plan: " &
      path)
  checkedRange(data, uint64(symbolTableOffset), uint64(symbolCount) * 18'u64,
               "COFF symbol table")
  let stringBase = symbolTableOffset + symbolCount * 18
  let stringSize = int(readU32Le(data, stringBase))
  if stringSize < 4:
    raise newException(ValueError, "invalid COFF string-table size: " & path)
  checkedRange(data, uint64(stringBase), uint64(stringSize),
               "COFF string table")
  let sectionTableOffset = 20
  checkedRange(data, uint64(sectionTableOffset), uint64(sectionCount) * 40'u64,
               "COFF section table")

  facts.sectionCount = sectionCount
  result.schemaId = "reprobuild.hcr.linkgraph.v1"
  result.sourcePath = path
  result.format = ofCoffAmd64
  result.arch = "coff/x86-64"

  var rawSections = newSeq[RawSection](sectionCount)
  for i in 0 ..< sectionCount:
    let pos = sectionTableOffset + i * 40
    rawSections[i] = RawSection(
      name: sectionName(data, pos, stringBase, stringSize),
      virtualAddress: readU32Le(data, pos + 12),
      rawSize: readU32Le(data, pos + 16),
      rawOffset: readU32Le(data, pos + 20),
      relocationOffset: readU32Le(data, pos + 24),
      relocationCount: readU16Le(data, pos + 32),
      characteristics: readU32Le(data, pos + 36))
    let raw = rawSections[i]
    let kind = coffSectionKind(raw.name, raw.characteristics)
    let sectionData =
      if raw.rawSize == 0'u32:
        newSeq[byte](0)
      else:
        bytesFrom(data, uint64(raw.rawOffset), uint64(raw.rawSize),
                  "section " & raw.name & " data")
    result.sections.add SectionFact(
      id: i,
      segmentName: "",
      name: raw.name,
      address: uint64(raw.virtualAddress),
      size: uint64(raw.rawSize),
      fileOffset: uint64(raw.rawOffset),
      alignmentPower: alignmentPower(raw.characteristics),
      flags: raw.characteristics,
      kind: kind,
      data: sectionData)
    if kind == skDebug:
      result.hasDebugFacts = true
    if kind == skUnwind:
      result.hasUnwindFacts = true
    if (raw.characteristics and ImageScnLnkComdat) != 0'u32:
      facts.comdatSectionCount += 1
      result.unsupportedFeatures.add UnsupportedFeatureFact(
        feature: "coff-comdat-section",
        severity: usFallbackRequired,
        sectionId: i,
        relocationId: -1,
        reason: "section " & raw.name &
          " is COMDAT; the linked image may retain another object's copy")

  var primaryIndices: seq[int]
  var rawIndex = 0
  while rawIndex < symbolCount:
    let pos = symbolTableOffset + rawIndex * 18
    let name = symbolName(data, pos, stringBase, stringSize)
    let value = readU32Le(data, pos + 8)
    let sectionNumber = readI16Le(data, pos + 12)
    let typeCode = readU16Le(data, pos + 14)
    let storageClass = readU8(data, pos + 16)
    let auxiliaryCount = readU8(data, pos + 17)
    if rawIndex + int(auxiliaryCount) >= symbolCount:
      raise newException(ValueError,
        "COFF symbol " & $rawIndex & " auxiliary records run past the table")
    let defined = sectionNumber > 0 and int(sectionNumber) <= sectionCount
    let sectionId = if defined: int(sectionNumber) - 1 else: -1
    var kind = sykOther
    if not defined:
      if sectionNumber == 0:
        kind = sykUndefined
    elif (typeCode and ImageSymDtypeFunction) != 0'u16:
      kind = sykFunction
    elif storageClass == ImageSymClassStatic and value == 0'u32 and
        name == result.sections[sectionId].name:
      kind = sykSection
    else:
      kind = sykData
    result.symbols.add SymbolFact(
      id: rawIndex,
      name: name,
      rawName: name,
      kind: kind,
      sectionId: sectionId,
      address: uint64(value),
      size: 0,
      isExternal: storageClass in
        [ImageSymClassExternal, ImageSymClassWeakExternal],
      isDefined: defined)
    primaryIndices.add rawIndex
    facts.primarySymbolCount += 1
    facts.symbolDetails.add CoffSymbolDetail(
      symbolIndex: rawIndex,
      typeCode: typeCode,
      storageClass: storageClass,
      auxiliaryCount: auxiliaryCount)
    for auxiliary in 1 .. int(auxiliaryCount):
      let auxiliaryIndex = rawIndex + auxiliary
      result.symbols.add SymbolFact(
        id: auxiliaryIndex,
        name: "$aux-" & $auxiliaryIndex,
        rawName: "",
        kind: sykOther,
        sectionId: -1,
        isDefined: false)
      facts.auxiliarySymbolCount += 1
    rawIndex += int(auxiliaryCount) + 1

  if result.symbols.len != symbolCount:
    raise newException(ValueError,
      "COFF raw symbol index map does not cover the whole symbol table")

  # COFF function symbols carry no authoritative byte size. Infer the bounded
  # range from the next function in the same section, or the section end. This
  # is explicit here, unlike ELF where st_size is authoritative.
  for symbolIndex in primaryIndices:
    if result.symbols[symbolIndex].kind != sykFunction or
        not result.symbols[symbolIndex].isDefined:
      continue
    let sectionId = result.symbols[symbolIndex].sectionId
    let start = result.symbols[symbolIndex].address
    var finish = result.sections[sectionId].size
    if start >= finish:
      raise newException(ValueError,
        "COFF function " & result.symbols[symbolIndex].name &
        " starts outside section " & result.sections[sectionId].name)
    for otherIndex in primaryIndices:
      let other = result.symbols[otherIndex]
      if other.kind == sykFunction and other.isDefined and
          other.sectionId == sectionId and other.address > start and
          other.address < finish:
        finish = other.address
    if finish <= start:
      raise newException(ValueError,
        "COFF function " & result.symbols[symbolIndex].name &
        " has no non-empty bounded range")
    result.symbols[symbolIndex].size = finish - start

  for sectionId, raw in rawSections:
    var relocationCount = int(raw.relocationCount)
    var relocationBase = int(raw.relocationOffset)
    if (raw.characteristics and ImageScnLnkNrelocOvfl) != 0'u32:
      if raw.relocationCount != 0xffff'u16:
        raise newException(ValueError,
          "COFF relocation-overflow flag lacks the 0xffff count sentinel")
      checkedRange(data, uint64(relocationBase), 10, "COFF overflow relocation")
      let encodedCount = int(readU32Le(data, relocationBase))
      if encodedCount <= 1:
        raise newException(ValueError, "invalid COFF overflow relocation count")
      relocationCount = encodedCount - 1
      relocationBase += 10
      facts.relocationOverflowSectionCount += 1
    if relocationCount == 0:
      continue
    checkedRange(data, uint64(relocationBase), uint64(relocationCount) * 10'u64,
                 "COFF relocation table for " & raw.name)
    for r in 0 ..< relocationCount:
      let pos = relocationBase + r * 10
      let relocationAddress = readU32Le(data, pos)
      if relocationAddress < raw.virtualAddress:
        raise newException(ValueError,
          "COFF relocation precedes the section virtual address")
      let localOffset = relocationAddress - raw.virtualAddress
      let symbolIndex = int(readU32Le(data, pos + 4))
      let typeCode = readU16Le(data, pos + 8)
      if symbolIndex < 0 or symbolIndex >= result.symbols.len:
        raise newException(ValueError,
          "COFF relocation names symbol index outside the symbol table")
      if typeCode > uint16(high(uint8)):
        raise newException(ValueError,
          "COFF relocation type does not fit LinkGraph.typeCode")
      let width = coffRelocationWidthBytes(typeCode)
      if width > 0'u8 and uint64(localOffset) + uint64(width) > raw.rawSize:
        raise newException(ValueError,
          coffRelocationKindName(typeCode) & " field lies outside " & raw.name)
      var addend = 0'i64
      if width > 0'u8:
        let field = int(raw.rawOffset + localOffset)
        case width
        of 8: addend = readI64Le(data, field)
        of 4:
          if coffRelocationIsPcRelative(typeCode):
            addend = int64(readI32Le(data, field))
          else:
            addend = int64(readU32Le(data, field))
        of 2: addend = int64(readU16Le(data, field))
        of 1: addend = int64(readU8(data, field))
        else: discard
        facts.implicitAddendCount += 1
      if typeCode >= 0x0005'u16 and typeCode <= 0x0009'u16:
        facts.rel32VariantCount += 1
      let target = result.symbols[symbolIndex]
      let targetName =
        if target.name.len > 0: target.name
        elif target.sectionId >= 0: result.sections[target.sectionId].name
        else: "$symbol-" & $symbolIndex
      let relocationId = result.relocations.len
      result.relocations.add RelocationFact(
        id: relocationId,
        sectionId: sectionId,
        offset: localOffset,
        typeCode: uint8(typeCode),
        kindName: coffRelocationKindName(typeCode),
        pcrel: coffRelocationIsPcRelative(typeCode),
        lengthBytes: width,
        isExtern: target.isExternal,
        symbolIndex: symbolIndex,
        targetName: targetName,
        addend: addend,
        scattered: false)
      result.sections[sectionId].relocationIds.add relocationId
      facts.relocationCount += 1

  if result.hasDebugFacts:
    result.unsupportedFeatures.add UnsupportedFeatureFact(
      feature: "pdb-debug-info-external",
      severity: usInfo,
      sectionId: -1,
      relocationId: -1,
      reason: "COFF CodeView records are present; linked private symbol RVAs " &
        "come from the matching full PDB")
  if result.hasUnwindFacts:
    result.unsupportedFeatures.add UnsupportedFeatureFact(
      feature: "seh-unwind-registration",
      severity: usFallbackRequired,
      sectionId: -1,
      relocationId: -1,
      reason: ".pdata/.xdata are recorded; relocation and " &
        "RtlAddFunctionTable registration are owned by HX-W-4")

proc parseCoffAmd64Object*(path: string): LinkGraph =
  var facts: CoffObjectFacts
  parseCoffAmd64Object(path, facts)
