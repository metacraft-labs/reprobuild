## SHA-256 and the source line table, for the `sourceChanged` notification.
##
## GDScript-Hot-Reload-Multi-Version-Sources design §4.3 requires the
## notification to carry `snapshotDigest`, `lineTableDigest` and `lineCount`,
## and §5.5 makes `digest-mismatch` and `line-count-mismatch` NAMED refusals.
## A refusal reason the host cannot actually evaluate is decoration, so the
## digest has to be one the host can recompute.
##
## **Why SHA-256 and not the `blake3-256:` of `byteDigest`.** The host that has
## to verify these bytes is the in-process C agent
## (`libs/repro_hcr_agent/c/repro_hcr_agent.c`) and, in GDH-M5, the Godot fork.
## Neither links `repro_hash`; both already carry `repro_hcr_sha256.h`, a
## SHA-256 with a FIPS self-test that `repro_hcr_notify_code_patch` refuses to
## record without. Sending a digest in an algorithm the host cannot compute
## would leave it two choices, and both are defects: refuse every notification,
## or accept the bytes unverified while a `snapshotDigest` field in the
## transcript makes it look verified. So the wire carries an ALGORITHM-TAGGED
## digest (`"<alg>:<hex>"`, the shape `byteDigest` already uses) and both ends
## speak `sha256`. A host that meets a tag it does not implement must refuse by
## name (`digest-algorithm-unsupported`), never wave it through.
##
## `byteDigest` is untouched and still governs patch payloads.

import std/strutils

const
  HcrSourceDigestAlgorithm* = "sha256"
    ## The algorithm tag both ends of the `sourceChanged` wire implement.

type
  Sha256State = object
    h: array[8, uint32]
    buffer: array[64, byte]
    bufferLen: int
    totalBits: uint64

const Sha256K: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc rotr(value: uint32; bits: int): uint32 {.inline.} =
  (value shr uint32(bits)) or (value shl uint32(32 - bits))

proc initSha256(): Sha256State =
  result.h = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
              0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]

proc compress(state: var Sha256State; block64: openArray[byte]) =
  var w: array[64, uint32]
  for i in 0 ..< 16:
    w[i] = (uint32(block64[i * 4]) shl 24) or
           (uint32(block64[i * 4 + 1]) shl 16) or
           (uint32(block64[i * 4 + 2]) shl 8) or
           uint32(block64[i * 4 + 3])
  for i in 16 ..< 64:
    let s0 = rotr(w[i - 15], 7) xor rotr(w[i - 15], 18) xor (w[i - 15] shr 3'u32)
    let s1 = rotr(w[i - 2], 17) xor rotr(w[i - 2], 19) xor (w[i - 2] shr 10'u32)
    w[i] = w[i - 16] + s0 + w[i - 7] + s1

  var a = state.h[0]
  var b = state.h[1]
  var c = state.h[2]
  var d = state.h[3]
  var e = state.h[4]
  var f = state.h[5]
  var g = state.h[6]
  var h = state.h[7]

  for i in 0 ..< 64:
    let s1 = rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)
    let ch = (e and f) xor ((not e) and g)
    let temp1 = h + s1 + ch + Sha256K[i] + w[i]
    let s0 = rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)
    let maj = (a and b) xor (a and c) xor (b and c)
    let temp2 = s0 + maj
    h = g
    g = f
    f = e
    e = d + temp1
    d = c
    c = b
    b = a
    a = temp1 + temp2

  state.h[0] = state.h[0] + a
  state.h[1] = state.h[1] + b
  state.h[2] = state.h[2] + c
  state.h[3] = state.h[3] + d
  state.h[4] = state.h[4] + e
  state.h[5] = state.h[5] + f
  state.h[6] = state.h[6] + g
  state.h[7] = state.h[7] + h

proc update(state: var Sha256State; data: openArray[byte]) =
  state.totalBits += uint64(data.len) * 8'u64
  var index = 0
  while index < data.len:
    let take = min(64 - state.bufferLen, data.len - index)
    for i in 0 ..< take:
      state.buffer[state.bufferLen + i] = data[index + i]
    state.bufferLen += take
    index += take
    if state.bufferLen == 64:
      state.compress(state.buffer)
      state.bufferLen = 0

proc finish(state: var Sha256State): array[32, byte] =
  var tail: array[72, byte]
  var tailLen = 0
  tail[tailLen] = 0x80'u8
  tailLen.inc
  while ((state.bufferLen + tailLen) mod 64) != 56:
    tail[tailLen] = 0'u8
    tailLen.inc
  let bits = state.totalBits
  for i in countdown(7, 0):
    tail[tailLen] = byte((bits shr uint64(i * 8)) and 0xff'u64)
    tailLen.inc
  # `update` must not re-count these bits, so the length is restored after.
  let recorded = state.totalBits
  state.update(tail.toOpenArray(0, tailLen - 1))
  state.totalBits = recorded
  for i in 0 ..< 8:
    result[i * 4] = byte((state.h[i] shr 24) and 0xff'u32)
    result[i * 4 + 1] = byte((state.h[i] shr 16) and 0xff'u32)
    result[i * 4 + 2] = byte((state.h[i] shr 8) and 0xff'u32)
    result[i * 4 + 3] = byte(state.h[i] and 0xff'u32)

proc sha256Bytes*(data: openArray[byte]): array[32, byte] =
  var state = initSha256()
  state.update(data)
  state.finish()

proc sha256Hex*(data: openArray[byte]): string =
  const digits = "0123456789abcdef"
  let digest = sha256Bytes(data)
  result = newStringOfCap(64)
  for value in digest:
    result.add digits[int(value shr 4)]
    result.add digits[int(value and 0x0f'u8)]

proc sha256Hex*(text: string): string =
  var data = newSeq[byte](text.len)
  for i, ch in text:
    data[i] = byte(ord(ch))
  sha256Hex(data)

proc taggedDigest*(hex: string): string =
  HcrSourceDigestAlgorithm & ":" & hex

proc digestAlgorithmOf*(digest: string): string =
  ## The algorithm tag of an `"<alg>:<hex>"` digest, or `""` when it carries
  ## none. An untagged digest is NOT assumed to be this algorithm — a host that
  ## guesses is a host that reports a verification it did not perform.
  let colon = digest.find(':')
  if colon <= 0: "" else: digest[0 ..< colon]

proc sourceSnapshotDigest*(content: openArray[byte]): string =
  ## §4.3's `snapshotDigest`: the digest of the file's bytes.
  taggedDigest(sha256Hex(content))

proc sourceLineStartOffsets*(content: openArray[byte]): seq[uint32] =
  ## The line-start offsets `lineTableDigest` is taken over.
  ##
  ## Offset 0 begins line 1; every byte after a `\n` that is not past the end
  ## begins the next line. A trailing `\n` therefore does NOT open a further
  ## line, which is the same convention `sourceLineCount` uses — the two must
  ## agree or a file could pass the line-count check and fail the table check
  ## for no reason a reader could act on.
  if content.len == 0:
    return @[]
  result.add 0'u32
  for i in 0 ..< content.len:
    if content[i] == byte('\n') and i + 1 < content.len:
      result.add uint32(i + 1)

proc sourceLineCount*(content: openArray[byte]): uint32 =
  ## §4.3's `lineCount`, mandatory because `registerPath` under bit 14 refuses
  ## a path with no count.
  uint32(sourceLineStartOffsets(content).len)

proc sourceLineTableDigest*(content: openArray[byte]): string =
  ## §4.3's `lineTableDigest`. It is "not decorative": it detects a content
  ## change that does not change the line count, which is the case a
  ## path-index-only scheme would look right and be wrong on.
  ##
  ## Serialized as the decimal offsets separated by `,` so the C host can
  ## reproduce it without an integer-encoding convention to get wrong.
  let offsets = sourceLineStartOffsets(content)
  var text = ""
  for index, offset in offsets:
    if index > 0:
      text.add ","
    text.add $offset
  taggedDigest(sha256Hex(text))

proc bytesOfString*(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))
