## RFC 8949 (CBOR) — Appendix A's published examples, reproduced
## exactly, in both directions.
##
## ## Where the vectors come from, and why that is the whole point
##
## A vector produced by the implementation under test proves nothing: it
## will agree with a stable wrong answer forever. So none of the bytes
## below were produced by this repository. `Rfc8949AppendixA` is a
## VERBATIM copy of Appendix A of RFC 8949 as published by the RFC
## Editor — table rules, column padding and the wrapped rows included —
## taken from
##
##   https://www.rfc-editor.org/rfc/rfc8949.txt
##   sha256 f1164a5b31a39350ad46abe29b83575eb933ca6c45366989c118b6b1058a214a
##
## lines 2743-2936 of that file, which is the appendix heading through
## the "Table 6" caption. `Rfc8949Section421` is the same file's lines
## 1382-1442, Section 4.2.1 "Core Deterministic Encoding Requirements",
## which publishes two float encodings and a worked eight-key sort order
## that appear NOWHERE in Appendix A.
##
## Both are embedded rather than transcribed, so there is no
## transcription step to get wrong, and both are PARSED rather than
## hand-copied into Nim literals, so a vector cannot be quietly dropped
## while re-typing.
##
## ## The corpus is constrained by its own gate
##
## A fixture set that is not constrained by its own gate can shrink to
## nothing and every case below then passes vacuously. So the table
## parser counts the lines it could not read and the suite asserts that
## count is zero; it asserts the row count, the number of DISTINCT
## diagnostic strings and the number of distinct encodings; it asserts
## the header row says "Diagnostic" and "Encoded"; and it asserts the
## exact number of comparisons made against RFC-published values.
## Adding a row, removing a row or mistyping one moves at least one of
## those numbers.
##
## ## The three claims, kept apart
##
## 1. `decodeItem` accepts each published encoding, and `encodeItem`
##    reproduces it BYTE FOR BYTE. This is what says the item model
##    keeps what the encoding said — the float width, the chunk
##    boundaries of an indefinite-length string, the order of a map.
## 2. `parseDiagnostic` of the LEFT column agrees with `decodeItem` of
##    the RIGHT column. These are two independent paths — text to item
##    and bytes to item — so their agreement is not an implementation
##    agreeing with itself.
## 3. `encodeDeterministic` produces the RFC 8949 §4.2.1 form. Seventeen
##    of the 81 published encodings are deliberately NOT in that form
##    (eleven use indefinite lengths, six use a float wider than
##    necessary);
##    the exact set is pinned BY VALUE, so a row moving between the two
##    buckets fails here rather than being absorbed.
##
## ## What this gate does NOT cover
##
## Appendix A is a table of WELL-FORMED items. The not-well-formed
## corpus of Appendix F is a separate gate,
## `t_cbor_rfc8949_malformed`. What this file adds to it are the two
## derived corpora Appendix F.1 tells a test suite to build for itself:
## "examples for well-formedness error kind 1 (too much data) can easily
## be formed by adding data to a well-formed encoded CBOR data item" and
## "examples for kind 2 (too little data) can be formed by truncating
## a well-formed encoded CBOR data item". Both are built here, from the
## 81 rows, because this is the file that holds them.
##
## Not covered anywhere: RFC 8949 §3.4's tag CONTENT semantics beyond
## bignums — tag 0 and tag 1 date-times are carried as a tag over their
## content and are not turned into a time, tag 24's embedded item is not
## decoded recursively by the decoder itself, and tags 4, 5 and 30
## (decimal fractions, bigfloats, rationals) have no interpretation at
## all. Appendix A's tag rows are pinned as ENCODINGS, which is what the
## table publishes.
##
## ## Mocking
##
## None. Every byte below is either published by RFC 8949 or computed by
## the code under test.

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

const Rfc8949AppendixA = """Appendix A.  Examples of Encoded CBOR Data Items

   The following table provides some CBOR-encoded values in hexadecimal
   (right column), together with diagnostic notation for these values
   (left column).  Note that the string "\u00fc" is one form of
   diagnostic notation for a UTF-8 string containing the single Unicode
   character U+00FC (LATIN SMALL LETTER U WITH DIAERESIS, "ü").
   Similarly, "\u6c34" is a UTF-8 string in diagnostic notation with a
   single character U+6C34 (CJK UNIFIED IDEOGRAPH-6C34, "水"), often
   representing "water", and "\ud800\udd51" is a UTF-8 string in
   diagnostic notation with a single character U+10151 (GREEK ACROPHONIC
   ATTIC FIFTY STATERS, "𐅑").  (Note that all these single-character
   strings could also be represented in native UTF-8 in diagnostic
   notation, just not if an ASCII-only specification is required.)  In
   the diagnostic notation provided for bignums, their intended numeric
   value is shown as a decimal number (such as 18446744073709551616)
   instead of a tagged byte string (such as 2(h'010000000000000000')).

   +==============================+====================================+
   |Diagnostic                    | Encoded                            |
   +==============================+====================================+
   |0                             | 0x00                               |
   +------------------------------+------------------------------------+
   |1                             | 0x01                               |
   +------------------------------+------------------------------------+
   |10                            | 0x0a                               |
   +------------------------------+------------------------------------+
   |23                            | 0x17                               |
   +------------------------------+------------------------------------+
   |24                            | 0x1818                             |
   +------------------------------+------------------------------------+
   |25                            | 0x1819                             |
   +------------------------------+------------------------------------+
   |100                           | 0x1864                             |
   +------------------------------+------------------------------------+
   |1000                          | 0x1903e8                           |
   +------------------------------+------------------------------------+
   |1000000                       | 0x1a000f4240                       |
   +------------------------------+------------------------------------+
   |1000000000000                 | 0x1b000000e8d4a51000               |
   +------------------------------+------------------------------------+
   |18446744073709551615          | 0x1bffffffffffffffff               |
   +------------------------------+------------------------------------+
   |18446744073709551616          | 0xc249010000000000000000           |
   +------------------------------+------------------------------------+
   |-18446744073709551616         | 0x3bffffffffffffffff               |
   +------------------------------+------------------------------------+
   |-18446744073709551617         | 0xc349010000000000000000           |
   +------------------------------+------------------------------------+
   |-1                            | 0x20                               |
   +------------------------------+------------------------------------+
   |-10                           | 0x29                               |
   +------------------------------+------------------------------------+
   |-100                          | 0x3863                             |
   +------------------------------+------------------------------------+
   |-1000                         | 0x3903e7                           |
   +------------------------------+------------------------------------+
   |0.0                           | 0xf90000                           |
   +------------------------------+------------------------------------+
   |-0.0                          | 0xf98000                           |
   +------------------------------+------------------------------------+
   |1.0                           | 0xf93c00                           |
   +------------------------------+------------------------------------+
   |1.1                           | 0xfb3ff199999999999a               |
   +------------------------------+------------------------------------+
   |1.5                           | 0xf93e00                           |
   +------------------------------+------------------------------------+
   |65504.0                       | 0xf97bff                           |
   +------------------------------+------------------------------------+
   |100000.0                      | 0xfa47c35000                       |
   +------------------------------+------------------------------------+
   |3.4028234663852886e+38        | 0xfa7f7fffff                       |
   +------------------------------+------------------------------------+
   |1.0e+300                      | 0xfb7e37e43c8800759c               |
   +------------------------------+------------------------------------+
   |5.960464477539063e-8          | 0xf90001                           |
   +------------------------------+------------------------------------+
   |0.00006103515625              | 0xf90400                           |
   +------------------------------+------------------------------------+
   |-4.0                          | 0xf9c400                           |
   +------------------------------+------------------------------------+
   |-4.1                          | 0xfbc010666666666666               |
   +------------------------------+------------------------------------+
   |Infinity                      | 0xf97c00                           |
   +------------------------------+------------------------------------+
   |NaN                           | 0xf97e00                           |
   +------------------------------+------------------------------------+
   |-Infinity                     | 0xf9fc00                           |
   +------------------------------+------------------------------------+
   |Infinity                      | 0xfa7f800000                       |
   +------------------------------+------------------------------------+
   |NaN                           | 0xfa7fc00000                       |
   +------------------------------+------------------------------------+
   |-Infinity                     | 0xfaff800000                       |
   +------------------------------+------------------------------------+
   |Infinity                      | 0xfb7ff0000000000000               |
   +------------------------------+------------------------------------+
   |NaN                           | 0xfb7ff8000000000000               |
   +------------------------------+------------------------------------+
   |-Infinity                     | 0xfbfff0000000000000               |
   +------------------------------+------------------------------------+
   |false                         | 0xf4                               |
   +------------------------------+------------------------------------+
   |true                          | 0xf5                               |
   +------------------------------+------------------------------------+
   |null                          | 0xf6                               |
   +------------------------------+------------------------------------+
   |undefined                     | 0xf7                               |
   +------------------------------+------------------------------------+
   |simple(16)                    | 0xf0                               |
   +------------------------------+------------------------------------+
   |simple(255)                   | 0xf8ff                             |
   +------------------------------+------------------------------------+
   |0("2013-03-21T20:04:00Z")     | 0xc074323031332d30332d32315432303a |
   |                              | 30343a30305a                       |
   +------------------------------+------------------------------------+
   |1(1363896240)                 | 0xc11a514b67b0                     |
   +------------------------------+------------------------------------+
   |1(1363896240.5)               | 0xc1fb41d452d9ec200000             |
   +------------------------------+------------------------------------+
   |23(h'01020304')               | 0xd74401020304                     |
   +------------------------------+------------------------------------+
   |24(h'6449455446')             | 0xd818456449455446                 |
   +------------------------------+------------------------------------+
   |32("http://www.example.com")  | 0xd82076687474703a2f2f7777772e6578 |
   |                              | 616d706c652e636f6d                 |
   +------------------------------+------------------------------------+
   |h''                           | 0x40                               |
   +------------------------------+------------------------------------+
   |h'01020304'                   | 0x4401020304                       |
   +------------------------------+------------------------------------+
   |""                            | 0x60                               |
   +------------------------------+------------------------------------+
   |"a"                           | 0x6161                             |
   +------------------------------+------------------------------------+
   |"IETF"                        | 0x6449455446                       |
   +------------------------------+------------------------------------+
   |"\"\\"                        | 0x62225c                           |
   +------------------------------+------------------------------------+
   |"\u00fc"                      | 0x62c3bc                           |
   +------------------------------+------------------------------------+
   |"\u6c34"                      | 0x63e6b0b4                         |
   +------------------------------+------------------------------------+
   |"\ud800\udd51"                | 0x64f0908591                       |
   +------------------------------+------------------------------------+
   |[]                            | 0x80                               |
   +------------------------------+------------------------------------+
   |[1, 2, 3]                     | 0x83010203                         |
   +------------------------------+------------------------------------+
   |[1, [2, 3], [4, 5]]           | 0x8301820203820405                 |
   +------------------------------+------------------------------------+
   |[1, 2, 3, 4, 5, 6, 7, 8, 9,   | 0x98190102030405060708090a0b0c0d0e |
   |10, 11, 12, 13, 14, 15, 16,   | 0f101112131415161718181819         |
   |17, 18, 19, 20, 21, 22, 23,   |                                    |
   |24, 25]                       |                                    |
   +------------------------------+------------------------------------+
   |{}                            | 0xa0                               |
   +------------------------------+------------------------------------+
   |{1: 2, 3: 4}                  | 0xa201020304                       |
   +------------------------------+------------------------------------+
   |{"a": 1, "b": [2, 3]}         | 0xa26161016162820203               |
   +------------------------------+------------------------------------+
   |["a", {"b": "c"}]             | 0x826161a161626163                 |
   +------------------------------+------------------------------------+
   |{"a": "A", "b": "B", "c": "C",| 0xa5616161416162614261636143616461 |
   |"d": "D", "e": "E"}           | 4461656145                         |
   +------------------------------+------------------------------------+
   |(_ h'0102', h'030405')        | 0x5f42010243030405ff               |
   +------------------------------+------------------------------------+
   |(_ "strea", "ming")           | 0x7f657374726561646d696e67ff       |
   +------------------------------+------------------------------------+
   |[_ ]                          | 0x9fff                             |
   +------------------------------+------------------------------------+
   |[_ 1, [2, 3], [_ 4, 5]]       | 0x9f018202039f0405ffff             |
   +------------------------------+------------------------------------+
   |[_ 1, [2, 3], [4, 5]]         | 0x9f01820203820405ff               |
   +------------------------------+------------------------------------+
   |[1, [2, 3], [_ 4, 5]]         | 0x83018202039f0405ff               |
   +------------------------------+------------------------------------+
   |[1, [_ 2, 3], [4, 5]]         | 0x83019f0203ff820405               |
   +------------------------------+------------------------------------+
   |[_ 1, 2, 3, 4, 5, 6, 7, 8, 9, | 0x9f0102030405060708090a0b0c0d0e0f |
   |10, 11, 12, 13, 14, 15, 16,   | 101112131415161718181819ff         |
   |17, 18, 19, 20, 21, 22, 23,   |                                    |
   |24, 25]                       |                                    |
   +------------------------------+------------------------------------+
   |{_ "a": 1, "b": [_ 2, 3]}     | 0xbf61610161629f0203ffff           |
   +------------------------------+------------------------------------+
   |["a", {_ "b": "c"}]           | 0x826161bf61626163ff               |
   +------------------------------+------------------------------------+
   |{_ "Fun": true, "Amt": -2}    | 0xbf6346756ef563416d7421ff         |
   +------------------------------+------------------------------------+

                Table 6: Examples of Encoded CBOR Data Items"""

const Rfc8949Section421 = """4.2.1.  Core Deterministic Encoding Requirements

   A CBOR encoding satisfies the "core deterministic encoding
   requirements" if it satisfies the following restrictions:

   *  Preferred serialization MUST be used.  In particular, this means
      that arguments (see Section 3) for integers, lengths in major
      types 2 through 5, and tags MUST be as short as possible, for
      instance:

      -  0 to 23 and -1 to -24 MUST be expressed in the same byte as the
         major type;

      -  24 to 255 and -25 to -256 MUST be expressed only with an
         additional uint8_t;

      -  256 to 65535 and -257 to -65536 MUST be expressed only with an
         additional uint16_t;

      -  65536 to 4294967295 and -65537 to -4294967296 MUST be expressed
         only with an additional uint32_t.

      Floating-point values also MUST use the shortest form that
      preserves the value, e.g., 1.5 is encoded as 0xf93e00 (binary16)
      and 1000000.5 as 0xfa49742408 (binary32).  (One implementation of
      this is to have all floats start as a 64-bit float, then do a test
      conversion to a 32-bit float; if the result is the same numeric
      value, use the shorter form and repeat the process with a test
      conversion to a 16-bit float.  This also works to select 16-bit
      float for positive and negative Infinity as well.)

   *  Indefinite-length items MUST NOT appear.  They can be encoded as
      definite-length items instead.

   *  The keys in every map MUST be sorted in the bytewise lexicographic
      order of their deterministic encodings.  For example, the
      following keys are sorted correctly:

      1.  10, encoded as 0x0a.

      2.  100, encoded as 0x1864.

      3.  -1, encoded as 0x20.

      4.  "z", encoded as 0x617a.

      5.  "aa", encoded as 0x626161.

      6.  [100], encoded as 0x811864.

      7.  [-1], encoded as 0x8120.

      8.  false, encoded as 0xf4.

      |  Implementation note: the self-delimiting nature of the CBOR
      |  encoding means that there are no two well-formed CBOR encoded
      |  data items where one is a prefix of the other.  The bytewise
      |  lexicographic comparison of deterministic encodings of
      |  different map keys therefore always ends in a position where
      |  the byte differs between the keys, before the end of a key is
      |  reached."""

# ---------------------------------------------------------------------
# Reading the published table
# ---------------------------------------------------------------------

type
  Row = object
    diag: string
    hex: string

  Table6 = object
    header: Row
    rows: seq[Row]
    unparsedLines: int

proc splitRow(line: string): Row =
  ## One `   |left|right|` line. The column rule is the RFC's own: the
  ## body after the three-space margin, split at the first `|`.
  let body = line[4 .. ^1]
  let bar = body.find('|')
  if bar < 0:
    return Row(diag: "", hex: "")
  result.diag = body[0 ..< bar].strip(leading = false)
  var right = body[bar + 1 .. ^1].strip()
  if right.endsWith("|"):
    right = right[0 ..< right.high].strip()
  result.hex = right

proc parseTable6(text: string): Table6 =
  var pending: seq[Row] = @[]
  var flushed: seq[Row] = @[]
  proc flush() =
    if pending.len == 0:
      return
    var diagParts: seq[string] = @[]
    var hex = ""
    for p in pending:
      if p.diag.len > 0:
        diagParts.add p.diag
      hex.add p.hex
    flushed.add Row(diag: diagParts.join(" ").strip(), hex: hex)
    pending = @[]
  for raw in text.splitLines():
    if raw.startsWith("   +"):
      flush()
    elif raw.startsWith("   |"):
      let r = splitRow(raw)
      if r.diag.len == 0 and r.hex.len == 0:
        inc result.unparsedLines
      else:
        pending.add r
    elif raw.strip().len > 0 and raw.startsWith("   |"):
      inc result.unparsedLines
  flush()
  if flushed.len == 0:
    return
  result.header = flushed[0]
  result.rows = flushed[1 .. ^1]

let Appendix = parseTable6(Rfc8949AppendixA)

proc hexToBytes(where, s: string): seq[byte] =
  if not s.startsWith("0x"):
    raise newException(ValueError, where & ": no 0x prefix in " & s)
  let body = s[2 .. ^1]
  if body.len mod 2 != 0:
    raise newException(ValueError, where & ": odd hex length in " & s)
  result = newSeq[byte](body.len div 2)
  for i in 0 ..< result.len:
    result[i] = byte(parseHexInt(body[2 * i .. 2 * i + 1]))

proc bytesToHex(b: openArray[byte]): string =
  result = "0x"
  for x in b:
    result.add toHex(int(x), 2).toLowerAscii()

# ---------------------------------------------------------------------
# Reading Section 4.2.1's two published lists
# ---------------------------------------------------------------------

proc normalizeSpace(text: string): string =
  var lastWasSpace = true
  for ch in text:
    if ch in {' ', '\t', '\r', '\n'}:
      if not lastWasSpace:
        result.add ' '
      lastWasSpace = true
    else:
      result.add ch
      lastWasSpace = false
  result = result.strip()

proc hexRunAt(text: string; start: int): string =
  var i = start
  while i < text.len and text[i] in HexDigits:
    inc i
  text[start ..< i]

proc everyEncodingIn(text: string): seq[Row] =
  ## Every `0x…` in the section, paired with the last token before it
  ## that reads as diagnostic notation. The pairing rule is mechanical
  ## rather than positional, so the entries are found the same way
  ## whether they came from the prose sentence about floats or from the
  ## numbered list of sorted keys.
  let flat = normalizeSpace(text)
  var at = 0
  while true:
    let found = flat.find("0x", at)
    if found < 0:
      break
    at = found + 2
    let hex = hexRunAt(flat, at)
    if hex.len < 2:
      continue
    at = found + 2 + hex.len
    var words: seq[string] = @[]
    for w in flat[0 ..< found].strip().split(' '):
      words.add w
    var diag = ""
    for i in countdown(words.high, 0):
      var w = words[i]
      while w.len > 0 and w[^1] in {',', ':'}:
        w = w[0 ..< w.high]
      if w.len == 0:
        continue
      try:
        discard parseDiagnostic(w)
        diag = w
        break
      except CborError:
        discard
    result.add Row(diag: diag, hex: "0x" & hex)

proc sortedKeyListIn(text: string): seq[Row] =
  ## The eight entries of Section 4.2.1's worked sort order, found by
  ## the shape the RFC writes them in: `<n>.  <key>, encoded as 0x<hex>.`
  ## This is a SECOND reading of the same prose, by a different rule
  ## than `everyEncodingIn`, so the two can be required to agree.
  const Marker = ", encoded as 0x"
  let flat = normalizeSpace(text)
  var at = 0
  while true:
    let found = flat.find(Marker, at)
    if found < 0:
      break
    at = found + Marker.len
    let hex = hexRunAt(flat, at)
    # Walk back to the `<n>. ` that opens this list entry.
    var i = found
    var opened = -1
    while i > 1:
      if flat[i] == ' ' and flat[i - 1] == '.' and flat[i - 2] in Digits:
        opened = i + 1
        break
      dec i
    if opened < 0:
      continue
    result.add Row(diag: flat[opened ..< found].strip(), hex: "0x" & hex)

let Section421Encodings = everyEncodingIn(Rfc8949Section421)
let Section421SortOrder = sortedKeyListIn(Rfc8949Section421)

# The seventeen Appendix A encodings that are deliberately NOT in RFC
# 8949 Section 4.2.1 core deterministic form, pinned by value. Eleven use an
# indefinite length; six spell a float wider than the shortest form that
# preserves it — Appendix A publishes Infinity, NaN and -Infinity at all
# three widths, and only the binary16 spelling of each is deterministic.
const NotDeterministic = [
  "0xfa7f800000", "0xfb7ff0000000000000",
  "0xfa7fc00000", "0xfb7ff8000000000000",
  "0xfaff800000", "0xfbfff0000000000000",
  "0x5f42010243030405ff",
  "0x7f657374726561646d696e67ff",
  "0x9fff",
  "0x9f018202039f0405ffff",
  "0x9f01820203820405ff",
  "0x9f0102030405060708090a0b0c0d0e0f101112131415161718181819ff",
  "0x83018202039f0405ff",
  "0x83019f0203ff820405",
  "0xbf61610161629f0203ffff",
  "0x826161bf61626163ff",
  "0xbf6346756ef563416d7421ff"]

suite "cbor rfc 8949 appendix a corpus":

  test "t_cbor_appendix_a_corpus_is_intact":
    # The corpus has to be constrained by its own gate, or it can shrink
    # to nothing and every case below passes vacuously.
    check Appendix.unparsedLines == 0
    check Appendix.header.diag == "Diagnostic"
    check Appendix.header.hex == "Encoded"
    check Appendix.rows.len == 81
    var diags: seq[string] = @[]
    var hexes: seq[string] = @[]
    for r in Appendix.rows:
      check r.diag.len > 0
      check r.hex.startsWith("0x")
      check r.hex.len >= 4
      if r.diag notin diags: diags.add r.diag
      if r.hex notin hexes: hexes.add r.hex
    # Every encoding is distinct; six diagnostic strings are not,
    # because Infinity, NaN and -Infinity each appear at three widths.
    check hexes.len == 81
    check diags.len == 75
    var repeated: seq[string] = @[]
    for d in diags:
      var n = 0
      for r in Appendix.rows:
        if r.diag == d: inc n
      if n > 1:
        check n == 3
        repeated.add d
    check repeated == @["Infinity", "NaN", "-Infinity"]
    # …and the seventeen non-deterministic rows named above are all real
    # rows of this table, so the exclusion list cannot name a row that
    # does not exist.
    for h in NotDeterministic:
      check h in hexes
    check NotDeterministic.len == 17

  test "t_cbor_appendix_a_round_trips_byte_for_byte":
    var compared = 0
    for r in Appendix.rows:
      let want = hexToBytes(r.diag, r.hex)
      let item = decodeItem(want)
      let got = bytesToHex(encodeItem(item))
      if got != r.hex:
        checkpoint("row " & r.diag)
      check got == r.hex
      inc compared
    check compared == 81

  test "t_cbor_appendix_a_diagnostic_column_agrees":
    # The left column and the right column are read by code that shares
    # nothing but the item model: one parses text, the other parses
    # bytes. Agreement between them is not this library agreeing with
    # itself about an encoding.
    var compared = 0
    for r in Appendix.rows:
      let fromBytes = decodeItem(hexToBytes(r.diag, r.hex))
      let fromText = parseDiagnostic(r.diag)
      if not equalValue(fromText, fromBytes):
        checkpoint("row " & r.diag & " -> " &
          bytesToHex(encodeItem(fromText)) & " against " & r.hex)
      check equalValue(fromText, fromBytes)
      inc compared
    check compared == 81
    # Two PAIRS of published rows differ only in whether a container is
    # indefinite. `equalValue` must not collapse them, or the loop above
    # would be satisfied by an item model that forgot the distinction
    # and the byte round-trip would be the only thing holding it.
    check not equalValue(decodeItem(hexToBytes("a", "0x9fff")),
                         decodeItem(hexToBytes("b", "0x80")))
    check not equalValue(
      decodeItem(hexToBytes("a", "0x83018202039f0405ff")),
      decodeItem(hexToBytes("b", "0x8301820203820405")))
    for h in ["0x9fff", "0x80", "0x83018202039f0405ff",
              "0x8301820203820405"]:
      var present = false
      for r in Appendix.rows:
        if r.hex == h: present = true
      check present

  test "t_cbor_appendix_a_sign_of_zero_and_nan_are_not_lost":
    # `0.0 == -0.0` and `NaN != NaN` in IEEE arithmetic, so a comparison
    # written the obvious way would accept a decoder that dropped the
    # sign of zero and would reject the three NaN rows outright. Both
    # halves are pinned here rather than left to the loop above, where a
    # weakening would be invisible.
    let zero = decodeItem(hexToBytes("zero", "0xf90000"))
    let negZero = decodeItem(hexToBytes("negzero", "0xf98000"))
    check zero.value == negZero.value          # IEEE says they are equal
    check not equalValue(zero, negZero)        # CBOR says they are not
    check bytesToHex(encodeItem(zero)) == "0xf90000"
    check bytesToHex(encodeItem(negZero)) == "0xf98000"
    let nanHalf = decodeItem(hexToBytes("nan16", "0xf97e00"))
    let nanSingle = decodeItem(hexToBytes("nan32", "0xfa7fc00000"))
    let nanDouble = decodeItem(hexToBytes("nan64", "0xfb7ff8000000000000"))
    check nanHalf.value != nanHalf.value       # IEEE says NaN differs
    check equalValue(nanHalf, nanSingle)       # all three are one value
    check equalValue(nanHalf, nanDouble)
    check nanHalf.width == cfwHalf             # …at three widths
    check nanSingle.width == cfwSingle
    check nanDouble.width == cfwDouble

suite "cbor rfc 8949 section 4.2.1 deterministic encoding":

  test "t_cbor_section_421_corpus_is_intact":
    check Section421Encodings.len == 10
    check Section421SortOrder.len == 8
    for e in Section421Encodings:
      check e.diag.len > 0
      check e.hex.startsWith("0x")
    # The sort list is a subset of every encoding the section publishes,
    # found by a different rule; if either reading drifted they would
    # stop agreeing.
    for e in Section421SortOrder:
      check e in Section421Encodings
    # The two the sort list does not contain are the float examples.
    var floats: seq[Row] = @[]
    for e in Section421Encodings:
      if e notin Section421SortOrder:
        floats.add e
    check floats.len == 2
    check floats[0].diag == "1.5"
    check floats[0].hex == "0xf93e00"
    check floats[1].diag == "1000000.5"
    check floats[1].hex == "0xfa49742408"
    check Section421SortOrder[0].diag == "10"
    check Section421SortOrder[^1].diag == "false"

  test "t_cbor_section_421_published_encodings":
    # Every value RFC 8949 Section 4.2.1 writes an encoding for,
    # encoded deterministically. 1000000.5 appears in no other part of
    # the document, so this is not a restatement of Appendix A.
    var compared = 0
    for e in Section421Encodings:
      let got = bytesToHex(encodeDeterministic(parseDiagnostic(e.diag)))
      if got != e.hex:
        checkpoint("section 4.2.1 entry " & e.diag)
      check got == e.hex
      inc compared
    check compared == 10

  test "t_cbor_section_421_map_key_order":
    # The section's worked example: eight keys "sorted correctly".
    # Encoding a map whose keys arrive in the REVERSE of that order must
    # produce the same bytes as one whose keys arrive in it — which is
    # the property, and which a comparison of the published order
    # against itself would not show.
    var forward: seq[CborPair] = @[]
    var backward: seq[CborPair] = @[]
    for i in 0 ..< Section421SortOrder.len:
      let k = parseDiagnostic(Section421SortOrder[i].diag)
      forward.add cPair(k, cUInt(uint64(i)))
      backward.add cPair(parseDiagnostic(
        Section421SortOrder[^(i + 1)].diag), cUInt(uint64(i)))
    check forward.len == 8
    let asWritten = encodeDeterministic(cMap(forward))
    let reversed = encodeDeterministic(cMap(backward))
    # The VALUES differ (they count position), so the two encodings are
    # not equal; the KEY ORDER is what must match. Compare the key
    # sequence the encoder produced, by decoding its own output.
    var keysForward: seq[string] = @[]
    for e in decodeItem(asWritten).entries:
      keysForward.add bytesToHex(encodeDeterministic(e.key))
    var keysReversed: seq[string] = @[]
    for e in decodeItem(reversed).entries:
      keysReversed.add bytesToHex(encodeDeterministic(e.key))
    check keysForward == keysReversed
    var published: seq[string] = @[]
    for e in Section421SortOrder:
      published.add e.hex
    check keysForward == published
    # And the reversed input really was reversed, so the case is not
    # comparing one order with itself.
    var backwardKeys: seq[string] = @[]
    for p in backward:
      backwardKeys.add bytesToHex(encodeDeterministic(p.key))
    check backwardKeys != published
    check backwardKeys.len == 8

  test "t_cbor_appendix_a_deterministic_form":
    # Which of the 81 published encodings are already in Section 4.2.1
    # form, and which are not, pinned as a SET rather than as a count.
    var offenders: seq[string] = @[]
    for r in Appendix.rows:
      let raw = hexToBytes(r.diag, r.hex)
      let again = bytesToHex(encodeDeterministic(decodeItem(raw)))
      if again != r.hex:
        offenders.add r.hex
    check offenders.len == 17
    for h in NotDeterministic:
      check h in offenders
    for h in offenders:
      check h in NotDeterministic
    # …and the deterministic reader agrees with the writer about which
    # is which: every row the writer leaves alone must be accepted under
    # `DeterministicCborOptions`, and every row it rewrites refused.
    var accepted = 0
    var refused = 0
    for r in Appendix.rows:
      let raw = hexToBytes(r.diag, r.hex)
      try:
        discard decodeItem(raw, DeterministicCborOptions)
        check r.hex notin NotDeterministic
        inc accepted
      except CborError as e:
        noteSite(e.site.filename, e.site.line)
        check r.hex in NotDeterministic
        check e.kind in {cekIndefiniteNotDeterministic, cekNonPreferredFloat}
        inc refused
    check accepted == 64
    check refused == 17
    # The concrete rewrites, so "deterministic" is a value here and not
    # only a predicate.
    check bytesToHex(encodeDeterministic(
      decodeItem(hexToBytes("indef", "0x9fff")))) == "0x80"
    check bytesToHex(encodeDeterministic(
      decodeItem(hexToBytes("indef", "0x5f42010243030405ff")))) ==
      "0x450102030405"
    check bytesToHex(encodeDeterministic(
      decodeItem(hexToBytes("inf64", "0xfb7ff0000000000000")))) == "0xf97c00"

  test "t_cbor_non_preferred_head_is_read_and_rewritten":
    # A head longer than it needs to be is WELL-FORMED and is not
    # deterministic. Both answers are pinned, because a decoder that
    # refused it outright and a decoder that silently normalised it
    # would each pass a gate that only checked one of them.
    let wide = @[0x18'u8, 0x17'u8]     # 23, spelled in two bytes
    let item = decodeItem(wide)
    check item.kind == ckUInt
    check item.arg == 23'u64
    check bytesToHex(encodeItem(item)) == "0x17"
    expect CborError:
      discard decodeItem(wide, DeterministicCborOptions)
    try:
      discard decodeItem(wide, DeterministicCborOptions)
      check false
    except CborError as e:
      noteSite(e.site.filename, e.site.line)
      check e.kind == cekNonPreferredHead

suite "cbor rfc 8949 appendix f derived corpora":

  test "t_cbor_appendix_a_rows_reject_appended_data":
    # RFC 8949 Appendix F.1: "Examples for well-formedness error kind 1
    # (too much data) can easily be formed by adding data to a
    # well-formed encoded CBOR data item." One per published row.
    var refused = 0
    for r in Appendix.rows:
      var bytes = hexToBytes(r.diag, r.hex)
      bytes.add 0x00'u8
      try:
        discard decodeItem(bytes)
        checkpoint("accepted trailing data after " & r.hex)
        check false
      except CborError as e:
        noteSite(e.site.filename, e.site.line)
        check e.kind == cekTrailingData
        inc refused
    check refused == 81

  test "t_cbor_appendix_a_rows_reject_truncation":
    # …and kind 2: "examples for well-formedness error kind 2 (too
    # little data) can be formed by truncating a well-formed encoded
    # CBOR data item." Dropping the last byte of any of the 81.
    var refused = 0
    var kinds: seq[CborErrorKind] = @[]
    for r in Appendix.rows:
      let full = hexToBytes(r.diag, r.hex)
      let short = full[0 ..< full.high]
      try:
        discard decodeItem(short)
        checkpoint("accepted truncation of " & r.hex)
        check false
      except CborError as e:
        noteSite(e.site.filename, e.site.line)
        check e.kind in {cekTruncatedHead, cekTruncatedString,
                         cekTruncatedItem}
        if e.kind notin kinds: kinds.add e.kind
        inc refused
    check refused == 81
    # All three truncation kinds are actually reached, so the set above
    # is not three names for one behaviour.
    check kinds.len == 3

  test "t_cbor_trailing_data_is_not_the_same_as_a_sequence":
    # `decodeItem` refuses leftovers; `decodeItemPrefix` is the surface
    # that does not, and it reports where it stopped. Without the second
    # there is no way to read a CBOR sequence, and without the first a
    # verifier would accept a message with anything appended to it.
    let two = hexToBytes("two", "0x0102")
    expect CborError:
      discard decodeItem(two)
    var at = 0
    let first = decodeItemPrefix(two, at)
    check first.kind == ckUInt
    check first.arg == 1'u64
    check at == 1
    let second = decodeItemPrefix(two, at)
    check second.arg == 2'u64
    check at == 2
