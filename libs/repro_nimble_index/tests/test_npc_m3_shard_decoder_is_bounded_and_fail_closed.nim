## NPC-M3 verification ``test_npc_m3_shard_decoder_is_bounded_and_fail_closed``
## (threat model G3, second half). A hash-valid shard or root -- one the
## publisher itself could have produced, so the hash check does not help --
## that is truncated, non-canonical, of an unknown schema or record kind, or
## declares counts and lengths beyond the format's bounds is refused before
## allocation; a mutation sweep over a valid shard yields only refusals or a
## value whose canonical encoding is exactly the mutated bytes.
##
## Hostile inputs are written the way an attacker would: by building the
## SSZ wire values directly (``List.init`` does not check a list's bound;
## only the decoder does) and framing them by hand, bypassing the encoder's
## validation.
##
## The oversized case comes first in the file and measures the process's
## peak heap (``getMaxMem``) around the decode: run alone or first, the
## peak before it is the fixture itself, so any allocation in proportion to
## the declared count shows as growth.

import std/[options, sequtils, strutils, unittest]

import repro_domain_types/nimble_index/wire
import repro_nimble_index

import ./index_fixtures

proc refusal(body: proc ()): string =
  try:
    body()
    "no refusal"
  except NimbleIndexError as e:
    $e.reason

proc framed(typeId: uint16; payload: seq[byte]): seq[byte] =
  result = @[byte('R'), byte('B'), byte('S'), byte('Z'), 1, 0,
    byte(typeId and 0xff), byte(typeId shr 8)]
  let n = uint32(payload.len)
  for i in 0 ..< 4: result.add byte((n shr (8 * i)) and 0xff)
  result.add payload

proc putU32(b: var seq[byte]; pos: int; v: uint32) =
  for i in 0 ..< 4: b[pos + i] = byte((v shr (8 * i)) and 0xff)

proc validShard(): seq[byte] =
  ## Every package in bucket 0 (no shard bits), so it is self-contained.
  var s = NimbleShard(shardBits: 0, bucket: 0)
  s.packages = @[package("aaa", @[record("aaa", "0.1.0")]), richPackage()]
  s.aliases = @[PackageAlias(alias: "richer", target: "rich")]
  encodeShard(s)

proc wireOf(bytes: seq[byte]): ShardW =
  SSZ.decode(bytes.toOpenArray(12, bytes.len - 1), ShardW)

proc reframe(w: ShardW): seq[byte] = framed(ShardTypeId, SSZ.encode(w))

suite "NPC-M3: the shard and root decoders are bounded and fail closed":

  test "a hash-valid shard declaring 600000 packages is refused before the list is allocated":
    # 600000 minimal package envelopes: 18 bytes each on the wire (a 4-byte
    # offset and a 14-byte empty envelope), 10.8 MB in all -- inside the
    # 16 MiB shard bound, so only the COUNT bound can refuse it. Decoded,
    # each envelope is a 56-byte object: some 34 MB.
    const n = 600_000
    let elem = SSZ.encode(PackageW())
    const fixedLen = fixedPortionSize(ShardW)
    let listLen = n * (4 + elem.len)
    let payloadLen = fixedLen + listLen
    var bytes = newSeq[byte](12 + payloadLen)
    for i, b in [byte('R'), byte('B'), byte('S'), byte('Z'), 1, 0,
                 byte(ShardTypeId and 0xff), byte(ShardTypeId shr 8)]:
      bytes[i] = b
    putU32(bytes, 8, uint32(payloadLen))
    let p = 12
    bytes[p] = 1 # schema 1 (u16 LE); shardBits 0; bucket 0
    putU32(bytes, p + 7, uint32(fixedLen))
    putU32(bytes, p + 11, uint32(fixedLen + listLen))
    let listAt = p + fixedLen
    for i in 0 ..< n:
      putU32(bytes, listAt + 4 * i, uint32(4 * n + i * elem.len))
      for k, b in elem:
        bytes[listAt + 4 * n + i * elem.len + k] = b
    check bytes.len <= MaxShardBytes
    let before = getMaxMem()
    let reason = refusal(proc () = discard decodeShard(bytes))
    let grown = getMaxMem() - before
    check reason == $nrBound
    # The refusal costs nothing in proportion to the declared count.
    check grown < 4 * 1024 * 1024
    if grown >= 4 * 1024 * 1024:
      echo "peak heap grew by ", grown, " bytes while refusing"

  test "an input longer than the shard bound is refused from its length alone":
    var bytes = newSeq[byte](MaxShardBytes + 1)
    let head = framed(ShardTypeId, @[])
    for i in 0 ..< 8: bytes[i] = head[i]
    putU32(bytes, 8, uint32(bytes.len - 12))
    check refusal(proc () = discard decodeShard(bytes)) == $nrOversize
    var root = newSeq[byte](MaxRootBytes + 1)
    for i in 0 ..< 8: root[i] = framed(RootTypeId, @[])[i]
    check refusal(proc () = discard decodeRoot(root)) == $nrOversize

  test "every truncation of a valid shard and of a valid root is refused":
    let shard = validShard()
    for n in 0 ..< shard.len:
      let cut = shard[0 ..< n]
      check refusal(proc () = discard decodeShard(cut)) != "no refusal"
    let root = syntheticIndex(40).rootBytes
    for n in 0 ..< root.len:
      let cut = root[0 ..< n]
      check refusal(proc () = discard decodeRoot(cut)) != "no refusal"

  test "an unknown schema, record kind or frame version is refused before decoding":
    let shard = validShard()
    # Schema 2 is a shard schema since NPC-M13 (records with a submodules
    # list) and schema 3 since NPC-M14 (Nim-version and OS-family
    # conditions); the first schema no reader of this build knows is the
    # next.
    var s2 = shard
    s2[12] = byte(NimbleShardConditionsSchema + 1)
    check refusal(proc () = discard decodeShard(s2)) == $nrUnknownSchema
    var kind = shard
    kind[6] = 0xff
    check refusal(proc () = discard decodeShard(kind)) == $nrUnknownKind
    var frameVersion = shard
    frameVersion[4] = byte(NimbleIndexFrameVersion + 1)
    check refusal(proc () = discard decodeShard(frameVersion)) ==
      $nrUnknownFrameVersion
    var magic = shard
    magic[0] = byte('X')
    check refusal(proc () = discard decodeShard(magic)) == $nrBadMagic
    # A root is not a shard, and a shard is not a root.
    let root = syntheticIndex(40).rootBytes
    check refusal(proc () = discard decodeShard(root)) == $nrUnknownKind
    check refusal(proc () = discard decodeRoot(shard)) == $nrUnknownKind
    var rootSchema = root
    rootSchema[12] = 7
    check refusal(proc () = discard decodeRoot(rootSchema)) == $nrUnknownSchema
    var length = shard
    length[8] = length[8] xor 1
    check refusal(proc () = discard decodeShard(length)) == $nrLengthMismatch

  test "counts and lengths beyond the format's bounds are refused":
    let base = wireOf(validShard())
    # A name longer than its bound.
    var w = base
    w.packages[0].name = WName.init(newSeqWith(MaxNameBytes + 1, byte('a')))
    check refusal(proc () = discard decodeShard(reframe(w))) == $nrBound
    # One requirement more than a record may hold.
    w = base
    var reqs = newSeq[RequirementW](MaxRequirements + 1)
    w.packages[1].versions[0].requires =
      List[RequirementW, MaxRequirements].init(reqs)
    check refusal(proc () = discard decodeShard(reframe(w))) == $nrBound
    # One version component more than a version may have.
    w = base
    w.packages[0].versions[0].version.components =
      List[uint64, MaxVersionComponents].init(newSeq[uint64](
        MaxVersionComponents + 1))
    check refusal(proc () = discard decodeShard(reframe(w))) == $nrBound
    # A condition with more nodes than the bound.
    w = base
    w.packages[1].versions[0].requires[1].condition = WCondition.init(
      newSeq[ConditionNodeW](MaxConditionNodes + 1))
    check refusal(proc () = discard decodeShard(reframe(w))) == $nrBound
    # More shards than a root may list.
    var rw = SSZ.decode(syntheticIndex(40).rootBytes.toOpenArray(12,
      syntheticIndex(40).rootBytes.len - 1), RootW)
    rw.shards = List[ShardRefW, MaxShards].init(newSeq[ShardRefW](
      MaxShards + 1))
    check refusal(proc () = discard decodeRoot(framed(RootTypeId,
      SSZ.encode(rw)))) in [$nrBound, $nrOversize]

  test "non-canonical and inconsistent shards are refused":
    let base = wireOf(validShard())
    # The genuine bytes decode (positive control).
    check decodeShard(reframe(base)).packages.len == 2
    # Packages out of order.
    var w = base
    var ps = asSeq(w.packages)
    swap(ps[0], ps[1])
    w.packages = List[PackageW, MaxPackagesPerShard].init(ps)
    check refusal(proc () = discard decodeShard(reframe(w))) == $nrUnsorted
    # A duplicated package.
    w = base
    ps = asSeq(w.packages)
    ps[1] = ps[0]
    w.packages = List[PackageW, MaxPackagesPerShard].init(ps)
    check refusal(proc () = discard decodeShard(reframe(w))) == $nrDuplicate
    # An unknown enumeration value and unknown flag bits.
    w = base
    w.packages[1].versions[0].requires[0].versionKind = 9
    check refusal(proc () = discard decodeShard(reframe(w))) ==
      $nrUnknownVocabulary
    w = base
    w.packages[1].versions[0].flags = 1'u32 shl 20
    check refusal(proc () = discard decodeShard(reframe(w))) ==
      $nrUnknownVocabulary
    # Version components that are not what the tag reads as.
    w = base
    w.packages[0].versions[0].version.components =
      List[uint64, MaxVersionComponents].init(@[9'u64, 9, 9])
    check refusal(proc () = discard decodeShard(reframe(w))) ==
      $nrInconsistent
    # Text outside its alphabet.
    w = base
    w.packages[0].name = WName.init(toSeq("a a".items).mapIt(byte(it)))
    check refusal(proc () = discard decodeShard(reframe(w))) == $nrInvalidText
    # A package in a shard it does not hash to.
    w = base
    w.shardBits = 4
    w.bucket = (shardBucket(nameKey("aaa"), 4) + 1) mod 16
    check refusal(proc () = discard decodeShard(reframe(w))) == $nrWrongShard
    # An operator node with a name, which no encoder writes.
    w = base
    w.packages[1].versions[0].layout.conditional[0].condition[0].name =
      WCondName.init(@[byte('x')])
    check refusal(proc () = discard decodeShard(reframe(w))) ==
      $nrNonCanonical
    # Bytes after the last field.
    var trailing = reframe(base)
    trailing.add 0
    putU32(trailing, 8, uint32(trailing.len - 12))
    check refusal(proc () = discard decodeShard(trailing)) != "no refusal"

  test "every single-byte mutation and truncation of a valid shard is a refusal or its own canonical value":
    let shard = validShard()
    let original = decodeShard(shard)
    var refused, accepted = 0
    var wrong: seq[string]
    let before = getMaxMem()
    for pos in 0 ..< shard.len:
      for v in 0 .. 255:
        if byte(v) == shard[pos]: continue
        var m = shard
        m[pos] = byte(v)
        try:
          let decoded = decodeShard(m)
          # Accepted only as a different value whose ONE encoding is
          # exactly these bytes.
          if encodeShard(decoded) != m or decoded == original:
            wrong.add "byte " & $pos & " = " & $v & " decodes to a value " &
              "that does not re-encode to the input"
          inc accepted
        except NimbleIndexError:
          inc refused
        except CatchableError as e:
          wrong.add "byte " & $pos & " = " & $v & ": " & $e.name & ": " & e.msg
    for n in 0 ..< shard.len:
      let cut = shard[0 ..< n]
      try:
        discard decodeShard(cut)
        wrong.add "truncation to " & $n & " bytes decodes"
      except NimbleIndexError:
        inc refused
      except CatchableError as e:
        wrong.add "truncation to " & $n & ": " & $e.name & ": " & e.msg
    let grown = getMaxMem() - before
    echo "shard of ", shard.len, " bytes: ", refused, " refused, ", accepted,
      " accepted as their own canonical value; peak heap growth ", grown
    check wrong.len == 0
    if wrong.len > 0:
      echo wrong[0 ..< min(20, wrong.len)].join("\n")
    check refused > 0
    # Half a million decodes, most of them refusals, in one process: a
    # refusal that leaked what it had built would show here (it did, until
    # the codec stopped raising from inside a half-built value).
    check grown < 4 * 1024 * 1024

  test "every single-byte mutation of a valid root is a refusal or its own canonical value":
    let root = syntheticIndex(40).rootBytes
    let original = decodeRoot(root)
    var wrong: seq[string]
    var refused = 0
    for pos in 0 ..< root.len:
      for v in 0 .. 255:
        if byte(v) == root[pos]: continue
        var m = root
        m[pos] = byte(v)
        try:
          let decoded = decodeRoot(m)
          if encodeRoot(decoded) != m or decoded == original:
            wrong.add "byte " & $pos & " = " & $v
        except NimbleIndexError:
          inc refused
        except CatchableError as e:
          wrong.add "byte " & $pos & " = " & $v & ": " & $e.name & ": " & e.msg
    check wrong.len == 0
    if wrong.len > 0:
      echo wrong[0 ..< min(20, wrong.len)].join("\n")
    check refused > 0

  test "the navigator refuses what the decoder refuses on the path it reads":
    let shard = validShard()
    let nav = navigateShard(viewOf(shard))
    check nav.packageCount == 2
    check nav.findPackage("RICH") == 1
    check nav.decodePackageAt(1) == decodeShard(shard).packages[1]
    var s2 = shard
    s2[12] = byte(NimbleShardConditionsSchema + 1)
    check refusal(proc () = discard navigateShard(viewOf(s2))) ==
      $nrUnknownSchema
    for n in 0 ..< shard.len:
      let cut = shard[0 ..< n]
      check refusal(proc () =
        let nv = navigateShard(viewOf(cut))
        for i in 0 ..< nv.packageCount:
          discard nv.decodePackageAt(i)) != "no refusal"
