## RFC 8949 Appendix F — the published corpus of CBOR data items that
## are NOT well-formed, and the refusal each one has to produce.
##
## ## Where the corpus comes from
##
## `Rfc8949AppendixF` is a VERBATIM copy of Appendix F of RFC 8949 as
## published by the RFC Editor, taken from
##
##   https://www.rfc-editor.org/rfc/rfc8949.txt
##   sha256 f1164a5b31a39350ad46abe29b83575eb933ca6c45366989c118b6b1058a214a
##
## lines 3360-3483 of that file, which is the appendix heading through
## the last line of F.1. It is embedded rather than transcribed and
## PARSED rather than hand-copied into Nim literals, for the same reason
## the well-formed corpus is: a re-typed corpus is a corpus that can
## quietly lose a case.
##
## ## The point of this file, and the shape it is defending against
##
## "This input is refused" is a weak claim. It is satisfied by a decoder
## that refuses everything, and — the shape that has defeated gates in
## this repository repeatedly — it is satisfied when the rule under test
## is dead and a DIFFERENT rule further down picks the input up and
## refuses it for its own reason. Both decoders would look identical to
## a suite that only asserted "an exception was raised".
##
## So this gate does not assert that. It asserts the EXACT
## `CborErrorKind` for every one of the 94 published items, and the
## expected kind is derived from Appendix F's OWN classification: the
## RFC groups its examples under fourteen labels and identifies five
## "subkinds" of syntax error in a numbered list, and
## `ExpectedKindForLabel` below maps those labels — the label text as
## parsed out of the embedded excerpt, not a paraphrase — onto this
## library's refusals. A label the table does not know fails the gate;
## a label the table knows that the excerpt no longer contains fails it
## too.
##
## Under that, `messagesAreDistinguishable` is asserted over the whole
## refusal vocabulary: no message is a substring of another. That is
## what makes a caller's `"…" in e.msg` safe, and it is the property
## whose absence turns an assertion about one rule into an assertion
## about whichever rule happens to answer the input first.
##
## ## The corpus is constrained by its own gate
##
##   * fourteen labels, and the label set must equal the expectation
##     table's key set in BOTH directions;
##   * the per-label item count is pinned by value, and so is the total;
##   * the raw text of every item list must consist of nothing but hex
##     digits, spaces and commas, so nothing inside a group can be
##     skipped unnoticed;
##   * the excerpt must still carry five "Subkind N:" headings.
##
## ## What is here that RFC 8949 does not publish
##
## Four rules that are not well-formedness rules and therefore have no
## Appendix F examples: RFC 8949 §5.6's duplicate map key, and the three
## §4.2.1 deterministic-encoding requirements. Their inputs are
## constructed here and each is named as constructed rather than
## published.
##
## ## Mocking
##
## None.

import std/[exitprocs, os, strutils, unittest]

import cbor

# ---------------------------------------------------------------------
# The refusal-site census
# ---------------------------------------------------------------------
#
# `CborError.site` carries the file and line of the rule that refused.
# Collecting them says which refusal sites any input in this suite can
# actually reach; a rule nothing reaches is a rule the program does not
# have. That is a shape counting finds and reading does not.
#
# The list is written out only when `REPRO_REFUSAL_CENSUS` names a file,
# so an ordinary run of the gate prints nothing extra.

var reachedSites: seq[string] = @[]
var lastSite = ""

proc noteSite(filename: string; line: int) =
  var base = filename
  let slash = base.rfind('/')
  if slash >= 0:
    base = base[slash + 1 .. ^1]
  lastSite = base & ":" & $line
  if lastSite notin reachedSites:
    reachedSites.add lastSite

proc writeCensus() {.noconv.} =
  let path = getEnv("REPRO_REFUSAL_CENSUS")
  if path.len == 0:
    return
  var f: File
  if open(f, path, fmAppend):
    for s in reachedSites:
      f.writeLine(s)
    f.close()

addExitProc(writeCensus)

const Rfc8949AppendixF = """Appendix F.  Well-Formedness Errors and Examples

   There are three basic kinds of well-formedness errors that can occur
   in decoding a CBOR data item:

   Too much data:  There are input bytes left that were not consumed.
      This is only an error if the application assumed that the input
      bytes would span exactly one data item.  Where the application
      uses the self-delimiting nature of CBOR encoding to permit
      additional data after the data item, as is done in CBOR sequences
      [RFC8742], for example, the CBOR decoder can simply indicate which
      part of the input has not been consumed.

   Too little data:  The input data available would need additional
      bytes added at their end for a complete CBOR data item.  This may
      indicate the input is truncated; it is also a common error when
      trying to decode random data as CBOR.  For some applications,
      however, this may not actually be an error, as the application may
      not be certain it has all the data yet and can obtain or wait for
      additional input bytes.  Some of these applications may have an
      upper limit for how much additional data can appear; here the
      decoder may be able to indicate that the encoded CBOR data item
      cannot be completed within this limit.

   Syntax error:  The input data are not consistent with the
      requirements of the CBOR encoding, and this cannot be remedied by
      adding (or removing) data at the end.

   In Appendix C, errors of the first kind are addressed in the first
   paragraph and bullet list (requiring "no bytes are left"), and errors
   of the second kind are addressed in the second paragraph/bullet list
   (failing "if n bytes are no longer available").  Errors of the third
   kind are identified in the pseudocode by specific instances of
   calling fail(), in order:

   *  a reserved value is used for additional information (28, 29, 30)

   *  major type 7, additional information 24, value < 32 (incorrect)

   *  incorrect substructure of indefinite-length byte string or text
      string (may only contain definite-length strings of the same major
      type)

   *  "break" stop code (major type 7, additional information 31) occurs
      in a value position of a map or except at a position directly in
      an indefinite-length item where also another enclosed data item
      could occur

   *  additional information 31 used with major type 0, 1, or 6

F.1.  Examples of CBOR Data Items That Are Not Well-Formed

   This subsection shows a few examples for CBOR data items that are not
   well-formed.  Each example is a sequence of bytes, each shown in
   hexadecimal; multiple examples in a list are separated by commas.

   Examples for well-formedness error kind 1 (too much data) can easily
   be formed by adding data to a well-formed encoded CBOR data item.

   Similarly, examples for well-formedness error kind 2 (too little
   data) can be formed by truncating a well-formed encoded CBOR data
   item.  In test suites, it may be beneficial to specifically test with
   incomplete data items that would require large amounts of addition to
   be completed (for instance by starting the encoding of a string of a
   very large size).

   A premature end of the input can occur in a head or within the
   enclosed data, which may be bare strings or enclosed data items that
   are either counted or should have been ended by a "break" stop code.

   End of input in a head:  18, 19, 1a, 1b, 19 01, 1a 01 02, 1b 01 02 03
      04 05 06 07, 38, 58, 78, 98, 9a 01 ff 00, b8, d8, f8, f9 00, fa 00
      00, fb 00 00 00

   Definite-length strings with short data:  41, 61, 5a ff ff ff ff 00,
      5b ff ff ff ff ff ff ff ff 01 02 03, 7a ff ff ff ff 00, 7b 7f ff
      ff ff ff ff ff ff 01 02 03

   Definite-length maps and arrays not closed with enough items:  81, 81
      81 81 81 81 81 81 81 81, 82 00, a1, a2 01 02, a1 00, a2 00 00 00

   Tag number not followed by tag content:  c0

   Indefinite-length strings not closed by a "break" stop code:  5f 41
      00, 7f 61 00

   Indefinite-length maps and arrays not closed by a "break" stop
   code:  9f, 9f 01 02, bf, bf 01 02 01 02, 81 9f, 9f 80 00, 9f 9f 9f 9f
      9f ff ff ff ff, 9f 81 9f 81 9f 9f ff ff ff

   A few examples for the five subkinds of well-formedness error kind 3
   (syntax error) are shown below.

   Subkind 1:
      Reserved additional information values:  1c, 1d, 1e, 3c, 3d, 3e,
         5c, 5d, 5e, 7c, 7d, 7e, 9c, 9d, 9e, bc, bd, be, dc, dd, de, fc,
         fd, fe,

   Subkind 2:
      Reserved two-byte encodings of simple values:  f8 00, f8 01, f8
         18, f8 1f

   Subkind 3:
      Indefinite-length string chunks not of the correct type:  5f 00
         ff, 5f 21 ff, 5f 61 00 ff, 5f 80 ff, 5f a0 ff, 5f c0 00 ff, 5f
         e0 ff, 7f 41 00 ff

      Indefinite-length string chunks not definite length:  5f 5f 41 00
         ff ff, 7f 7f 61 00 ff ff

   Subkind 4:
      Break occurring on its own outside of an indefinite-length
      item:  ff

      Break occurring in a definite-length array or map or a tag:  81
         ff, 82 00 ff, a1 ff, a1 ff 00, a1 00 ff, a2 00 00 ff, 9f 81 ff,
         9f 82 9f 81 9f 9f ff ff ff ff

      Break in an indefinite-length map that would lead to an odd
      number of items (break in a value position):  bf 00 ff, bf 00 00
         00 ff

   Subkind 5:
      Major type 0, 1, 6 with additional information 31:  1f, 3f, df"""

# ---------------------------------------------------------------------
# Reading the published corpus
# ---------------------------------------------------------------------

type
  MalformedGroup = object
    label: string
    raw: string
    items: seq[seq[byte]]

const HexChars = {'0' .. '9', 'a' .. 'f'}

proc looksLikeItemStart(s: string): bool =
  s.len >= 2 and s[0] in HexChars and s[1] in HexChars and
    (s.len == 2 or s[2] in {' ', ','})

proc isPureItemText(s: string): bool =
  for ch in s:
    if ch notin HexChars and ch != ' ' and ch != ',':
      return false
  s.len > 0

proc parseBytes(where, text: string): seq[byte] =
  for tok in text.splitWhitespace():
    if tok.len != 2:
      raise newException(ValueError,
        where & ": not a byte: " & tok)
    result.add byte(parseHexInt(tok))

proc parseAppendixF(text: string): seq[MalformedGroup] =
  ## Groups are `[<wrapped label>]: <item>, <item>, …`, with the item
  ## list continuing onto any following line that holds nothing but hex
  ## digits, spaces and commas. The label may be wrapped across lines,
  ## which the RFC does twice, so prose lines are accumulated and
  ## prepended to the label they belong to.
  var pending: seq[string] = @[]
  var openGroup = false
  for raw in text.splitLines():
    let line = raw.strip()
    if openGroup:
      if line.len > 0 and isPureItemText(line):
        result[^1].raw = result[^1].raw & " " & line
        continue
      openGroup = false
    if line.len == 0:
      pending = @[]
      continue
    # A label line is `<label>:` followed by two or more spaces and then
    # something that starts like a byte.
    var colon = -1
    var i = 0
    while i < line.len:
      if line[i] == ':' and i + 2 < line.len and
         line[i + 1] == ' ' and line[i + 2] == ' ':
        colon = i
        break
      inc i
    if colon >= 0:
      let rest = line[colon + 1 .. ^1].strip()
      if looksLikeItemStart(rest):
        var parts = pending
        parts.add line[0 ..< colon].strip()
        result.add MalformedGroup(label: parts.join(" ").strip(), raw: rest)
        pending = @[]
        openGroup = true
        continue
    pending.add line

let Corpus = block:
  var groups = parseAppendixF(Rfc8949AppendixF)
  for g in groups.mitems:
    for piece in g.raw.split(','):
      let s = piece.strip()
      if s.len > 0:
        g.items.add parseBytes(g.label, s)
  groups

# The RFC's own taxonomy, keyed on the label text the parser recovers.
# Appendix F names three kinds of well-formedness error and, within
# kind 3, five numbered subkinds; each label below belongs to exactly
# one of them, and the mapping is a per-item EXACT expectation.
const ExpectedKindForLabel: seq[(string, CborErrorKind)] = @[
  ("End of input in a head",
   cekTruncatedHead),
  ("Definite-length strings with short data",
   cekTruncatedString),
  ("Definite-length maps and arrays not closed with enough items",
   cekTruncatedItem),
  ("Tag number not followed by tag content",
   cekTruncatedItem),
  ("Indefinite-length strings not closed by a \"break\" stop code",
   cekTruncatedItem),
  ("Indefinite-length maps and arrays not closed by a \"break\" stop code",
   cekTruncatedItem),
  ("Subkind 1: Reserved additional information values",
   cekReservedAdditionalInfo),
  ("Subkind 2: Reserved two-byte encodings of simple values",
   cekReservedSimpleValue),
  ("Subkind 3: Indefinite-length string chunks not of the correct type",
   cekBadIndefiniteChunk),
  ("Indefinite-length string chunks not definite length",
   cekBadIndefiniteChunk),
  ("Subkind 4: Break occurring on its own outside of an " &
     "indefinite-length item",
   cekUnexpectedBreak),
  ("Break occurring in a definite-length array or map or a tag",
   cekUnexpectedBreak),
  ("Break in an indefinite-length map that would lead to an odd number " &
     "of items (break in a value position)",
   cekUnexpectedBreak),
  ("Subkind 5: Major type 0, 1, 6 with additional information 31",
   cekIndefiniteNotAllowed)]

const ExpectedItemCounts: seq[(string, int)] = @[
  ("End of input in a head", 18),
  ("Definite-length strings with short data", 6),
  ("Definite-length maps and arrays not closed with enough items", 7),
  ("Tag number not followed by tag content", 1),
  ("Indefinite-length strings not closed by a \"break\" stop code", 2),
  ("Indefinite-length maps and arrays not closed by a \"break\" stop code", 8),
  ("Subkind 1: Reserved additional information values", 24),
  ("Subkind 2: Reserved two-byte encodings of simple values", 4),
  ("Subkind 3: Indefinite-length string chunks not of the correct type", 8),
  ("Indefinite-length string chunks not definite length", 2),
  ("Subkind 4: Break occurring on its own outside of an " &
     "indefinite-length item", 1),
  ("Break occurring in a definite-length array or map or a tag", 8),
  ("Break in an indefinite-length map that would lead to an odd number " &
     "of items (break in a value position)", 2),
  ("Subkind 5: Major type 0, 1, 6 with additional information 31", 3)]

proc expectedKind(label: string): CborErrorKind =
  for (l, k) in ExpectedKindForLabel:
    if l == label:
      return k
  raise newException(ValueError, "no expected kind for label: " & label)

# ---------------------------------------------------------------------
# The instrument: which refusals this gate actually reaches
# ---------------------------------------------------------------------

var reachedKinds: set[CborErrorKind] = {}

proc hexOf(b: openArray[byte]): string =
  for x in b:
    result.add toHex(int(x), 2).toLowerAscii()

template refusesWith(where: string; want: CborErrorKind; body: untyped) =
  ## Runs `body`, requires it to raise `CborError`, and requires the
  ## KIND to be exactly `want`. Records the kind that was reached.
  block:
    var raised = false
    try:
      body
    except CborError as e:
      raised = true
      reachedKinds.incl e.kind
      noteSite(e.site.filename, e.site.line)
      if e.kind != want:
        checkpoint(where & ": wanted " & $want & ", got " & $e.kind &
          " — " & e.msg)
      check e.kind == want
    if not raised:
      checkpoint(where & ": nothing was refused")
    check raised

proc driveCborAppendixFEveryItemIsRefusedForItsOwnReason() =
  ## The body of test
  ##   "t_cbor_appendix_f_every_item_is_refused_for_its_own_reason"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  var checkedItems = 0
  for g in Corpus:
    let want = expectedKind(g.label)
    for it in g.items:
      refusesWith(g.label & " / " & hexOf(it), want):
        discard decodeItem(it)
      inc checkedItems
  check checkedItems == 94

proc driveCborAppendixFTheSmallViewIsFailClosedToo() =
  ## The body of test
  ##   "t_cbor_appendix_f_the_small_view_is_fail_closed_too"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # `decode` projects onto the small `DynamicValue` view that
  # `repro_profile_intent` reads. It must not have its own, weaker
  # answer to "is this well-formed": every one of the 94 has to be
  # refused there as well, with the SAME kind, because the parse is
  # the reader's and the projection happens after it.
  var refused = 0
  for g in Corpus:
    let want = expectedKind(g.label)
    for it in g.items:
      refusesWith("view " & hexOf(it), want):
        discard decode(it)
      inc refused
  check refused == 94
  # The projection has refusals of its own, for the WELL-FORMED items
  # the smaller type cannot hold. They must refuse rather than
  # approximate: a view that turned an integer key into its decimal
  # spelling, or `undefined` into null, would be answering a question
  # it was not asked.
  refusesWith("an integer map key in the small view", cekBadDiagnostic):
    discard decode([0xa1'u8, 0x00, 0x00])
  refusesWith("undefined in the small view", cekBadDiagnostic):
    discard decode([0xf7'u8])
  check decodeItem([0xa1'u8, 0x00, 0x00]).entries.len == 1
  check decodeItem([0xf7'u8]).simple == 23'u8

suite "cbor rfc 8949 appendix f corpus":

  test "t_cbor_appendix_f_corpus_is_intact":
    check Corpus.len == 14
    check ExpectedKindForLabel.len == 14
    check ExpectedItemCounts.len == 14
    # The label set and the expectation table's key set must agree in
    # both directions, so neither a new group nor a stale expectation
    # can pass unnoticed.
    for g in Corpus:
      var known = false
      for (l, _) in ExpectedKindForLabel:
        if l == g.label: known = true
      if not known:
        checkpoint("unmapped label: " & g.label)
      check known
    for (l, _) in ExpectedKindForLabel:
      var present = false
      for g in Corpus:
        if g.label == l: present = true
      if not present:
        checkpoint("label no longer in the excerpt: " & l)
      check present
    # Per-label counts, pinned by value, and the total.
    var total = 0
    for g in Corpus:
      var want = -1
      for (l, n) in ExpectedItemCounts:
        if l == g.label: want = n
      if g.items.len != want:
        checkpoint("group " & g.label)
      check g.items.len == want
      total += g.items.len
      # Nothing inside a group can be skipped: the raw region is only
      # hex, spaces and commas, and every item is at least one byte.
      check isPureItemText(g.raw)
      for it in g.items:
        check it.len >= 1
    check total == 94
    # The excerpt still carries the five numbered subkinds it is
    # classified by.
    var subkinds = 0
    for n in 1 .. 5:
      if ("Subkind " & $n & ":") in Rfc8949AppendixF:
        inc subkinds
    check subkinds == 5

  test "t_cbor_appendix_f_every_item_is_refused_for_its_own_reason":
    driveCborAppendixFEveryItemIsRefusedForItsOwnReason()

  test "t_cbor_appendix_f_the_small_view_is_fail_closed_too":
    driveCborAppendixFTheSmallViewIsFailClosedToo()

  test "t_cbor_refusal_messages_are_distinguishable":
    # The property a caller matching on a fragment of one refusal
    # depends on. Asserted over the whole vocabulary, not a sample.
    var messages: seq[string] = @[]
    for k in CborErrorKind:
      messages.add CborErrorMessage[k]
    check messages.len == 17
    check messagesAreDistinguishable(messages)
    check MessagesAreDistinguishable ==
      "no refusal message is a substring of any other refusal message"
    # …and the predicate can fail, shown rather than assumed: two
    # messages where one contains the other, and an empty one.
    check not messagesAreDistinguishable(
      ["the input ended", "the input ended in the middle of an item head"])
    check not messagesAreDistinguishable(["", "something"])
    check messagesAreDistinguishable(["alpha", "beta"])
    # Every kind carries a message, and the detail a refusal appends is
    # never what tells two kinds apart.
    for k in CborErrorKind:
      check CborErrorMessage[k].len > 0

proc driveCborDuplicateMapKeyIsRefused() =
  ## The body of test
  ##   "t_cbor_duplicate_map_key_is_refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # RFC 8949 §5.6: a map with a repeated key is well-formed and is not
  # VALID. The input is constructed here; the RFC publishes no example.
  refusesWith("duplicate key 1", cekDuplicateMapKey):
    discard decodeItem([0xa2'u8, 0x01, 0x01, 0x01, 0x02])
  # The same map with distinct keys is accepted, so the rule is not
  # refusing every two-entry map.
  let ok = decodeItem([0xa2'u8, 0x01, 0x01, 0x02, 0x02])
  check ok.kind == ckMap
  check ok.entries.len == 2
  # Duplicate detection is on the ENCODED key, so two spellings of one
  # key are caught: 1 as 0x01 and 1 as 0x1801 are the same key.
  refusesWith("duplicate key, two spellings", cekDuplicateMapKey):
    discard decodeItem([0xa2'u8, 0x01, 0x01, 0x18, 0x01, 0x02])
  # …and it can be switched off, because RFC 8949 makes it a validity
  # rule rather than a well-formedness one.
  var lenient = DefaultCborOptions
  lenient.rejectDuplicateKeys = false
  let dup = decodeItem([0xa2'u8, 0x01, 0x01, 0x01, 0x02], lenient)
  check dup.entries.len == 2

proc driveCborDeterministicRulesAreRefusedSeparately() =
  ## The body of test
  ##   "t_cbor_deterministic_rules_are_refused_separately"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # The three RFC 8949 §4.2.1 requirements, each with its own input
  # and its own refusal. A single "not deterministic" answer would let
  # any one of the three rules be deleted without a case going red.
  refusesWith("non-preferred head", cekNonPreferredHead):
    discard decodeItem([0x18'u8, 0x17], DeterministicCborOptions)
  refusesWith("indefinite array", cekIndefiniteNotDeterministic):
    discard decodeItem([0x9f'u8, 0xff], DeterministicCborOptions)
  refusesWith("1.5 as a double", cekNonPreferredFloat):
    discard decodeItem(
      [0xfb'u8, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0], DeterministicCborOptions)
  # RFC 8949 Section 4.2.1's own second float example, which narrows
  # to binary32 but not to binary16 — a different arm of the same rule
  # than 1.5, and the only input that reaches it.
  let wideFloat = encodeItem(cFloat(1000000.5, cfwDouble))
  check wideFloat.len == 9
  refusesWith("1000000.5 as a double", cekNonPreferredFloat):
    discard decodeItem(wideFloat, DeterministicCborOptions)
  check hexOf(encodeDeterministic(cFloat(1000000.5, cfwDouble))) ==
    "fa49742408"
  refusesWith("keys out of order", cekMapKeysOutOfOrder):
    # {2: 0, 1: 0} — well-formed, valid, and not in bytewise order.
    discard decodeItem([0xa2'u8, 0x02, 0x00, 0x01, 0x00],
                       DeterministicCborOptions)
  # Each of those four inputs is accepted under the default options,
  # so none of the four cases above is being satisfied by the input
  # being malformed in some other way.
  check decodeItem([0x18'u8, 0x17]).arg == 23'u64
  check decodeItem([0x9f'u8, 0xff]).elems.len == 0
  check decodeItem([0xfb'u8, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0]).value == 1.5
  check decodeItem([0xa2'u8, 0x02, 0x00, 0x01, 0x00]).entries.len == 2
  # …and the deterministic spelling of each is accepted under
  # `DeterministicCborOptions`, so the rules are not simply refusing
  # their whole category.
  check decodeItem([0x17'u8], DeterministicCborOptions).arg == 23'u64
  check decodeItem([0x80'u8], DeterministicCborOptions).elems.len == 0
  check decodeItem([0xf9'u8, 0x3e, 0x00],
                   DeterministicCborOptions).value == 1.5
  check decodeItem([0xa2'u8, 0x01, 0x00, 0x02, 0x00],
                   DeterministicCborOptions).entries.len == 2

proc driveCborTruncationInsideAContainer() =
  ## The body of test
  ##   "t_cbor_truncation_inside_a_container"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Every container example in Appendix F.1 runs out of bytes at its
  # FIRST element, which one rule answers. These run out later, after
  # a nested item has consumed the bytes the container's own bound
  # accounted for — a different rule, and one no published item
  # reaches.
  refusesWith("array whose second element is missing", cekTruncatedItem):
    discard decodeItem([0x82'u8, 0x81, 0x00])
  refusesWith("indefinite map key with no value", cekTruncatedItem):
    discard decodeItem([0xbf'u8, 0x00])
  # Each is one byte short of well-formed, so the refusal is about the
  # missing byte rather than about the shape.
  check decodeItem([0x82'u8, 0x81, 0x00, 0x00]).elems.len == 2
  check decodeItem([0xbf'u8, 0x00, 0x00, 0xff]).entries.len == 1

proc driveCborTrailingDataIsRefused() =
  ## The body of test
  ##   "t_cbor_trailing_data_is_refused"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Appendix F's error kind 1, "too much data", which F.1 publishes no
  # examples of because it tells a test suite to build them: "examples
  # for well-formedness error kind 1 (too much data) can easily be
  # formed by adding data to a well-formed encoded CBOR data item."
  # `t_cbor_rfc8949_vectors` does that for all 81 published items;
  # here it is one case, so this gate's own vocabulary is complete.
  refusesWith("a byte after a complete item", cekTrailingData):
    discard decodeItem([0x00'u8, 0x00])
  check decodeItem([0x00'u8]).arg == 0'u64

proc driveCborEncoderAndBignumRefusals() =
  ## The body of test
  ##   "t_cbor_encoder_and_bignum_refusals"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # The refusal sites that live in the ENCODER and in the bignum
  # conversions. Not one of them can be reached by decoding bytes, so
  # without this case they are rules no input in this suite reaches —
  # which is the same as not having them.
  refusesWith("encoding a nil item", cekBadDiagnostic):
    discard encodeItem(nil)
  refusesWith("1.1 claimed as binary16", cekNonPreferredFloat):
    discard encodeItem(cFloat(1.1, cfwHalf))
  refusesWith("1.1 claimed as binary32", cekNonPreferredFloat):
    discard encodeItem(cFloat(1.1, cfwSingle))
  # …and the widths that DO hold the value are written, so the two
  # above are the rule rather than a refusal of every narrow float.
  check encodeItem(cFloat(1.5, cfwHalf)).len == 3
  check encodeItem(cFloat(1.5, cfwSingle)).len == 5
  var mismatched = cIndefBytes([@[1'u8], @[2'u8]])
  mismatched.chunks = @[1]
  refusesWith("chunk lengths that do not sum", cekBadIndefiniteChunk):
    discard encodeItem(mismatched)
  # …and the other direction, which is the one that matters: recorded
  # chunk lengths summing to MORE than the payload holds. A check made
  # after the payload has been copied only ever catches the case
  # above; this input walks off the end of the payload before it could
  # be reached, so the check has to come first.
  var overlong = cIndefBytes([@[1'u8], @[2'u8]])
  overlong.chunks = @[5]
  refusesWith("chunk lengths past the end of the payload",
              cekBadIndefiniteChunk):
    discard encodeItem(overlong)
  # A negative recorded chunk length is its own rule: it can make the
  # lengths sum correctly and still index backwards.
  var negativeChunk = cIndefBytes([@[1'u8], @[2'u8]])
  negativeChunk.chunks = @[-1, 3]
  refusesWith("a negative chunk length", cekBadIndefiniteChunk):
    discard encodeItem(negativeChunk)
  # The same item with its real boundaries is written, so none of the
  # three above is a refusal of every indefinite string.
  check hexOf(encodeItem(cIndefBytes([@[1'u8], @[2'u8]]))) ==
    "5f41014102ff"
  var deep = cUInt(0)
  for _ in 0 ..< 400:
    deep = cArray([deep])
  refusesWith("encoding a 400-deep item", cekNestingTooDeep):
    discard encodeItem(deep)
  refusesWith("asInt64 of a text item", cekNotBignum):
    discard asInt64(cText("1"))
  refusesWith("an empty decimal literal", cekBadDiagnostic):
    discard integerFromDecimal("")
  refusesWith("a decimal literal with a letter in it", cekBadDiagnostic):
    discard integerFromDecimal("12x")
  refusesWith("a nine-byte magnitude as a uint64", cekNotBignum):
    discard magnitudeToUint64([1'u8, 0, 0, 0, 0, 0, 0, 0, 0])
  refusesWith("integerToDecimal of nil", cekNotBignum):
    discard integerToDecimal(nil)
  # `magnitudeMinusOne`'s zero guard is reachable only directly:
  # `integerFromDecimal` answers "-0" with the integer zero before it
  # could be called with an empty magnitude.
  var emptyMagnitude: seq[byte] = @[]
  refusesWith("magnitudeMinusOne on zero", cekBadDiagnostic):
    discard magnitudeMinusOne(emptyMagnitude)
  check integerToDecimal(integerFromDecimal("-0")) == "0"

proc driveCborDiagnosticNotationRefusals() =
  ## The body of test
  ##   "t_cbor_diagnostic_notation_refusals"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # Twenty-six malformed inputs, one per refusal site in the
  # diagnostic-notation reader. They all raise the same KIND, so the
  # thing being asserted is not the kind — it is that each input
  # reaches a DIFFERENT site. The count below is what says so, and it
  # is what stops one rule from answering for all twenty-six.
  const Malformed = [
    "/ a comment that never closes",
    "[1",
    "h'0",
    "h'zz'",
    "h'0'",
    "\"\\u12\"",
    "\"abc",
    "\"abc\\",
    "\"\\ud800\"",
    "\"\\ud800\\u0041\"",
    "\"\\udc00\"",
    "\"\\q\"",
    "(_ )",
    "(_ 1)",
    "(_ 'a', \"b\")",
    "-",
    "1e",
    "-1(2)",
    "99999999999999999999(1)",
    "",
    "(1)",
    "<1",
    "<< 1 >",
    "simple(300)",
    "-Infinit",
    "1 2"]
  var sites: seq[string] = @[]
  for text in Malformed:
    refusesWith("diagnostic notation " & text, cekBadDiagnostic):
      discard parseDiagnostic(text)
    if lastSite in sites:
      checkpoint("input " & text & " reaches the same rule as an " &
        "earlier one: " & lastSite)
    check lastSite notin sites
    sites.add lastSite
  check Malformed.len == 26
  check sites.len == 26
  # And the reader accepts what it is supposed to: one value per shape
  # the malformed inputs above are broken versions of.
  check parseDiagnostic("/ c / [1]").elems.len == 1
  check parseDiagnostic("h'00'").bytes.len == 1
  check parseDiagnostic("\"\\u0041\"").text == "A"
  check parseDiagnostic("\"\\ud800\\udd51\"").text.len == 4
  check parseDiagnostic("(_ 'a', 'b')").bytes.len == 2
  check parseDiagnostic("1e3").value == 1000.0
  check parseDiagnostic("1(2)").tag == 1'u64
  check parseDiagnostic("<< 1 >>").bytes == @[1'u8]
  check parseDiagnostic("simple(255)").simple == 255'u8
  check parseDiagnostic("-Infinity").value == -Inf

proc driveCborNestingIsBounded() =
  ## The body of test
  ##   "t_cbor_nesting_is_bounded"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # A declared length is never the size of an allocation, and depth is
  # never the size of the C stack. 400 nested one-element arrays is
  # well-formed CBOR that this decoder refuses on purpose.
  var deep: seq[byte] = @[]
  for _ in 0 ..< 400:
    deep.add 0x81'u8
  deep.add 0x00'u8
  refusesWith("400 deep", cekNestingTooDeep):
    discard decodeItem(deep)
  # 200 deep, which is inside the default bound, is accepted — so the
  # bound is a bound and not a refusal of all nesting.
  var shallow: seq[byte] = @[]
  for _ in 0 ..< 200:
    shallow.add 0x81'u8
  shallow.add 0x00'u8
  var item = decodeItem(shallow)
  var depth = 0
  while item.kind == ckArray:
    item = item.elems[0]
    inc depth
  check depth == 200
  check item.arg == 0'u64
  # The bound is configurable, and raising it accepts the deep input —
  # which is what says 400 was refused BY the bound rather than by
  # something else the input happens to violate.
  var deeper = DefaultCborOptions
  deeper.maxDepth = 500
  check decodeItem(deep, deeper).kind == ckArray

proc driveCborAHugeDeclaredLengthCostsOneComparison() =
  ## The body of test
  ##   "t_cbor_a_huge_declared_length_costs_one_comparison"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # `5b ff ff ff ff ff ff ff ff 01 02 03` is in the published corpus
  # above, where it is checked for its refusal kind. What is checked
  # here is the thing that makes it interesting: the decoder must not
  # try to allocate the 18446744073709551615 bytes the head declares.
  # A decoder that did would not reach this line.
  let huge = @[0x5b'u8, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
               0x01, 0x02, 0x03]
  # The input really does declare more than it holds, by an amount no
  # machine can allocate — asserted from the bytes rather than
  # described, so the case is about the bound and not about a short
  # string that happens to be refused.
  var declared = 0'u64
  for i in 1 .. 8:
    declared = (declared shl 8) or uint64(huge[i])
  check declared == high(uint64)
  check declared > uint64(huge.len)
  check huge.len == 12
  refusesWith("2^64-1 byte string", cekTruncatedString):
    discard decodeItem(huge)
  # The same for a container's element count, which is bounded by a
  # weaker but sound rule: an item needs at least one byte.
  refusesWith("2^64-1 element array", cekTruncatedItem):
    discard decodeItem([0x9b'u8, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
                        0xff, 0xff])

proc driveCborBignumAndDiagnosticRefusals() =
  ## The body of test
  ##   "t_cbor_bignum_and_diagnostic_refusals"
  ## — a proc so the coverage case can drive the same inputs
  ## again in its own process (see that case).
  # The two remaining kinds, so the vocabulary has no member that this
  # gate never reaches.
  refusesWith("decimal of a text item", cekNotBignum):
    discard integerToDecimal(cText("12"))
  refusesWith("tag 4 is not a bignum", cekNotBignum):
    discard integerToDecimal(cTag(4, cBytes([1'u8])))
  refusesWith("not diagnostic notation", cekBadDiagnostic):
    discard parseDiagnostic("[1, 2")
  refusesWith("a float has no small-view projection", cekBadDiagnostic):
    discard decode([0xf9'u8, 0x3c, 0x00])
  # …and the bignum conversions agree with RFC 8949 Appendix A's own
  # decimal renderings, in both directions.
  check integerToDecimal(decodeItem(
    [0xc2'u8, 0x49, 1, 0, 0, 0, 0, 0, 0, 0, 0])) ==
    "18446744073709551616"
  check integerToDecimal(decodeItem(
    [0xc3'u8, 0x49, 1, 0, 0, 0, 0, 0, 0, 0, 0])) ==
    "-18446744073709551617"
  check integerToDecimal(decodeItem(
    [0x1b'u8, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])) ==
    "18446744073709551615"
  check integerToDecimal(decodeItem(
    [0x3b'u8, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff])) ==
    "-18446744073709551616"
  check hexOf(encodeItem(integerFromDecimal("18446744073709551616"))) ==
    "c249010000000000000000"
  check hexOf(encodeItem(integerFromDecimal("-18446744073709551617"))) ==
    "c349010000000000000000"

suite "cbor rules that appendix f does not publish examples for":

  test "t_cbor_duplicate_map_key_is_refused":
    driveCborDuplicateMapKeyIsRefused()

  test "t_cbor_deterministic_rules_are_refused_separately":
    driveCborDeterministicRulesAreRefusedSeparately()

  test "t_cbor_truncation_inside_a_container":
    driveCborTruncationInsideAContainer()

  test "t_cbor_trailing_data_is_refused":
    driveCborTrailingDataIsRefused()

  test "t_cbor_encoder_and_bignum_refusals":
    driveCborEncoderAndBignumRefusals()

  test "t_cbor_diagnostic_notation_refusals":
    driveCborDiagnosticNotationRefusals()

  test "t_cbor_nesting_is_bounded":
    driveCborNestingIsBounded()

  test "t_cbor_a_huge_declared_length_costs_one_comparison":
    driveCborAHugeDeclaredLengthCostsOneComparison()

  test "t_cbor_bignum_and_diagnostic_refusals":
    driveCborBignumAndDiagnosticRefusals()

# Every case above that raises a refusal. The coverage case drives all of
# them itself: the suite runner executes each case in its own process
# (`--run suite::test`), so `reachedKinds` holds only what ran in THIS
# process, and a coverage case that read what earlier cases left behind
# would measure the execution mode rather than the decoder.
const RefusalDrivers: seq[(string, proc () {.nimcall.})] = @[
  ("t_cbor_appendix_f_every_item_is_refused_for_its_own_reason",
    driveCborAppendixFEveryItemIsRefusedForItsOwnReason),
  ("t_cbor_appendix_f_the_small_view_is_fail_closed_too",
    driveCborAppendixFTheSmallViewIsFailClosedToo),
  ("t_cbor_duplicate_map_key_is_refused", driveCborDuplicateMapKeyIsRefused),
  ("t_cbor_deterministic_rules_are_refused_separately",
    driveCborDeterministicRulesAreRefusedSeparately),
  ("t_cbor_truncation_inside_a_container",
    driveCborTruncationInsideAContainer),
  ("t_cbor_trailing_data_is_refused", driveCborTrailingDataIsRefused),
  ("t_cbor_encoder_and_bignum_refusals", driveCborEncoderAndBignumRefusals),
  ("t_cbor_diagnostic_notation_refusals",
    driveCborDiagnosticNotationRefusals),
  ("t_cbor_nesting_is_bounded", driveCborNestingIsBounded),
  ("t_cbor_a_huge_declared_length_costs_one_comparison",
    driveCborAHugeDeclaredLengthCostsOneComparison),
  ("t_cbor_bignum_and_diagnostic_refusals",
    driveCborBignumAndDiagnosticRefusals)]

suite "cbor refusal coverage":

  test "t_cbor_every_refusal_kind_is_reached":
    # The reached-refusal ratio, measured rather than argued. Every kind
    # in the vocabulary must be raised by an input one of the cases above
    # runs; a rule that no input can reach is a rule the program does not
    # have. The inputs are driven HERE, from an empty set, so the verdict
    # is the same whether this case runs alone or after the others.
    reachedKinds = {}
    for (name, drive) in RefusalDrivers:
      checkpoint("driving " & name)
      drive()
    var unreached: seq[string] = @[]
    var count = 0
    for k in CborErrorKind:
      inc count
      if k notin reachedKinds:
        unreached.add $k
    check count == 17
    if unreached.len > 0:
      checkpoint("never reached: " & unreached.join(", "))
    check unreached.len == 0
    check card(reachedKinds) == 17
