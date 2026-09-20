## Arbitrary-precision magnitudes, only as far as RFC 8949 §3.4.3 needs
## them: a big-endian byte string in one direction and a decimal string
## in the other.
##
## RFC 8949 encodes an integer outside the 64-bit range as tag 2 (the
## value is the unsigned big-endian magnitude) or tag 3 (the value is
## -1 - magnitude). Appendix A publishes exactly one of each —
## 18446744073709551616 and -18446744073709551617 — and prints them in
## the diagnostic column as DECIMAL rather than as a tagged byte string,
## which is why a decimal conversion is needed at all: without it the
## published diagnostic notation for those two rows cannot be read.
##
## The algorithms are schoolbook base-10 <-> base-256. They are here
## rather than in a dependency because the whole requirement is two
## conversions on numbers a few hundred bits wide.

import std/strutils

import ./item

proc stripLeadingZeros(m: seq[byte]): seq[byte] =
  var i = 0
  while i < m.len and m[i] == 0:
    inc i
  m[i .. ^1]

proc decimalToMagnitude*(digits: string): seq[byte] =
  ## Big-endian magnitude of a non-negative decimal string, with no
  ## leading zero bytes. Zero becomes the empty sequence, which is what
  ## RFC 8949 §3.4.3's preferred serialization of a zero bignum is.
  if digits.len == 0:
    cborFail(cekBadDiagnostic, "empty decimal literal")
  var acc: seq[byte] = @[]
  for ch in digits:
    if ch notin {'0' .. '9'}:
      cborFail(cekBadDiagnostic, "not a decimal digit: " & $ch)
    # acc = acc * 10 + digit, big-endian, least significant last.
    var carry = uint32(ord(ch) - ord('0'))
    for i in countdown(acc.high, 0):
      let t = uint32(acc[i]) * 10'u32 + carry
      acc[i] = byte(t and 0xff'u32)
      carry = t shr 8
    while carry > 0:
      acc.insert(byte(carry and 0xff'u32), 0)
      carry = carry shr 8
  stripLeadingZeros(acc)

proc magnitudeToDecimal*(m: openArray[byte]): string =
  ## Decimal rendering of a big-endian magnitude. The inverse of
  ## `decimalToMagnitude` on every value it can produce.
  var digits: seq[byte] = @[]   # least significant first, base 10
  for b in m:
    var carry = uint32(b)
    for i in 0 ..< digits.len:
      let t = uint32(digits[i]) * 256'u32 + carry
      digits[i] = byte(t mod 10'u32)
      carry = t div 10'u32
    while carry > 0:
      digits.add byte(carry mod 10'u32)
      carry = carry div 10'u32
  if digits.len == 0:
    return "0"
  result = newStringOfCap(digits.len)
  for i in countdown(digits.high, 0):
    result.add chr(ord('0') + int(digits[i]))

proc magnitudeFitsUint64*(m: openArray[byte]): bool =
  let s = stripLeadingZeros(@m)
  s.len <= 8

proc magnitudeToUint64*(m: openArray[byte]): uint64 =
  let s = stripLeadingZeros(@m)
  if s.len > 8:
    cborFail(cekNotBignum, "magnitude wider than 64 bits")
  for b in s:
    result = (result shl 8) or uint64(b)

proc uint64ToMagnitude*(v: uint64): seq[byte] =
  var started = false
  for shift in countdown(56, 0, 8):
    let b = byte((v shr shift) and 0xff'u64)
    if b != 0 or started:
      result.add b
      started = true

proc magnitudeMinusOne*(m: openArray[byte]): seq[byte] =
  ## `m - 1` for a magnitude known to be non-zero.
  var out0 = @m
  var i = out0.high
  while i >= 0:
    if out0[i] == 0:
      out0[i] = 0xff'u8
      dec i
    else:
      out0[i] = out0[i] - 1
      break
  if i < 0:
    cborFail(cekBadDiagnostic, "magnitudeMinusOne on zero")
  stripLeadingZeros(out0)

proc magnitudePlusOne*(m: openArray[byte]): seq[byte] =
  var out0 = @m
  var i = out0.high
  var carry = true
  while i >= 0 and carry:
    if out0[i] == 0xff'u8:
      out0[i] = 0
    else:
      out0[i] = out0[i] + 1
      carry = false
    dec i
  if carry:
    out0.insert(1'u8, 0)
  stripLeadingZeros(out0)

proc integerFromDecimal*(literal: string): CborItem =
  ## The RFC 8949 encoding of a decimal integer literal: major type 0 or
  ## 1 when the value fits the 64-bit argument, tag 2 or tag 3 over a
  ## byte string otherwise. This is the rule Appendix A's diagnostic
  ## column relies on, stated once.
  var text = literal
  var negative = false
  if text.startsWith("-"):
    negative = true
    text = text[1 .. ^1]
  let m = decimalToMagnitude(text)
  if not negative:
    if magnitudeFitsUint64(m):
      return cUInt(magnitudeToUint64(m))
    return cTag(TagUnsignedBignum, cBytes(m))
  if m.len == 0:
    # "-0" is the integer zero; there is no negative zero in CBOR's
    # integer range.
    return cUInt(0)
  let n = magnitudeMinusOne(m)
  if magnitudeFitsUint64(n):
    return cNegInt(magnitudeToUint64(n))
  cTag(TagNegativeBignum, cBytes(n))

proc integerToDecimal*(item: CborItem): string =
  ## The inverse of `integerFromDecimal` over the four shapes it emits.
  ## Refuses anything else rather than inventing a rendering.
  if item.isNil:
    cborFail(cekNotBignum, "nil item")
  case item.kind
  of ckUInt:
    magnitudeToDecimal(uint64ToMagnitude(item.arg))
  of ckNegInt:
    "-" & magnitudeToDecimal(magnitudePlusOne(uint64ToMagnitude(item.arg)))
  of ckTag:
    if not item.isBignum:
      cborFail(cekNotBignum, "tag " & $item.tag)
    elif item.tag == TagUnsignedBignum:
      magnitudeToDecimal(item.content.bytes)
    else:
      "-" & magnitudeToDecimal(magnitudePlusOne(item.content.bytes))
  else:
    cborFail(cekNotBignum, $item.kind)
