## Minimal ELF64 `ET_REL` reader used by the HLX-M0 gates.
##
## Deliberately narrow: it reads section headers, `.symtab`/`.strtab` and
## relocation counts from a REAL relocatable object produced by a REAL compiler
## invocation, which is what the gates need in order to send real patch bytes
## over the wire and to assert that the extracted body carries no relocations.
##
## It is not the HLX-M1 pipeline and must not grow into one. HLX-M1 owns the
## production ELF reader (`SHN_XINDEX`, `SHT_GROUP`/`GRP_COMDAT`,
## `SHF_LINK_ORDER`, `.debug_*`, `.eh_frame`, structured unsupported-feature
## reasons, build-id verification). This helper exists so the HLX-M0 gates do
## not have to hand-assemble their patch bytes.

import std/[strutils]

type
  ElfSection* = object
    name*: string
    shType*: uint32
    flags*: uint64
    vaddr*: uint64
    offset*: uint64
    size*: uint64
    link*: uint32
    info*: uint32
    entsize*: uint64

  ElfSymbol* = object
    name*: string
    value*: uint64
    size*: uint64
    info*: uint8
    shndx*: uint16

  ElfRelObject* = object
    bytes*: seq[byte]
    sections*: seq[ElfSection]
    symbols*: seq[ElfSymbol]

proc readU16(bytes: openArray[byte]; offset: int): uint16 =
  uint16(bytes[offset]) or (uint16(bytes[offset + 1]) shl 8)

proc readU32(bytes: openArray[byte]; offset: int): uint32 =
  uint32(bytes[offset]) or (uint32(bytes[offset + 1]) shl 8) or
    (uint32(bytes[offset + 2]) shl 16) or (uint32(bytes[offset + 3]) shl 24)

proc readU64(bytes: openArray[byte]; offset: int): uint64 =
  var result0: uint64 = 0
  for i in countdown(7, 0):
    result0 = (result0 shl 8) or uint64(bytes[offset + i])
  result0

proc cstringAt(bytes: openArray[byte]; base, index: int): string =
  var i = base + index
  while i < bytes.len and bytes[i] != 0:
    result.add char(bytes[i])
    inc i

proc readFileBytes*(path: string): seq[byte] =
  let raw = readFile(path)
  result = newSeq[byte](raw.len)
  for i, ch in raw:
    result[i] = byte(ord(ch))

proc parseElfRelObject*(path: string): ElfRelObject =
  result.bytes = readFileBytes(path)
  let b = result.bytes
  if b.len < 64:
    raise newException(ValueError, "not an ELF64 object (too short): " & path)
  if not (b[0] == 0x7f'u8 and b[1] == byte('E') and b[2] == byte('L') and
          b[3] == byte('F')):
    raise newException(ValueError, "missing ELF magic: " & path)
  if b[4] != 2'u8:
    raise newException(ValueError, "not ELFCLASS64: " & path)
  if b[5] != 1'u8:
    raise newException(ValueError, "not little-endian ELF: " & path)
  let eType = readU16(b, 16)
  if eType != 1'u16:
    raise newException(ValueError,
      "expected ET_REL (1), got " & $eType & ": " & path)

  let shoff = int(readU64(b, 0x28))
  let shentsize = int(readU16(b, 0x3a))
  let shnum = int(readU16(b, 0x3c))
  let shstrndx = int(readU16(b, 0x3e))
  if shoff == 0 or shnum == 0:
    raise newException(ValueError, "object has no section headers: " & path)

  var raw: seq[ElfSection] = @[]
  for i in 0 ..< shnum:
    let base = shoff + i * shentsize
    raw.add ElfSection(
      name: $readU32(b, base),
      shType: readU32(b, base + 4),
      flags: readU64(b, base + 8),
      vaddr: readU64(b, base + 16),
      offset: readU64(b, base + 24),
      size: readU64(b, base + 32),
      link: readU32(b, base + 40),
      info: readU32(b, base + 44),
      entsize: readU64(b, base + 56))

  let strBase = int(raw[shstrndx].offset)
  for i in 0 ..< shnum:
    let base = shoff + i * shentsize
    var section = raw[i]
    section.name = cstringAt(b, strBase, int(readU32(b, base)))
    result.sections.add section

  for section in result.sections:
    if section.shType != 2'u32: # SHT_SYMTAB
      continue
    let linkedStr = result.sections[int(section.link)]
    let entries = int(section.size div section.entsize)
    for i in 0 ..< entries:
      let base = int(section.offset) + i * int(section.entsize)
      result.symbols.add ElfSymbol(
        name: cstringAt(b, int(linkedStr.offset), int(readU32(b, base))),
        info: b[base + 4],
        shndx: readU16(b, base + 6),
        value: readU64(b, base + 8),
        size: readU64(b, base + 16))

proc sectionIndex*(obj: ElfRelObject; name: string): int =
  result = -1
  for i, section in obj.sections:
    if section.name == name:
      return i

proc sectionBytes*(obj: ElfRelObject; name: string): seq[byte] =
  let index = obj.sectionIndex(name)
  if index < 0:
    raise newException(ValueError, "object has no section named " & name)
  let section = obj.sections[index]
  result = newSeq[byte](int(section.size))
  for i in 0 ..< int(section.size):
    result[i] = obj.bytes[int(section.offset) + i]

proc relocationCount*(obj: ElfRelObject; sectionName: string): int =
  ## Number of entries in `.rela<sectionName>` (0 when the object has none).
  let index = obj.sectionIndex(".rela" & sectionName)
  if index < 0:
    return 0
  let section = obj.sections[index]
  if section.entsize == 0:
    return 0
  int(section.size div section.entsize)

proc symbol*(obj: ElfRelObject; name: string): ElfSymbol =
  for candidate in obj.symbols:
    if candidate.name == name:
      return candidate
  raise newException(ValueError, "object has no symbol named " & name)

proc functionBytes*(obj: ElfRelObject; symbolName: string): seq[byte] =
  ## The bytes of `symbolName`'s body, taken from the section it is defined in.
  let sym = obj.symbol(symbolName)
  if sym.shndx == 0'u16 or int(sym.shndx) >= obj.sections.len:
    raise newException(ValueError,
      "symbol " & symbolName & " is not defined in a section of this object")
  if sym.size == 0:
    raise newException(ValueError,
      "symbol " & symbolName & " has zero st_size; refusing to guess a length")
  let section = obj.sections[int(sym.shndx)]
  let start = int(section.offset) + int(sym.value)
  result = newSeq[byte](int(sym.size))
  for i in 0 ..< int(sym.size):
    result[i] = obj.bytes[start + i]

proc definingSectionName*(obj: ElfRelObject; symbolName: string): string =
  let sym = obj.symbol(symbolName)
  obj.sections[int(sym.shndx)].name

proc hexBytes*(bytes: openArray[byte]): string =
  for b in bytes:
    result.add toHex(int(b), 2).toLowerAscii()
