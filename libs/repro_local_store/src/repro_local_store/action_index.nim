## Tier 2 of the action-cache store: a host-wide shared-memory index of
## REFERENCES into the Tier-1 per-edge disk store
## (`reprobuild-specs/Action-Cache-Per-Edge-Store.md` §6).
##
## The structure is a grow-only set (`nim-shm-gset`): a state-based convergent
## CRDT whose merge is set union, file-backed by `mmap(MAP_SHARED)` and
## inserted into DIRECTLY by every engine on the host. There is no submission
## ring, no daemon, no ownership election and no backpressure policy, because a
## grow-only set has no full state: insert is an idempotent slot-claim, the
## structure is bounded by DISTINCT ELEMENTS rather than by events, and a full
## shard grows the chain instead of refusing a producer (§6.1).
##
## THIS IS A SECOND, INDEPENDENT USE OF `nim-shm-gset`. That library is already
## deployed as io-mon's Linux dependency-capture channel, where monitored I/O
## events are deduplicated at source. Reprobuild does not import it for that —
## those events reach the engine through io-mon. What this module reuses is the
## DATA STRUCTURE, under a different key discipline: keyed on fingerprints
## rather than on observed paths.
##
## WHAT THE INDEX HOLDS, AND WHAT IT DELIBERATELY DOES NOT. An element is 84
## bytes: `(kind, flags, weakAlgorithm, weakDomain, strongAlgorithm,
## strongDomain, generation, weakFingerprint, strongFingerprint)`. It is
## SELF-RESOLVING — it asserts that
## `hot-records/perEdgeDirName(weak)/toHex(strong).rec` exists, and that path is
## a pure function of the element's own fields. The index carries keys and how
## to reach the data; it never carries the record. Record bytes stay on disk
## (§12.C: a resident mirror of the store would be 102 MB for a measured
## developer cache and ~35 GB for a busy shared root, against ~85 KB and ~27 MB
## for references over the same key sets).
##
## TIER 1 STAYS AUTHORITATIVE. Everything here can turn a miss into a hit and
## can force a fallback to the disk union read; nothing here can mask a record
## that is on disk. An engine that cannot attach the chain, is told not to
## (`REPRO_ACTION_CACHE_SHM=0`), or runs on Windows reaches the IDENTICAL
## decision from Tier 1 alone (§8 step 5, §10).

import std/[algorithm, os, strutils, tables, times]
import repro_hash
import shm_gset

export shm_gset.InsertStatus, shm_gset.AttachFailure, shm_gset.shmGSetSupported

const actionIndexSupported* = shmGSetSupported
  ## Linux and macOS, via `mmap(MAP_SHARED)` and C11 atomics (§6.8). On any
  ## other platform no chain is created and the cache runs Tier-1 only, which
  ## is correct.

# --- §6.2 element layout ----------------------------------------------------
#
#   off  size  field                notes
#     0     4  magic "RBIE"         Reprobuild Index Element
#     4     1  kind                 0 = record, 1 = edge-complete
#     5     1  flags                bit 0 = tombstone
#     6     1  weakAlgorithm        HashAlgorithm ordinal
#     7     1  weakDomain           HashDomain ordinal
#     8     1  strongAlgorithm      0 when kind = 1
#     9     1  strongDomain         0 when kind = 1
#    10     2  reserved             must be 0
#    12     8  generation u64le     §6.5
#    20    32  weakFingerprint
#    52    32  strongFingerprint    present only when kind = 0
#         ---
#          84  bytes (kind = 0) / 52 bytes (kind = 1)
#
# The fingerprint ALGORITHM and DOMAIN bytes are carried even though the weak
# fingerprint alone is the lookup key, because `perEdgeDirName` embeds them and
# a resolver must be able to build the Tier-1 path from the element alone.

const
  AcMagic = ['R'.byte, 'B'.byte, 'I'.byte, 'E'.byte]
  AcOffKind = 4
  AcOffFlags = 5
  AcOffWeakAlgo = 6
  AcOffWeakDomain = 7
  AcOffStrongAlgo = 8
  AcOffStrongDomain = 9
  AcOffGeneration = 12
  AcOffWeakFp* = 20
  AcOffStrongFp = 52
  AcRecordSize* = 84
  AcEdgeCompleteSize* = 52
  AcFlagTombstone = 0x01'u8

const
  AcGenWord* = 0
    ## §6.5: THE global generation counter. One `u64` in shard0's control
    ## block, so "newer" is a total order over the whole chain — which is what
    ## lets a tombstone in any shard retire a record in any other shard by a
    ## plain `u64` compare, with no cross-shard coordination.
  AcBypassWord* = 1
    ## §6.8: `bypassWrites`. An engine that declines the index still writes
    ## Tier 1, so it bumps this once before its first write; a nonzero value
    ## voids every completeness claim in the chain until the next flatten.
  AcUnresolvedWord* = 2
    ## §11: `unresolvedReferences`. A live key that did not resolve to a
    ## `.rec`, forcing the union fallback. It exists because a silently
    ## bypassed accelerator is indistinguishable from a healthy idle one.
  AcControlWords = 3

type
  AcKind* = enum
    akRecord = 0
    akEdgeComplete = 1

  AcIndexKey* = object
    ## The action-cache key discipline (§6.3): key ≠ element. The primary hash
    ## is computed over the WEAK fingerprint alone, for every element kind, so
    ## all elements of one edge share a home slot and, under linear probing,
    ## occupy ONE contiguous run. Enumerating an edge is the walk from
    ## `h(weak)` to the first empty slot. There is no stored chain, no
    ## chain-length counter and no pointer update: the probe run IS the
    ## enumeration, and because nothing is ever deleted a run is never
    ## punctured, so the walk can neither terminate early nor miss a present
    ## element.

proc primaryKeySpan*(_: typedesc[AcIndexKey];
    blob: openArray[byte]): tuple[a, b: int] {.inline.} =
  (AcOffWeakFp, AcOffWeakFp + 31)

proc keyFormatVersion*(_: typedesc[AcIndexKey]): uint32 {.inline.} =
  ## "AC01". A chain written under this discipline must never be attached
  ## under another one: the header check rejects the mismatch rather than
  ## reading foreign bytes through the wrong key projection.
  0x41433031'u32

proc extraControlWords*(_: typedesc[AcIndexKey]): int {.inline.} = AcControlWords

# `hashKey`, `identityFp` and `identityEq` keep the library defaults on
# purpose. `identityEq` in particular stays BYTE EQUALITY over the whole
# element, so an element differing only in its generation or its tombstone flag
# is a DIFFERENT element — required, because a tombstone must not dedup against
# the record it retires, and two generations of one key must coexist until a
# flatten folds them.

type
  AcElement* = object
    ## One decoded element. `strong` is meaningless when `kind` is
    ## `akEdgeComplete` and is left zeroed by the encoder.
    kind*: AcKind
    tombstone*: bool
    generation*: uint64
    weak*: ContentDigest
    strong*: ContentDigest

  EdgeView* = object
    ## The result of enumerating one edge's probe run (§8 step 1). Produced
    ## from mapped memory alone: no syscall, no filesystem access.
    attached*: bool          ## the chain was attached and walked
    complete*: bool          ## a live `edge-complete` element exists AND the
                             ## claim is sound (§8 step 2)
    liveStrong*: seq[ContentDigest]   ## live `record` keys for this edge
    foreign*: int            ## run members belonging to another weak key
    visited*: int            ## slots walked (the run length)

  ActionIndex* = ref object
    ## An attached view of one cache root's chain. A `ref` so an `ActionCache`
    ## VALUE can be copied without duplicating the mapping or double-detaching.
    attached*: bool
    dir*: string
    anchor*: string
    failure*: AttachFailure
    when actionIndexSupported:
      gset: ShmGSetT[AcIndexKey]

const
  ActionIndexDirName* = "action-index"
  ActionIndexAnchorName* = "index.shard0"
    ## §6.1 names the shard files `shard0`, `shard1`, …; the library requires an
    ## anchor whose name ends in `.shard0` (it derives every growth shard's name
    ## by replacing that suffix), so the chain is `index.shard0`,
    ## `index.shard1`, … under the same directory. The stem is the only
    ## deviation and it is not observable through any interface.
  ActionIndexAppId = "reproac"
  ActionIndexRunId = "action-cache-index"
  Shard0Slots* = 4096
    ## §13 leaves shard0's geometry to the owner and notes that the slot array
    ## binds first: at the measured 2.5 elements and ~231 B of arena per edge,
    ## 1,024 slots cover only ~200 edges at a load factor of 0.5 while the
    ## paired 256 KiB arena would carry ~1,100. These defaults are rebalanced
    ## toward slots so both bind at roughly the same edge count (~800), and
    ## they are runtime parameters read from the shard header, so retuning them
    ## needs no format change and does not make two binaries disagree.
  Shard0ArenaBytes* = 512 * 1024

# --- element codec ----------------------------------------------------------

proc putU64le(dst: var seq[byte]; off: int; v: uint64) =
  for i in 0 ..< 8: dst[off + i] = byte((v shr (8 * i)) and 0xFF'u64)

proc getU64le(src: openArray[byte]; off: int): uint64 =
  for i in 0 ..< 8: result = result or (uint64(src[off + i]) shl (8 * i))

proc encodeElement*(kind: AcKind; weak, strong: ContentDigest;
                    generation: uint64; tombstone = false): seq[byte] =
  ## Encode one §6.2 element. The bytes are a PURE FUNCTION of
  ## `(kind, weak, strong, generation, tombstone)`, which is what makes a
  ## tombstone derivable from the identity of the element it retires without
  ## anyone having to read that element first.
  result = newSeq[byte](
    if kind == akRecord: AcRecordSize else: AcEdgeCompleteSize)
  for i in 0 .. 3: result[i] = AcMagic[i]
  result[AcOffKind] = byte(ord(kind))
  result[AcOffFlags] = (if tombstone: AcFlagTombstone else: 0'u8)
  result[AcOffWeakAlgo] = byte(ord(weak.algorithm))
  result[AcOffWeakDomain] = byte(ord(weak.domain))
  if kind == akRecord:
    result[AcOffStrongAlgo] = byte(ord(strong.algorithm))
    result[AcOffStrongDomain] = byte(ord(strong.domain))
  putU64le(result, AcOffGeneration, generation)
  for i in 0 ..< 32: result[AcOffWeakFp + i] = weak.bytes[i]
  if kind == akRecord:
    for i in 0 ..< 32: result[AcOffStrongFp + i] = strong.bytes[i]

proc validAlgorithm(b: byte): bool = int(b) <= ord(high(HashAlgorithm))
proc validDomain(b: byte): bool = int(b) <= ord(high(HashDomain))

proc decodeElement*(e: openArray[byte]; out0: var AcElement): bool =
  ## Decode, rejecting anything this binary cannot interpret. A malformed or
  ## foreign element is treated as absent rather than as an error: the index is
  ## an accelerator, and Tier 1 answers the question either way.
  if e.len notin {AcRecordSize, AcEdgeCompleteSize}: return false
  for i in 0 .. 3:
    if e[i] != AcMagic[i]: return false
  if e[AcOffKind] > byte(ord(akEdgeComplete)): return false
  let kind = AcKind(e[AcOffKind])
  if kind == akRecord and e.len != AcRecordSize: return false
  if kind == akEdgeComplete and e.len != AcEdgeCompleteSize: return false
  if e[10] != 0'u8 or e[11] != 0'u8: return false
  if not validAlgorithm(e[AcOffWeakAlgo]) or not validDomain(e[AcOffWeakDomain]):
    return false
  out0 = AcElement(kind: kind,
    tombstone: (e[AcOffFlags] and AcFlagTombstone) != 0'u8,
    generation: getU64le(e, AcOffGeneration))
  out0.weak.algorithm = HashAlgorithm(e[AcOffWeakAlgo])
  out0.weak.domain = HashDomain(e[AcOffWeakDomain])
  for i in 0 ..< 32: out0.weak.bytes[i] = e[AcOffWeakFp + i]
  if kind == akRecord:
    if not validAlgorithm(e[AcOffStrongAlgo]) or
        not validDomain(e[AcOffStrongDomain]):
      return false
    out0.strong.algorithm = HashAlgorithm(e[AcOffStrongAlgo])
    out0.strong.domain = HashDomain(e[AcOffStrongDomain])
    for i in 0 ..< 32: out0.strong.bytes[i] = e[AcOffStrongFp + i]
  true

proc digestKeyOf(d: ContentDigest): string =
  result = newStringOfCap(34)
  result.add char(ord(d.algorithm))
  result.add char(ord(d.domain))
  for b in d.bytes: result.add char(b)

proc identityOf(e: AcElement): string =
  ## The KEY identity `(kind, weak, strong)` of §6.4. It deliberately EXCLUDES
  ## the generation and the tombstone flag, because a tombstone retires the key
  ## its identity names.
  result = newStringOfCap(70)
  result.add char(ord(e.kind))
  result.add digestKeyOf(e.weak)
  if e.kind == akRecord: result.add digestKeyOf(e.strong)

proc perEdgeDirNameFor*(weak: ContentDigest): string =
  ## The Tier-1 per-edge directory name an element denotes. Kept here, in the
  ## element layer, because §6.2's self-resolution claim is exactly that this
  ## is derivable from the element alone.
  $ord(weak.algorithm) & "-" & $ord(weak.domain) & "-" &
    toHex(weak.bytes) & ".rbar"

proc recFileNameFor*(strong: ContentDigest): string =
  toHex(strong.bytes) & ".rec"

proc resolvePath*(hotRoot: string; weak, strong: ContentDigest): string =
  ## `hot-records/perEdgeDirName(weak)/toHex(strong).rec` — a pure function of
  ## the element's own fields (§6.2).
  hotRoot / perEdgeDirNameFor(weak) / recFileNameFor(strong)

when actionIndexSupported:
  import std/posix

  proc link(oldp, newp: cstring): cint {.importc, header: "<unistd.h>".}

  # --- create-or-attach (§6.1) ---------------------------------------------

  proc removeChainFiles(dir: string) =
    try:
      for kind, path in walkDir(dir):
        if kind == pcFile and path.extractFilename.startsWith("index.shard"):
          try: removeFile(path)
          except CatchableError: discard
    except CatchableError: discard

  proc tryCreateChain(dir, anchor: string): bool =
    ## Create shard0 and publish it at the well-known anchor under an exclusive
    ## `link`, so concurrent creators converge on ONE chain: the winner's file
    ## becomes the anchor and every loser discards its own and attaches to the
    ## winner's. Nothing is ever recreated over a live chain.
    let staging = dir / ("staging." & $getCurrentProcessId() & "." &
      $epochTime().int64)
    var made = createSetT(staging, ActionIndexAppId, ActionIndexRunId,
      AcIndexKey, Shard0Slots, Shard0ArenaBytes)
    if not made.available:
      try: removeDir(staging)
      except CatchableError: discard
      return false
    let created = made.path0
    made.detach()
    result = link(created.cstring, anchor.cstring) == 0
    if not result:
      result = fileExists(anchor)   # a racer published first: that is a win too
    try: removeDir(staging)
    except CatchableError: discard

  proc openActionIndex*(cacheRoot: string): ActionIndex =
    ## Attach the chain for `cacheRoot`, creating it if absent. Best-effort in
    ## every direction: a failure leaves `attached = false` and the caller runs
    ## Tier 1 only, which is correct.
    ##
    ## A chain whose creator boot id does not match the current boot is STALE
    ## (§6.1). It is removed and recreated empty rather than read, because
    ## Tier 1 is authoritative and a cold index costs only a warm-up.
    let dir = cacheRoot / ActionIndexDirName
    let anchor = dir / ActionIndexAnchorName
    result = ActionIndex(attached: false, dir: dir, anchor: anchor,
      failure: afMissing)
    try:
      createDir(dir)
    except CatchableError:
      return
    for attempt in 0 .. 1:
      if not fileExists(anchor):
        if not tryCreateChain(dir, anchor):
          return
      var s = attachSetT(anchor, AcIndexKey)
      if s.available:
        result.gset = s
        result.attached = true
        result.failure = afNone
        return
      result.failure = s.attachFailure()
      s.detach()
      if attempt == 1: return
      # A stale (`afWrongBoot`), skewed or unreadable chain is disposable: the
      # index is a cache of a cache. Drop it and build a fresh one once.
      removeChainFiles(dir)

  proc closeActionIndex*(idx: ActionIndex) =
    if idx == nil or not idx.attached: return
    idx.gset.detach()
    idx.attached = false

  # --- counters -------------------------------------------------------------

  proc growthFailed*(idx: ActionIndex): uint64 =
    if idx == nil or not idx.attached: return 0
    idx.gset.growthFailures()

  proc bypassWrites*(idx: ActionIndex): uint64 =
    if idx == nil or not idx.attached: return 0
    idx.gset.controlWord(AcBypassWord)

  proc unresolvedReferences*(idx: ActionIndex): uint64 =
    if idx == nil or not idx.attached: return 0
    idx.gset.controlWord(AcUnresolvedWord)

  proc noteUnresolvedReference*(idx: ActionIndex) =
    if idx == nil or not idx.attached: return
    discard idx.gset.controlWordFetchAdd(AcUnresolvedWord, 1)

  proc noteBypassWrite*(idx: ActionIndex) =
    ## §6.8. An engine that declined the index still writes Tier 1, so it says
    ## so once; a nonzero `bypassWrites` voids every completeness claim in the
    ## chain until the next flatten. That is what keeps the escape hatch SAFE
    ## rather than merely documented.
    if idx == nil or not idx.attached: return
    discard idx.gset.controlWordFetchAdd(AcBypassWord, 1)

  proc shardCount*(idx: ActionIndex): int =
    if idx == nil or not idx.attached: return 0
    idx.gset.shardCount()

  proc liveElementCount*(idx: ActionIndex): uint64 =
    if idx == nil or not idx.attached: return 0
    idx.gset.claimedSlots()

  # --- enumeration (§6.3, §8 step 1) ---------------------------------------

  type EdgeScan = object
    newestRecord: Table[string, uint64]
    newestTombstone: Table[string, uint64]
    strongOf: Table[string, ContentDigest]
    foreign: int
    visited: int
    walked: bool

  proc isLive(scan: EdgeScan; id: string): bool =
    ## > A key is live iff no tombstone for it exists bearing a generation NEWER
    ## > than the newest `record` element for that key. (§6.5)
    ##
    ## "Newer" is STRICT. That is why an eviction allocates a fresh generation
    ## rather than reusing the counter's current value: a tombstone that merely
    ## TIES the generation of the record it retires leaves the key live and the
    ## eviction is silently lost.
    if id notin scan.newestRecord: return false
    if id notin scan.newestTombstone: return true
    scan.newestTombstone[id] <= scan.newestRecord[id]

  proc scanEdge(idx: ActionIndex; weak: ContentDigest): EdgeScan =
    ## Walk the probe run for `weak` across the shard chain, OLDEST SHARD
    ## FIRST. The order is a correctness requirement, not a preference: a
    ## flatten copies a live element into the newer shard BEFORE retiring the
    ## older one, so a reader travelling in the same direction as the migration
    ## can never be overtaken by it. A newest-first reader can be — it passes
    ## the newest shard before the copy lands, then reaches the older shard
    ## after it is retired, and misses an element that was live throughout.
    result.newestRecord = initTable[string, uint64]()
    result.newestTombstone = initTable[string, uint64]()
    result.strongOf = initTable[string, ContentDigest]()
    if idx == nil or not idx.attached: return
    result.walked = true
    var key: array[32, byte] = weak.bytes
    var elem: AcElement
    for view in idx.gset.withPrimaryKey(key):
      inc result.visited
      if not decodeElement(view.bytes, elem) or elem.weak != weak:
        # A different weak fingerprint hashing into this cluster. The filter
        # costs one comparison and the run is unaffected (§6.3).
        inc result.foreign
        continue
      let id = identityOf(elem)
      if elem.tombstone:
        if id notin result.newestTombstone or
            result.newestTombstone[id] < elem.generation:
          result.newestTombstone[id] = elem.generation
      else:
        if id notin result.newestRecord or
            result.newestRecord[id] < elem.generation:
          result.newestRecord[id] = elem.generation
        if elem.kind == akRecord:
          result.strongOf[id] = elem.strong

  proc enumerateEdge*(idx: ActionIndex; weak: ContentDigest): EdgeView =
    ## §8 step 1 + step 2. Touches only mapped memory; performs no syscall.
    ##
    ## The completeness claim is honoured ONLY when it is sound: a nonzero
    ## `growthFailed` means the chain is saturated and may be missing elements,
    ## and a nonzero `bypassWrites` means someone wrote Tier 1 without telling
    ## the index. Either voids every claim chain-wide, degrading every lookup
    ## to the union read — which is correct.
    result.attached = idx != nil and idx.attached
    if not result.attached: return
    let scan = idx.scanEdge(weak)
    result.foreign = scan.foreign
    result.visited = scan.visited
    let completeId = identityOf(AcElement(kind: akEdgeComplete, weak: weak))
    if scan.isLive(completeId) and idx.growthFailed() == 0 and
        idx.bypassWrites() == 0:
      result.complete = true
    for id, gen in scan.newestRecord:
      if id.len == 0 or id[0] != char(ord(akRecord)): continue
      if not scan.isLive(id): continue
      result.liveStrong.add(scan.strongOf[id])
    # A stable order, so two processes enumerating the same edge produce the
    # same candidate list before the `(writeSequence, strongFpHex)` order of
    # §5.3 is recovered from the containers themselves.
    result.liveStrong.sort(proc (a, b: ContentDigest): int =
      cmp(toHex(a.bytes), toHex(b.bytes)))

  # --- insert (§6.4) --------------------------------------------------------

  proc insertElement(idx: ActionIndex; kind: AcKind;
                     weak, strong: ContentDigest): InsertStatus =
    ## §6.4. (1) If a LIVE element with this identity is already present,
    ## return `isExists` and write NOTHING — this is what keeps a re-record of
    ## an unchanged path-set free of any shared-memory mutation. (2) Otherwise
    ## stamp with `max(currentGeneration, supersedingTombstoneGeneration + 1)`,
    ## bumping the global counter if the second term wins, and claim a slot.
    if idx == nil or not idx.attached: return isUnavailable
    let scan = idx.scanEdge(weak)
    let id = identityOf(AcElement(kind: kind, weak: weak, strong: strong))
    if scan.isLive(id): return isExists
    var gen = idx.gset.controlWord(AcGenWord)
    if id in scan.newestTombstone and scan.newestTombstone[id] + 1 > gen:
      # A resurrection: the key was tombstoned and is being written again. It
      # needs a generation strictly newer than that tombstone, and no
      # coordination with whoever tombstoned it.
      gen = scan.newestTombstone[id] + 1
      discard idx.gset.controlWordBumpTo(AcGenWord, gen)
    # The counter's INVARIANT is that every generation ever stamped into an
    # element is <= its current value, which is what makes the strict liveness
    # comparison decidable. An ordinary insert therefore stamps the counter's
    # value and never raises it — including the very first insert, which stamps
    # 0 against a counter that is still 0. Fudging that first stamp up to 1
    # breaks the invariant in the one direction that matters: the first
    # eviction's `fetch-add` would then also produce 1, the tombstone would TIE
    # the record instead of exceeding it, and §6.5's eviction would be silently
    # lost.
    let blob = encodeElement(kind, weak, strong, gen)
    idx.gset.insert(blob)

  proc insertRecord*(idx: ActionIndex;
                     weak, strong: ContentDigest): InsertStatus =
    insertElement(idx, akRecord, weak, strong)

  proc insertEdgeComplete*(idx: ActionIndex; weak: ContentDigest): InsertStatus =
    ## §6.2 / §8.2: inserted only AFTER every `record` element it attests to,
    ## and only if all of those inserts succeeded. The caller enforces that
    ## ordering; this is the publish.
    var zero: ContentDigest
    insertElement(idx, akEdgeComplete, weak, zero)

  # --- eviction by tombstone (§6.5) ----------------------------------------

  proc evictElement(idx: ActionIndex; kind: AcKind;
                    weak, strong: ContentDigest): InsertStatus =
    ## Nothing is ever removed from the set. A key is retired by inserting a
    ## tombstone: an ordinary element whose bytes are a pure function of the
    ## original's identity, carrying a FRESHLY ALLOCATED generation from an
    ## atomic fetch-add on the global counter.
    ##
    ## Fresh rather than merely current, and that distinction is the whole
    ## mechanism. Liveness is decided by a STRICT comparison, so a tombstone
    ## that ties the generation of the record it is meant to retire does not
    ## retire it — the key stays live and the eviction is silently lost.
    ## Allocating a new generation makes the tombstone strictly newer than
    ## every element stamped before it, which is precisely the set of records
    ## this eviction is entitled to retire.
    if idx == nil or not idx.attached: return isUnavailable
    let gen = idx.gset.controlWordFetchAdd(AcGenWord, 1) + 1
    idx.gset.insert(encodeElement(kind, weak, strong, gen, tombstone = true))

  proc evictRecord*(idx: ActionIndex;
                    weak, strong: ContentDigest): InsertStatus =
    evictElement(idx, akRecord, weak, strong)

  proc evictEdgeComplete*(idx: ActionIndex; weak: ContentDigest): InsertStatus =
    ## How a completeness claim is withdrawn. The tombstone rule applies
    ## uniformly to `edge-complete` elements.
    var zero: ContentDigest
    evictElement(idx, akEdgeComplete, weak, zero)

  proc currentGenerationValue*(idx: ActionIndex): uint64 =
    if idx == nil or not idx.attached: return 0
    idx.gset.controlWord(AcGenWord)

  # --- flattening and retirement (§6.7) ------------------------------------

  proc flock(fd: cint; op: cint): cint {.importc, header: "<sys/file.h>".}
  const
    LockEx = cint(2)
    LockNb = cint(4)

  proc flattenChain*(idx: ActionIndex): bool =
    ## Copy each still-live element of every older shard into the newest shard,
    ## then mark the drained shard and unlink it (§6.7).
    ##
    ## This is not a daemon. It is a maintenance pass guarded by a
    ## non-blocking `flock(LOCK_EX|LOCK_NB)` on the anchor, so at most one
    ## flattener runs per root and every other process simply skips it. It
    ## performs no election, holds no long-lived state, and blocks nothing.
    ##
    ## PER-EDGE ORDERING IS NORMATIVE: every `record` and tombstone element is
    ## copied BEFORE that edge's `edge-complete` element, and if any of those
    ## copies fails the `edge-complete` element is not copied. That preserves
    ## §6.2's invariant — a completeness claim exists only in a chain state
    ## where every key it attests to is present.
    ##
    ## COPY-THEN-RETIRE is load-bearing for concurrent readers, not merely
    ## tidy: because an element reaches the newer shard before it leaves the
    ## older one, the ascending reader of §6.3 always sees it in one shard or
    ## the other.
    if idx == nil or not idx.attached: return false
    let n = idx.gset.shardCount()
    if n <= 1: return false
    let fd = posix.open(idx.anchor.cstring, O_RDWR)
    if fd < 0: return false
    defer: discard posix.close(fd)
    if flock(fd, LockEx or LockNb) != 0: return false
    var elem: AcElement
    # shard0 is never retired — it carries the control block — so there is
    # nothing to gain by copying its elements forward into a shard that will
    # itself be walked after it.
    for k in 1 ..< n - 1:
      if idx.gset.shardIsDrained(k): continue
      # Gather first: the copy targets the NEWEST shard, and inserting while
      # iterating a shard's slots would be reading and writing the same
      # structure through two cursors.
      var records: seq[seq[byte]] = @[]
      var completes: seq[seq[byte]] = @[]
      var scans = initTable[string, EdgeScan]()
      for view in idx.gset.shardElements(k):
        if not decodeElement(view.bytes, elem): continue
        let wk = digestKeyOf(elem.weak)
        if wk notin scans: scans[wk] = idx.scanEdge(elem.weak)
        let id = identityOf(elem)
        let scan = scans[wk]
        if elem.tombstone:
          # A tombstone stays live evidence for as long as it is the newest
          # thing said about its key; once a resurrection has superseded it it
          # is redundant, and this is the only place such redundancy is
          # reclaimed. Only the newest tombstone for a key is carried forward.
          if not scan.isLive(id) and
              scan.newestTombstone[id] == elem.generation:
            records.add(view.toBytesSeq())
          continue
        if not scan.isLive(id): continue        # superseded or tombstoned
        if scan.newestRecord[id] != elem.generation: continue  # older copy
        if elem.kind == akEdgeComplete: completes.add(view.toBytesSeq())
        else: records.add(view.toBytesSeq())
      var ok = true
      for blob in records:
        if idx.gset.insert(blob) == isSaturated: ok = false
      if not ok: continue        # do NOT publish a completeness claim we could
                                 # not back with its records
      for blob in completes:
        if idx.gset.insert(blob) == isSaturated: ok = false
      if not ok: continue
      idx.gset.markShardDrained(k)
      idx.gset.retireShard(k)
    # A flatten re-establishes completeness from the elements that survived it,
    # so the escape-hatch counter that voided every claim is cleared with it
    # (§6.8). Subtracting exactly the value observed, rather than storing zero,
    # keeps a concurrent bypassing engine's bump from being lost.
    let bypassed = idx.bypassWrites()
    if bypassed != 0:
      discard idx.gset.controlWordFetchAdd(AcBypassWord, 0'u64 - bypassed)
    true

else:
  proc openActionIndex*(cacheRoot: string): ActionIndex =
    ActionIndex(attached: false, dir: cacheRoot / ActionIndexDirName,
      failure: afMissing)
  proc closeActionIndex*(idx: ActionIndex) = discard
  proc growthFailed*(idx: ActionIndex): uint64 = 0
  proc bypassWrites*(idx: ActionIndex): uint64 = 0
  proc unresolvedReferences*(idx: ActionIndex): uint64 = 0
  proc noteUnresolvedReference*(idx: ActionIndex) = discard
  proc noteBypassWrite*(idx: ActionIndex) = discard
  proc shardCount*(idx: ActionIndex): int = 0
  proc liveElementCount*(idx: ActionIndex): uint64 = 0
  proc enumerateEdge*(idx: ActionIndex; weak: ContentDigest): EdgeView =
    EdgeView(attached: false)
  proc insertRecord*(idx: ActionIndex;
                     weak, strong: ContentDigest): InsertStatus = isUnavailable
  proc insertEdgeComplete*(idx: ActionIndex;
                           weak: ContentDigest): InsertStatus = isUnavailable
  proc evictRecord*(idx: ActionIndex;
                    weak, strong: ContentDigest): InsertStatus = isUnavailable
  proc evictEdgeComplete*(idx: ActionIndex;
                          weak: ContentDigest): InsertStatus = isUnavailable
  proc currentGenerationValue*(idx: ActionIndex): uint64 = 0
  proc flattenChain*(idx: ActionIndex): bool = false
