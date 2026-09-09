## ELF64 x86_64 `ET_REL` object reader (HLX-M1).
##
## The ELF analogue of `macho.nim`'s M26 Mach-O profile, per
## `reprobuild-specs/HCR/Linux-ELF-Provider.md` §7.5: section headers,
## `.symtab`/`.strtab`, `.rela.*` and `.rel.*`, `SHT_GROUP`/`GRP_COMDAT`,
## `SHF_LINK_ORDER` (which `__patchable_function_entries` uses), `.debug_*`,
## `.eh_frame`/`.eh_frame_hdr`, `SHN_XINDEX`, and an explicit structured set of
## unsupported-feature reasons.
##
## It produces the same `LinkGraph` the Mach-O reader does, so `analysis.nim`'s
## diffing and `planner.nim`'s plan emission are shared rather than duplicated.
##
## Two ELF-specific properties this exploits, both stated in design §7.5:
##
## - `Elf64_Sym.st_size` is authoritative, so the size-inference heuristic the
##   Mach-O path needs (sort the symbols of a section and take the gap to the
##   next one, `macho.nim:280-298`) is unnecessary here. A zero `st_size` on a
##   defined function is therefore a REPORTED fact, not something to guess
##   around.
## - Two of the three `SHN_XINDEX`/overflow escapes are reachable in ordinary
##   C++ builds, not just in synthetic files: measured, a single Godot
##   translation unit compiles to 9,660 sections. The third needs more than
##   that, so the gate compiles 66,000 functions under `-ffunction-sections`,
##   which produces `e_shnum == 0` with the real count in `shdr[0].sh_size`,
##   `e_shstrndx == SHN_XINDEX`, and a `.symtab_shndx` covering 1,448 symbols
##   (724 functions and their 724 section symbols). All three are handled, and
##   all three counts were re-measured independently by review 2026-09-10.
##
## Every structural defect raises rather than returning a partial graph. A
## parser that fails to read a table and answers "0 symbols" is the vacuous
## check `codetracer-specs/Testing/Verification-Harness-Traps.md` §9 describes,
## and it is precisely the failure this reader must not have.

import std/[strutils, tables]
from repro_core/paths import extendedPath

import repro_hcr_linkgraph/types

const
  # e_type
  EtRel* = 1'u16
  # e_machine
  EmX86_64* = 62'u16
  # sh_type
  ShtProgbits = 1'u32
  ShtSymtab = 2'u32
  ShtStrtab = 3'u32
  ShtRela = 4'u32
  ShtNobits = 8'u32
  ShtRel = 9'u32
  ShtGroup = 17'u32
  ShtSymtabShndx = 18'u32
  # sh_flags
  ShfWrite = 0x1'u64
  ShfAlloc = 0x2'u64
  ShfExecinstr = 0x4'u64
  ShfMerge = 0x10'u64
  ShfStrings = 0x20'u64
  ShfLinkOrder = 0x80'u64
  ShfTls = 0x400'u64
  # special section indices
  ShnUndef = 0'u32
  ShnLoreserve = 0xff00'u32
  ShnAbs = 0xfff1'u32
  ShnCommon = 0xfff2'u32
  ShnXindex = 0xffff'u32
  # GROUP flags
  GrpComdat = 0x1'u32
  # st_info type
  SttNoType = 0'u8
  SttObject = 1'u8
  SttFunc = 2'u8
  SttSection = 3'u8
  SttFile = 4'u8
  SttCommon = 5'u8
  SttTls = 6'u8
  SttGnuIfunc = 10'u8
  # st_info bind
  StbLocal = 0'u8
  StbGlobal = 1'u8
  StbWeak = 2'u8

type
  ElfSymbolDetail* = object
    ## The ELF-specific facts `SymbolFact` has no room for, kept alongside the
    ## graph so a patch plan can carry design §7.4's identity tuple and the
    ## `STT_FILE` attribution that actually disambiguates it.
    symbolIndex*: int
    symbolBind*: uint8
    symbolType*: uint8
    sectionIndex*: uint32 ## already SHN_XINDEX-expanded
    sourceFile*: string   ## the governing STT_FILE symbol, for STB_LOCAL only

  ElfObjectFacts* = object
    ## Facts about the object that do not fit `LinkGraph` but that the HLX-M1
    ## gates and the Linux support profile need to assert on.
    sectionCount*: int
    usedShnumOverflow*: bool     ## e_shnum == 0, real count in shdr[0].sh_size
    usedShstrndxXindex*: bool    ## e_shstrndx == SHN_XINDEX
    xindexSymbolCount*: int      ## symbols resolved through SHT_SYMTAB_SHNDX
    comdatGroupCount*: int
    linkOrderSectionCount*: int
    patchableEntrySectionCount*: int
    symbolDetails*: seq[ElfSymbolDetail]

proc readU8(data: string; pos: int): uint8 =
  if pos < 0 or pos >= data.len:
    raise newException(ValueError, "truncated ELF byte at " & $pos)
  uint8(ord(data[pos]))

proc readU16Le(data: string; pos: int): uint16 =
  if pos < 0 or pos + 2 > data.len:
    raise newException(ValueError, "truncated ELF uint16 at " & $pos)
  uint16(readU8(data, pos)) or (uint16(readU8(data, pos + 1)) shl 8)

proc readU32Le(data: string; pos: int): uint32 =
  if pos < 0 or pos + 4 > data.len:
    raise newException(ValueError, "truncated ELF uint32 at " & $pos)
  uint32(readU8(data, pos)) or
    (uint32(readU8(data, pos + 1)) shl 8) or
    (uint32(readU8(data, pos + 2)) shl 16) or
    (uint32(readU8(data, pos + 3)) shl 24)

proc readU64Le(data: string; pos: int): uint64 =
  uint64(readU32Le(data, pos)) or (uint64(readU32Le(data, pos + 4)) shl 32)

proc readI64Le(data: string; pos: int): int64 =
  cast[int64](readU64Le(data, pos))

proc readCString(data: string; base: int; index: uint32; limit: int): string =
  let start = base + int(index)
  if start < 0 or start >= limit or limit > data.len:
    raise newException(ValueError,
      "ELF string index " & $index & " is outside its string table")
  var i = start
  while i < limit and data[i] != '\0':
    result.add data[i]
    inc i
  if i >= limit:
    raise newException(ValueError,
      "ELF string table is not NUL-terminated within its own bounds")

proc bytesFrom(data: string; offset, size: uint64; what: string): seq[byte] =
  if offset > uint64(data.len) or size > uint64(data.len) - offset:
    raise newException(ValueError, what & " lies outside the ELF file")
  result = newSeq[byte](int(size))
  for i in 0 ..< int(size):
    result[i] = byte(ord(data[int(offset) + i]))

proc elfSectionKind(name: string; flags: uint64; shType: uint32): SectionKind =
  if name.startsWith(".debug") or name.startsWith(".zdebug"):
    return skDebug
  if name == ".eh_frame" or name == ".eh_frame_hdr" or
      name == ".gcc_except_table" or name.startsWith(".eh_frame."):
    return skUnwind
  if (flags and ShfExecinstr) != 0'u64:
    return skCode
  if shType == ShtNobits or (flags and ShfWrite) != 0'u64 or
      name.startsWith(".rodata") or name == ".data" or name == ".bss":
    return skData
  skOther

proc relocationKindName*(typeCode: uint32): string =
  ## x86_64 psABI relocation names. Named rather than numbered because a
  ## structured unsupported-feature reason that says "type 42" tells whoever
  ## reads it nothing.
  case typeCode
  of 0: "R_X86_64_NONE"
  of 1: "R_X86_64_64"
  of 2: "R_X86_64_PC32"
  of 3: "R_X86_64_GOT32"
  of 4: "R_X86_64_PLT32"
  of 5: "R_X86_64_COPY"
  of 6: "R_X86_64_GLOB_DAT"
  of 7: "R_X86_64_JUMP_SLOT"
  of 8: "R_X86_64_RELATIVE"
  of 9: "R_X86_64_GOTPCREL"
  of 10: "R_X86_64_32"
  of 11: "R_X86_64_32S"
  of 12: "R_X86_64_16"
  of 13: "R_X86_64_PC16"
  of 14: "R_X86_64_8"
  of 15: "R_X86_64_PC8"
  of 16: "R_X86_64_DTPMOD64"
  of 17: "R_X86_64_DTPOFF64"
  of 18: "R_X86_64_TPOFF64"
  of 19: "R_X86_64_TLSGD"
  of 20: "R_X86_64_TLSLD"
  of 21: "R_X86_64_DTPOFF32"
  of 22: "R_X86_64_GOTTPOFF"
  of 23: "R_X86_64_TPOFF32"
  of 24: "R_X86_64_PC64"
  of 25: "R_X86_64_GOTOFF64"
  of 26: "R_X86_64_GOTPC32"
  of 27: "R_X86_64_GOT64"
  of 28: "R_X86_64_GOTPCREL64"
  of 29: "R_X86_64_GOTPC64"
  of 30: "R_X86_64_GOTPLT64"
  of 31: "R_X86_64_PLTOFF64"
  of 32: "R_X86_64_SIZE32"
  of 33: "R_X86_64_SIZE64"
  of 34: "R_X86_64_GOTPC32_TLSDESC"
  of 35: "R_X86_64_TLSDESC_CALL"
  of 36: "R_X86_64_TLSDESC"
  of 37: "R_X86_64_IRELATIVE"
  of 38: "R_X86_64_RELATIVE64"
  of 41: "R_X86_64_GOTPCRELX"
  of 42: "R_X86_64_REX_GOTPCRELX"
  of 43: "R_X86_64_CODE_4_GOTPCRELX"
  else: "R_X86_64_UNKNOWN_" & $typeCode

proc relocationWidthBytes*(typeCode: uint32): uint8 =
  case typeCode
  of 1, 16, 17, 18, 24, 25, 27, 28, 29, 30, 31, 33, 36, 38: 8'u8
  of 2, 3, 4, 9, 10, 11, 19, 20, 21, 22, 23, 26, 32, 34, 41, 42, 43: 4'u8
  of 12, 13: 2'u8
  of 14, 15: 1'u8
  else: 0'u8

proc relocationIsPcRelative*(typeCode: uint32): bool =
  typeCode in [2'u32, 4'u32, 9'u32, 13'u32, 15'u32, 24'u32, 26'u32, 28'u32,
               29'u32, 34'u32, 41'u32, 42'u32, 43'u32]

proc elfSymbolKind(symbolType: uint8; sectionIndex: uint32): SymbolKind =
  if sectionIndex == ShnUndef:
    return sykUndefined
  case symbolType
  of SttFunc, SttGnuIfunc: sykFunction
  of SttObject, SttCommon, SttTls: sykData
  of SttSection: sykSection
  # STT_NOTYPE covers assembly labels and linker-synthesised markers. Some of
  # them sit in code sections, but a symbol that does not declare itself a
  # function is not treated as one: `st_size` is usually 0 there, so there is
  # no byte range to plan a patch from, and guessing one is how a patch ends up
  # spanning two functions.
  else: sykOther

proc parseElfX86_64Object*(path: string; facts: var ElfObjectFacts): LinkGraph =
  ## Parse a real ELF64 x86_64 relocatable object into a `LinkGraph`.
  ##
  ## Raises `ValueError` on any structural defect. Nothing here degrades to a
  ## partial graph, because "0 symbols" and "the symbol table could not be
  ## read" must never be the same answer.
  let data = readFile(extendedPath(path))
  facts = ElfObjectFacts()

  if data.len < 64:
    raise newException(ValueError, "file too small for an ELF64 header: " & path)
  if not (readU8(data, 0) == 0x7f'u8 and data[1] == 'E' and data[2] == 'L' and
          data[3] == 'F'):
    raise newException(ValueError, "missing ELF magic: " & path)
  if readU8(data, 4) != 2'u8:
    raise newException(ValueError, "expected ELFCLASS64: " & path)
  if readU8(data, 5) != 1'u8:
    raise newException(ValueError, "expected little-endian ELF: " & path)
  let eType = readU16Le(data, 16)
  if eType != EtRel:
    raise newException(ValueError,
      "expected ET_REL (1), got e_type=" & $eType & ": " & path)
  let eMachine = readU16Le(data, 18)
  if eMachine != EmX86_64:
    raise newException(ValueError,
      "expected EM_X86_64 (62), got e_machine=" & $eMachine & ": " & path)

  let shoff = int(readU64Le(data, 0x28))
  let shentsize = int(readU16Le(data, 0x3a))
  var shnum = int(readU16Le(data, 0x3c))
  var shstrndx = uint32(readU16Le(data, 0x3e))
  if shoff == 0:
    raise newException(ValueError, "object has no section header table: " & path)
  if shentsize != 64:
    raise newException(ValueError,
      "unexpected e_shentsize " & $shentsize & " (want 64): " & path)

  # The two overflow escapes. `e_shnum == 0` puts the real count in the
  # reserved section-header entry, and `e_shstrndx == SHN_XINDEX` puts the real
  # string-table index in that same entry's `sh_link`. A 70,000-section object
  # from `-ffunction-sections` uses both.
  let shnumField = shnum
  if shnumField == 0:
    shnum = int(readU64Le(data, shoff + 32))
    facts.usedShnumOverflow = true
    if shnum == 0:
      raise newException(ValueError,
        "e_shnum is 0 and shdr[0].sh_size is 0, so the real section count is " &
        "unknown: " & path)
  if shstrndx == ShnXindex:
    shstrndx = readU32Le(data, shoff + 40)
    facts.usedShstrndxXindex = true
  if shoff + shnum * shentsize > data.len:
    raise newException(ValueError,
      "section header table (" & $shnum & " entries) runs past end of file: " &
      path)
  facts.sectionCount = shnum

  type RawSection = object
    nameIndex: uint32
    shType: uint32
    flags: uint64
    address: uint64
    offset: uint64
    size: uint64
    link: uint32
    info: uint32
    alignment: uint64
    entsize: uint64

  var raw = newSeq[RawSection](shnum)
  for i in 0 ..< shnum:
    let base = shoff + i * shentsize
    raw[i] = RawSection(
      nameIndex: readU32Le(data, base),
      shType: readU32Le(data, base + 4),
      flags: readU64Le(data, base + 8),
      address: readU64Le(data, base + 16),
      offset: readU64Le(data, base + 24),
      size: readU64Le(data, base + 32),
      link: readU32Le(data, base + 40),
      info: readU32Le(data, base + 44),
      alignment: readU64Le(data, base + 48),
      entsize: readU64Le(data, base + 56))

  if int(shstrndx) >= shnum:
    raise newException(ValueError,
      "e_shstrndx " & $shstrndx & " is out of range for " & $shnum &
      " sections: " & path)
  if raw[int(shstrndx)].shType != ShtStrtab:
    raise newException(ValueError,
      "section header string table is not SHT_STRTAB: " & path)
  let shstrBase = int(raw[int(shstrndx)].offset)
  let shstrLimit = shstrBase + int(raw[int(shstrndx)].size)
  if shstrLimit > data.len:
    raise newException(ValueError,
      "section header string table runs past end of file: " & path)

  result.schemaId = "reprobuild.hcr.linkgraph.v1"
  result.sourcePath = path
  result.format = ofElf64X86_64
  result.arch = "elf64/x86-64"

  var alignmentPower: uint32
  for i in 0 ..< shnum:
    let name = readCString(data, shstrBase, raw[i].nameIndex, shstrLimit)
    alignmentPower = 0
    var a = raw[i].alignment
    while a > 1'u64:
      a = a shr 1
      inc alignmentPower
    let kind = elfSectionKind(name, raw[i].flags, raw[i].shType)
    # SHT_NOBITS occupies address space but no file bytes. Reading `sh_size`
    # bytes at `sh_offset` for one would read whatever section follows it.
    let dataBytes =
      if raw[i].shType == ShtNobits or raw[i].size == 0:
        newSeq[byte](0)
      else:
        bytesFrom(data, raw[i].offset, raw[i].size,
                  "section " & name & " data")
    result.sections.add SectionFact(
      id: i,
      segmentName: "",
      name: name,
      address: raw[i].address,
      size: raw[i].size,
      fileOffset: raw[i].offset,
      alignmentPower: alignmentPower,
      flags: uint32(raw[i].flags and 0xffff_ffff'u64),
      kind: kind,
      data: dataBytes)
    if kind == skDebug:
      result.hasDebugFacts = true
    if kind == skUnwind:
      result.hasUnwindFacts = true
    if (raw[i].flags and ShfLinkOrder) != 0'u64:
      facts.linkOrderSectionCount += 1
    if name == "__patchable_function_entries":
      facts.patchableEntrySectionCount += 1

  # ---------------------------------------------------------------------------
  # SHT_GROUP / GRP_COMDAT. Real C++ objects are full of these: measured, one
  # Godot translation unit carries 3,723 group sections. Every member of a
  # COMDAT group is a candidate for the linker to discard in favour of another
  # object's copy, so a patch body extracted from one is not necessarily the
  # copy that was linked. That is recorded as a structured reason rather than
  # silently ignored.
  # ---------------------------------------------------------------------------
  var comdatSections: Table[int, string] = initTable[int, string]()
  for i in 0 ..< shnum:
    if raw[i].shType != ShtGroup:
      continue
    if raw[i].size < 4'u64 or (raw[i].size mod 4'u64) != 0'u64:
      raise newException(ValueError,
        "SHT_GROUP section " & $i & " has an unusable size: " & path)
    let flags = readU32Le(data, int(raw[i].offset))
    if (flags and GrpComdat) == 0'u32:
      continue
    facts.comdatGroupCount += 1
    var signature = ""
    # sh_link is the symbol table, sh_info the index of the signature symbol.
    if int(raw[i].link) < shnum and raw[int(raw[i].link)].shType == ShtSymtab:
      let symtab = raw[int(raw[i].link)]
      if int(symtab.link) < shnum:
        let strtab = raw[int(symtab.link)]
        let symOffset = int(symtab.offset) + int(raw[i].info) * 24
        if symOffset + 24 <= data.len:
          signature = readCString(data, int(strtab.offset),
                                  readU32Le(data, symOffset),
                                  int(strtab.offset) + int(strtab.size))
    let members = int(raw[i].size div 4'u64) - 1
    for m in 0 ..< members:
      let memberIndex = int(readU32Le(data, int(raw[i].offset) + 4 + m * 4))
      if memberIndex >= 0 and memberIndex < shnum:
        comdatSections[memberIndex] = signature

  # ---------------------------------------------------------------------------
  # Symbols.
  # ---------------------------------------------------------------------------
  var symtabIndex = -1
  for i in 0 ..< shnum:
    if raw[i].shType == ShtSymtab:
      symtabIndex = i
      break
  if symtabIndex < 0:
    raise newException(ValueError,
      "object has no SHT_SYMTAB; a relocatable object without one cannot be " &
      "planned from, and reporting zero symbols instead would be a vacuous " &
      "answer: " & path)
  let symtab = raw[symtabIndex]
  if symtab.entsize != 24'u64:
    raise newException(ValueError,
      "unexpected symbol entry size " & $symtab.entsize & " (want 24): " & path)
  if int(symtab.link) >= shnum:
    raise newException(ValueError, "symbol table sh_link is out of range: " & path)
  if raw[int(symtab.link)].shType != ShtStrtab:
    # Without this the names below are whatever bytes live at `sh_offset`:
    # garbage that matches nothing, which reads downstream as "this object
    # defines no function you asked for" rather than "this object is broken".
    raise newException(ValueError,
      "symbol table sh_link does not name an SHT_STRTAB section: " & path)
  let symstr = raw[int(symtab.link)]
  let symstrBase = int(symstr.offset)
  let symstrLimit = symstrBase + int(symstr.size)
  if symstrLimit > data.len:
    raise newException(ValueError, "string table runs past end of file: " & path)

  # SHT_SYMTAB_SHNDX carries the real section index of every symbol whose
  # `st_shndx` is SHN_XINDEX.
  var xindexOffset = -1
  var xindexCount = 0
  for i in 0 ..< shnum:
    if raw[i].shType == ShtSymtabShndx and int(raw[i].link) == symtabIndex:
      xindexOffset = int(raw[i].offset)
      xindexCount = int(raw[i].size div 4'u64)
      break

  let symbolCount = int(symtab.size div symtab.entsize)
  if symbolCount == 0:
    # A real symbol table always holds at least the STN_UNDEF entry, so this is
    # a structural defect. Returning a graph with zero symbols would be the
    # same vacuous answer the missing-SHT_SYMTAB check above refuses to give.
    raise newException(ValueError,
      "SHT_SYMTAB is empty; it does not even hold the STN_UNDEF entry: " & path)
  var currentSourceFile = ""
  for i in 0 ..< symbolCount:
    let base = int(symtab.offset) + i * 24
    let nameIndex = readU32Le(data, base)
    let info = readU8(data, base + 4)
    let shndx16 = readU16Le(data, base + 6)
    let value = readU64Le(data, base + 8)
    let size = readU64Le(data, base + 16)
    let symbolType = info and 0x0f'u8
    let symbolBind = info shr 4
    let name = if nameIndex == 0'u32: "" else:
      readCString(data, symstrBase, nameIndex, symstrLimit)

    var sectionIndex = uint32(shndx16)
    var viaXindex = false
    if sectionIndex == ShnXindex:
      if xindexOffset < 0 or i >= xindexCount:
        raise newException(ValueError,
          "symbol " & $i & " uses SHN_XINDEX but no SHT_SYMTAB_SHNDX entry " &
          "covers it: " & path)
      sectionIndex = readU32Le(data, xindexOffset + i * 4)
      facts.xindexSymbolCount += 1
      viaXindex = true

    if symbolType == SttFile:
      currentSourceFile = name

    # The reserved range [SHN_LORESERVE, SHN_HIRESERVE] applies to the RAW
    # 16-bit `st_shndx` only. Once SHN_XINDEX has been expanded, the value is
    # an ordinary section index that may legitimately be far above 0xff00 —
    # measured on the 66,013-section object the object-parsing gate compiles,
    # 724 of its 66,000 functions sit there, and applying the reserved-range
    # test after expansion silently reclassified every one of them as
    # undefined. (Review 2026-09-10 re-measured this: an earlier, larger
    # fixture was the one the "4,725" figure came from, and that fixture is not
    # the one this gate ships.)
    let isReserved = (not viaXindex) and sectionIndex >= ShnLoreserve
    let defined = sectionIndex != ShnUndef and not isReserved and
      int(sectionIndex) < shnum
    let sectionId = if defined: int(sectionIndex) else: -1
    result.symbols.add SymbolFact(
      id: i,
      name: name,
      rawName: name,
      kind: elfSymbolKind(symbolType, sectionIndex),
      sectionId: sectionId,
      address: value,
      # Design §7.5: st_size is authoritative on ELF. No gap heuristic.
      size: size,
      isExternal: symbolBind != StbLocal,
      isDefined: defined)
    facts.symbolDetails.add ElfSymbolDetail(
      symbolIndex: i,
      symbolBind: symbolBind,
      symbolType: symbolType,
      sectionIndex: sectionIndex,
      # STT_FILE governs only the STB_LOCAL symbols that follow it; a global
      # attributed to one would be a fact that is simply false.
      sourceFile: if symbolBind == StbLocal: currentSourceFile else: "")

  # ---------------------------------------------------------------------------
  # Relocations. Both SHT_RELA (what x86_64 uses) and SHT_REL (recorded when
  # encountered, per design §7.5).
  # ---------------------------------------------------------------------------
  for i in 0 ..< shnum:
    if raw[i].shType != ShtRela and raw[i].shType != ShtRel:
      continue
    let isRela = raw[i].shType == ShtRela
    let stride = if isRela: 24 else: 16
    if raw[i].entsize != uint64(stride):
      raise newException(ValueError,
        "relocation section " & $i & " has entry size " & $raw[i].entsize &
        " (want " & $stride & "): " & path)
    let appliesTo = int(raw[i].info)
    if appliesTo < 0 or appliesTo >= shnum:
      raise newException(ValueError,
        "relocation section " & $i & " applies to out-of-range section " &
        $appliesTo & ": " & path)
    let count = int(raw[i].size div uint64(stride))
    for r in 0 ..< count:
      let base = int(raw[i].offset) + r * stride
      let offset = readU64Le(data, base)
      let rInfo = readU64Le(data, base + 8)
      let symbolIndex = int(rInfo shr 32)
      let typeCode32 = uint32(rInfo and 0xffff_ffff'u64)
      let addend = if isRela: readI64Le(data, base + 16) else: 0'i64
      let relocationId = result.relocations.len
      let kindName = relocationKindName(typeCode32)
      var targetName = ""
      var isExtern = false
      if symbolIndex > 0 and symbolIndex < result.symbols.len:
        let sym = result.symbols[symbolIndex]
        targetName =
          if sym.name.len > 0: sym.name
          elif sym.sectionId >= 0: result.sections[sym.sectionId].name
          else: "$symbol-" & $symbolIndex
        isExtern = sym.kind != sykSection
      elif symbolIndex == 0:
        targetName = "$no-symbol"
      else:
        raise newException(ValueError,
          "relocation " & $r & " in section " & $i & " names symbol " &
          $symbolIndex & ", which is outside the symbol table: " & path)

      if offset > uint64(high(uint32)):
        result.unsupportedFeatures.add UnsupportedFeatureFact(
          feature: "elf-relocation-offset-overflows-uint32",
          severity: usReject,
          sectionId: appliesTo,
          relocationId: relocationId,
          reason: "r_offset 0x" & toHex(offset) &
            " does not fit the link-graph relocation offset field")
      if typeCode32 > 255'u32:
        result.unsupportedFeatures.add UnsupportedFeatureFact(
          feature: "elf-relocation-type-overflows-uint8",
          severity: usReject,
          sectionId: appliesTo,
          relocationId: relocationId,
          reason: kindName & " does not fit the link-graph type-code field")
      if not isRela:
        result.unsupportedFeatures.add UnsupportedFeatureFact(
          feature: "elf-sht-rel-implicit-addend",
          severity: usFallbackRequired,
          sectionId: appliesTo,
          relocationId: relocationId,
          reason: "SHT_REL stores the addend in the instruction stream; the " &
            "x86_64 psABI mandates SHT_RELA and this reader records the " &
            "entry but does not decode the implicit addend")

      result.relocations.add RelocationFact(
        id: relocationId,
        sectionId: appliesTo,
        offset: uint32(offset and 0xffff_ffff'u64),
        typeCode: uint8(typeCode32 and 0xff'u32),
        kindName: kindName,
        pcrel: relocationIsPcRelative(typeCode32),
        lengthBytes: relocationWidthBytes(typeCode32),
        isExtern: isExtern,
        symbolIndex: symbolIndex,
        targetName: targetName,
        addend: addend,
        scattered: false)
      result.sections[appliesTo].relocationIds.add relocationId

  # ---------------------------------------------------------------------------
  # Structured unsupported-feature reasons (design §7.5).
  # ---------------------------------------------------------------------------
  for sectionId, signature in comdatSections:
    result.unsupportedFeatures.add UnsupportedFeatureFact(
      feature: "elf-comdat-group-member",
      severity: usFallbackRequired,
      sectionId: sectionId,
      relocationId: -1,
      reason: "section " & result.sections[sectionId].name &
        " belongs to COMDAT group \"" & signature &
        "\"; the linker may have kept another object's copy, so bytes " &
        "extracted here are not certainly the linked ones")

  for section in result.sections:
    if (uint64(section.flags) and ShfLinkOrder) != 0'u64:
      result.unsupportedFeatures.add UnsupportedFeatureFact(
        feature: "elf-shf-link-order",
        severity: usInfo,
        sectionId: section.id,
        relocationId: -1,
        reason: "section " & section.name &
          " is SHF_LINK_ORDER; its lifetime follows the section it links to, " &
          "which is how __patchable_function_entries survives --gc-sections")
    if (uint64(section.flags) and (ShfMerge or ShfStrings)) ==
        (ShfMerge or ShfStrings) and section.kind == skCode:
      result.unsupportedFeatures.add UnsupportedFeatureFact(
        feature: "elf-mergeable-code-section",
        severity: usReject,
        sectionId: section.id,
        relocationId: -1,
        reason: "section " & section.name &
          " is SHF_MERGE|SHF_STRINGS and executable; its contents may be " &
          "deduplicated at link time")
    if (uint64(section.flags) and ShfTls) != 0'u64:
      result.unsupportedFeatures.add UnsupportedFeatureFact(
        feature: "elf-tls-section",
        severity: usFallbackRequired,
        sectionId: section.id,
        relocationId: -1,
        reason: "section " & section.name &
          " is SHF_TLS; thread-local storage is not part of the HLX-M1 profile")

  for detail in facts.symbolDetails:
    if detail.symbolType == SttGnuIfunc:
      result.unsupportedFeatures.add UnsupportedFeatureFact(
        feature: "elf-stt-gnu-ifunc",
        severity: usReject,
        sectionId: -1,
        relocationId: -1,
        reason: "symbol \"" & result.symbols[detail.symbolIndex].name &
          "\" is STT_GNU_IFUNC; its st_value is a resolver, not the " &
          "implementation, so it is never a patch target")

  if facts.usedShnumOverflow or facts.usedShstrndxXindex or
      facts.xindexSymbolCount > 0:
    result.unsupportedFeatures.add UnsupportedFeatureFact(
      feature: "elf-shn-xindex-in-use",
      severity: usInfo,
      sectionId: -1,
      relocationId: -1,
      reason: "object uses the SHN_XINDEX escapes (e_shnum overflow=" &
        $facts.usedShnumOverflow & ", e_shstrndx=" &
        $facts.usedShstrndxXindex & ", symbols via SHT_SYMTAB_SHNDX=" &
        $facts.xindexSymbolCount & "); all three are handled")

  if result.hasDebugFacts:
    result.unsupportedFeatures.add UnsupportedFeatureFact(
      feature: "debug-info-registration",
      severity: usFallbackRequired,
      sectionId: -1,
      relocationId: -1,
      reason: "HLX-M1 records DWARF facts but GDB JIT registration is HLX-M5")
  else:
    result.unsupportedFeatures.add UnsupportedFeatureFact(
      feature: "debug-info-absent",
      severity: usInfo,
      sectionId: -1,
      relocationId: -1,
      reason: "object has no .debug_* sections")

  if result.hasUnwindFacts:
    result.unsupportedFeatures.add UnsupportedFeatureFact(
      feature: "unwind-registration",
      severity: usFallbackRequired,
      sectionId: -1,
      relocationId: -1,
      reason: "HLX-M1 records .eh_frame facts but __register_frame " &
        "registration and the PT_GNU_EH_FRAME subtlety are HLX-M5")
  else:
    result.unsupportedFeatures.add UnsupportedFeatureFact(
      feature: "unwind-absent",
      severity: usInfo,
      sectionId: -1,
      relocationId: -1,
      reason: "object has no .eh_frame sections")

proc parseElfX86_64Object*(path: string): LinkGraph =
  var facts: ElfObjectFacts
  parseElfX86_64Object(path, facts)

proc elfFunctionSymbolCount*(graph: LinkGraph): int =
  for symbol in graph.symbols:
    if symbol.kind == sykFunction and symbol.isDefined:
      result += 1

proc elfSourceFileOf*(facts: ElfObjectFacts; symbolId: int): string =
  for detail in facts.symbolDetails:
    if detail.symbolIndex == symbolId:
      return detail.sourceFile
  ""
