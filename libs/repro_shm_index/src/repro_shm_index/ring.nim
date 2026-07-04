## Shared-memory MPSC submission ring (Action-Cache-Per-Edge-Store.md §4.4).
##
## Many producer PROCESSES append records; the single consumer (the daemon;
## here a test stand-in) drains them. Lock-free, no socket, no process-shared
## mutex.
##
## Reservation protocol (bounded, drop-on-full SIGNALLED):
##   * `tail` is a monotonically increasing u64 ticket counter, CAS-bumped by
##     producers to RESERVE a ticket. `head` is the consumer-owned ticket of the
##     next slot to drain. A ticket maps to a slot via `ticket mod RingCap`.
##   * A producer reserves ticket T via CAS(tail: T -> T+1) only if the ring is
##     not full (`T - head < RingCap`); on full it bumps the atomic `dropped`
##     counter and returns a drop signal (never silent).
##   * The producer writes its payload into slot `T mod RingCap`, then PUBLISHES
##     by storing the slot's `ready` field = T+1 (release). `ready == 0` means
##     never-written; `ready == ticket+1` means "the record for ticket `ticket`
##     is complete". Because tickets are unique per slot generation, the
##     consumer distinguishes a freshly-published slot from a stale one.
##   * The single consumer drains ticket H: it spins until slot(H).ready == H+1
##     (published), reads the payload (acquire), advances `head` to H+1, and
##     clears `ready` to 0 so the slot can be reused by ticket H+RingCap.

import ./[layout, atomics_shm]

type
  SubmissionRing* = object
    ## A view over the ring embedded in the control region. `base` is the
    ## control-region mapped base; ring offsets are relative to it.
    base*: ShmBase

  RingAppendStatus* = enum
    rasAppended     ## the record was reserved + published
    rasDropped      ## ring full: SIGNALLED drop (the `dropped` counter bumped)
    rasOversized    ## record > RingSlotRecCap: not enqueueable

  RingRecord* = object
    digest*: array[KeyDigestLen, byte]
    rec*: seq[byte]

func slotOffFor(ticket: uint64): int {.inline.} =
  RingSlotsBase + int(ticket mod uint64(RingCap)) * RingSlotStride

proc initRing*(base: ShmBase): SubmissionRing {.inline.} =
  SubmissionRing(base: base)

proc resetRing*(base: ShmBase) =
  ## Zero the ring header (fresh region init). Slot `ready` fields are already
  ## zero in a freshly-created (zero-filled) region.
  storeU64Relaxed(base, RingOffHead, 0)
  storeU64Relaxed(base, RingOffTail, 0)
  storeU64Relaxed(base, RingOffDropped, 0)

# --- multi-producer append (CAS tail) ------------------------------------

proc append*(r: SubmissionRing; digest: openArray[byte];
    rec: openArray[byte]): RingAppendStatus =
  ## Lock-free multi-producer append. Reserves a ticket by CAS-bumping `tail`,
  ## writes the slot, and publishes via the slot `ready` field. Bounded: on a
  ## full ring the `dropped` counter is bumped and `rasDropped` returned (the
  ## drop is SIGNALLED, never silent — spec §4.6).
  if rec.len > RingSlotRecCap:
    return rasOversized
  let base = r.base
  var tail = loadU64Acquire(base, RingOffTail)
  while true:
    let head = loadU64Acquire(base, RingOffHead)
    if tail - head >= uint64(RingCap):
      # Ring full. Re-check tail once (it may have advanced under us) before
      # committing to a drop, then signal the drop via the atomic counter.
      let tailNow = loadU64Acquire(base, RingOffTail)
      if tailNow != tail:
        tail = tailNow
        continue
      discard fetchAddU64(base, RingOffDropped, 1)
      return rasDropped
    # Reserve `tail` by advancing it to tail+1. On failure `tail` is refreshed
    # with the observed value (casU64 semantics) and we retry.
    if casU64(base, RingOffTail, tail, tail + 1):
      break
    # CAS failed: `tail` now holds the current value; loop and retry.
  # We own ticket `tail`. The slot for this ticket must be free — the consumer
  # cleared `ready` for the previous occupant (ticket tail-RingCap); a producer
  # would only reach here after head advanced past that occupant.
  let so = slotOffFor(tail)
  copyIn(base, so + RingSlotOffDigest, digest.toOpenArray(0, KeyDigestLen - 1))
  storeU32Release(base, so + RingSlotOffRecLen, uint32(rec.len))
  if rec.len > 0:
    copyIn(base, so + RingSlotOffRec, rec)
  # Publish: ready = ticket + 1 (never 0). Release-ordered so the consumer that
  # observes `ready` also observes the payload writes above.
  storeU64Release(base, so + RingSlotOffReady, tail + 1)
  rasAppended

# --- single-consumer drain -----------------------------------------------

proc tryDrainOne*(r: SubmissionRing; outRec: var RingRecord): bool =
  ## Single-consumer non-blocking drain of the next ready ticket. Returns false
  ## if the head slot is not yet published (empty or a producer mid-write).
  let base = r.base
  let head = loadU64Relaxed(base, RingOffHead)      # consumer-owned
  let tail = loadU64Acquire(base, RingOffTail)
  if head >= tail:
    return false                                    # nothing reserved past head
  let so = slotOffFor(head)
  let ready = loadU64Acquire(base, so + RingSlotOffReady)
  if ready != head + 1:
    return false                                    # producer still publishing
  # Read the payload (acquire on `ready` above ordered these reads).
  copyOut(base, so + RingSlotOffDigest, outRec.digest, KeyDigestLen)
  let recLen = int(loadU32Acquire(base, so + RingSlotOffRecLen))
  outRec.rec = newSeq[byte](recLen)
  if recLen > 0:
    copyOut(base, so + RingSlotOffRec, outRec.rec, recLen)
  # Retire the slot: clear ready (so ticket head+RingCap can reuse it) and
  # advance head (release) as the consumer's linearization point.
  storeU64Release(base, so + RingSlotOffReady, 0)
  storeU64Release(base, RingOffHead, head + 1)
  true

proc droppedCount*(r: SubmissionRing): uint64 {.inline.} =
  loadU64Acquire(r.base, RingOffDropped)

proc pendingCount*(r: SubmissionRing): uint64 {.inline.} =
  ## Reserved-but-not-yet-drained tickets (tail - head). Bounded by RingCap.
  loadU64Acquire(r.base, RingOffTail) - loadU64Acquire(r.base, RingOffHead)
