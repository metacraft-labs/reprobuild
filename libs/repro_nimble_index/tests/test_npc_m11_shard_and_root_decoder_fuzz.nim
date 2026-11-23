## NPC-M11 adversarial audit (threat model T15, G3, G31): a bounded fuzz of
## the client's index decoders.
##
## A compromised mirror or publisher (A4, A5) can hand a client any bytes
## that hash to what a root names, so the decoders are the boundary. The
## decoders this fuzz drives are the ones the client's reader calls
## (`decodeRoot`, `decodeShard`, `decodeNameMap`, `decodeEvents`) and the
## shard navigator (`navigateShard`, `decodePackageAt`). The seeds are valid
## objects of every kind: a shard exercising every record field (conditions,
## features, layout, binaries, foreign dependencies, a label, a pseudo-
## version), a shard with an observation and held versions, a root, its
## name map and an events object.
##
## Each iteration applies one to four mutations to a seed: random byte
## flips, a 32-bit field overwritten with a boundary value (0, 1, 0x7f..,
## 0xff.., the input's length and its neighbours), a range deleted,
## inserted, duplicated or truncated, or a splice from another seed of the
## same kind. Most mutants then have the frame's payload length rewritten
## to match, so they reach the payload decoder instead of stopping at the
## frame check. The oracle, for every mutant: the decoder either refuses it
## with `NimbleIndexError`, or returns a value whose one canonical encoding
## is exactly the mutant's bytes. Any other exception (a range or index
## defect, an overflow, an out-of-memory) is a failure, and so is a heap
## that grows with the iterations. The navigator must also refuse with
## `NimbleIndexError` only, and agree with the decoder on every package
## when both accept.
##
## The default budget runs in seconds. `REPRO_NPC_FUZZ_ITERATIONS` (per
## seed) and `REPRO_NPC_FUZZ_SEED` widen it for a longer campaign; the test
## prints the seed, the iterations and the time it took, so a failure can
## be replayed.

import std/[options, os, sequtils, strutils, tables, times, unittest]

import repro_domain_types/nimble_index
import repro_domain_types/nimble_index/navigator
import repro_nimble_index

import ./index_fixtures

type
  Kind = enum kShard, kRoot, kNameMap, kEvents
  Seed = object
    name: string
    kind: Kind
    bytes: seq[byte]

  Rng = object
    s: uint64

proc next(r: var Rng): uint64 =
  # xorshift64*: deterministic, so a printed seed replays the run.
  r.s = r.s xor (r.s shr 12)
  r.s = r.s xor (r.s shl 25)
  r.s = r.s xor (r.s shr 27)
  r.s * 2685821657736338717'u64

proc below(r: var Rng; n: int): int =
  if n <= 0: 0 else: int(r.next() mod uint64(n))

const FrameHeader = 12

proc setLength(b: var seq[byte]) =
  ## Make the frame's payload length match the bytes after it.
  if b.len < FrameHeader: return
  let n = uint32(b.len - FrameHeader)
  for i in 0 ..< 4: b[8 + i] = byte((n shr (8 * i)) and 0xff)

proc mutate(r: var Rng; input: seq[byte]; donors: seq[seq[byte]]): seq[byte] =
  result = input
  let rounds = 1 + r.below(4)
  for _ in 0 ..< rounds:
    if result.len == 0: result.add byte(r.below(256))
    case r.below(8)
    of 0, 1:
      for _ in 0 ..< 1 + r.below(8):
        result[r.below(result.len)] = byte(r.below(256))
    of 2:
      let interesting = [0'u32, 1, 2, 0x7f, 0x80, 0xff, 0x100, 0xffff,
        0x10000, 0x7fffffff, 0x80000000'u32, 0xffffffff'u32,
        uint32(result.len), uint32(result.len + 1), uint32(max(0, result.len - 1)),
        uint32(r.below(1 shl 20))]
      if result.len >= 4:
        let at = r.below(result.len - 3)
        let v = interesting[r.below(interesting.len)]
        for i in 0 ..< 4: result[at + i] = byte((v shr (8 * i)) and 0xff)
    of 3:
      let at = r.below(result.len)
      let n = min(result.len - at, 1 + r.below(64))
      result.delete(at .. at + n - 1)
    of 4:
      let at = r.below(result.len + 1)
      var ins: seq[byte]
      for _ in 0 ..< 1 + r.below(64): ins.add byte(r.below(256))
      result.insert(ins, at)
    of 5:
      let a = r.below(result.len)
      let n = min(result.len - a, 1 + r.below(128))
      let chunk = result[a ..< a + n]
      result.insert(chunk, r.below(result.len + 1))
    of 6:
      result.setLen(r.below(result.len + 1))
    else:
      if donors.len > 0:
        let d = donors[r.below(donors.len)]
        if d.len > 0:
          let a = r.below(d.len)
          let n = min(d.len - a, 1 + r.below(256))
          let at = r.below(result.len + 1)
          let cut = min(result.len - at, n)
          if cut > 0: result.delete(at ..< at + cut)
          result.insert(d[a ..< a + n], at)
  if r.below(5) != 0:
    result.setLength()

proc check1(kind: Kind; m: seq[byte]): string =
  ## "" when the decoder refused with its own error or returned the
  ## mutant's canonical value; else what went wrong.
  try:
    case kind
    of kShard:
      let v = decodeShard(m)
      if encodeShard(v) != m: return "accepted bytes that are not its encoding"
      # The navigator reads the same bytes lazily; it must agree.
      let nav = navigateShard(viewOf(m))
      if nav.packageCount != v.packages.len:
        return "navigator counts " & $nav.packageCount & " packages, decoder " &
          $v.packages.len
      for i in 0 ..< nav.packageCount:
        if nav.decodePackageAt(i) != v.packages[i]:
          return "navigator and decoder disagree on package " & $i
    of kRoot:
      let v = decodeRoot(m)
      if encodeRoot(v) != m: return "accepted bytes that are not its encoding"
    of kNameMap:
      let v = decodeNameMap(m)
      if encodeNameMap(v) != m: return "accepted bytes that are not its encoding"
    of kEvents:
      let v = decodeEvents(m)
      if encodeEvents(v) != m: return "accepted bytes that are not its encoding"
  except NimbleIndexError:
    discard
  except CatchableError as e:
    return $e.name & ": " & e.msg
  except Defect as e:
    return "DEFECT " & $e.name & ": " & e.msg
  if kind == kShard:
    # A refused shard: the navigator may read less than the decoder, but it
    # may only ever refuse with the decoder's error.
    try:
      let nav = navigateShard(viewOf(m))
      for i in 0 ..< nav.packageCount: discard nav.decodePackageAt(i)
    except NimbleIndexError:
      discard
    except CatchableError as e:
      return "navigator: " & $e.name & ": " & e.msg
    except Defect as e:
      return "navigator: DEFECT " & $e.name & ": " & e.msg
  ""

proc seeds(): seq[Seed] =
  var rich = NimbleShard(shardBits: 0, bucket: 0)
  rich.packages = @[package("aaa", @[record("aaa", "0.1.0")]), richPackage()]
  rich.aliases = @[PackageAlias(alias: "richer", target: "rich")]
  result.add Seed(name: "rich shard", kind: kShard, bytes: encodeShard(rich))
  var observed = NimbleShard(shardBits: 0, bucket: 0)
  observed.packages = @[package("obs", @[record("obs", "v1.0.0"),
    record("obs", "v1.1.0", @[req("aaa", ">= 0.1.0")])])]
  observed.observations = @[PackageObservation(name: "obs",
    origin: PackageOrigin(url: "https://forge.invalid/o/obs.git", vcs: ovGit),
    state: osAnswering, headRef: "main", head: commitOf("head"),
    tags: @[ObservedTag(name: "v1.0.0", commit: commitOf("v1.0.0")),
            ObservedTag(name: "v1.1.0", commit: commitOf("v1.1.0")),
            ObservedTag(name: "v1.2.0", commit: commitOf("v1.2.0"))],
    held: @[HeldVersion(version: record("obs", "v1.2.0").version,
      commit: commitOf("v1.2.0"), firstSeen: 1_790_000_000'u64)])]
  result.add Seed(name: "observed shard", kind: kShard,
    bytes: encodeShard(observed))
  let idx = syntheticIndex(40)
  result.add Seed(name: "root", kind: kRoot, bytes: idx.rootBytes)
  result.add Seed(name: "name map", kind: kNameMap,
    bytes: idx.objectTable()[idx.root.nameMap.id])
  var ev = NimbleEvents()
  ev.events = @[
    OriginEvent(kind: oeGone, package: "alpha", before: "answering",
      after: "no answer", observedAt: 1_790_000_000'u64),
    OriginEvent(kind: oeTagMoved, package: "beta", version: "v1.0.0",
      before: commitOf("b1"), after: commitOf("b2"),
      observedAt: 1_790_000_000'u64),
    OriginEvent(kind: oeRepointed, package: "gamma",
      before: "https://forge.invalid/a/gamma.git",
      after: "https://forge.invalid/b/gamma.git",
      observedAt: 1_790_000_000'u64)]
  result.add Seed(name: "events", kind: kEvents, bytes: encodeEvents(ev))

suite "NPC-M11: the index decoders under a bounded fuzz":
  test "every mutant is refused with the decoder's error or is its own canonical value":
    let perSeed = parseInt(getEnv("REPRO_NPC_FUZZ_ITERATIONS", "40000"))
    let seed = parseBiggestUInt(getEnv("REPRO_NPC_FUZZ_SEED", "20261123"))
    let corpus = seeds()
    # Every seed decodes as itself first (the positive control).
    for s in corpus:
      check check1(s.kind, s.bytes) == ""
    var r = Rng(s: uint64(seed) or 1)
    var failures: seq[string]
    var refused, accepted, total = 0
    let started = epochTime()
    let heapBefore = getMaxMem()
    for s in corpus:
      var donors: seq[seq[byte]]
      for d in corpus:
        if d.kind == s.kind and d.name != s.name: donors.add d.bytes
      donors.add s.bytes
      for i in 0 ..< perSeed:
        let m = r.mutate(s.bytes, donors)
        inc total
        let verdict = check1(s.kind, m)
        if verdict.len > 0:
          if failures.len < 20:
            failures.add s.name & " iteration " & $i & ": " & verdict &
              " (" & $m.len & " bytes)"
        else:
          # Count the outcome for the report.
          var ok = false
          try:
            case s.kind
            of kShard: discard decodeShard(m)
            of kRoot: discard decodeRoot(m)
            of kNameMap: discard decodeNameMap(m)
            of kEvents: discard decodeEvents(m)
            ok = true
          except NimbleIndexError:
            discard
          if ok: inc accepted else: inc refused
    let seconds = epochTime() - started
    let grown = getMaxMem() - heapBefore
    echo "fuzz seed ", seed, ": ", corpus.len, " seeds x ", perSeed,
      " iterations = ", total, " mutants in ", formatFloat(seconds, ffDecimal, 1),
      " s; ", refused, " refused, ", accepted,
      " accepted as their own canonical value; peak heap growth ", grown
    if failures.len > 0:
      echo failures.join("\n")
    check failures.len == 0
    check total == corpus.len * perSeed
    check refused > 0
    check grown < 64 * 1024 * 1024
