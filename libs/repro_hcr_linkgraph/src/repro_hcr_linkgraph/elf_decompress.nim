## `SHF_COMPRESSED` section expansion for ELF64 relocatable objects (HLX-M8).
##
## Design: `reprobuild-specs/HCR/Linux-ELF-Provider.md` §5.1 (what
## `prepare-object` is for), §8 (why a compressed `.debug_*` cannot be
## relocated in process).
##
## ## Why this exists
##
## The Linux HCR agent applies relocations to the patch object's `.debug_*` and
## `.eh_frame` sections IN MEMORY, so a debugger stopping inside the patched
## body attributes it correctly. `SHF_COMPRESSED` puts an `Elf64_Chdr` and a
## zlib stream where the relocation offsets say the debug bytes are, so
## relocating into it would corrupt the stream — and the corruption would
## surface as WRONG LINE NUMBERS rather than as an error. The provider
## therefore refuses such an object by name
## (`debug-object-compressed-debug-section`,
## `libs/repro_hcr_agent/c/repro_hcr_linux_unwind.h`).
##
## That refusal is correct and stays. What was wrong is WHERE the problem was
## being solved. GCC on this toolchain emits `SHF_COMPRESSED` `.debug_*` BY
## DEFAULT, so an ordinary `gcc(debug3 = true)` build edge produces a patch
## object the agent can never register. The only remedy was a per-edge
## `debugCompression = "none"` flag that exists on `gcc` and cannot be
## expressed on `clang` at all, that exactly one HCR edge in this repo carried,
## and that nothing prevents the next edge from omitting. `prepare-object` is
## the pass whose whole job is to make an object patchable; expanding the
## sections there fixes the class instead of the instances.
##
## ## Why a DEFLATE decoder is written out here
##
## `repro_hcr_linkgraph` has no third-party dependencies and this module keeps
## it that way. Shelling out to `objcopy --decompress-debug-sections` would
## make a build edge depend on a binutils binary that the object's own
## toolchain need not ship, and binding `libz` would add a link dependency to
## every consumer of this library for one call. The decoder below is RFC 1951
## inflate plus the RFC 1950 zlib wrapper, in the shape `zlib`'s own reference
## decoder `puff.c` uses; the gate cross-checks its output against
## `objcopy --decompress-debug-sections`, which is an independent producer.
##
## ## What is NOT handled, and says so
##
## `ELFCOMPRESS_ZSTD` (`ch_type == 2`) is REFUSED BY NAME rather than passed
## through. A pass-through would hand the agent the same compressed stream it
## already refuses, one step further from the cause; the refusal here names the
## remedy (`-gz=none` / `gcc(debugCompression = "none")`) at the step that could
## have fixed it.

import std/[algorithm, strutils]
from repro_core/paths import extendedPath

const
  # e_ident
  ElfClass64 = 2'u8
  ElfData2Lsb = 1'u8
  # sh_type
  ShtNull = 0'u32
  ShtNobits = 8'u32
  # sh_flags
  ShfCompressed* = 0x800'u64
  # special section indices
  ShnXindex = 0xffff'u16
  # Elf64_Chdr.ch_type
  ElfCompressZlib* = 1'u32
  ElfCompressZstd* = 2'u32

  Elf64EhdrSize = 64
  Elf64ShdrSize = 64
  Elf64ChdrSize = 24

type
  ElfDecompressedSection* = object
    ## One section this pass expanded, reported so a caller can assert on the
    ## expansion rather than on the command having exited 0.
    name*: string
    index*: int
    compressedBytes*: int   ## including the 24-byte `Elf64_Chdr`
    expandedBytes*: int     ## `ch_size`

  ElfDecompressReport* = object
    ## The outcome of one `expandElfCompressedSections` call.
    sectionCount*: int          ## sections in the object, XINDEX-expanded
    expanded*: seq[ElfDecompressedSection]
    rewritten*: bool
      ## False when the object carried no `SHF_COMPRESSED` section at all, in
      ## which case the output is byte-identical to the input. Reported
      ## separately from `expanded.len` so a caller can distinguish "nothing to
      ## do" from "did nothing".

  ElfDecompressError* = object of CatchableError
    ## Raised for every structural refusal. `reason` is the stable machine name;
    ## `msg` carries the remedy a reader acts on.
    reason*: string

proc fail(reason, message: string) {.noreturn.} =
  var err = newException(ElfDecompressError, message)
  err.reason = reason
  raise err

# ---------------------------------------------------------------------------
# RFC 1951 inflate.
# ---------------------------------------------------------------------------

type
  BitReader = object
    data: string
    pos: int        ## next byte to consume
    bitBuf: uint32
    bitCount: int

  Huffman = object
    ## Canonical Huffman table in `puff.c`'s counts/symbols form: `counts[n]` is
    ## how many codes have length `n`, and `symbols` lists the symbols in
    ## canonical order. Decoding walks lengths 1..15 and needs no table
    ## expansion, which keeps this decoder small enough to read.
    counts: array[0 .. 15, int]
    symbols: seq[int]

const
  LengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
                35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  LengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
                 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
  DistBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
              257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
              8193, 12289, 16385, 24577]
  DistExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
               7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
  CodeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4,
                     12, 3, 13, 2, 14, 1, 15]

proc bit(br: var BitReader): int =
  if br.bitCount == 0:
    if br.pos >= br.data.len:
      fail("elf-compressed-section-stream-truncated",
        "DEFLATE stream ended while more bits were required")
    br.bitBuf = uint32(ord(br.data[br.pos]))
    br.pos.inc
    br.bitCount = 8
  result = int(br.bitBuf and 1'u32)
  br.bitBuf = br.bitBuf shr 1
  br.bitCount.dec

proc bits(br: var BitReader; count: int): int =
  result = 0
  for i in 0 ..< count:
    result = result or (br.bit() shl i)

proc buildHuffman(lengths: openArray[int]): Huffman =
  for length in lengths:
    if length < 0 or length > 15:
      fail("elf-compressed-section-stream-malformed",
        "DEFLATE code length " & $length & " is out of range")
    result.counts[length].inc
  if result.counts[0] == lengths.len:
    # An all-zero table is legal only for the distance alphabet of a block
    # that emits no matches. Leave it empty; `decodeSymbol` refuses to use it.
    return
  # Reject over- and under-subscribed tables. A decoder that accepts them
  # silently invents symbols for bit patterns the encoder never emitted.
  var left = 1
  for length in 1 .. 15:
    left = left shl 1
    left -= result.counts[length]
    if left < 0:
      fail("elf-compressed-section-stream-malformed",
        "DEFLATE Huffman table is over-subscribed")
  # `offsets[1]` is 0, NOT `counts[0]`: `counts[0]` is how many symbols have no
  # code at all, and those occupy no place in the canonical ordering. Seeding
  # this with `counts[0]` shifts every symbol the decoder returns by the number
  # of unused symbols, which is a silent wrong answer rather than a failure —
  # it surfaced here as a downstream "over-subscribed" refusal building a table
  # out of lengths that had been decoded from the wrong alphabet.
  var offsets: array[0 .. 16, int]
  offsets[1] = 0
  for length in 1 .. 15:
    offsets[length + 1] = offsets[length] + result.counts[length]
  result.symbols = newSeq[int](lengths.len)
  for symbol in 0 ..< lengths.len:
    if lengths[symbol] != 0:
      result.symbols[offsets[lengths[symbol]]] = symbol
      offsets[lengths[symbol]].inc

proc decodeSymbol(br: var BitReader; table: Huffman): int =
  var
    code = 0
    first = 0
    index = 0
  for length in 1 .. 15:
    code = code or br.bit()
    let count = table.counts[length]
    if code - first < count:
      return table.symbols[index + (code - first)]
    index += count
    first = (first + count) shl 1
    code = code shl 1
  fail("elf-compressed-section-stream-malformed",
    "DEFLATE symbol is longer than 15 bits")

proc fixedTables(): tuple[lit, dist: Huffman] =
  var litLengths = newSeq[int](288)
  for i in 0 ..< 144: litLengths[i] = 8
  for i in 144 ..< 256: litLengths[i] = 9
  for i in 256 ..< 280: litLengths[i] = 7
  for i in 280 ..< 288: litLengths[i] = 8
  var distLengths = newSeq[int](30)
  for i in 0 ..< 30: distLengths[i] = 5
  (buildHuffman(litLengths), buildHuffman(distLengths))

proc inflateBlock(br: var BitReader; out2: var seq[byte];
                  lit, dist: Huffman; limit: int) =
  while true:
    let symbol = br.decodeSymbol(lit)
    if symbol < 256:
      if out2.len >= limit:
        fail("elf-compressed-section-size-mismatch",
          "DEFLATE stream produced more bytes than the section header declared")
      out2.add byte(symbol)
    elif symbol == 256:
      return
    else:
      let lengthIndex = symbol - 257
      if lengthIndex >= LengthBase.len:
        fail("elf-compressed-section-stream-malformed",
          "DEFLATE length symbol " & $symbol & " is not defined")
      let matchLength = LengthBase[lengthIndex] +
        br.bits(LengthExtra[lengthIndex])
      let distSymbol = br.decodeSymbol(dist)
      if distSymbol >= DistBase.len:
        fail("elf-compressed-section-stream-malformed",
          "DEFLATE distance symbol " & $distSymbol & " is not defined")
      let distance = DistBase[distSymbol] + br.bits(DistExtra[distSymbol])
      if distance > out2.len:
        fail("elf-compressed-section-stream-malformed",
          "DEFLATE back-reference reaches before the start of the output")
      if out2.len + matchLength > limit:
        fail("elf-compressed-section-size-mismatch",
          "DEFLATE stream produced more bytes than the section header declared")
      let start = out2.len - distance
      for i in 0 ..< matchLength:
        out2.add out2[start + i]

proc inflateRaw(data: string; start, limit: int): seq[byte] =
  ## RFC 1951. `limit` is the exact byte count the caller expects, taken from
  ## `Elf64_Chdr.ch_size` — an inflate that overruns it is refused rather than
  ## grown, because the declared size is the only independent statement of how
  ## large the section is.
  var br = BitReader(data: data, pos: start, bitBuf: 0, bitCount: 0)
  result = newSeqOfCap[byte](limit)
  while true:
    let final = br.bit()
    let blockType = br.bits(2)
    case blockType
    of 0:
      # Stored: discard the remaining bits of the current byte, then LEN/NLEN.
      br.bitCount = 0
      br.bitBuf = 0
      if br.pos + 4 > br.data.len:
        fail("elf-compressed-section-stream-truncated",
          "DEFLATE stored block header is truncated")
      let length = int(uint8(ord(br.data[br.pos]))) or
        (int(uint8(ord(br.data[br.pos + 1]))) shl 8)
      let inverse = int(uint8(ord(br.data[br.pos + 2]))) or
        (int(uint8(ord(br.data[br.pos + 3]))) shl 8)
      if (length xor 0xFFFF) != inverse:
        fail("elf-compressed-section-stream-malformed",
          "DEFLATE stored block LEN/NLEN disagree")
      br.pos += 4
      if br.pos + length > br.data.len:
        fail("elf-compressed-section-stream-truncated",
          "DEFLATE stored block runs past the end of the stream")
      if result.len + length > limit:
        fail("elf-compressed-section-size-mismatch",
          "DEFLATE stream produced more bytes than the section header declared")
      for i in 0 ..< length:
        result.add byte(ord(br.data[br.pos + i]))
      br.pos += length
    of 1:
      let tables = fixedTables()
      inflateBlock(br, result, tables.lit, tables.dist, limit)
    of 2:
      let litCount = br.bits(5) + 257
      let distCount = br.bits(5) + 1
      let codeCount = br.bits(4) + 4
      if litCount > 286 or distCount > 30:
        fail("elf-compressed-section-stream-malformed",
          "DEFLATE dynamic block declares too many codes")
      var codeLengths = newSeq[int](19)
      for i in 0 ..< codeCount:
        codeLengths[CodeLengthOrder[i]] = br.bits(3)
      let codeTable = buildHuffman(codeLengths)
      var lengths = newSeq[int](litCount + distCount)
      var index = 0
      while index < lengths.len:
        let symbol = br.decodeSymbol(codeTable)
        if symbol < 16:
          lengths[index] = symbol
          index.inc
        elif symbol == 16:
          if index == 0:
            fail("elf-compressed-section-stream-malformed",
              "DEFLATE repeat code appears before any length")
          let previous = lengths[index - 1]
          let repeat = 3 + br.bits(2)
          for _ in 0 ..< repeat:
            if index >= lengths.len:
              fail("elf-compressed-section-stream-malformed",
                "DEFLATE code-length repeat overruns the alphabet")
            lengths[index] = previous
            index.inc
        elif symbol == 17:
          let repeat = 3 + br.bits(3)
          for _ in 0 ..< repeat:
            if index >= lengths.len:
              fail("elf-compressed-section-stream-malformed",
                "DEFLATE code-length repeat overruns the alphabet")
            lengths[index] = 0
            index.inc
        else:
          let repeat = 11 + br.bits(7)
          for _ in 0 ..< repeat:
            if index >= lengths.len:
              fail("elf-compressed-section-stream-malformed",
                "DEFLATE code-length repeat overruns the alphabet")
            lengths[index] = 0
            index.inc
      let lit = buildHuffman(lengths[0 ..< litCount])
      let dist = buildHuffman(lengths[litCount ..< lengths.len])
      inflateBlock(br, result, lit, dist, limit)
    else:
      fail("elf-compressed-section-stream-malformed",
        "DEFLATE block type 3 is reserved")
    if final == 1:
      break

proc adler32(data: openArray[byte]): uint32 =
  var a = 1'u32
  var b = 0'u32
  for value in data:
    a = (a + uint32(value)) mod 65521'u32
    b = (b + a) mod 65521'u32
  (b shl 16) or a

proc zlibDecompress(data: string; start, expanded: int): seq[byte] =
  ## RFC 1950. The trailing Adler-32 is VERIFIED, not skipped: it is the only
  ## end-to-end check that the decoder above reproduced what the compressor
  ## consumed, and a decoder that silently produces plausible-but-wrong debug
  ## bytes is the exact failure this module exists to prevent.
  if start + 2 > data.len:
    fail("elf-compressed-section-stream-truncated",
      "zlib stream is shorter than its two-byte header")
  let cmf = uint32(ord(data[start]))
  let flg = uint32(ord(data[start + 1]))
  if (cmf and 0x0F'u32) != 8'u32:
    fail("elf-compressed-section-stream-malformed",
      "zlib compression method " & $(cmf and 0x0F'u32) & " is not DEFLATE")
  if ((cmf shl 8) or flg) mod 31'u32 != 0'u32:
    fail("elf-compressed-section-stream-malformed",
      "zlib header check bits are wrong")
  if (flg and 0x20'u32) != 0'u32:
    fail("elf-compressed-section-stream-malformed",
      "zlib stream uses a preset dictionary, which no ELF producer emits")
  result = inflateRaw(data, start + 2, expanded)
  if result.len != expanded:
    fail("elf-compressed-section-size-mismatch",
      "zlib stream expanded to " & $result.len & " bytes but Elf64_Chdr.ch_size " &
      "declared " & $expanded)
  # The Adler-32 follows the DEFLATE stream on a byte boundary. Locating it by
  # counting back from the END of the section is deliberate: it does not depend
  # on this decoder's idea of where the stream stopped, so a decoder that
  # consumed the wrong number of bytes cannot also pick the wrong checksum and
  # agree with itself.
  let checksumAt = data.len - 4
  if checksumAt < start + 2:
    fail("elf-compressed-section-stream-truncated",
      "zlib stream has no room for its Adler-32 trailer")
  let stored = (uint32(ord(data[checksumAt])) shl 24) or
    (uint32(ord(data[checksumAt + 1])) shl 16) or
    (uint32(ord(data[checksumAt + 2])) shl 8) or
    uint32(ord(data[checksumAt + 3]))
  let computed = adler32(result)
  if stored != computed:
    fail("elf-compressed-section-checksum-mismatch",
      "zlib Adler-32 is 0x" & toHex(stored, 8) & " but the expanded bytes " &
      "hash to 0x" & toHex(computed, 8))

# ---------------------------------------------------------------------------
# ELF64 read/write.
# ---------------------------------------------------------------------------

proc readU16(data: string; pos: int): uint16 =
  if pos < 0 or pos + 2 > data.len:
    fail("elf-truncated", "truncated ELF uint16 at " & $pos)
  uint16(ord(data[pos])) or (uint16(ord(data[pos + 1])) shl 8)

proc readU32(data: string; pos: int): uint32 =
  if pos < 0 or pos + 4 > data.len:
    fail("elf-truncated", "truncated ELF uint32 at " & $pos)
  uint32(uint8(ord(data[pos]))) or
    (uint32(uint8(ord(data[pos + 1]))) shl 8) or
    (uint32(uint8(ord(data[pos + 2]))) shl 16) or
    (uint32(uint8(ord(data[pos + 3]))) shl 24)

proc readU64(data: string; pos: int): uint64 =
  uint64(readU32(data, pos)) or (uint64(readU32(data, pos + 4)) shl 32)

proc writeU16(buffer: var string; pos: int; value: uint16) =
  buffer[pos] = chr(int(value and 0xFF'u16))
  buffer[pos + 1] = chr(int((value shr 8) and 0xFF'u16))

proc writeU32(buffer: var string; pos: int; value: uint32) =
  for i in 0 ..< 4:
    buffer[pos + i] = chr(int((value shr (8 * i)) and 0xFF'u32))

proc writeU64(buffer: var string; pos: int; value: uint64) =
  for i in 0 ..< 8:
    buffer[pos + i] = chr(int((value shr (8 * i)) and 0xFF'u64))

proc alignUp(value, alignment: uint64): uint64 =
  if alignment <= 1'u64: value
  else: ((value + alignment - 1'u64) div alignment) * alignment

type
  SectionHeader = object
    name: uint32
    shType: uint32
    flags: uint64
    address: uint64
    offset: uint64
    size: uint64
    link: uint32
    info: uint32
    addralign: uint64
    entsize: uint64

proc readSectionHeader(data: string; base: int): SectionHeader =
  SectionHeader(
    name: readU32(data, base + 0),
    shType: readU32(data, base + 4),
    flags: readU64(data, base + 8),
    address: readU64(data, base + 16),
    offset: readU64(data, base + 24),
    size: readU64(data, base + 32),
    link: readU32(data, base + 40),
    info: readU32(data, base + 44),
    addralign: readU64(data, base + 48),
    entsize: readU64(data, base + 56))

proc writeSectionHeader(buffer: var string; base: int; header: SectionHeader) =
  writeU32(buffer, base + 0, header.name)
  writeU32(buffer, base + 4, header.shType)
  writeU64(buffer, base + 8, header.flags)
  writeU64(buffer, base + 16, header.address)
  writeU64(buffer, base + 24, header.offset)
  writeU64(buffer, base + 32, header.size)
  writeU32(buffer, base + 40, header.link)
  writeU32(buffer, base + 44, header.info)
  writeU64(buffer, base + 48, header.addralign)
  writeU64(buffer, base + 56, header.entsize)

proc sectionName(data: string; strtabOffset, strtabSize: int;
                 nameIndex: uint32): string =
  if strtabSize == 0: return ""
  var cursor = strtabOffset + int(nameIndex)
  if cursor < 0 or cursor >= strtabOffset + strtabSize or cursor >= data.len:
    return ""
  result = ""
  while cursor < data.len and data[cursor] != '\0':
    result.add data[cursor]
    cursor.inc

proc expandElfCompressedSections*(inputPath, outputPath: string):
    ElfDecompressReport =
  ## Copy `inputPath` to `outputPath`, expanding every `SHF_COMPRESSED` section
  ## on the way and clearing the flag. When the object carries none, the output
  ## is a byte-for-byte copy and `rewritten` is false.
  ##
  ## Section INDICES are preserved exactly. Everything that refers to a section
  ## — `sh_link`, `sh_info`, `SHT_GROUP` membership, `st_shndx`, the relocation
  ## sections' targets — is an index, so preserving them is what makes this a
  ## content rewrite rather than a relink. Relocation `r_offset` values are
  ## section-relative and are likewise untouched; they were always offsets into
  ## the EXPANDED bytes, which is precisely why relocating a compressed section
  ## corrupts it.
  let data = readFile(extendedPath(inputPath))
  if data.len < Elf64EhdrSize or data[0 .. 3] != "\x7FELF":
    fail("elf-not-an-object",
      inputPath & " is not an ELF object (bad magic)")
  if uint8(ord(data[4])) != ElfClass64:
    fail("elf-not-elf64",
      inputPath & " is not ELFCLASS64; the Linux HCR provider is 64-bit only")
  if uint8(ord(data[5])) != ElfData2Lsb:
    fail("elf-not-little-endian",
      inputPath & " is not ELFDATA2LSB")

  let ePhnum = readU16(data, 56)
  if ePhnum != 0'u16:
    # A relocatable object has no program headers. Anything that does is an
    # executable or a shared object, whose segment file offsets this pass would
    # have to keep consistent with `p_offset`/`p_filesz`. Refused by name
    # rather than attempted.
    fail("elf-has-program-headers",
      inputPath & " carries program headers; `prepare-object` expands sections " &
      "in ET_REL relocatable objects only")

  let eShoff = readU64(data, 40)
  let eShentsize = readU16(data, 58)
  if eShoff == 0'u64:
    fail("elf-no-section-headers", inputPath & " has no section header table")
  if eShentsize.int != Elf64ShdrSize:
    fail("elf-unexpected-shentsize",
      inputPath & " has e_shentsize=" & $eShentsize & ", expected 64")

  let shoff = int(eShoff)
  let zeroth = readSectionHeader(data, shoff)
  var sectionCount = int(readU16(data, 60))
  if sectionCount == 0:
    # HLX-M1's measured overflow escape: the real count lives in
    # `shdr[0].sh_size`.
    sectionCount = int(zeroth.size)
  var shstrndx = readU16(data, 62)
  var shstrndxIndex = int(shstrndx)
  if shstrndx == ShnXindex:
    shstrndxIndex = int(zeroth.link)
  if sectionCount <= 0:
    fail("elf-no-sections", inputPath & " declares zero sections")
  if shoff + sectionCount * Elf64ShdrSize > data.len:
    fail("elf-truncated",
      inputPath & " section header table runs past the end of the file")

  var headers = newSeq[SectionHeader](sectionCount)
  for i in 0 ..< sectionCount:
    headers[i] = readSectionHeader(data, shoff + i * Elf64ShdrSize)

  var strtabOffset = 0
  var strtabSize = 0
  if shstrndxIndex > 0 and shstrndxIndex < sectionCount:
    strtabOffset = int(headers[shstrndxIndex].offset)
    strtabSize = int(headers[shstrndxIndex].size)

  result.sectionCount = sectionCount
  result.rewritten = false

  # ---- expand -------------------------------------------------------------
  var contents = newSeq[string](sectionCount)
  var anyCompressed = false
  for i in 1 ..< sectionCount:
    let header = headers[i]
    if header.shType == ShtNull or header.shType == ShtNobits:
      continue
    let start = int(header.offset)
    let size = int(header.size)
    if start < 0 or size < 0 or start + size > data.len:
      fail("elf-truncated",
        "section " & $i & " of " & inputPath & " runs past the end of the file")
    if (header.flags and ShfCompressed) == 0'u64:
      contents[i] = data[start ..< start + size]
      continue
    anyCompressed = true
    let name = sectionName(data, strtabOffset, strtabSize, header.name)
    if size < Elf64ChdrSize:
      fail("elf-compressed-section-truncated",
        "section " & name & " is SHF_COMPRESSED but is smaller than an Elf64_Chdr")
    let chType = readU32(data, start)
    let chSize = readU64(data, start + 8)
    let chAddralign = readU64(data, start + 16)
    if chType == ElfCompressZstd:
      fail("elf-compressed-section-zstd",
        "section " & name & " of " & inputPath & " is ELFCOMPRESS_ZSTD, which " &
        "`repro hcr prepare-object` cannot expand. Rebuild the patch object " &
        "with `-gz=none` (`gcc(debugCompression = \"none\")` in the DSL); the " &
        "HCR agent refuses a compressed debug section by name because a " &
        "relocation applied into the stream corrupts it silently.")
    if chType != ElfCompressZlib:
      fail("elf-compressed-section-unknown-algorithm",
        "section " & name & " of " & inputPath & " declares Elf64_Chdr.ch_type=" &
        $chType & ", which is not ELFCOMPRESS_ZLIB or ELFCOMPRESS_ZSTD")
    if chSize > uint64(high(int)):
      fail("elf-compressed-section-size-mismatch",
        "section " & name & " declares an implausible ch_size")
    let stream = data[start + Elf64ChdrSize ..< start + size]
    let expanded = zlibDecompress(stream, 0, int(chSize))
    var text = newString(expanded.len)
    for j in 0 ..< expanded.len:
      text[j] = chr(int(expanded[j]))
    contents[i] = text
    headers[i].size = chSize
    headers[i].addralign = (if chAddralign == 0'u64: 1'u64 else: chAddralign)
    headers[i].flags = header.flags and not ShfCompressed
    result.expanded.add ElfDecompressedSection(
      name: name, index: i, compressedBytes: size, expandedBytes: int(chSize))

  if not anyCompressed:
    writeFile(extendedPath(outputPath), data)
    return

  # ---- relay out ----------------------------------------------------------
  # Sections are placed in their ORIGINAL file-offset order so the output
  # resembles the input as closely as an expansion allows; a reader diffing the
  # two sees the expanded sections and nothing else reordered.
  var order = newSeq[int](0)
  for i in 1 ..< sectionCount:
    order.add i
  order.sort do (a, b: int) -> int:
    if headers[a].offset < headers[b].offset: -1
    elif headers[a].offset > headers[b].offset: 1
    elif a < b: -1
    elif a > b: 1
    else: 0

  var body = newStringOfCap(data.len * 2)
  body.add data[0 ..< Elf64EhdrSize]
  var cursor = uint64(Elf64EhdrSize)
  for i in order:
    if headers[i].shType == ShtNobits:
      # Occupies no file space. Its `sh_offset` is conventional; point it at the
      # current cursor and advance nothing.
      headers[i].offset = cursor
      continue
    if contents[i].len == 0 and headers[i].size == 0'u64:
      headers[i].offset = cursor
      continue
    let aligned = alignUp(cursor, headers[i].addralign)
    while cursor < aligned:
      body.add '\0'
      cursor.inc
    headers[i].offset = cursor
    body.add contents[i]
    cursor += uint64(contents[i].len)

  let tableAt = alignUp(cursor, 8'u64)
  while cursor < tableAt:
    body.add '\0'
    cursor.inc
  var output = body
  output.setLen(int(tableAt) + sectionCount * Elf64ShdrSize)
  writeSectionHeader(output, int(tableAt), zeroth)
  for i in 1 ..< sectionCount:
    writeSectionHeader(output, int(tableAt) + i * Elf64ShdrSize, headers[i])
  writeU64(output, 40, tableAt)
  # `e_shnum` / `e_shstrndx` keep whatever escape the input used; neither the
  # count nor the string-table index changed.
  writeU16(output, 58, uint16(Elf64ShdrSize))
  writeFile(extendedPath(outputPath), output)
  result.rewritten = true

proc elfHasCompressedSections*(path: string): bool =
  ## Cheap predicate over an object already on disk. Used by gates to assert
  ## their own premise — that the compiler really did emit a compressed
  ## section — before asserting anything about the expansion.
  let data = readFile(extendedPath(path))
  if data.len < Elf64EhdrSize or data[0 .. 3] != "\x7FELF":
    return false
  if uint8(ord(data[4])) != ElfClass64 or uint8(ord(data[5])) != ElfData2Lsb:
    return false
  let eShoff = readU64(data, 40)
  if eShoff == 0'u64: return false
  let shoff = int(eShoff)
  var sectionCount = int(readU16(data, 60))
  if sectionCount == 0:
    sectionCount = int(readSectionHeader(data, shoff).size)
  if shoff + sectionCount * Elf64ShdrSize > data.len:
    return false
  for i in 1 ..< sectionCount:
    let header = readSectionHeader(data, shoff + i * Elf64ShdrSize)
    if (header.flags and ShfCompressed) != 0'u64:
      return true
  false
