{.compile: "blake3/capi.c".}

# Windows: there is no system-wide libblake3 to link against. Compile the
# portable subset of the vendored mold/blake3 C library directly. The portable
# implementation has no SIMD requirements and works with any C99 compiler;
# blake3_dispatch.c hands every chunk to blake3_compress_in_place_portable when
# none of BLAKE3_USE_* macros are defined.
when defined(windows):
  # Windows: relative path is anchored at the directory of this .nim file
  # (libs/blake3/src/); back up three levels to reach the repo root, then dive
  # into references/.
  const blake3Root = "../../../references/mold/third-party/blake3/c"
  {.passC: "-DBLAKE3_NO_AVX2 -DBLAKE3_NO_AVX512 -DBLAKE3_NO_SSE2 " &
           "-DBLAKE3_NO_SSE41 -DBLAKE3_USE_NEON=0".}
  {.compile: blake3Root & "/blake3.c".}
  {.compile: blake3Root & "/blake3_dispatch.c".}
  {.compile: blake3Root & "/blake3_portable.c".}

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
