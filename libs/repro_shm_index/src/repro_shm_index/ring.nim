## Shared-memory MPSC submission ring (Action-Cache-Per-Edge-Store.md §4.4).
##
## Many producer PROCESSES append records; the single consumer (the daemon;
## here a test stand-in) drains them. Lock-free, no socket, no process-shared
## mutex.
##
## SHM-QUEUE-MIGRATE: the ring COORDINATION (ticket-CAS ``tail`` reservation,
## release-store publish, single-consumer ``head``-advance drain, atomic
## SIGNALLED drop counter) is no longer implemented here — it is the extracted,
## shared single MPSC ring from ``nim-shm-queue`` (Layer 1 ``shm_queue/ring``),
## the SAME ring io-mon's dependency queue sits on. This module keeps ONLY
## reprobuild's cache-record shape ``(digest[32], rec)`` and the append/drain
## front-end; it packs a record into the ring's opaque byte blob as
## ``digest[32] ++ rec`` and splits it back on drain. The ring is EMBEDDED at
## ``RingHdrBase`` inside the control region this library owns (``EmbeddedRing``
## over the caller-owned ``base``), so the boot-guarded header, reader-epoch
## table AND the ring stay in the one ``action-index.ctl`` mapping — while the
## MPSC mechanism has exactly one home.

import ./[layout, atomics_shm]
import shm_queue/ring as shmring
import shm_queue/segment as shmseg

type
  SubmissionRing* = object
    ## A view over the ring embedded in the control region. `base` is the
    ## control-region mapped base; the ring lives at `RingHdrBase` within it.
    er: shmring.EmbeddedRing

  RingAppendStatus* = enum
    rasAppended     ## the record was reserved + published
    rasDropped      ## ring full: SIGNALLED drop (the `dropped` counter bumped)
    rasOversized    ## record > RingSlotRecCap: not enqueueable (SIGNALLED via
                    ## the `oversized` counter)

  RingRecord* = object
    digest*: array[KeyDigestLen, byte]
    rec*: seq[byte]

  RingPeekStatus* = enum
    rpsEmpty
      ## No ticket is reserved at the current head.
    rpsUnpublished
      ## The head ticket is reserved but its producer has not published it.
    rpsMalformed
      ## The head ticket is published but not a valid cache-record blob.
    rpsRecord
      ## A complete record was copied without advancing the shared head.

  PeekedRingRecord* = object
    ## A stable copy of one published head record. `ticket` is the exact head
    ## value that `ackPeek` must CAS to `ticket + 1`; a stale consumer can never
    ## acknowledge a successor's record.
    ticket*: uint64
    record*: RingRecord

proc initRing*(base: atomics_shm.ShmBase): SubmissionRing {.inline.} =
  SubmissionRing(er: shmring.initEmbeddedRing(base, RingHdrBase, RingCap,
    RingBlobCap))

proc resetRing*(base: atomics_shm.ShmBase) =
  ## Zero the ring header (fresh region init). Slot `ready` fields are already
  ## zero in a freshly-created (zero-filled) region. Delegates to shm_queue.
  shmring.resetEmbeddedRing(
    shmring.initEmbeddedRing(base, RingHdrBase, RingCap, RingBlobCap))
  # The oversize counter is the ring's SECOND rejection signal and lives beside
  # the ring (control-region extension) rather than in shm_queue's header, so it
  # is reset here together with the `dropped` word shm_queue owns.
  atomics_shm.storeU64Release(base, CtlExtOffRingOversizedCount, 0'u64)

# --- multi-producer append (CAS tail) ------------------------------------

proc noteOversized(r: SubmissionRing) {.inline.} =
  ## SIGNAL an over-cap rejection the same way a ring-full drop is signalled:
  ## an atomic, cross-process counter in the shared control region. Without it
  ## an engine whose records all exceed `RingSlotRecCap` bypasses the shm
  ## live-sharing tier 100% of the time and looks IDENTICAL, from outside, to a
  ## healthy one — the ring stays empty, the daemon is never asked to publish,
  ## and every lookup quietly falls through to Tier-1 disk.
  if r.er.base.isNil: return
  discard atomics_shm.fetchAddU64(r.er.base, CtlExtOffRingOversizedCount, 1'u64)

proc append*(r: SubmissionRing; digest: openArray[byte];
    rec: openArray[byte]): RingAppendStatus =
  ## Lock-free multi-producer append. Packs the record as ``digest[32] ++ rec``
  ## into a stack buffer (NO heap alloc on the hot path) and hands it to the
  ## shm_queue ring's ``tryPush`` (CAS ticket reserve + release-store publish).
  ## Bounded: on a full ring the `dropped` counter is bumped and `rasDropped`
  ## returned (the drop is SIGNALLED, never silent — spec §4.6). A record larger
  ## than the inline slot capacity leaves the ring unchanged and returns
  ## `rasOversized`, bumping the `oversized` counter — that rejection is
  ## SIGNALLED too (spec §4.4 / §8 AC-2c: oversized is "signalled Tier-1-only",
  ## never silent), so `oversizedCount` tells an operator whether the shm tier
  ## is actually carrying traffic or is being silently bypassed.
  if rec.len > RingSlotRecCap:
    r.noteOversized()
    return rasOversized
  var blob: array[RingBlobCap, byte]
  # digest is exactly KeyDigestLen bytes (weak fingerprint); copy verbatim.
  for i in 0 ..< KeyDigestLen:
    blob[i] = (if i < digest.len: digest[i] else: 0'u8)
  if rec.len > 0:
    for i in 0 ..< rec.len:
      blob[KeyDigestLen + i] = rec[i]
  case r.er.tryPush(blob.toOpenArray(0, KeyDigestLen + rec.len - 1))
  of prPushed: rasAppended
  of prDropped: rasDropped
  of prOversize:
    # Unreachable given the `RingSlotRecCap` pre-check above (the blob is
    # exactly `KeyDigestLen + rec.len` <= `RingBlobCap`), but a geometry change
    # must not turn a rejection into a silent one.
    r.noteOversized()
    rasOversized
  # Any other producer result is treated as a drop (the record could not be
  # delivered). Newer nim-shm-queue revisions add ``prConsumerGone`` — an
  # ``opBlockProducer``-only outcome the non-blocking ``tryPush`` never returns
  # — so naming it explicitly would fail to compile against the older pinned
  # revisions that lack the enum value. This ``else`` keeps the case exhaustive
  # AND version-agnostic across nim-shm-queue revs in both directions.
  else: rasDropped

# --- single-consumer drain -----------------------------------------------

proc tryDrainOne*(r: SubmissionRing; outRec: var RingRecord): bool =
  ## Single-consumer non-blocking drain of the next ready ticket. Returns false
  ## if the head slot is not yet published (empty or a producer mid-write). On
  ## true, `outRec.digest` + `outRec.rec` are the split-back cache record.
  var blob: array[RingBlobCap, byte]
  var blobLen = 0
  if r.er.tryDrainOne(blob, blobLen) != drGot:
    return false
  # A well-formed blob is `digest[32] ++ rec`; anything shorter than the digest
  # is malformed (never produced by `append`) — treat as empty digest + no rec.
  for i in 0 ..< KeyDigestLen:
    outRec.digest[i] = (if i < blobLen: blob[i] else: 0'u8)
  let recLen = (if blobLen > KeyDigestLen: blobLen - KeyDigestLen else: 0)
  outRec.rec = newSeq[byte](recLen)
  for i in 0 ..< recLen:
    outRec.rec[i] = blob[KeyDigestLen + i]
  true

func embeddedSlotOff(ticket: uint64): int {.inline.} =
  RingHdrBase + shmseg.ringSlotsBaseOffset() +
    int(ticket mod uint64(RingCap)) * shmseg.slotStrideFor(RingBlobCap)

proc peekOne*(r: SubmissionRing; outRec: var PeekedRingRecord):
    RingPeekStatus =
  ## Crash-replayable single-consumer read. Unlike shm_queue's `tryDrainOne`,
  ## this copies the published head slot but deliberately does NOT clear
  ## `ready` or advance `head`. The daemon first applies the record and only
  ## then calls `ackPeek`, so a crash at any point before the ack replays the
  ## same idempotent record under the next exact owner.
  ##
  ## The payload is revalidated through the publication ticket after copying.
  ## A producer cannot reuse the slot until `head` advances, so a matching
  ## ticket remains stable throughout this window.
  if r.er.base.isNil:
    return rpsEmpty
  let base = r.er.base
  let head = atomics_shm.loadU64Acquire(base,
    RingHdrBase + shmseg.RingOffHead)
  let tail = atomics_shm.loadU64Acquire(base,
    RingHdrBase + shmseg.RingOffTail)
  if head >= tail:
    return rpsEmpty
  let so = embeddedSlotOff(head)
  let wantReady = head + 1'u64
  if atomics_shm.loadU64Acquire(base,
      so + shmseg.SlotOffReady) != wantReady:
    return rpsUnpublished
  let blobLen = int(atomics_shm.loadU32Acquire(base,
    so + shmseg.SlotOffBlobLen))
  if blobLen < KeyDigestLen or blobLen > RingBlobCap:
    outRec.ticket = head
    return rpsMalformed
  var blob: array[RingBlobCap, byte]
  atomics_shm.copyOut(base, so + shmseg.SlotOffBlob, blob, blobLen)
  if atomics_shm.loadU64Acquire(base,
      so + shmseg.SlotOffReady) != wantReady:
    return rpsUnpublished
  outRec.ticket = head
  for i in 0 ..< KeyDigestLen:
    outRec.record.digest[i] = blob[i]
  let recLen = blobLen - KeyDigestLen
  outRec.record.rec = newSeq[byte](recLen)
  for i in 0 ..< recLen:
    outRec.record.rec[i] = blob[KeyDigestLen + i]
  rpsRecord

proc ackPeek*(r: SubmissionRing; ticket: uint64): bool =
  ## Retire exactly the record previously returned by `peekOne`.
  ##
  ## Advancing `head` is the sole acknowledgement/linearization point. We
  ## intentionally leave the old `ready = ticket + 1` value in place: once
  ## head advances, the producer for ticket+RingCap may reuse this slot, and
  ## its new publication ticket cannot equal the stale value. Avoiding a
  ## separate ready-clear removes both crash windows of the legacy drain
  ## sequence (clear-before-head strands the ring; head-before-clear can erase
  ## a successor publication).
  if r.er.base.isNil:
    return false
  var expected = ticket
  atomics_shm.casU64(r.er.base, RingHdrBase + shmseg.RingOffHead, expected,
    ticket + 1'u64)

proc headTicket*(r: SubmissionRing): uint64 {.inline.} =
  if r.er.base.isNil: return 0
  atomics_shm.loadU64Acquire(r.er.base,
    RingHdrBase + shmseg.RingOffHead)

proc tailTicket*(r: SubmissionRing): uint64 {.inline.} =
  if r.er.base.isNil: return 0
  atomics_shm.loadU64Acquire(r.er.base,
    RingHdrBase + shmseg.RingOffTail)

proc reserveUnpublishedForTesting*(r: SubmissionRing): uint64 =
  ## Deterministic crash fixture for the one residual limitation of the
  ## unchanged embedded MPSC layout: reserve a tail ticket and intentionally
  ## never publish its slot. Production never calls this helper.
  if r.er.base.isNil: return high(uint64)
  let base = r.er.base
  var tail = atomics_shm.loadU64Acquire(base,
    RingHdrBase + shmseg.RingOffTail)
  while true:
    let head = atomics_shm.loadU64Acquire(base,
      RingHdrBase + shmseg.RingOffHead)
    if tail - head >= uint64(RingCap):
      return high(uint64)
    if atomics_shm.casU64(base, RingHdrBase + shmseg.RingOffTail, tail,
        tail + 1'u64):
      return tail

proc droppedCount*(r: SubmissionRing): uint64 {.inline.} =
  r.er.droppedCount()

proc oversizedCount*(r: SubmissionRing): uint64 {.inline.} =
  ## Submissions rejected because the encoded record exceeded
  ## `RingSlotRecCap` — the SIGNALLED counterpart of `droppedCount` for the
  ## over-cap path. A steadily climbing value with a flat `droppedCount` means
  ## the shm live-sharing tier is being bypassed (records are Tier-1-only),
  ## not that it is idle.
  if r.er.base.isNil: return 0
  atomics_shm.loadU64Acquire(r.er.base, CtlExtOffRingOversizedCount)

proc pendingCount*(r: SubmissionRing): uint64 {.inline.} =
  ## Reserved-but-not-yet-drained tickets (tail - head). Bounded by RingCap.
  r.er.pendingCount()
