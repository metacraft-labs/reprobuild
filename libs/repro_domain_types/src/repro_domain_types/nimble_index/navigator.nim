## Navigator-style partial access to Nimble index objects
## (Repository-And-Index-Format § Encoding Policy): a thin facade over the
## SSZ library's type-derived field-boundary helpers
## (``getFieldBoundingOffsets``, ``fixedPortionSize``), so a reader holding
## an object in memory -- typically a memory-mapped file -- can find one
## package in a shard, or one shard reference in a root, touching only the
## offsets on the path and the bytes of what it decodes.
##
## Every offset read is checked against the region it lies in before it is
## used, and every count against its bound, so a navigator over hostile
## bytes refuses (``NimbleIndexError``) and never reads outside the view or
## allocates in proportion to a declared count. A package the navigator
## decodes gets the same validation and canonical-form check a whole-shard
## decode applies to it (``decodePackageSlice``). What partial access does
## NOT check is everything it does not touch: a navigator never certifies
## that the rest of the object is canonical. The solver path therefore
## decodes whole shards (``decodeShard``); the navigator is for read-mostly
## lookups over published, hash-checked objects.

import ssz_serialization

import ./types
import ./wire
import ./codec

type
  ByteView* = object
    ## A borrowed byte range. The owner of the memory (a ``seq`` or a
    ## ``MemFile``) must outlive every view and navigator made from it.
    data*: ptr UncheckedArray[byte]
    len*: int

  ShardNavigator* = object
    whole: ByteView
    packages: ByteView
    count: int
    shardBits*: uint8
    bucket*: uint32
    schema*: uint16
      ## ``NimbleIndexSchemaVersion``, ``NimbleShardSubmodulesSchema`` or
      ## ``NimbleShardConditionsSchema``: which wire type the packages are
      ## (their fixed parts agree)

  RootNavigator* = object
    whole: ByteView
    shards: ByteView
    count: int
    shardBits*: uint8

proc viewOf*(bytes: openArray[byte]): ByteView =
  ## A view of ``bytes``; the caller keeps them alive.
  if bytes.len == 0:
    ByteView(data: nil, len: 0)
  else:
    ByteView(data: cast[ptr UncheckedArray[byte]](unsafeAddr bytes[0]),
      len: bytes.len)

proc viewOf*(p: pointer; len: int): ByteView =
  ByteView(data: cast[ptr UncheckedArray[byte]](p), len: len)

template bytesOf*(v: ByteView): untyped =
  ## The view as an ``openArray[byte]``.
  (if v.len == 0: toOpenArray(cast[ptr UncheckedArray[byte]](nil), 0, -1)
   else: toOpenArray(v.data, 0, v.len - 1))

proc sub(v: ByteView; a, b: int; what: string): ByteView =
  if a < 0 or b < a or b > v.len:
    refuse(nrMalformed, what & ": region " & $a & ".." & $b &
      " is outside 0.." & $v.len)
  if b == a:
    ByteView(data: nil, len: 0)
  else:
    ByteView(data: cast[ptr UncheckedArray[byte]](addr v.data[a]), len: b - a)

proc u32At(v: ByteView; pos: int; what: string): int =
  if pos < 0 or pos + 4 > v.len:
    refuse(nrTruncated, what & ": offset at " & $pos & " is outside the region")
  var r = 0'u32
  for i in 0 ..< 4:
    r = r or (uint32(v.data[pos + i]) shl (8 * i))
  int(r)

template varField(obj: ByteView; T: typedesc; field: static string;
                  what: string): ByteView =
  ## The region of the variable-size ``field`` of an SSZ object ``T``.
  block:
    const bo = getFieldBoundingOffsets(T, field)
    const fixedLen = fixedPortionSize(T)
    if obj.len < fixedLen:
      refuse(nrTruncated, what & ": shorter than its fixed part")
    let a = u32At(obj, bo.fieldOffset, what)
    let b = (when bo.nextFieldOffset == -1: obj.len
             else: u32At(obj, bo.nextFieldOffset, what))
    if a < fixedLen:
      refuse(nrMalformed, what & ": field " & field & " starts inside the " &
        "fixed part")
    sub(obj, a, b, what & "." & field)

template fixedField(obj: ByteView; T: typedesc; field: static string;
                    what: string): ByteView =
  block:
    const bo = getFieldBoundingOffsets(T, field)
    if obj.len < fixedPortionSize(T):
      refuse(nrTruncated, what & ": shorter than its fixed part")
    sub(obj, bo.fieldOffset, bo.nextFieldOffset, what & "." & field)

proc varListCount(list: ByteView; bound: int; what: string): int =
  ## The element count of a list of variable-size elements, checked against
  ## ``bound`` before anything is read per element.
  if list.len == 0:
    return 0
  let first = u32At(list, 0, what)
  if first == 0 or first mod 4 != 0 or first > list.len:
    refuse(nrMalformed, what & ": first element offset " & $first &
      " is not a valid list header")
  result = first div 4
  if result > bound:
    refuse(nrBound, what & ": " & $result & " elements, bound " & $bound)

proc varListItem(list: ByteView; count, i: int; what: string): ByteView =
  let a = u32At(list, 4 * i, what)
  let b = if i + 1 < count: u32At(list, 4 * (i + 1), what) else: list.len
  if a < 4 * count:
    refuse(nrMalformed, what & "[" & $i & "] starts inside the offset table")
  sub(list, a, b, what & "[" & $i & "]")

proc checkFrameView(v: ByteView; kind: NimbleObjectKind;
                    schema: var uint16): ByteView =
  ## The frame checks of the full decoder, on a view; returns the payload
  ## and sets ``schema``.
  if v.len > maxBytesOf(kind):
    refuse(nrOversize, $kind & " of " & $v.len & " bytes exceeds " &
      $maxBytesOf(kind))
  let got = peekObjectKind(bytesOf(v))
  if got != kind:
    refuse(nrUnknownKind, "expected a " & $kind & ", the frame holds a " & $got)
  if FrameHeaderLen + u32At(v, 8, $kind) != v.len:
    refuse(nrLengthMismatch, "the frame length field disagrees with the input")
  if v.len < FrameHeaderLen + 2:
    refuse(nrTruncated, $kind & " payload has no schema")
  schema = uint16(v.data[FrameHeaderLen]) or
    (uint16(v.data[FrameHeaderLen + 1]) shl 8)
  if not acceptsSchema(kind, schema):
    refuse(nrUnknownSchema, $kind & " schema " & $schema)
  sub(v, FrameHeaderLen, v.len, $kind)

# ---------------------------------------------------------------------------
# Shards
# ---------------------------------------------------------------------------

proc navigateShard*(v: ByteView): ShardNavigator =
  ## Open a shard for partial access. Reads the frame, the fixed part and
  ## the package list's offset header only.
  var schema = 0'u16
  let payload = checkFrameView(v, nokShard, schema)
  result.whole = v
  result.schema = schema
  if schema == NimbleShardConditionsSchema:
    result.shardBits = fixedField(payload, ShardW3, "shardBits", "shard").data[0]
    let b = fixedField(payload, ShardW3, "bucket", "shard")
    result.bucket = uint32(u32At(b, 0, "shard.bucket"))
    result.packages = varField(payload, ShardW3, "packages", "shard")
  elif schema == NimbleShardSubmodulesSchema:
    result.shardBits = fixedField(payload, ShardW2, "shardBits", "shard").data[0]
    let b = fixedField(payload, ShardW2, "bucket", "shard")
    result.bucket = uint32(u32At(b, 0, "shard.bucket"))
    result.packages = varField(payload, ShardW2, "packages", "shard")
  else:
    result.shardBits = fixedField(payload, ShardW, "shardBits", "shard").data[0]
    let b = fixedField(payload, ShardW, "bucket", "shard")
    result.bucket = uint32(u32At(b, 0, "shard.bucket"))
    result.packages = varField(payload, ShardW, "packages", "shard")
  if int(result.shardBits) > MaxShardBits:
    refuse(nrBound, "shard: shardBits " & $result.shardBits)
  result.count = varListCount(result.packages, MaxPackagesPerShard,
    "shard.packages")

proc packageCount*(n: ShardNavigator): int = n.count

proc packageRegion(n: ShardNavigator; i: int): ByteView =
  if i < 0 or i >= n.count:
    raise newException(IndexDefect, "package index " & $i & " of " & $n.count)
  varListItem(n.packages, n.count, i, "shard.packages")

proc packageNameAt*(n: ShardNavigator; i: int): string =
  ## The canonical name of package ``i``, reading only its name field.
  let name =
    if n.schema == NimbleShardConditionsSchema:
      varField(packageRegion(n, i), PackageW3, "name",
        "shard.packages[" & $i & "]")
    elif n.schema == NimbleShardSubmodulesSchema:
      varField(packageRegion(n, i), PackageW2, "name",
        "shard.packages[" & $i & "]")
    else:
      varField(packageRegion(n, i), PackageW, "name",
        "shard.packages[" & $i & "]")
  if name.len > MaxNameBytes:
    refuse(nrBound, "shard.packages[" & $i & "].name is longer than " &
      $MaxNameBytes & " bytes")
  result = newString(name.len)
  for k in 0 ..< name.len:
    result[k] = char(name.data[k])

proc findPackage*(n: ShardNavigator; name: string): int =
  ## The position of the package whose ``nameKey`` is ``nameKey(name)``, by
  ## binary search over the canonical order; -1 when the shard holds none.
  let key = nameKey(name)
  var lo = 0
  var hi = n.count - 1
  while lo <= hi:
    let mid = (lo + hi) div 2
    let c = cmp(nameKey(packageNameAt(n, mid)), key)
    if c == 0:
      return mid
    if c < 0: lo = mid + 1
    else: hi = mid - 1
  -1

proc decodePackageAt*(n: ShardNavigator; i: int): PackageEnvelope =
  ## Decode package ``i`` alone (bounded, validated, canonical).
  let r = packageRegion(n, i)
  decodePackageSlice(bytesOf(r), "shard.packages[" & $i & "]", n.shardBits,
    n.bucket, n.schema)

# ---------------------------------------------------------------------------
# Roots
# ---------------------------------------------------------------------------

proc navigateRoot*(v: ByteView): RootNavigator =
  var schema = 0'u16
  let payload = checkFrameView(v, nokRoot, schema)
  result.whole = v
  result.shardBits = fixedField(payload, RootW, "shardBits", "root").data[0]
  if int(result.shardBits) > MaxShardBits:
    refuse(nrBound, "root: shardBits " & $result.shardBits)
  result.shards = varField(payload, RootW, "shards", "root")
  const elem = fixedPortionSize(ShardRefW)
  if result.shards.len mod elem != 0:
    refuse(nrMalformed, "root.shards is not a whole number of entries")
  result.count = result.shards.len div elem
  if result.count > MaxShards:
    refuse(nrBound, "root.shards: " & $result.count & " entries")

proc shardCount*(n: RootNavigator): int = n.count

proc shardRefAt*(n: RootNavigator; i: int): ShardRef =
  const elem = fixedPortionSize(ShardRefW)
  if i < 0 or i >= n.count:
    raise newException(IndexDefect, "shard index " & $i & " of " & $n.count)
  let r = sub(n.shards, i * elem, (i + 1) * elem, "root.shards")
  var w: ShardRefW
  var failure = ""
  try:
    w = SSZ.decode(bytesOf(r), ShardRefW)
  except SerializationError as e:
    failure = e.msg
  if failure.len > 0:
    refuse(nrMalformed, "root.shards[" & $i & "]: " & failure)
  ShardRef(bucket: w.bucket, id: w.id, size: w.size, packages: w.packages)

proc findShard*(n: RootNavigator; bucket: uint32): int =
  ## The position of the shard of ``bucket``, or -1 (no package there).
  var lo = 0
  var hi = n.count - 1
  while lo <= hi:
    let mid = (lo + hi) div 2
    let b = shardRefAt(n, mid).bucket
    if b == bucket:
      return mid
    if b < bucket: lo = mid + 1
    else: hi = mid - 1
  -1

proc shardFor*(n: RootNavigator; name: string): int =
  ## The shard that holds ``name`` if the index has it, or -1.
  findShard(n, shardBucket(nameKey(name), int(n.shardBits)))

