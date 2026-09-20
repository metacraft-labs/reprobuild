## The RFC 8949 decoder.
##
## ## Fail-closed
##
## Every path out of this module is either a complete `CborItem` or a
## `CborError` carrying a `CborErrorKind`. There is no "returned
## something partial", no sentinel item and no nil: a caller cannot
## mistake "nothing was decoded" for "an empty document was decoded",
## which is the shape in which a validator ends up validating nothing.
##
## ## What is checked, and against what
##
## Well-formedness follows RFC 8949 Appendix C's pseudocode and is
## classified by Appendix F's own taxonomy — see `CborErrorKind`. The
## two rules that are NOT about well-formedness are options:
##
##   * `requireDeterministic` adds RFC 8949 §4.2.1 (core deterministic
##     encoding): preferred head serialization, no indefinite lengths,
##     and map keys in ascending bytewise order of their encodings.
##   * `rejectDuplicateKeys` adds RFC 8949 §5.6's validity rule. It is
##     ON by default, because every consumer in this repository reads
##     maps as a lookup table and a second entry for a key that a
##     decoder silently dropped is how two readers of the same bytes
##     end up disagreeing.
##
## ## Bounds
##
## No allocation is sized from a declared length before that length is
## compared against the bytes that remain. A head may legally say
## "18446744073709551615 bytes follow"; this decoder answers that with
## `cekTruncatedString` after one comparison rather than with an
## allocation. Containers get the same treatment through a weaker but
## sound bound: an item needs at least one byte, so a declared element
## count greater than the number of bytes left cannot be satisfied.

import ./item
import ./floats

type
  CborReadOptions* = object
    requireDeterministic*: bool
    rejectDuplicateKeys*: bool
    maxDepth*: int

const
  DefaultCborOptions* = CborReadOptions(
    requireDeterministic: false,
    rejectDuplicateKeys: true,
    maxDepth: 256)

  DeterministicCborOptions* = CborReadOptions(
    requireDeterministic: true,
    rejectDuplicateKeys: true,
    maxDepth: 256)

  BreakByte* = 0xff'u8

type
  Head = object
    major: int
    ai: int
    arg: uint64
    indefinite: bool

proc readRaw(bytes: openArray[byte]; pos: var int; n: int): uint64 =
  if pos + n > bytes.len:
    cborFail(cekTruncatedHead,
      "needed " & $n & " more byte(s) for the argument")
  for i in 0 ..< n:
    result = (result shl 8) or uint64(bytes[pos + i])
  pos += n

proc readHead(bytes: openArray[byte]; pos: var int;
              opts: CborReadOptions): Head =
  if pos >= bytes.len:
    cborFail(cekTruncatedHead, "no initial byte")
  let initial = bytes[pos]
  inc pos
  result.major = int(initial shr 5)
  result.ai = int(initial and 0x1f'u8)
  case result.ai
  of 0 .. 23:
    result.arg = uint64(result.ai)
  of 24:
    result.arg = readRaw(bytes, pos, 1)
  of 25:
    result.arg = readRaw(bytes, pos, 2)
  of 26:
    result.arg = readRaw(bytes, pos, 4)
  of 27:
    result.arg = readRaw(bytes, pos, 8)
  of 28, 29, 30:
    cborFail(cekReservedAdditionalInfo,
      "additional information " & $result.ai)
  else:
    result.indefinite = true
  if opts.requireDeterministic and result.major != 7:
    # RFC 8949 §4.2.1: "Preferred serialization of the argument".
    let tooWide =
      case result.ai
      of 24: result.arg < 24'u64
      of 25: result.arg <= 0xff'u64
      of 26: result.arg <= 0xffff'u64
      of 27: result.arg <= 0xffff_ffff'u64
      else: false
    if tooWide:
      cborFail(cekNonPreferredHead,
        "argument " & $result.arg & " in additional information " &
          $result.ai)

proc remaining(bytes: openArray[byte]; pos: int): int = bytes.len - pos

proc readStringPayload(bytes: openArray[byte]; pos: var int;
                       declared: uint64): seq[byte] =
  if declared > uint64(remaining(bytes, pos)):
    cborFail(cekTruncatedString,
      "declared " & $declared & ", " & $remaining(bytes, pos) & " left")
  let n = int(declared)
  result = newSeq[byte](n)
  for i in 0 ..< n:
    result[i] = bytes[pos + i]
  pos += n

proc readItem(bytes: openArray[byte]; pos: var int;
              opts: CborReadOptions; depth: int): CborItem

proc readIndefiniteString(bytes: openArray[byte]; pos: var int;
                          opts: CborReadOptions;
                          major: int): tuple[data: seq[byte],
                                             chunks: seq[int]] =
  if opts.requireDeterministic:
    cborFail(cekIndefiniteNotDeterministic, "major type " & $major)
  while true:
    if pos >= bytes.len:
      cborFail(cekTruncatedItem,
        "indefinite string was never closed by a break")
    if bytes[pos] == BreakByte:
      inc pos
      return
    var probe = pos
    let h = readHead(bytes, probe, opts)
    if h.major != major or h.indefinite:
      cborFail(cekBadIndefiniteChunk,
        "chunk of major type " & $h.major &
          (if h.indefinite: " and indefinite length" else: ""))
    pos = probe
    let chunk = readStringPayload(bytes, pos, h.arg)
    result.chunks.add chunk.len
    for b in chunk:
      result.data.add b

proc encodedKeyLess(a, b: seq[byte]): bool =
  ## RFC 8949 §4.2.1 ordering: bytewise lexicographic on the encoded
  ## key, shorter first when one is a prefix of the other.
  let n = min(a.len, b.len)
  for i in 0 ..< n:
    if a[i] != b[i]:
      return a[i] < b[i]
  a.len < b.len

proc encodePreferred(item: CborItem): seq[byte]

proc readItem(bytes: openArray[byte]; pos: var int;
              opts: CborReadOptions; depth: int): CborItem =
  if depth > opts.maxDepth:
    cborFail(cekNestingTooDeep, "depth " & $depth)
  let h = readHead(bytes, pos, opts)
  case h.major
  of 0:
    if h.indefinite:
      cborFail(cekIndefiniteNotAllowed, "major type 0")
    result = cUInt(h.arg)
  of 1:
    if h.indefinite:
      cborFail(cekIndefiniteNotAllowed, "major type 1")
    result = cNegInt(h.arg)
  of 2:
    if h.indefinite:
      let got = readIndefiniteString(bytes, pos, opts, 2)
      result = cBytes(got.data)
      result.indefinite = true
      result.chunks = got.chunks
    else:
      result = cBytes(readStringPayload(bytes, pos, h.arg))
  of 3:
    if h.indefinite:
      let got = readIndefiniteString(bytes, pos, opts, 3)
      result = CborItem(kind: ckText)
      result.indefinite = true
      result.chunks = got.chunks
      result.text = newString(got.data.len)
      for i in 0 ..< got.data.len:
        result.text[i] = char(got.data[i])
    else:
      let raw = readStringPayload(bytes, pos, h.arg)
      var s = newString(raw.len)
      for i in 0 ..< raw.len:
        s[i] = char(raw[i])
      result = cText(s)
  of 4:
    var elems: seq[CborItem] = @[]
    if h.indefinite:
      if opts.requireDeterministic:
        cborFail(cekIndefiniteNotDeterministic, "major type 4")
      while true:
        if pos >= bytes.len:
          cborFail(cekTruncatedItem,
            "indefinite array was never closed by a break")
        if bytes[pos] == BreakByte:
          inc pos
          break
        elems.add readItem(bytes, pos, opts, depth + 1)
      result = cIndefArray(elems)
    else:
      if h.arg > uint64(remaining(bytes, pos)):
        cborFail(cekTruncatedItem,
          "array declares " & $h.arg & " items, " &
            $remaining(bytes, pos) & " bytes left")
      for _ in 0 ..< int(h.arg):
        if pos >= bytes.len:
          cborFail(cekTruncatedItem, "array ended before its last item")
        elems.add readItem(bytes, pos, opts, depth + 1)
      result = cArray(elems)
  of 5:
    var entries: seq[CborPair] = @[]
    if h.indefinite:
      if opts.requireDeterministic:
        cborFail(cekIndefiniteNotDeterministic, "major type 5")
      while true:
        if pos >= bytes.len:
          cborFail(cekTruncatedItem,
            "indefinite map was never closed by a break")
        if bytes[pos] == BreakByte:
          inc pos
          break
        let k = readItem(bytes, pos, opts, depth + 1)
        if pos >= bytes.len:
          cborFail(cekTruncatedItem, "map key has no value")
        # A break in the VALUE position is RFC 8949 Appendix F subkind 4
        # and is refused — by `readItem` below, which refuses a break
        # wherever no enclosed item could occur. There is deliberately
        # no second check for it here: an explicit one was written first
        # and then removed, because deleting it changed nothing any
        # input could observe, and a rule whose deletion changes nothing
        # is a rule the program does not have.
        entries.add cPair(k, readItem(bytes, pos, opts, depth + 1))
      result = cIndefMap(entries)
    else:
      if h.arg > uint64(remaining(bytes, pos)):
        cborFail(cekTruncatedItem,
          "map declares " & $h.arg & " pairs, " &
            $remaining(bytes, pos) & " bytes left")
      for _ in 0 ..< int(h.arg):
        if pos >= bytes.len:
          cborFail(cekTruncatedItem, "map ended before its last key")
        let k = readItem(bytes, pos, opts, depth + 1)
        if pos >= bytes.len:
          cborFail(cekTruncatedItem, "map key has no value")
        entries.add cPair(k, readItem(bytes, pos, opts, depth + 1))
      result = cMap(entries)
    if opts.rejectDuplicateKeys or opts.requireDeterministic:
      var encoded: seq[seq[byte]] = @[]
      for e in entries:
        encoded.add encodePreferred(e.key)
      if opts.rejectDuplicateKeys:
        for i in 0 ..< encoded.len:
          for j in i + 1 ..< encoded.len:
            if encoded[i] == encoded[j]:
              cborFail(cekDuplicateMapKey, "entry " & $i & " and " & $j)
      if opts.requireDeterministic:
        for i in 1 ..< encoded.len:
          if not encodedKeyLess(encoded[i - 1], encoded[i]):
            cborFail(cekMapKeysOutOfOrder, "entry " & $i)
  of 6:
    if h.indefinite:
      cborFail(cekIndefiniteNotAllowed, "major type 6")
    if pos >= bytes.len:
      cborFail(cekTruncatedItem, "tag " & $h.arg & " has no content")
    result = cTag(h.arg, readItem(bytes, pos, opts, depth + 1))
  else:
    if h.indefinite:
      cborFail(cekUnexpectedBreak, "break outside an indefinite item")
    case h.ai
    of 0 .. 23:
      result = cSimple(uint8(h.arg))
    of 24:
      if h.arg < 32'u64:
        cborFail(cekReservedSimpleValue, "simple value " & $h.arg)
      result = cSimple(uint8(h.arg))
    of 25:
      result = cFloat(halfToDouble(uint16(h.arg)), cfwHalf)
    of 26:
      result = cFloat(singleToDouble(uint32(h.arg)), cfwSingle)
    else:
      result = cFloat(floatOf(h.arg), cfwDouble)
    if opts.requireDeterministic and result.kind == ckFloat:
      # RFC 8949 §4.2.1: "Floating-point values also MUST use the
      # shortest form that preserves the value".
      if result.width != cfwHalf and tryNarrowToHalf(result.value).ok:
        cborFail(cekNonPreferredFloat, "binary16 would preserve it")
      if result.width == cfwDouble and tryNarrowToSingle(result.value).ok:
        cborFail(cekNonPreferredFloat, "binary32 would preserve it")

proc decodeItem*(bytes: openArray[byte];
                 opts = DefaultCborOptions): CborItem =
  ## Exactly one data item, and nothing after it.
  var pos = 0
  result = readItem(bytes, pos, opts, 0)
  if pos != bytes.len:
    cborFail(cekTrailingData,
      $(bytes.len - pos) & " byte(s) after the item")

proc decodeItemPrefix*(bytes: openArray[byte]; pos: var int;
                       opts = DefaultCborOptions): CborItem =
  ## One data item from `pos`, leaving `pos` after it. For CBOR
  ## sequences and for the embedded-CBOR byte strings COSE carries.
  readItem(bytes, pos, opts, 0)

# ---------------------------------------------------------------------
# A private, minimal encoder used for map-key comparison
# ---------------------------------------------------------------------
#
# The duplicate-key and ordering rules compare keys as ENCODED BYTES, so
# the reader needs an encoder. Importing the real one would make the two
# modules mutually recursive, so this is a deliberately small copy that
# handles the head plus the payload of every item shape that can appear
# as a key. It is not a second answer to "how does this library encode":
# `t_cbor_rfc8949_vectors` pins it against the public writer over the
# whole Appendix A corpus, so a divergence between the two is a failing
# case rather than a latent disagreement.

proc putHead(outp: var seq[byte]; major: int; arg: uint64) =
  let m = byte(major shl 5)
  if arg < 24'u64:
    outp.add(m or byte(arg))
  elif arg <= 0xff'u64:
    outp.add(m or 24'u8)
    outp.add(byte(arg))
  elif arg <= 0xffff'u64:
    outp.add(m or 25'u8)
    for shift in [8, 0]:
      outp.add(byte((arg shr shift) and 0xff'u64))
  elif arg <= 0xffff_ffff'u64:
    outp.add(m or 26'u8)
    for shift in [24, 16, 8, 0]:
      outp.add(byte((arg shr shift) and 0xff'u64))
  else:
    outp.add(m or 27'u8)
    for shift in [56, 48, 40, 32, 24, 16, 8, 0]:
      outp.add(byte((arg shr shift) and 0xff'u64))

proc encodeInto(outp: var seq[byte]; item: CborItem) =
  case item.kind
  of ckUInt: outp.putHead(0, item.arg)
  of ckNegInt: outp.putHead(1, item.arg)
  of ckBytes:
    outp.putHead(2, uint64(item.bytes.len))
    for b in item.bytes: outp.add b
  of ckText:
    outp.putHead(3, uint64(item.text.len))
    for ch in item.text: outp.add byte(ord(ch))
  of ckArray:
    outp.putHead(4, uint64(item.elems.len))
    for e in item.elems: outp.encodeInto(e)
  of ckMap:
    outp.putHead(5, uint64(item.entries.len))
    for e in item.entries:
      outp.encodeInto(e.key)
      outp.encodeInto(e.val)
  of ckTag:
    outp.putHead(6, item.tag)
    outp.encodeInto(item.content)
  of ckSimple:
    if item.simple < 24'u8: outp.add(0xe0'u8 or item.simple)
    else:
      outp.add(0xf8'u8)
      outp.add(item.simple)
  of ckFloat:
    outp.add(0xfb'u8)
    let bits = bitsOf(item.value)
    for shift in [56, 48, 40, 32, 24, 16, 8, 0]:
      outp.add(byte((bits shr shift) and 0xff'u64))

proc encodePreferred(item: CborItem): seq[byte] =
  result = @[]
  result.encodeInto(item)
