import std/strutils

proc toHex*(bytes: openArray[byte]): string =
  result = newStringOfCap(bytes.len * 2)
  for b in bytes:
    result.add(toHex(int(b), 2).toLowerAscii())

proc toHex*(value: uint64): string =
  toHex(value, 16).toLowerAscii()
