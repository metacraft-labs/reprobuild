{.compile: "blake3/capi.c".}

# Vendored-hash builds compile the portable subset of the BLAKE3 C
# library directly. In system-hash mode, including on Windows,
# `blake3/capi.c` relies on the include/link flags configured by config.nims.
# The portable implementation has no SIMD requirements and works with any C99
# compiler; blake3_dispatch.c hands every chunk to
# blake3_compress_in_place_portable when none of BLAKE3_USE_* macros are
# defined.
when defined(reproVendoredHash):
  const blake3Root = "blake3/vendor"
  {.passC: "-DREPRO_VENDORED_HASH".}
  {.passC: "-DBLAKE3_NO_AVX2 -DBLAKE3_NO_AVX512 -DBLAKE3_NO_SSE2 " &
           "-DBLAKE3_NO_SSE41 -DBLAKE3_USE_NEON=0".}
  {.compile: blake3Root & "/blake3.c".}
  {.compile: blake3Root & "/blake3_dispatch.c".}
  {.compile: blake3Root & "/blake3_portable.c".}

import std/strutils

type Blake3Digest* = array[32, byte]
type Blake3Hasher* = distinct pointer

proc reproBlake3Hash(input: pointer; inputLen: csize_t; output: ptr byte)
  {.importc: "repro_blake3_hash".}

proc reproBlake3Version(): cstring {.importc: "repro_blake3_version".}

proc reproBlake3HasherNew(): pointer {.importc: "repro_blake3_hasher_new".}

proc reproBlake3HasherUpdate(state: pointer; input: pointer; inputLen: csize_t)
  {.importc: "repro_blake3_hasher_update".}

proc reproBlake3HasherFinalize(state: pointer; output: ptr byte)
  {.importc: "repro_blake3_hasher_finalize".}

proc reproBlake3HasherFree(state: pointer) {.importc: "repro_blake3_hasher_free".}

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

proc initHasher*(): Blake3Hasher =
  let state = reproBlake3HasherNew()
  if state.isNil:
    raise newException(OutOfMemDefect, "could not allocate BLAKE3 hasher")
  Blake3Hasher(state)

proc update*(hasher: Blake3Hasher; input: pointer; inputLen: int) =
  reproBlake3HasherUpdate(pointer(hasher), input, csize_t(inputLen))

proc update*(hasher: Blake3Hasher; bytes: openArray[byte]) =
  let input =
    if bytes.len == 0: nil
    else: unsafeAddr bytes[0]
  hasher.update(input, bytes.len)

proc update*(hasher: Blake3Hasher; text: string) =
  let input =
    if text.len == 0: nil
    else: unsafeAddr text[0]
  hasher.update(input, text.len)

proc finalize*(hasher: Blake3Hasher): Blake3Digest =
  reproBlake3HasherFinalize(pointer(hasher), addr result[0])

proc close*(hasher: Blake3Hasher) =
  reproBlake3HasherFree(pointer(hasher))

proc version*(): string =
  $reproBlake3Version()

proc toHex*(value: Blake3Digest): string =
  result = newStringOfCap(value.len * 2)
  for b in value:
    result.add(toHex(int(b), 2).toLowerAscii())
