## Fixed byte layouts for the control region, the MPSC submission ring, and the
## generation segments (Action-Cache-Per-Edge-Store.md §4.1, §4.2).
##
## All layouts are OFFSET-ONLY and mapping-base-independent: every field is a
## compile-time byte offset from the mapped base, naturally aligned so the
## atomic accesses in `atomics_shm` are well-defined on every process's mapping.

# --- alignment helpers (usable in const context) --------------------------

func align8*(n: int): int = (n + 7) and not 7
func align4k*(n: int): int = (n + 4095) and not 4095

const
  CtlMagic* = 0x4C544341_42524850'u64  ## "RBACTL"-derived magic tag.
  SegMagic* = 0x4745535F_42524850'u64  ## "RBP_SEG"-derived magic tag.
  FormatVersion* = 1'u32

  KeyDigestLen* = 32          ## BLAKE3 weak/strong fingerprint digest bytes.
  SlotInlineCap* = 256        ## max metadata-record bytes stored inline in a slot.

  MaxReaders* = 64            ## reader-epoch table size (RCU grace window).
  RingCap* = 1024             ## MPSC submission-ring capacity (power of two).
  RingSlotRecCap* = SlotInlineCap
    ## inline metadata-record capacity of one submission slot.

static:
  # RingCap must be a power of two so `tail mod RingCap` is a mask.
  doAssert (RingCap and (RingCap - 1)) == 0

# --- Control region header ------------------------------------------------
#
# All 8-byte fields sit on 8-byte-aligned offsets. Layout (bytes):
const
  CtlOffMagic*            = 0                       # u64
  CtlOffFormatVersion*    = CtlOffMagic + 8         # u32
  CtlOffFlags*            = CtlOffFormatVersion + 4 # u32 (reserved / init-done)
  CtlOffCreatorBootId*    = CtlOffFlags + 4         # u64
  CtlOffCurrentGen*       = CtlOffCreatorBootId + 8 # u64 atomic
  CtlOffDaemonPid*        = CtlOffCurrentGen + 8    # u64 atomic
  CtlOffDaemonHeartbeat*  = CtlOffDaemonPid + 8     # u64 atomic (epoch seconds)
  CtlOffSegByteSize*      = CtlOffDaemonHeartbeat + 8 # u64 (bytes of live seg)
  CtlOffSegSlotCap*       = CtlOffSegByteSize + 8   # u64 (slots in live seg)
  # Reader-epoch table: MaxReaders * u64, each reader publishes the generation
  # it is currently reading (0 == idle). Enables RCU reclamation (AC-2b).
  CtlOffReaderEpochs*     = CtlOffSegSlotCap + 8    # u64 * MaxReaders

# --- MPSC submission ring -------------------------------------------------
#
# SHM-QUEUE-MIGRATE: the submission ring is now the extracted, shared MPSC ring
# from ``nim-shm-queue`` (Layer 1 ``shm_queue/ring``), EMBEDDED at ``RingHdrBase``
# inside this control region (the caller-owned mapping this library owns). The
# ring's coordination state (head/tail/dropped) + fixed slot array follow the
# reader-epoch table; their byte span is computed by ``shm_queue`` from the ring
# geometry so exactly ONE MPSC layout exists. reprobuild's record codec
# (``(digest, rec)``) is unchanged — it is packed into the ring's opaque byte
# blob as ``digest[32] ++ rec`` (see ring.nim); the ring never interprets it.
import shm_queue/segment as shmseg

const
  RingHdrBase*   = CtlOffReaderEpochs + MaxReaders * 8
    ## Byte offset of the embedded ring (its head/tail/dropped header) within
    ## the control region — the ``ringBase`` handed to ``initEmbeddedRing``.
  RingBlobCap*   = KeyDigestLen + RingSlotRecCap
    ## Per-slot blob capacity: the 32-byte key digest plus the inline record.
  RingSpan*      = shmseg.embeddedRingSize(RingCap, RingBlobCap)
    ## Total byte span of the embedded ring (header + ``RingCap`` slots), as laid
    ## out by ``shm_queue`` — the single source of the ring's on-region layout.

const
  CtlRegionSize* = align4k(RingHdrBase + RingSpan)
    ## Fixed byte size of `action-index.ctl` (page-rounded).

# --- Compatible control-region extension ---------------------------------
#
# AC-2 originally page-rounded the control mapping after the embedded ring.
# Keep every original offset, the ring geometry, CtlRegionSize, file name, and
# FormatVersion byte-for-byte unchanged, and use only that already-zero-filled
# trailing page padding for lifecycle coordination added after deployment.
#
# Older binaries never address these bytes.  New binaries therefore coexist
# with an old same-boot mapping without splitting the control region or making
# either side reject it on size/version grounds.
const
  CtlExtBase* = align8(RingHdrBase + RingSpan)

  CtlExtOffOwnerMagic*       = CtlExtBase                  # u64 atomic
  CtlExtOffOwnerPid*         = CtlExtOffOwnerMagic + 8     # u64 atomic
  CtlExtOffOwnerNonce*       = CtlExtOffOwnerPid + 8       # u64 atomic
  CtlExtOffOwnerStart*       = CtlExtOffOwnerNonce + 8     # u64 process incarnation
  CtlExtOffWriterGate*       = CtlExtOffOwnerStart + 8     # u64 capability CAS
  CtlExtOffNonceCounter*     = CtlExtOffWriterGate + 8     # u64 fetch-add

  CtlExtOffLaunchLease*      = CtlExtOffNonceCounter + 8   # u64 CAS
  CtlExtOffLaunchStarted*    = CtlExtOffLaunchLease + 8    # legacy diagnostic mirror
  CtlExtOffLaunchStartedToken* = CtlExtOffLaunchStarted + 8 # legacy diagnostic mirror

  # A work generation advances by two.  Its association is prepared in one of
  # two alternating slots *before* the generation CAS publishes it.  A producer
  # killed after publishing the ring record but before the CAS is repaired by
  # the next producer, while a killed producer after the CAS can never leave a
  # visible generation without a full-width age/previous-generation record.
  CtlExtOffWorkSequence*     = CtlExtOffLaunchStartedToken + 8 # u64 CAS, stable even
  CtlExtOffWorkAck*          = CtlExtOffWorkSequence + 8   # u64 owner-written
  CtlExtOffWorkStartSeq*     = CtlExtOffWorkAck + 8        # association slot 0 target
  CtlExtOffWorkStartedMs*    = CtlExtOffWorkStartSeq + 8   # association slot 0 epoch ms
  CtlExtOffWorkPreviousSeq*  = CtlExtOffWorkStartedMs + 8  # association slot 0 predecessor
  CtlExtOffWorkAckAtStart*   = CtlExtOffWorkPreviousSeq + 8 # association slot 0 ack
  CtlExtOffWorkStartSeq1*    = CtlExtOffWorkAckAtStart + 8 # association slot 1 target
  CtlExtOffWorkStartedMs1*   = CtlExtOffWorkStartSeq1 + 8  # association slot 1 epoch ms
  CtlExtOffWorkPreviousSeq1* = CtlExtOffWorkStartedMs1 + 8 # association slot 1 predecessor
  CtlExtOffWorkAckAtStart1*  = CtlExtOffWorkPreviousSeq1 + 8 # association slot 1 ack

  # Diagnostic counters are part of the compatible extension rather than
  # process-local test hooks. They make launch-storm assertions observable
  # across real producer processes without changing the coordination protocol.
  CtlExtOffOsProbeCount*     = CtlExtOffWorkAckAtStart1 + 8 # u64 fetch-add
  CtlExtOffSpawnAttemptCount* = CtlExtOffOsProbeCount + 8  # u64 fetch-add
  CtlExtOffOwnerClaimCount*  = CtlExtOffSpawnAttemptCount + 8 # u64 fetch-add
  CtlExtOffShutdownPassCount* = CtlExtOffOwnerClaimCount + 8 # u64 fetch-add
  CtlExtOffShutdownTicketCount* = CtlExtOffShutdownPassCount + 8 # u64 fetch-add

  # A 64-bit capability is never split into PID/nonce fragments.  It names one
  # immutable identity record prepared before the capability is published in a
  # gate, lease, or owner field.  This gives a single-word CAS linearization
  # point without truncating the nonce, while the record supplies PID
  # incarnation information for exact crash recovery.
  CoordSlotCount* = 48
  CoordSlotStride* = 56
  CoordSlotOffReservation* = 0  # u64 CAS; capability while the slot is allocated
  CoordSlotOffToken*       = 8  # u64 release-published last
  CoordSlotOffPid*         = 16 # u64
  CoordSlotOffStart*       = 24 # u64 process-start incarnation
  CoordSlotOffStarted*     = 32 # u64 epoch seconds
  CoordSlotOffFlags*       = 40 # u64 lifecycle phase
  CoordSlotOffGateStarted* = 48 # u64 prepared before writer-gate CAS
  CtlExtCoordSlotsBase* = CtlExtOffShutdownTicketCount + 8

  # Preserve the deployed record offsets/stride and place the publication
  # guard in a parallel array in the same compatible zero-filled page padding.
  # The guard is the single CAS linearization word for provisional commit,
  # cancellation, dead-initializer recovery, and exact release.
  CtlExtCoordGuardsBase* =
    CtlExtCoordSlotsBase + CoordSlotCount * CoordSlotStride
  CoordGuardStateBits* = 3
  CoordGuardStateMask* = (1'u64 shl CoordGuardStateBits) - 1'u64
  CoordGuardReserved* = 1'u64
  CoordGuardCommitted* = 2'u64
  CoordGuardCancelled* = 3'u64
  CoordGuardRetiring* = 4'u64
  CoordGuardReclaiming* = 5'u64
  CoordGuardUpdating* = 6'u64
    ## One exact committed generation owns a mutable coordination-field store.
  CoordGuardRetireRequested* = 7'u64
    ## Release raced an updater. The slot stays quarantined until that exact
    ## updater acknowledges the request or definite-death recovery completes it.

  CtlExtCoordGuardsEnd* = CtlExtCoordGuardsBase + CoordSlotCount * 8

  # A terminal cleanup performed by the original live capability holder needs
  # no extra ownership record: its immutable PID/start/token identity remains
  # published until Guard becomes Free. Crash takeover is different. The
  # recovering process may perform ordinary legacy-owner stores, so one exact
  # cleanup claimant must exclude every other process until physical reuse.
  #
  # Only 232 compatible padding bytes remain in the deployed control mapping:
  # 48 naturally-aligned u32 per-slot tickets consume 192 bytes, and the five
  # u64 words below consume the remaining 40. Cleanup is therefore serialized
  # only on the exceptional terminal-takeover path; healthy release is
  # unaffected.
  #
  # NOTE: with the oversize counter below, the compatible zero-filled padding
  # of the deployed control mapping is now FULLY consumed (`CtlExtEnd ==
  # CtlRegionSize`, enforced by the static assert at the end of this block).
  # Any further control-region field needs a `FormatVersion` bump (which
  # recreates the region) rather than another compatible extension.
  CoordCleanupTicketStride* = 4
  CtlExtCoordCleanupTicketsBase* = CtlExtCoordGuardsEnd
  CtlExtOffCleanupClaim* =
    CtlExtCoordCleanupTicketsBase +
      CoordSlotCount * CoordCleanupTicketStride # packed PID/start fingerprint
  CtlExtOffCleanupStart* = CtlExtOffCleanupClaim + 8 # exact process start
  CtlExtOffCleanupStartClaim* = CtlExtOffCleanupStart + 8 # association guard
  CtlExtOffCleanupEpoch* = CtlExtOffCleanupStartClaim + 8 # full cleanup generation

  # An OVER-CAP submission (`rec.len > RingSlotRecCap`) is rejected before it
  # ever reaches the ring, so it cannot be signalled by the ring header's
  # `dropped` word the way a ring-full drop is. It gets its own atomic,
  # cross-process counter here — same shared, zero-initialised control region
  # every producer already maps, so the oversize signal is observable from a
  # running system exactly like the drop signal
  # (Action-Cache-Per-Edge-Store.md §4.4 / §8 AC-2c: an oversized record is
  # "signalled Tier-1-only", never silent).
  CtlExtOffRingOversizedCount* = CtlExtOffCleanupEpoch + 8 # u64 fetch-add

  CtlExtEnd* = CtlExtOffRingOversizedCount + 8

static:
  doAssert CtlExtBase >= RingHdrBase + RingSpan
  doAssert (CtlExtCoordSlotsBase and 7) == 0
  doAssert (CtlExtCoordGuardsBase and 7) == 0
  doAssert (CtlExtCoordCleanupTicketsBase and 3) == 0
  doAssert (CtlExtOffCleanupClaim and 7) == 0
  doAssert (CtlExtOffCleanupStart and 7) == 0
  doAssert (CtlExtOffCleanupStartClaim and 7) == 0
  doAssert (CtlExtOffCleanupEpoch and 7) == 0
  doAssert (CtlExtOffRingOversizedCount and 7) == 0
  doAssert CtlExtEnd <= CtlRegionSize

# --- Generation segment ---------------------------------------------------
#
# Segment header + open-addressed slot array. Each slot:
#   {seq(u64 seqlock), keyDigest[32], recLen(u16), pad, recBytes[SlotInlineCap]}
const
  SegOffMagic*        = 0                           # u64
  SegOffFormatVersion* = SegOffMagic + 8            # u32
  SegOffGeneration*   = SegOffFormatVersion + 4     # u32
  SegOffSlotCap*      = SegOffGeneration + 4        # u64
  SegOffCreatorBootId* = SegOffSlotCap + 8          # u64
  SegSlotsBase*       = align8(SegOffCreatorBootId + 8)

  SegSlotOffSeq*      = 0                            # u64 seqlock
  SegSlotOffDigest*   = SegSlotOffSeq + 8            # byte[32]
  SegSlotOffRecLen*   = SegSlotOffDigest + KeyDigestLen  # u16
  SegSlotOffPad*      = SegSlotOffRecLen + 2         # pad -> align8
  SegSlotOffRec*      = align8(SegSlotOffPad)        # byte[SlotInlineCap]
  SegSlotStride*      = align8(SegSlotOffRec + SlotInlineCap)

proc segRegionSize*(slotCap: int): int =
  ## Page-rounded byte size of a generation segment holding `slotCap` slots.
  align4k(SegSlotsBase + slotCap * SegSlotStride)
