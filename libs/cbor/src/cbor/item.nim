## The RFC 8949 data model, as a single item type, plus the refusal
## vocabulary the reader and the writer share.
##
## ## Why the refusals are an enum and not just strings
##
## A decoder that answers every bad input with one error is a decoder
## whose caller cannot tell "the input stopped early" from "the input
## said something forbidden". Worse for a test suite: a case that asserts
## "this is refused" is then satisfied by *any* refusal, including one
## raised by a different rule that happened to pick the input up first.
##
## So every refusal carries a `CborErrorKind`, each kind has exactly one
## message, and `messagesAreDistinguishable` states the property those
## messages must have: no message is a substring of any other. That is
## stronger than "they differ" — a caller matching on a substring of one
## message cannot be satisfied by a different refusal.
##
## The kinds are named after RFC 8949 Appendix F's own classification of
## well-formedness errors, so a reader of the RFC can map them one to
## one:
##
##   * kind 1, "too much data"  -> `cekTrailingData`
##   * kind 2, "too little data" -> `cekTruncatedHead`,
##     `cekTruncatedString`, `cekTruncatedItem`
##   * kind 3, "syntax error", five subkinds in the RFC's own order ->
##     `cekReservedAdditionalInfo`, `cekReservedSimpleValue`,
##     `cekBadIndefiniteChunk`, `cekUnexpectedBreak`,
##     `cekIndefiniteNotAllowed`
##
## The remaining kinds are not RFC well-formedness errors: they are this
## decoder's own limits (`cekNestingTooDeep`) and the extra rules that
## only apply when the caller asks for RFC 8949 §4.2 deterministic
## encoding, or for RFC 8949 §5.6 map validity.

import std/strutils

type
  CborErrorKind* = enum
    ## RFC 8949 Appendix F well-formedness errors, then this decoder's
    ## own additions. The order is the RFC's.
    cekTruncatedHead
    cekTruncatedString
    cekTruncatedItem
    cekReservedAdditionalInfo
    cekReservedSimpleValue
    cekBadIndefiniteChunk
    cekUnexpectedBreak
    cekIndefiniteNotAllowed
    cekTrailingData
    cekNestingTooDeep
    cekNonPreferredHead
    cekNonPreferredFloat
    cekIndefiniteNotDeterministic
    cekMapKeysOutOfOrder
    cekDuplicateMapKey
    cekNotBignum
    cekBadDiagnostic

  CborError* = object of CatchableError
    ## Every refusal this library makes. `kind` is the discriminator a
    ## caller should branch on; `msg` is the sentence for a human, and
    ## `site` is the file and line of the rule that refused.
    ##
    ## `site` exists so that "which refusal sites can any input actually
    ## reach" is a measurement rather than an argument. A rule nothing
    ## can reach is a rule the program does not have, and counting the
    ## rules a suite reaches is the only way to notice one.
    kind*: CborErrorKind
    site*: tuple[filename: string, line: int, column: int]

const
  CborErrorMessage*: array[CborErrorKind, string] = [
    cekTruncatedHead:
      "the input ended in the middle of an item head",
    cekTruncatedString:
      "a definite-length string declares more data than the input holds",
    cekTruncatedItem:
      "a container ended before all of its items were present",
    cekReservedAdditionalInfo:
      "additional information 28, 29 or 30 is reserved",
    cekReservedSimpleValue:
      "a two-byte simple value below 32 is reserved",
    cekBadIndefiniteChunk:
      "an indefinite-length string may only contain definite-length " &
        "chunks of its own major type",
    cekUnexpectedBreak:
      "a break stop code appeared where no enclosed item could occur",
    cekIndefiniteNotAllowed:
      "additional information 31 is not usable with major type 0, 1 or 6",
    cekTrailingData:
      "bytes were left over after one complete item",
    cekNestingTooDeep:
      "the item nests deeper than this decoder accepts",
    cekNonPreferredHead:
      "a head is longer than the preferred serialization for its argument",
    cekNonPreferredFloat:
      "a float is wider than the shortest form that preserves its value",
    cekIndefiniteNotDeterministic:
      "an indefinite length cannot appear in deterministically encoded " &
        "input",
    cekMapKeysOutOfOrder:
      "map keys are not in the deterministic bytewise order",
    cekDuplicateMapKey:
      "the same map key appears twice",
    cekNotBignum:
      "the item is not a bignum: tag 2 or tag 3 over a byte string",
    cekBadDiagnostic:
      "the diagnostic notation could not be read"]

proc cborFailAt*(kind: CborErrorKind; detail: string;
                 site: tuple[filename: string, line: int, column: int])
                {.noreturn.} =
  ## The single construction site for a refusal. `detail` is appended
  ## after a colon and must never be relied on to tell two kinds apart —
  ## that is what `kind` is for.
  var e = newException(CborError, CborErrorMessage[kind])
  if detail.len > 0:
    e.msg = e.msg & ": " & detail
  e.kind = kind
  e.site = site
  raise e

template cborFail*(kind: CborErrorKind; detail: string = "") =
  ## What every rule calls. It is a TEMPLATE rather than a proc for one
  ## reason: `instantiationInfo()` reports the expansion site, so the
  ## file and line recorded on the error are the RULE's, not this
  ## file's. A proc with a defaulted `instantiationInfo()` parameter
  ## reports `???:0` — measured, after writing it that way first.
  cborFailAt(kind, detail, instantiationInfo())

proc messagesAreDistinguishable*(messages: openArray[string]): bool =
  ## True when no message in `messages` is a substring of another, and
  ## none is empty. This is the property that stops a test matching on a
  ## fragment of one refusal from being satisfied by a different one.
  for i in 0 ..< messages.len:
    if messages[i].len == 0:
      return false
    for j in 0 ..< messages.len:
      if i == j:
        continue
      if messages[j].contains(messages[i]):
        return false
  true

const MessagesAreDistinguishable* =
  "no refusal message is a substring of any other refusal message"
  ## The sentence `messagesAreDistinguishable` decides, spelled out so a
  ## gate can pin the claim as well as the predicate.

# ---------------------------------------------------------------------
# The data model
# ---------------------------------------------------------------------

type
  CborItemKind* = enum
    ckUInt       ## major type 0
    ckNegInt     ## major type 1; `arg` is n, the value is -1 - n
    ckBytes      ## major type 2
    ckText       ## major type 3
    ckArray      ## major type 4
    ckMap        ## major type 5
    ckTag        ## major type 6
    ckSimple     ## major type 7, additional information 0..24
    ckFloat      ## major type 7, additional information 25, 26 or 27

  CborFloatWidth* = enum
    cfwHalf      ## additional information 25, IEEE 754 binary16
    cfwSingle    ## additional information 26, binary32
    cfwDouble    ## additional information 27, binary64

  CborPair* = object
    key*: CborItem
    val*: CborItem

  CborItem* = ref CborItemObj

  CborItemObj* = object
    ## `indefinite` and `chunks` record HOW a string or container was
    ## encoded, not what it means. They exist so that decoding and
    ## re-encoding is byte-exact for input that was already in preferred
    ## form: without them, `(_ h'0102', h'030405')` and `h'0102030405'`
    ## would be the same item and one of the two RFC 8949 Appendix A rows
    ## could not be reproduced.
    indefinite*: bool
    chunks*: seq[int]
      ## For an indefinite-length string, the length of each chunk, in
      ## order. Their sum is the length of `bytes` / `text`.
    case kind*: CborItemKind
    of ckUInt, ckNegInt:
      arg*: uint64
    of ckBytes:
      bytes*: seq[byte]
    of ckText:
      text*: string
    of ckArray:
      elems*: seq[CborItem]
    of ckMap:
      entries*: seq[CborPair]
    of ckTag:
      tag*: uint64
      content*: CborItem
    of ckSimple:
      simple*: uint8
    of ckFloat:
      width*: CborFloatWidth
      value*: float64

const
  SimpleFalse* = 20'u8
  SimpleTrue* = 21'u8
  SimpleNull* = 22'u8
  SimpleUndefined* = 23'u8

  TagUnsignedBignum* = 2'u64
  TagNegativeBignum* = 3'u64

proc cUInt*(v: uint64): CborItem = CborItem(kind: ckUInt, arg: v)
proc cNegInt*(n: uint64): CborItem = CborItem(kind: ckNegInt, arg: n)
  ## `n` is the encoded argument; the value is -1 - n.

proc cBytes*(b: openArray[byte]): CborItem =
  CborItem(kind: ckBytes, bytes: @b)

proc cText*(s: string): CborItem = CborItem(kind: ckText, text: s)

proc cArray*(items: openArray[CborItem]): CborItem =
  CborItem(kind: ckArray, elems: @items)

proc cMap*(entries: openArray[CborPair]): CborItem =
  CborItem(kind: ckMap, entries: @entries)

proc cPair*(k, v: CborItem): CborPair = CborPair(key: k, val: v)

proc cTag*(tag: uint64; content: CborItem): CborItem =
  CborItem(kind: ckTag, tag: tag, content: content)

proc cSimple*(v: uint8): CborItem = CborItem(kind: ckSimple, simple: v)
proc cFalse*(): CborItem = cSimple(SimpleFalse)
proc cTrue*(): CborItem = cSimple(SimpleTrue)
proc cNull*(): CborItem = cSimple(SimpleNull)
proc cUndefined*(): CborItem = cSimple(SimpleUndefined)

proc cFloat*(v: float64; width = cfwDouble): CborItem =
  CborItem(kind: ckFloat, width: width, value: v)

proc cIndefBytes*(chunks: openArray[seq[byte]]): CborItem =
  result = CborItem(kind: ckBytes)
  result.indefinite = true
  for c in chunks:
    result.chunks.add c.len
    for b in c:
      result.bytes.add b

proc cIndefText*(chunks: openArray[string]): CborItem =
  result = CborItem(kind: ckText)
  result.indefinite = true
  for c in chunks:
    result.chunks.add c.len
    result.text.add c

proc cIndefArray*(items: openArray[CborItem]): CborItem =
  result = cArray(items)
  result.indefinite = true

proc cIndefMap*(entries: openArray[CborPair]): CborItem =
  result = cMap(entries)
  result.indefinite = true

# ---------------------------------------------------------------------
# Equality, in two strengths
# ---------------------------------------------------------------------

proc floatBits(v: float64): uint64 =
  cast[uint64](v)

proc sameFloat(a, b: float64): bool =
  ## Bit-pattern equality, deliberately. `0.0 == -0.0` is true in IEEE
  ## arithmetic and they are DIFFERENT CBOR items (0xf90000 against
  ## 0xf98000), so a value comparison that used `==` would accept a
  ## decoder that lost the sign of zero. `NaN == NaN` is false in IEEE
  ## arithmetic and the RFC 8949 Appendix A NaN rows must compare equal
  ## to each other, so the same choice fixes both.
  floatBits(a) == floatBits(b)

proc equalValue*(a, b: CborItem): bool
  ## Equality of what the items MEAN: the encoded width of a float and
  ## the chunk structure of an indefinite string are ignored, everything
  ## else — including the sign of zero and the distinction between a
  ## definite and an indefinite container — must agree.
  ##
  ## Indefinite-ness of a CONTAINER is compared, because `[1, 2]` and
  ## `[_ 1, 2]` are distinct rows in the RFC's own table of examples.

proc equalValueSeq(a, b: seq[CborItem]): bool =
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if not equalValue(a[i], b[i]): return false
  true

proc equalValue*(a, b: CborItem): bool =
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.kind != b.kind:
    return false
  if a.indefinite != b.indefinite:
    return false
  case a.kind
  of ckUInt, ckNegInt: a.arg == b.arg
  of ckBytes: a.bytes == b.bytes
  of ckText: a.text == b.text
  of ckArray: equalValueSeq(a.elems, b.elems)
  of ckMap:
    if a.entries.len != b.entries.len: return false
    for i in 0 ..< a.entries.len:
      if not equalValue(a.entries[i].key, b.entries[i].key): return false
      if not equalValue(a.entries[i].val, b.entries[i].val): return false
    true
  of ckTag: a.tag == b.tag and equalValue(a.content, b.content)
  of ckSimple: a.simple == b.simple
  of ckFloat: sameFloat(a.value, b.value)

proc `==`*(a, b: CborItem): bool =
  ## Exact equality: everything `equalValue` compares, plus the encoded
  ## float width and the chunk boundaries of an indefinite string.
  if not equalValue(a, b):
    return false
  if a.kind == ckFloat and a.width != b.width:
    return false
  if a.indefinite and a.chunks != b.chunks:
    return false
  case a.kind
  of ckArray:
    for i in 0 ..< a.elems.len:
      if not (a.elems[i] == b.elems[i]): return false
  of ckMap:
    for i in 0 ..< a.entries.len:
      if not (a.entries[i].key == b.entries[i].key): return false
      if not (a.entries[i].val == b.entries[i].val): return false
  of ckTag:
    if not (a.content == b.content): return false
  else: discard
  true

# ---------------------------------------------------------------------
# Small conveniences the consumers of this library want
# ---------------------------------------------------------------------

proc isBool*(item: CborItem): bool =
  not item.isNil and item.kind == ckSimple and
    item.simple in {SimpleFalse, SimpleTrue}

proc boolValue*(item: CborItem): bool =
  item.simple == SimpleTrue

proc isNull*(item: CborItem): bool =
  not item.isNil and item.kind == ckSimple and item.simple == SimpleNull

proc isBignum*(item: CborItem): bool =
  not item.isNil and item.kind == ckTag and
    (item.tag == TagUnsignedBignum or item.tag == TagNegativeBignum) and
    not item.content.isNil and item.content.kind == ckBytes

proc fitsInt64*(item: CborItem): bool =
  ## True when the item is a plain integer whose value fits `int64`.
  if item.isNil: return false
  case item.kind
  of ckUInt: item.arg <= uint64(high(int64))
  of ckNegInt: item.arg <= uint64(high(int64))
  else: false

proc asInt64*(item: CborItem): int64 =
  ## The value of a plain integer item. Call `fitsInt64` first.
  case item.kind
  of ckUInt: int64(item.arg)
  of ckNegInt: -1'i64 - int64(item.arg)
  else:
    cborFail(cekNotBignum, "asInt64 on a " & $item.kind)

proc lookup*(item: CborItem; key: CborItem): CborItem =
  ## The value a map associates with `key`, or nil. Linear, because a
  ## COSE header bucket has a handful of entries and the order matters
  ## elsewhere.
  if item.isNil or item.kind != ckMap:
    return nil
  for e in item.entries:
    if equalValue(e.key, key):
      return e.val
  nil

proc lookupInt*(item: CborItem; key: int64): CborItem =
  if key >= 0: item.lookup(cUInt(uint64(key)))
  else: item.lookup(cNegInt(uint64(-1 - key)))
