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

type
  SubmissionRing* = object
    ## A view over the ring embedded in the control region. `base` is the
    ## control-region mapped base; the ring lives at `RingHdrBase` within it.
    er: shmring.EmbeddedRing

  RingAppendStatus* = enum
    rasAppended     ## the record was reserved + published
    rasDropped      ## ring full: SIGNALLED drop (the `dropped` counter bumped)
    rasOversized    ## record > RingSlotRecCap: not enqueueable

  RingRecord* = object
    digest*: array[KeyDigestLen, byte]
    rec*: seq[byte]

proc initRing*(base: ShmBase): SubmissionRing {.inline.} =
  SubmissionRing(er: shmring.initEmbeddedRing(base, RingHdrBase, RingCap,
    RingBlobCap))

proc resetRing*(base: ShmBase) =
  ## Zero the ring header (fresh region init). Slot `ready` fields are already
  ## zero in a freshly-created (zero-filled) region. Delegates to shm_queue.
  shmring.resetEmbeddedRing(
    shmring.initEmbeddedRing(base, RingHdrBase, RingCap, RingBlobCap))

# --- multi-producer append (CAS tail) ------------------------------------

proc append*(r: SubmissionRing; digest: openArray[byte];
    rec: openArray[byte]): RingAppendStatus =
  ## Lock-free multi-producer append. Packs the record as ``digest[32] ++ rec``
  ## into a stack buffer (NO heap alloc on the hot path) and hands it to the
  ## shm_queue ring's ``tryPush`` (CAS ticket reserve + release-store publish).
  ## Bounded: on a full ring the `dropped` counter is bumped and `rasDropped`
  ## returned (the drop is SIGNALLED, never silent — spec §4.6). A record larger
  ## than the inline slot capacity is `rasOversized` (ring unchanged).
  if rec.len > RingSlotRecCap:
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
  of prOversize: rasOversized
  # Any other producer result is treated as a drop (the record could not be
  # delivered). Newer nim-shm-queue revisions add ``prConsumerGone`` (an
  # ``opBlockProducer``-only outcome the non-blocking ``tryPush`` never returns);
  # ``else`` keeps this exhaustive and version-agnostic across nim-shm-queue revs
  # (older pins have only the three named results above).
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

proc droppedCount*(r: SubmissionRing): uint64 {.inline.} =
  r.er.droppedCount()

proc pendingCount*(r: SubmissionRing): uint64 {.inline.} =
  ## Reserved-but-not-yet-drained tickets (tail - head). Bounded by RingCap.
  r.er.pendingCount()
