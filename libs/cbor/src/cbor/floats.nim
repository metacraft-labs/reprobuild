## IEEE 754 binary16 / binary32 / binary64 conversions, done on bit
## patterns rather than on C conversions.
##
## RFC 8949 Appendix D gives a C decoder for half precision. This module
## is the same arithmetic expressed on the bits, and it is on the bits
## for two reasons the Appendix A corpus makes concrete:
##
##   * 0.0 and -0.0 are different items (0xf90000, 0xf98000) but compare
##     equal under `==`, so nothing that goes through a comparison may
##     be trusted to preserve them; and
##   * the table carries NaN at all three widths, and a widening that
##     went through the platform's float conversions could quiet or
##     re-pattern the payload. Shifting the mantissa keeps 0xf97e00,
##     0xfa7fc00000 and 0xfb7ff8000000000000 the same double.
##
## Narrowing is written as "produce a candidate, then widen it back and
## compare the bits". A narrowing that is not exact is therefore
## impossible to accept by accident: the check is the definition.

const
  DoubleSignShift = 63
  DoubleExpShift = 52
  DoubleExpMask = 0x7ff'u64
  DoubleMantMask = 0xf_ffff_ffff_ffff'u64
  HalfMantShift = 42   ## 52 - 10
  SingleMantShift = 29 ## 52 - 23

proc bitsOf*(v: float64): uint64 = cast[uint64](v)
proc floatOf*(bits: uint64): float64 = cast[float64](bits)

proc halfToDouble*(h: uint16): float64 =
  let sign = uint64(h shr 15) shl DoubleSignShift
  let exp = int((h shr 10) and 0x1f'u16)
  let mant = uint64(h and 0x3ff'u16)
  if exp == 0x1f:
    return floatOf(sign or (DoubleExpMask shl DoubleExpShift) or
      (mant shl HalfMantShift))
  if exp == 0:
    if mant == 0:
      return floatOf(sign)
    # Subnormal binary16: value is mant * 2^-24. Normalise it into the
    # much wider binary64 exponent range, where it is an ordinary
    # number.
    var m = mant
    var e = -14
    while (m and 0x400'u64) == 0:
      m = m shl 1
      dec e
    m = m and 0x3ff'u64
    return floatOf(sign or (uint64(e + 1023) shl DoubleExpShift) or
      (m shl HalfMantShift))
  floatOf(sign or (uint64(exp - 15 + 1023) shl DoubleExpShift) or
    (mant shl HalfMantShift))

proc singleToDouble*(s: uint32): float64 =
  let sign = uint64(s shr 31) shl DoubleSignShift
  let exp = int((s shr 23) and 0xff'u32)
  let mant = uint64(s and 0x7f_ffff'u32)
  if exp == 0xff:
    return floatOf(sign or (DoubleExpMask shl DoubleExpShift) or
      (mant shl SingleMantShift))
  if exp == 0:
    if mant == 0:
      return floatOf(sign)
    var m = mant
    var e = -126
    while (m and 0x80_0000'u64) == 0:
      m = m shl 1
      dec e
    m = m and 0x7f_ffff'u64
    return floatOf(sign or (uint64(e + 1023) shl DoubleExpShift) or
      (m shl SingleMantShift))
  floatOf(sign or (uint64(exp - 127 + 1023) shl DoubleExpShift) or
    (mant shl SingleMantShift))

proc candidateHalf(v: float64): uint16 =
  let bits = bitsOf(v)
  let sign = uint16((bits shr DoubleSignShift) and 1'u64) shl 15
  let exp = int((bits shr DoubleExpShift) and DoubleExpMask)
  let mant = bits and DoubleMantMask
  if exp == 0x7ff:
    return sign or 0x7c00'u16 or uint16(mant shr HalfMantShift)
  if exp == 0 and mant == 0:
    return sign
  let unbiased = exp - 1023
  if unbiased >= -14 and unbiased <= 15:
    return sign or (uint16(unbiased + 15) shl 10) or
      uint16((mant shr HalfMantShift) and 0x3ff'u64)
  if unbiased >= -24 and unbiased < -14:
    # Representable, if at all, only as a binary16 subnormal.
    let withImplicit = (1'u64 shl 52) or mant
    let shiftBy = HalfMantShift + (-14 - unbiased)
    if shiftBy >= 64:
      return sign
    return sign or uint16((withImplicit shr shiftBy) and 0x3ff'u64)
  # Out of binary16 range entirely; the round-trip below will reject it.
  sign or 0x7c00'u16

proc tryNarrowToHalf*(v: float64): tuple[ok: bool, bits: uint16] =
  ## A binary16 that widens back to exactly `v`, or `ok = false`.
  let c = candidateHalf(v)
  if bitsOf(halfToDouble(c)) == bitsOf(v): (true, c) else: (false, 0'u16)

proc tryNarrowToSingle*(v: float64): tuple[ok: bool, bits: uint32] =
  ## A binary32 that widens back to exactly `v`, or `ok = false`.
  let c = cast[uint32](float32(v))
  if bitsOf(singleToDouble(c)) == bitsOf(v): (true, c) else: (false, 0'u32)
