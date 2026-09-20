## The RFC 8949 encoder, in two modes.
##
## `encodeItem` is FAITHFUL: it reproduces the item exactly as the item
## records it — the recorded float width, the recorded chunk boundaries
## of an indefinite-length string, the recorded map order. That is what
## makes `encodeItem(decodeItem(x)) == x` a meaningful statement about
## a decoder, and it is also what COSE needs, because a COSE protected
## header is signed as the bytes it arrived as and a re-ordering
## encoder would invalidate every signature it touched.
##
## `encodeDeterministic` applies RFC 8949 §4.2.1 instead: preferred
## argument serialization, the shortest float that preserves the value,
## definite lengths only, and map keys in bytewise lexicographic order
## of their own deterministic encodings.
##
## Both emit preferred argument serialization. A decoder that accepted a
## longer-than-necessary head therefore does NOT round-trip byte-exactly
## through `encodeItem`, and that is deliberate: see
## `t_cbor_rfc8949_vectors`, which pins one such input and both of its
## answers.

import std/algorithm

import ./item
import ./floats

proc putHead*(outp: var seq[byte]; major: int; arg: uint64) =
  ## The preferred serialization of a head, RFC 8949 §3 and §4.2.1.
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

proc putSimple(outp: var seq[byte]; v: uint8) =
  if v < 24'u8:
    outp.add(0xe0'u8 or v)
  else:
    # Values 24..31 are reserved for the two-byte form's own use and the
    # reader refuses them; anything else is emitted as 0xf8 ‖ value.
    outp.add(0xf8'u8)
    outp.add(v)

proc putFloat(outp: var seq[byte]; v: float64; width: CborFloatWidth) =
  case width
  of cfwHalf:
    let got = tryNarrowToHalf(v)
    if not got.ok:
      cborFail(cekNonPreferredFloat,
        "item claims binary16 but the value does not fit")
    outp.add(0xf9'u8)
    outp.add(byte((got.bits shr 8) and 0xff'u16))
    outp.add(byte(got.bits and 0xff'u16))
  of cfwSingle:
    let got = tryNarrowToSingle(v)
    if not got.ok:
      cborFail(cekNonPreferredFloat,
        "item claims binary32 but the value does not fit")
    outp.add(0xfa'u8)
    for shift in [24, 16, 8, 0]:
      outp.add(byte((got.bits shr shift) and 0xff'u32))
  of cfwDouble:
    outp.add(0xfb'u8)
    let bits = bitsOf(v)
    for shift in [56, 48, 40, 32, 24, 16, 8, 0]:
      outp.add(byte((bits shr shift) and 0xff'u64))

proc shortestFloatWidth*(v: float64): CborFloatWidth =
  ## RFC 8949 §4.2.1's "test conversion" rule. The RFC describes it as
  ## binary32 first and then binary16; asking for the narrower width
  ## first is the same function, because `tryNarrowToHalf` succeeds only
  ## when the value is preserved exactly and every such value is
  ## preserved by binary32 as well.
  if tryNarrowToHalf(v).ok: cfwHalf
  elif tryNarrowToSingle(v).ok: cfwSingle
  else: cfwDouble

proc writeItem(outp: var seq[byte]; item: CborItem;
               deterministic: bool; depth: int)

proc writeString(outp: var seq[byte]; item: CborItem; major: int;
                 payload: seq[byte]; deterministic: bool) =
  if item.indefinite and not deterministic:
    # The recorded chunk lengths are checked against the payload BEFORE
    # any of it is copied. Checking afterwards catches only the case
    # where they sum to too little; the other direction reads past the
    # end of the payload and never reaches the check.
    var total = 0
    for n in item.chunks:
      if n < 0:
        cborFail(cekBadIndefiniteChunk, "negative chunk length " & $n)
      total += n
    if total != payload.len:
      cborFail(cekBadIndefiniteChunk,
        "chunk lengths sum to " & $total & ", payload is " & $payload.len)
    outp.add(byte(major shl 5) or 31'u8)
    var at = 0
    for n in item.chunks:
      outp.putHead(major, uint64(n))
      for i in 0 ..< n:
        outp.add payload[at + i]
      at += n
    outp.add(0xff'u8)
  else:
    outp.putHead(major, uint64(payload.len))
    for b in payload:
      outp.add b

proc textBytes(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i in 0 ..< s.len:
    result[i] = byte(ord(s[i]))

proc writeItem(outp: var seq[byte]; item: CborItem;
               deterministic: bool; depth: int) =
  if item.isNil:
    cborFail(cekBadDiagnostic, "nil item at depth " & $depth)
  if depth > 256:
    cborFail(cekNestingTooDeep, "depth " & $depth)
  case item.kind
  of ckUInt: outp.putHead(0, item.arg)
  of ckNegInt: outp.putHead(1, item.arg)
  of ckBytes: outp.writeString(item, 2, item.bytes, deterministic)
  of ckText: outp.writeString(item, 3, textBytes(item.text), deterministic)
  of ckArray:
    if item.indefinite and not deterministic:
      outp.add(0x9f'u8)
      for e in item.elems:
        outp.writeItem(e, deterministic, depth + 1)
      outp.add(0xff'u8)
    else:
      outp.putHead(4, uint64(item.elems.len))
      for e in item.elems:
        outp.writeItem(e, deterministic, depth + 1)
  of ckMap:
    var entries = item.entries
    if deterministic:
      var keyed: seq[tuple[k: seq[byte], v: CborPair]] = @[]
      for e in entries:
        var kb: seq[byte] = @[]
        kb.writeItem(e.key, true, depth + 1)
        keyed.add (kb, e)
      keyed.sort(proc(a, b: tuple[k: seq[byte], v: CborPair]): int =
        let n = min(a.k.len, b.k.len)
        for i in 0 ..< n:
          if a.k[i] != b.k[i]:
            return cmp(a.k[i], b.k[i])
        cmp(a.k.len, b.k.len))
      entries = @[]
      for e in keyed:
        entries.add e.v
    if item.indefinite and not deterministic:
      outp.add(0xbf'u8)
      for e in entries:
        outp.writeItem(e.key, deterministic, depth + 1)
        outp.writeItem(e.val, deterministic, depth + 1)
      outp.add(0xff'u8)
    else:
      outp.putHead(5, uint64(entries.len))
      for e in entries:
        outp.writeItem(e.key, deterministic, depth + 1)
        outp.writeItem(e.val, deterministic, depth + 1)
  of ckTag:
    outp.putHead(6, item.tag)
    outp.writeItem(item.content, deterministic, depth + 1)
  of ckSimple: outp.putSimple(item.simple)
  of ckFloat:
    let w = if deterministic: shortestFloatWidth(item.value)
            else: item.width
    outp.putFloat(item.value, w)

proc encodeItem*(item: CborItem): seq[byte] =
  ## Faithful encoding: what the item records, byte for byte.
  result = @[]
  result.writeItem(item, false, 0)

proc encodeDeterministic*(item: CborItem): seq[byte] =
  ## RFC 8949 §4.2.1 core deterministic encoding.
  result = @[]
  result.writeItem(item, true, 0)
