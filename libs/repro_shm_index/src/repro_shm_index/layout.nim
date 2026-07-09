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
