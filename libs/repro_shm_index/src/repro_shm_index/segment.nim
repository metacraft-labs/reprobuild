## Generation segment: a fixed open-addressed slot table with lock-free seqlock
## reads and a single-writer slot-write primitive
## (Action-Cache-Per-Edge-Store.md §4.2, §4.3).
##
## Each slot holds `{ seq(u64 seqlock), keyDigest(32B), recLen(u16),
## recBytes[SlotInlineCap] }` and stores a METADATA-ONLY record inline. A record
## whose metadata exceeds `SlotInlineCap` is reported not-shm-cacheable so the
## caller falls through to the Tier-1 disk store.
##
## Seqlock protocol (single writer / many lock-free readers):
##   * empty slot           -> seq == 0
##   * write in progress     -> seq is ODD  (odd = being written / unstable)
##   * stable published slot -> seq is EVEN and > 0
## A reader snapshots `seq` (acquire); if odd it is being written (miss/retry);
## it copies the payload, re-loads `seq` (acquire) and accepts the snapshot only
## if `seq` is unchanged AND even — otherwise the copy may be torn (retry/miss).

import std/os

import ./[layout, mapping, atomics_shm]

type
  SegmentTable* = object
    region*: MappedRegion
    slotCap*: int
    generation*: uint32

  SlotReadStatus* = enum
    srsHit          ## a stable snapshot for a matching keyDigest
    srsMiss         ## key not present (empty slot terminated the probe)
    srsRetry        ## a concurrent write raced us; retry the whole lookup
    srsProbeFull    ## the probe ran the whole table without a hit or an empty slot

  SlotSnapshot* = object
    digest*: array[KeyDigestLen, byte]
    rec*: seq[byte]

func slotBase(slotCap, idx: int): int {.inline.} =
  SegSlotsBase + idx * SegSlotStride

proc keyProbeStart(digest: openArray[byte]; slotCap: int): int {.inline.} =
  ## Linear-probe start index derived from the leading digest bytes.
  var h: uint64 = 0
  for i in 0 ..< min(8, digest.len):
    h = (h shl 8) or uint64(digest[i])
  int(h mod uint64(slotCap))

func digestEq(a: openArray[byte]; base: ShmBase; off: int): bool =
  for i in 0 ..< KeyDigestLen:
    if a[i] != base[off + i]:
      return false
  true

# --- create / attach ------------------------------------------------------

proc segPath*(cacheRoot: string; gen: uint32): string =
  cacheRoot / ("action-index." & $gen & ".seg")

proc createSegment*(cacheRoot: string; gen: uint32; slotCap: int;
    bootId: uint64): SegmentTable =
  ## Create + map a fresh, zero-filled segment for `gen`.
  let size = segRegionSize(slotCap)
  result.region = createRegionAtomically(segPath(cacheRoot, gen), size)
  if not result.region.isValid:
    return
  result.slotCap = slotCap
  result.generation = gen
  let base = result.region.base
  storeU64Relaxed(base, SegOffMagic, SegMagic)
  storeU32Release(base, SegOffFormatVersion, FormatVersion)
  storeU32Release(base, SegOffGeneration, gen)
  storeU64Relaxed(base, SegOffSlotCap, uint64(slotCap))
  storeU64Relaxed(base, SegOffCreatorBootId, bootId)
  # Publish the magic last so a concurrent attacher that observes the magic
  # also observes the header fields.
  storeU64Release(base, SegOffMagic, SegMagic)

proc attachSegment*(cacheRoot: string; gen: uint32; slotCap: int): SegmentTable =
  ## Attach to an existing segment for `gen`; validates the magic/version.
  ##
  ## The mapping size is derived from the segment file's ACTUAL on-disk size —
  ## NOT from the caller-supplied `slotCap` — so an attacher never has to agree
  ## with the control region's `segSlotCap` about the segment's size. This
  ## closes a crash-safety window during a CAS-resize: between the daemon
  ## publishing the new generation's `segSlotCap` and the `casCurrentGeneration`
  ## commit (or vice-versa), the ctl's cap and the live generation's true cap
  ## can momentarily disagree; sizing from the file makes the attach correct
  ## regardless. `slotCap` is retained only as a fallback for callers that map a
  ## segment before its file exists. The true cap is read from the header.
  let path = segPath(cacheRoot, gen)
  var size = segRegionSize(slotCap)
  if fileExists(path):
    let onDisk = int(getFileSize(path))
    if onDisk > 0:
      size = onDisk
  result.region = attachRegion(path, size)
  if not result.region.isValid:
    return
  let base = result.region.base
  if loadU64Acquire(base, SegOffMagic) != SegMagic or
     loadU32Acquire(base, SegOffFormatVersion) != FormatVersion or
     loadU32Acquire(base, SegOffGeneration) != gen:
    result.region.detach()
    return
  result.slotCap = int(loadU64Relaxed(base, SegOffSlotCap))
  result.generation = gen

proc isValid*(t: SegmentTable): bool {.inline.} = t.region.isValid

proc detach*(t: var SegmentTable) = t.region.detach()

# --- lock-free seqlock read ----------------------------------------------

proc readSlotAt(t: SegmentTable; idx: int; snap: var SlotSnapshot): SlotReadStatus =
  ## Seqlock-read ONE slot: snapshot seq (acquire); reject odd; copy digest +
  ## record; re-load seq (acquire); accept only if unchanged AND even.
  let base = t.region.base
  let sb = slotBase(t.slotCap, idx)
  let seq0 = loadU64Acquire(base, sb + SegSlotOffSeq)
  if seq0 == 0:
    return srsMiss                 # empty slot
  if (seq0 and 1) != 0:
    return srsRetry                # being written (odd)
  # Copy under the optimistic window.
  var digest: array[KeyDigestLen, byte]
  copyOut(base, sb + SegSlotOffDigest, digest, KeyDigestLen)
  let recLen = int(loadU32Acquire(base, sb + SegSlotOffRecLen)) and 0xFFFF
  var rec = newSeq[byte](recLen)
  if recLen > 0:
    copyOut(base, sb + SegSlotOffRec, rec, recLen)
  # Re-validate: the snapshot is stable iff seq is unchanged AND still even.
  let seq1 = loadU64Acquire(base, sb + SegSlotOffSeq)
  if seq1 != seq0 or (seq1 and 1) != 0:
    return srsRetry
  snap.digest = digest
  snap.rec = rec
  srsHit

proc lookupSlot*(t: SegmentTable; digest: openArray[byte];
    snap: var SlotSnapshot): SlotReadStatus =
  ## Open-addressed lock-free lookup by keyDigest. Linear probe from the
  ## hash-derived start; stops at a matching key (hit), an empty slot (miss),
  ## or after a full sweep (probe-full). A raced slot yields srsRetry so the
  ## caller re-runs the whole lookup.
  if not t.isValid or digest.len < KeyDigestLen:
    return srsMiss
  let base = t.region.base
  var idx = keyProbeStart(digest, t.slotCap)
  for _ in 0 ..< t.slotCap:
    let sb = slotBase(t.slotCap, idx)
    let seq0 = loadU64Acquire(base, sb + SegSlotOffSeq)
    if seq0 == 0:
      return srsMiss               # empty terminates the probe
    if (seq0 and 1) == 0 and digestEq(digest, base, sb + SegSlotOffDigest):
      let st = readSlotAt(t, idx, snap)
      if st == srsRetry:
        return srsRetry            # let the caller retry the whole lookup
      if st == srsHit:
        return srsHit
      # a concurrent overwrite changed the key mid-copy: keep probing.
    idx = (idx + 1) mod t.slotCap
  srsProbeFull

# --- single-writer slot write --------------------------------------------

type
  SlotWriteStatus* = enum
    swsWritten          ## the record was written to a slot
    swsOversized        ## metadata > SlotInlineCap: NOT shm-cacheable
    swsProbeFull        ## no free/matching slot within the probe (eviction hook)

proc writeSlotRaw(t: SegmentTable; idx: int; digest: openArray[byte];
    rec: openArray[byte]) =
  ## Single-writer seqlock write of slot `idx`: seq even->odd (release), write
  ## digest+recLen+recBytes, seq -> old+2 (release, back to even). A reader that
  ## snapshots the odd seq (or a changed seq) rejects the window.
  let base = t.region.base
  let sb = slotBase(t.slotCap, idx)
  let seqOld = loadU64Relaxed(base, sb + SegSlotOffSeq)
  # even->odd: mark the slot unstable. From empty(0) the first odd is 1.
  storeU64Release(base, sb + SegSlotOffSeq, seqOld or 1'u64)
  copyIn(base, sb + SegSlotOffDigest, digest.toOpenArray(0, KeyDigestLen - 1))
  storeU32Release(base, sb + SegSlotOffRecLen, uint32(rec.len))
  if rec.len > 0:
    copyIn(base, sb + SegSlotOffRec, rec)
  # Publish: bump seq to the next EVEN value (odd -> +1). A fresh slot goes
  # 0 -> 1 -> 2; a rewrite goes 2 -> 3 -> 4, etc. Monotonic + even == stable.
  storeU64Release(base, sb + SegSlotOffSeq, (seqOld or 1'u64) + 1'u64)

proc writeSlot*(t: var SegmentTable; digest: openArray[byte];
    rec: openArray[byte]): SlotWriteStatus =
  ## Insert/update a record by keyDigest (single-writer / daemon path; exposed
  ## for the AC-2a test stand-in consumer). Oversized metadata is rejected
  ## (caller falls to disk). Open-addressed linear probe finds the matching key
  ## or the first empty slot; a full probe returns swsProbeFull so the caller's
  ## eviction policy (AC-2b) can intervene.
  if rec.len > SlotInlineCap:
    return swsOversized
  if not t.isValid or digest.len < KeyDigestLen:
    return swsProbeFull
  let base = t.region.base
  var idx = keyProbeStart(digest, t.slotCap)
  for _ in 0 ..< t.slotCap:
    let sb = slotBase(t.slotCap, idx)
    let seq0 = loadU64Relaxed(base, sb + SegSlotOffSeq)
    if seq0 == 0:
      writeSlotRaw(t, idx, digest, rec)     # empty slot: fresh insert
      return swsWritten
    if (seq0 and 1) != 0:
      # A prior sole writer may have died after publishing the odd seqlock but
      # before completing this slot. There cannot be a live concurrent writer
      # on this single-writer API; overwrite the abandoned slot in place. The
      # daemon keeps the corresponding ring head unacknowledged until apply
      # completes, so takeover replays the exact record idempotently here.
      writeSlotRaw(t, idx, digest, rec)
      return swsWritten
    if (seq0 and 1) == 0 and digestEq(digest, base, sb + SegSlotOffDigest):
      writeSlotRaw(t, idx, digest, rec)     # same key: in-place update
      return swsWritten
    idx = (idx + 1) mod t.slotCap
  swsProbeFull

proc evictSlot*(t: var SegmentTable; idx: int) =
  ## Eviction MECHANISM (the POLICY is AC-2b): reset a slot to empty via a
  ## seqlock window so a concurrent reader never sees a torn transition. The
  ## slot's seq goes even->odd->0 (empty); readers treat odd/0 as not-present.
  if not t.isValid or idx < 0 or idx >= t.slotCap:
    return
  let base = t.region.base
  let sb = slotBase(t.slotCap, idx)
  let seqOld = loadU64Relaxed(base, sb + SegSlotOffSeq)
  storeU64Release(base, sb + SegSlotOffSeq, seqOld or 1'u64)  # unstable
  var zero: array[KeyDigestLen, byte]
  copyIn(base, sb + SegSlotOffDigest, zero)
  storeU32Release(base, sb + SegSlotOffRecLen, 0'u32)
  storeU64Release(base, sb + SegSlotOffSeq, 0'u64)           # empty

proc probeIndexFor*(t: SegmentTable; digest: openArray[byte]): int =
  ## Expose the probe start (for the AC-2b eviction policy / tests).
  keyProbeStart(digest, t.slotCap)

# --- single-writer introspection (daemon-only: rehash + load factor) ------
#
# These helpers read a segment WITHOUT the seqlock re-check because the DAEMON
# is the sole writer (AC-2b) and calls them only from its own single thread
# between its own writes — there is never a concurrent writer to tear against.
# They are NOT for lock-free readers (those use `lookupSlot`).

proc liveSlotCount*(t: SegmentTable): int =
  ## Number of published (even, non-zero seq) slots. Single-writer view used to
  ## compute the load factor for the growth threshold.
  if not t.isValid: return 0
  let base = t.region.base
  for idx in 0 ..< t.slotCap:
    let sb = slotBase(t.slotCap, idx)
    let sq = loadU64Relaxed(base, sb + SegSlotOffSeq)
    if sq != 0 and (sq and 1) == 0:
      inc result

iterator liveSlots*(t: SegmentTable): SlotSnapshot =
  ## Yield every published slot's {digest, rec} for rehash into a new
  ## generation. Single-writer only (no seqlock re-check needed).
  if t.isValid:
    let base = t.region.base
    for idx in 0 ..< t.slotCap:
      let sb = slotBase(t.slotCap, idx)
      let sq = loadU64Relaxed(base, sb + SegSlotOffSeq)
      if sq != 0 and (sq and 1) == 0:
        var snap: SlotSnapshot
        copyOut(base, sb + SegSlotOffDigest, snap.digest, KeyDigestLen)
        let recLen = int(loadU32Acquire(base, sb + SegSlotOffRecLen)) and 0xFFFF
        snap.rec = newSeq[byte](recLen)
        if recLen > 0:
          copyOut(base, sb + SegSlotOffRec, snap.rec, recLen)
        yield snap

proc slotSeqAt*(t: SegmentTable; idx: int): uint64 =
  ## The raw seqlock value of slot `idx` (single-writer LRU-window inspection).
  if not t.isValid or idx < 0 or idx >= t.slotCap: return 0
  loadU64Relaxed(t.region.base, slotBase(t.slotCap, idx) + SegSlotOffSeq)
