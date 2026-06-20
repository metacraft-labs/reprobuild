{.compile: "xxh3/capi.c".}

# Vendored-hash builds compile the vendored xxhash.c directly. In system-hash
# mode, including on Windows, `xxh3/capi.c` relies on the include/link flags
# configured by config.nims.
when defined(reproVendoredHash):
  const xxh3Root = "xxh3/vendor"
  {.passC: "-DREPRO_VENDORED_HASH".}
  {.compile: xxh3Root & "/xxhash.c".}

import std/strutils

type Xxh3Digest* = distinct uint64

proc reproXxh3_64(input: pointer; inputLen: csize_t): uint64
  {.importc: "repro_xxh3_64".}

proc reproXxh3_64Seeded(input: pointer; inputLen: csize_t; seed: uint64): uint64
  {.importc: "repro_xxh3_64_seeded".}

proc asPointer(bytes: openArray[byte]): pointer =
  if bytes.len == 0: nil
  else: unsafeAddr bytes[0]

proc digest64*(bytes: openArray[byte]): Xxh3Digest =
  Xxh3Digest(reproXxh3_64(asPointer(bytes), csize_t(bytes.len)))

proc digest64*(text: string): Xxh3Digest =
  var bytes = newSeq[byte](text.len)
  for i, ch in text:
    bytes[i] = byte(ord(ch))
  digest64(bytes)

proc digest64WithSeed*(bytes: openArray[byte]; seed: uint64): Xxh3Digest =
  Xxh3Digest(reproXxh3_64Seeded(asPointer(bytes), csize_t(bytes.len), seed))

proc value*(digest: Xxh3Digest): uint64 =
  uint64(digest)

proc toHex*(digest: Xxh3Digest): string =
  toHex(uint64(digest), 16).toLowerAscii()
