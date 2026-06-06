## Cuckoo filter — Peer-Cache-Scale M1.
##
## Implements the cuckoo-filter data structure from Fan, Andersen,
## Kaminsky, Mitzenmacher (CoNEXT 2014). The filter stores fixed-bit
## fingerprints in a bucketed array; insertion uses partial-key cuckoo
## hashing (each item has two candidate buckets, the second derived from
## the first by XOR-ing the hash of the fingerprint), with random
## eviction up to `maxKicks` times. Delete is supported by removing one
## fingerprint slot, and is exact only as long as the caller never
## inserts the same item twice (the standard cuckoo-filter caveat).
##
## Hashing is BLAKE3-based: we hash the input once, then slice the
## resulting 32-byte digest into a `uint64` bucket index, a `uint64`
## fingerprint-hash, and a `uint16` raw fingerprint. The fingerprint
## must be non-zero (a zero fingerprint is the empty-slot sentinel);
## when the low-bits hash produces a zero, we XOR a constant to push
## it into the non-zero range. This biases the fingerprint distribution
## very slightly toward the chosen constant but does not affect the
## published false-positive bound.
##
## Sizing follows the paper §3.1 default: `numBuckets =
## ceil(capacity / bucketSize / 0.95)` (95% load-factor target) and
## `fingerprintBits = ceil(log2(2 * bucketSize / falsePositiveRate))`.
## For the default bucketSize=4 and FPR=0.01 the formula yields ~7
## bits; we round up to 8 bits which gives a comfortable margin and
## packs cleanly in the on-wire byte array.
##
## Wire format (used by `AdvertiseV2`):
##   uint32 numBuckets       (little-endian)
##   uint8  bucketSize
##   uint8  fingerprintBits
##   uint16 maxKicks         (little-endian)
##   uint32 count            (little-endian)
##   bit-packed body of numBuckets * bucketSize fingerprints,
##     each `fingerprintBits` bits wide, little-endian per byte.
##
## The bit packing is straightforward: fingerprints are concatenated
## bit-by-bit, low-bit-first within each byte. The total body length is
## `ceil(numBuckets * bucketSize * fingerprintBits / 8)` bytes.

import std/[math, random]

import blake3

const
  EmptySlot* = 0'u16
    ## Sentinel for an empty bucket slot. Fingerprints are guaranteed
    ## to be non-zero so the sentinel is unambiguous.

  DefaultBucketSize* = 4'u8
  DefaultFingerprintBits* = 8'u8
  DefaultMaxKicks* = 500'u16
  DefaultFalsePositiveRate* = 0.01

  NonZeroFingerprintNudge = 0x55'u16
    ## XOR constant applied when the raw fingerprint hashes to zero.
    ## Spec §3.2 calls for any non-zero deterministic perturbation; we
    ## use `0x55` (alternating bits) so the perturbed values do not
    ## cluster at low or high ranges of the fingerprint domain.

type
  CuckooFilter* = ref object
    numBuckets*: uint32
    bucketSize*: uint8
    fingerprintBits*: uint8
    maxKicks*: uint16
    buckets*: seq[seq[uint16]]
      ## `numBuckets` rows, each holding `bucketSize` slots. Empty
      ## slots carry `EmptySlot`; occupied slots carry a non-zero
      ## fingerprint masked to `fingerprintBits` bits.
    count*: uint32
    rng: Rand

  CuckooFilterError* = object of CatchableError

# ---------------------------------------------------------------------------
# Construction.
# ---------------------------------------------------------------------------

proc nextPowerOfTwo(x: uint32): uint32 =
  ## Rounds `x` up to the next power of two (or returns `x` if it is
  ## already a power of two and non-zero). Used so the bucket index
  ## modulus reduces to a bit mask and so the XOR-with-fingerprint-hash
  ## step lands in a valid bucket (the partial-key trick requires the
  ## bucket count to be a power of two; see paper §3.1).
  if x <= 1: return 1'u32
  var v = x - 1
  v = v or (v shr 1)
  v = v or (v shr 2)
  v = v or (v shr 4)
  v = v or (v shr 8)
  v = v or (v shr 16)
  v + 1

proc newCuckooFilter*(capacity: uint32;
                     falsePositiveRate: float = DefaultFalsePositiveRate;
                     seed: int64 = 0): CuckooFilter =
  ## Build a filter sized for `capacity` items at the requested FPR.
  ##
  ## - `bucketSize` is fixed at the spec default 4 (paper §3.1 reports
  ##   best load factor at 4 slots per bucket).
  ## - `fingerprintBits = ceil(log2(2 * bucketSize / falsePositiveRate))`,
  ##   rounded up to a byte (we store fingerprints in `uint16`).
  ## - `numBuckets = nextPow2(ceil(capacity / bucketSize / 0.95))`. The
  ##   load factor 0.95 follows the paper; rounding up to a power of two
  ##   keeps the XOR-derived alternate index inside the valid range.
  ## - `seed` lets tests pin the per-filter RNG. Production code passes
  ##   the default (0), which makes the runtime fall back to a
  ##   wallclock-seeded RNG.
  if capacity == 0:
    raise newException(CuckooFilterError,
      "cuckoo filter capacity must be > 0")
  if falsePositiveRate <= 0.0 or falsePositiveRate >= 1.0:
    raise newException(CuckooFilterError,
      "cuckoo filter falsePositiveRate must be in (0, 1)")

  let bs = DefaultBucketSize
  # Bits needed per fingerprint: log2(2b / eps).
  let bitsFloat = log2(2.0 * float(bs) / falsePositiveRate)
  var fpBits = uint8(ceil(bitsFloat))
  if fpBits < 4: fpBits = 4
  if fpBits > 16: fpBits = 16

  let rawBuckets = uint32(ceil(float(capacity) / float(bs) / 0.95))
  let nb = nextPowerOfTwo(max(rawBuckets, 1'u32))

  result = CuckooFilter(
    numBuckets: nb,
    bucketSize: bs,
    fingerprintBits: fpBits,
    maxKicks: DefaultMaxKicks,
    buckets: newSeq[seq[uint16]](nb.int),
    count: 0'u32)
  for i in 0 ..< nb.int:
    result.buckets[i] = newSeq[uint16](bs.int)
  if seed != 0:
    result.rng = initRand(seed)
  else:
    result.rng = initRand()

# ---------------------------------------------------------------------------
# Hashing primitives.
# ---------------------------------------------------------------------------

proc readLE64(buf: array[32, byte]; offset: int): uint64 =
  result = 0
  for i in 0 ..< 8:
    result = result or (uint64(buf[offset + i]) shl uint64(i * 8))

proc readLE16(buf: array[32, byte]; offset: int): uint16 =
  result = uint16(buf[offset]) or (uint16(buf[offset + 1]) shl 8)

proc fingerprintMask(cf: CuckooFilter): uint16 =
  if cf.fingerprintBits >= 16: 0xffff'u16
  else: uint16((1'u32 shl uint32(cf.fingerprintBits)) - 1'u32)

proc fingerprintOf(cf: CuckooFilter; digest: array[32, byte]): uint16 =
  ## Derive the fingerprint from the BLAKE3 digest of the item. Uses
  ## bytes [16, 18) as the source; masks to `fingerprintBits`; if the
  ## result is zero, XORs with `NonZeroFingerprintNudge` to produce a
  ## guaranteed non-zero value. The nudge constant is intentionally
  ## small and non-zero so the perturbed fingerprint stays within the
  ## domain after masking.
  let mask = cf.fingerprintMask()
  var fp = readLE16(digest, 16) and mask
  if fp == 0:
    fp = (NonZeroFingerprintNudge and mask)
    if fp == 0:
      # Defensive: only triggers if mask happens to be zero (which
      # means fingerprintBits is zero — guarded against in the
      # constructor) — keep the filter sound rather than crashing.
      fp = 1'u16
  fp

proc indexOf(cf: CuckooFilter; rawHash: uint64): uint32 =
  # numBuckets is a power of two, so we can mod with a bit mask.
  uint32(rawHash and uint64(cf.numBuckets - 1'u32))

proc altIndex(cf: CuckooFilter; idx: uint32; fp: uint16): uint32 =
  ## Compute the alternate bucket for fingerprint `fp` relative to `idx`.
  ## Per paper §3.1: `i2 = i1 XOR hash(fp)`. We re-hash the fingerprint
  ## via BLAKE3 so collisions in the alternate-index mapping don't
  ## cluster around small fingerprints (the paper's reference uses a
  ## strong hash here too).
  var fpBytes: array[2, byte]
  fpBytes[0] = byte(fp and 0xff'u16)
  fpBytes[1] = byte((fp shr 8) and 0xff'u16)
  let fpDigest = blake3.digest(fpBytes)
  let fpHash = readLE64(fpDigest, 0)
  uint32((uint64(idx) xor fpHash) and uint64(cf.numBuckets - 1'u32))

proc indexAndFingerprint(cf: CuckooFilter; item: openArray[byte]):
    tuple[i1: uint32; i2: uint32; fp: uint16] =
  let digest = blake3.digest(item)
  let h = readLE64(digest, 0)
  let fp = cf.fingerprintOf(digest)
  let i1 = cf.indexOf(h)
  let i2 = cf.altIndex(i1, fp)
  (i1, i2, fp)

# ---------------------------------------------------------------------------
# Insert / query / delete.
# ---------------------------------------------------------------------------

proc tryInsertAt(cf: CuckooFilter; bucketIdx: uint32; fp: uint16): bool =
  ## If the bucket has an empty slot, place `fp` there and return true.
  for slot in 0 ..< cf.bucketSize.int:
    if cf.buckets[bucketIdx.int][slot] == EmptySlot:
      cf.buckets[bucketIdx.int][slot] = fp
      return true
  false

proc insert*(cf: CuckooFilter; item: openArray[byte]): bool =
  ## Insert `item`. Returns false on `maxKicks` exhaustion — the
  ## caller is expected to allocate a larger filter and re-insert.
  ## On a successful insert, increments `cf.count`.
  let (i1, i2, fpInitial) = cf.indexAndFingerprint(item)
  if cf.tryInsertAt(i1, fpInitial) or cf.tryInsertAt(i2, fpInitial):
    inc cf.count
    return true

  # Both buckets full — random eviction loop.
  var idx = if cf.rng.rand(1) == 0: i1 else: i2
  var fp = fpInitial
  for _ in 0 ..< cf.maxKicks.int:
    let slot = cf.rng.rand(cf.bucketSize.int - 1)
    let evicted = cf.buckets[idx.int][slot]
    cf.buckets[idx.int][slot] = fp
    fp = evicted
    idx = cf.altIndex(idx, fp)
    if cf.tryInsertAt(idx, fp):
      inc cf.count
      return true
  false

proc bucketContains(cf: CuckooFilter; bucketIdx: uint32; fp: uint16): bool =
  for slot in 0 ..< cf.bucketSize.int:
    if cf.buckets[bucketIdx.int][slot] == fp:
      return true
  false

proc query*(cf: CuckooFilter; item: openArray[byte]): bool =
  let (i1, i2, fp) = cf.indexAndFingerprint(item)
  cf.bucketContains(i1, fp) or cf.bucketContains(i2, fp)

proc removeOne(cf: CuckooFilter; bucketIdx: uint32; fp: uint16): bool =
  for slot in 0 ..< cf.bucketSize.int:
    if cf.buckets[bucketIdx.int][slot] == fp:
      cf.buckets[bucketIdx.int][slot] = EmptySlot
      return true
  false

proc delete*(cf: CuckooFilter; item: openArray[byte]): bool =
  ## Delete one occurrence of `item`. Returns false if the fingerprint
  ## was not found in either candidate bucket. Per the paper §4.2,
  ## delete is sound iff each item is inserted at most once; the
  ## peer-cache caller guarantees this via the digest-set semantics.
  let (i1, i2, fp) = cf.indexAndFingerprint(item)
  if cf.removeOne(i1, fp) or cf.removeOne(i2, fp):
    if cf.count > 0: dec cf.count
    return true
  false

proc count*(cf: CuckooFilter): uint32 = cf.count

proc capacity*(cf: CuckooFilter): uint32 =
  ## Effective declared capacity. Reverses the constructor's
  ## load-factor computation so callers can echo back the "this filter
  ## was sized for N blobs" value without storing it separately.
  uint32(float(cf.numBuckets) * float(cf.bucketSize) * 0.95)

# ---------------------------------------------------------------------------
# Serialization.
# ---------------------------------------------------------------------------

proc bodyByteLen(cf: CuckooFilter): int =
  let bits = int(cf.numBuckets) * int(cf.bucketSize) * int(cf.fingerprintBits)
  (bits + 7) div 8

proc writeBits(dst: var seq[byte]; bitOffset: var int; value: uint16; width: int) =
  for b in 0 ..< width:
    let bitIdx = bitOffset + b
    let byteIdx = bitIdx shr 3
    let bitInByte = bitIdx and 7
    if ((value shr uint16(b)) and 1'u16) != 0:
      dst[byteIdx] = dst[byteIdx] or byte(1'u8 shl bitInByte)
  bitOffset += width

proc readBits(src: openArray[byte]; bitOffset: var int; width: int): uint16 =
  result = 0
  for b in 0 ..< width:
    let bitIdx = bitOffset + b
    let byteIdx = bitIdx shr 3
    let bitInByte = bitIdx and 7
    if (src[byteIdx] and byte(1'u8 shl bitInByte)) != 0:
      result = result or (1'u16 shl uint16(b))
  bitOffset += width

proc writeU16LE(dst: var seq[byte]; value: uint16) =
  dst.add(byte(value and 0xff'u16))
  dst.add(byte((value shr 8) and 0xff'u16))

proc writeU32LE(dst: var seq[byte]; value: uint32) =
  for shift in countup(0, 24, 8):
    dst.add(byte((value shr uint32(shift)) and 0xff'u32))

proc readU16LE(src: openArray[byte]; pos: var int): uint16 =
  if pos + 2 > src.len:
    raise newException(CuckooFilterError,
      "cuckoo filter header truncated reading uint16")
  result = uint16(src[pos]) or (uint16(src[pos + 1]) shl 8)
  inc pos, 2

proc readU32LE(src: openArray[byte]; pos: var int): uint32 =
  if pos + 4 > src.len:
    raise newException(CuckooFilterError,
      "cuckoo filter header truncated reading uint32")
  result = 0'u32
  for i in 0 ..< 4:
    result = result or (uint32(src[pos + i]) shl uint32(i * 8))
  inc pos, 4

proc readU8(src: openArray[byte]; pos: var int): uint8 =
  if pos + 1 > src.len:
    raise newException(CuckooFilterError,
      "cuckoo filter header truncated reading uint8")
  result = src[pos]
  inc pos

proc serialize*(cf: CuckooFilter): seq[byte] =
  ## Serialize the filter into the wire format documented above.
  ## Header is 12 bytes; the body is bit-packed at
  ## `fingerprintBits` bits per slot in row-major order
  ## (bucket 0 slots 0..bucketSize-1, then bucket 1, ...).
  let bodyLen = cf.bodyByteLen()
  result = newSeqOfCap[byte](12 + bodyLen)
  result.writeU32LE(cf.numBuckets)
  result.add(cf.bucketSize)
  result.add(cf.fingerprintBits)
  result.writeU16LE(cf.maxKicks)
  result.writeU32LE(cf.count)
  # Pre-extend body and bit-pack into it.
  let headerLen = result.len
  result.setLen(headerLen + bodyLen)
  for i in headerLen ..< result.len:
    result[i] = 0'u8
  var bitOffset = 0
  var body = newSeq[byte](bodyLen)
  for bucket in 0 ..< cf.numBuckets.int:
    for slot in 0 ..< cf.bucketSize.int:
      writeBits(body, bitOffset, cf.buckets[bucket][slot], cf.fingerprintBits.int)
  for i in 0 ..< bodyLen:
    result[headerLen + i] = body[i]

proc deserialize*(bytes: openArray[byte]): CuckooFilter =
  ## Reverse of `serialize`. Raises `CuckooFilterError` on truncated
  ## input or out-of-range header fields. The deserialised filter
  ## carries its own freshly-seeded RNG — the on-wire format does not
  ## include RNG state because future eviction decisions are
  ## independent of past inserts.
  var pos = 0
  let nb = readU32LE(bytes, pos)
  let bs = readU8(bytes, pos)
  let fpBits = readU8(bytes, pos)
  let mk = readU16LE(bytes, pos)
  let cnt = readU32LE(bytes, pos)
  if nb == 0:
    raise newException(CuckooFilterError,
      "cuckoo filter header reports zero buckets")
  if bs == 0 or bs > 16:
    raise newException(CuckooFilterError,
      "cuckoo filter bucketSize out of supported range: " & $bs)
  if fpBits == 0 or fpBits > 16:
    raise newException(CuckooFilterError,
      "cuckoo filter fingerprintBits out of supported range: " & $fpBits)
  let cf = CuckooFilter(
    numBuckets: nb,
    bucketSize: bs,
    fingerprintBits: fpBits,
    maxKicks: mk,
    buckets: newSeq[seq[uint16]](nb.int),
    count: cnt,
    rng: initRand())
  for i in 0 ..< nb.int:
    cf.buckets[i] = newSeq[uint16](bs.int)
  let bodyLen = cf.bodyByteLen()
  if bytes.len - pos < bodyLen:
    raise newException(CuckooFilterError,
      "cuckoo filter body truncated: need " & $bodyLen &
      " bytes, have " & $(bytes.len - pos))
  # Copy body slice so the bit reader sees a self-contained openArray.
  var body = newSeq[byte](bodyLen)
  for i in 0 ..< bodyLen:
    body[i] = bytes[pos + i]
  inc pos, bodyLen
  var bitOffset = 0
  for bucket in 0 ..< cf.numBuckets.int:
    for slot in 0 ..< cf.bucketSize.int:
      cf.buckets[bucket][slot] = readBits(body, bitOffset, cf.fingerprintBits.int)
  cf
