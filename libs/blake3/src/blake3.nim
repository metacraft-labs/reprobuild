{.compile: "blake3/capi.c".}

import std/strutils

type Blake3Digest* = array[32, byte]

proc reproBlake3Hash(input: pointer; inputLen: csize_t; output: ptr byte)
  {.importc: "repro_blake3_hash".}

proc reproBlake3Version(): cstring {.importc: "repro_blake3_version".}

proc digest*(bytes: openArray[byte]): Blake3Digest =
  var output: Blake3Digest
  let input =
    if bytes.len == 0: nil
    else: unsafeAddr bytes[0]
  reproBlake3Hash(input, csize_t(bytes.len), addr output[0])
  output

proc digest*(text: string): Blake3Digest =
  var bytes = newSeq[byte](text.len)
  for i, ch in text:
    bytes[i] = byte(ord(ch))
  digest(bytes)

proc version*(): string =
  $reproBlake3Version()

proc toHex*(value: Blake3Digest): string =
  result = newStringOfCap(value.len * 2)
  for b in value:
    result.add(toHex(int(b), 2).toLowerAscii())
