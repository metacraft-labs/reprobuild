## RFC 1950 (zlib) and RFC 1951 (DEFLATE) decoding, in pure Nim.
##
## Moved here from `repro_hcr_linkgraph/elf_decompress`, which wrote it out so
## that library would need neither a `libz` link dependency nor a binutils
## binary at build time. A second consumer needs the same thing for the same
## reasons: the engine scans the outputs of a build edge for embedded checkout
## paths before it writes a record other checkouts may be served from
## (Caching-Architecture.md D4), and GCC compresses `.debug_*` sections with
## zlib by default, so the scan has to read through them. One decoder in the
## lowest library both can see keeps the two from drifting.
##
## The decoder follows the shape of zlib's own reference decoder `puff.c`
## (https://github.com/madler/zlib/blob/develop/contrib/puff/puff.c): canonical
## Huffman tables in counts/symbols form, no table expansion. `zlibDecompress`
## verifies the trailing Adler-32, so a decoder that produced
## plausible-but-wrong bytes fails instead of answering.
##
## Every refusal raises `InflateError` with a stable machine `reason`. The
## reasons keep the `elf-compressed-section-*` names they had in
## `elf_decompress`, whose refusals re-raise them unchanged and whose tests
## assert on them.

import std/strutils

type
  InflateError* = object of CatchableError
    ## Raised for every malformed, truncated or mismatched stream. `reason` is
    ## the stable machine name; `msg` says what was wrong.
    reason*: string

proc fail(reason, message: string) {.noreturn.} =
  var err = newException(InflateError, message)
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

proc inflateRawAt(data: string; start, limit, capacity: int;
                  endPos: var int): seq[byte] =
  ## RFC 1951. `limit` is the exact byte count the caller expects, taken from
  ## `Elf64_Chdr.ch_size` — an inflate that overruns it is refused rather than
  ## grown, because the declared size is the only independent statement of how
  ## large the section is. A caller whose `limit` is only a ceiling (gzip)
  ## passes a smaller `capacity` so the ceiling is not allocated up front.
  ## ``endPos`` receives the offset of the first byte after the stream (the
  ## final block's last partial byte included), where a container's trailer
  ## starts.
  var br = BitReader(data: data, pos: start, bitBuf: 0, bitCount: 0)
  result = newSeqOfCap[byte](if capacity < 0: limit else: min(capacity, limit))
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
  endPos = br.pos

proc inflateRaw(data: string; start, limit: int): seq[byte] =
  var ignored = 0
  inflateRawAt(data, start, limit, -1, ignored)

proc adler32(data: openArray[byte]): uint32 =
  var a = 1'u32
  var b = 0'u32
  for value in data:
    a = (a + uint32(value)) mod 65521'u32
    b = (b + a) mod 65521'u32
  (b shl 16) or a

proc zlibDecompress*(data: string; start, expanded: int): seq[byte] =
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
# RFC 1952 (gzip), for archives a forge serves.
# ---------------------------------------------------------------------------

proc crc32Table(): array[256, uint32] =
  for n in 0 ..< 256:
    var c = uint32(n)
    for _ in 0 ..< 8:
      c = if (c and 1'u32) != 0: 0xEDB88320'u32 xor (c shr 1) else: c shr 1
    result[n] = c

const Crc32Table = crc32Table()

proc crc32*(data: openArray[byte]): uint32 =
  ## The CRC-32 of RFC 1952 section 8 (the ISO 3309 polynomial).
  var c = 0xFFFFFFFF'u32
  for b in data:
    c = Crc32Table[int((c xor uint32(b)) and 0xFF'u32)] xor (c shr 8)
  c xor 0xFFFFFFFF'u32

proc gzipDecompress*(data: string; maxBytes: int): seq[byte] =
  ## One gzip member (RFC 1952, https://www.rfc-editor.org/rfc/rfc1952),
  ## expanded to at most ``maxBytes``: a stream that would expand further is
  ## refused (`gzip-too-large`) while it is decoded, so a decompression bomb
  ## costs at most ``maxBytes``. The trailer's CRC-32 and ISIZE are verified,
  ## located from the END of the input as `zlibDecompress` locates its
  ## Adler-32, and the DEFLATE stream must end exactly where the trailer
  ## starts, so trailing bytes or a second member are a refusal
  ## (`gzip-malformed`): a forge serves one member, and nothing after it is
  ## part of the archive. A header CRC (FHCRC) is verified when present.
  ##
  ## Refusal reasons: `gzip-truncated`, `gzip-malformed`, `gzip-too-large`,
  ## `gzip-checksum-mismatch`.
  const
    FText = 1'u8
    FHcrc = 2'u8
    FExtra = 4'u8
    FName = 8'u8
    FComment = 16'u8
  discard FText
  if data.len < 18:
    fail("gzip-truncated", "gzip stream is shorter than its header and trailer")
  if ord(data[0]) != 0x1f or ord(data[1]) != 0x8b:
    fail("gzip-malformed", "not a gzip stream (no 1f 8b magic)")
  if ord(data[2]) != 8:
    fail("gzip-malformed", "gzip compression method " & $ord(data[2]) &
      " is not DEFLATE")
  let flg = uint8(ord(data[3]))
  if (flg and 0xE0'u8) != 0:
    fail("gzip-malformed", "gzip header sets reserved flag bits")
  var pos = 10
  let trailer = data.len - 8
  if (flg and FExtra) != 0:
    if pos + 2 > trailer:
      fail("gzip-truncated", "gzip FEXTRA length is truncated")
    let xlen = ord(data[pos]) or (ord(data[pos + 1]) shl 8)
    pos += 2 + xlen
  for flag in [FName, FComment]:
    if (flg and flag) != 0:
      while pos < trailer and data[pos] != '\0': inc pos
      inc pos
  if (flg and FHcrc) != 0:
    if pos + 2 > trailer:
      fail("gzip-truncated", "gzip FHCRC is truncated")
    var header = newSeq[byte](pos)
    for i in 0 ..< pos: header[i] = byte(ord(data[i]))
    let storedHcrc = uint32(ord(data[pos])) or (uint32(ord(data[pos + 1])) shl 8)
    if (crc32(header) and 0xFFFF'u32) != storedHcrc:
      fail("gzip-checksum-mismatch", "gzip header CRC-16 is 0x" &
        toHex(storedHcrc, 4) & " but the header hashes to 0x" &
        toHex(crc32(header) and 0xFFFF'u32, 4))
    pos += 2
  if pos > trailer:
    fail("gzip-truncated", "gzip header runs into the trailer")
  var streamEnd = 0
  try:
    result = inflateRawAt(data, pos, maxBytes, data.len * 4, streamEnd)
  except InflateError as e:
    if e.reason == "elf-compressed-section-size-mismatch":
      fail("gzip-too-large", "gzip stream expands to more than " &
        $maxBytes & " bytes")
    elif e.reason.endsWith("truncated"):
      fail("gzip-truncated", e.msg)
    else:
      fail("gzip-malformed", e.msg)
  if streamEnd < trailer:
    fail("gzip-malformed", "gzip stream has " & $(trailer - streamEnd) &
      " byte(s) after its DEFLATE data and before the last 8 (trailing " &
      "data or a second member)")
  if streamEnd > trailer:
    fail("gzip-truncated", "gzip DEFLATE data runs into the 8-byte trailer")
  proc le32(at: int): uint32 =
    uint32(ord(data[at])) or (uint32(ord(data[at + 1])) shl 8) or
      (uint32(ord(data[at + 2])) shl 16) or (uint32(ord(data[at + 3])) shl 24)
  let storedCrc = le32(trailer)
  let storedSize = le32(trailer + 4)
  if storedSize != uint32(result.len and 0xFFFFFFFF):
    fail("gzip-checksum-mismatch", "gzip ISIZE is " & $storedSize &
      " but the stream expanded to " & $result.len & " bytes")
  let computed = crc32(result)
  if storedCrc != computed:
    fail("gzip-checksum-mismatch", "gzip CRC-32 is 0x" & toHex(storedCrc, 8) &
      " but the expanded bytes hash to 0x" & toHex(computed, 8))
