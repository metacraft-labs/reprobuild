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
# Ring header + fixed slot array follow the reader-epoch table.
const
  RingHdrBase*     = CtlOffReaderEpochs + MaxReaders * 8
  RingOffHead*     = RingHdrBase                    # u64 atomic (consumer-owned)
  RingOffTail*     = RingOffHead + 8                # u64 atomic (producers CAS)
  RingOffDropped*  = RingOffTail + 8                # u64 atomic (drop-on-full count)
  RingSlotsBase*   = RingOffDropped + 8             # ring[RingCap]

# One submission slot: {ready(u64 seq), keyDigest[32], recLen(u32), pad,
#                       recBytes[RingSlotRecCap]}
# `ready` is a per-slot publication ticket: a producer CASes the tail to
# RESERVE the index, fills the payload, then stores ready = reservation+1
# (release). The consumer reads ready (acquire) to know the slot is complete.
const
  RingSlotOffReady*   = 0                           # u64 atomic
  RingSlotOffDigest*  = RingSlotOffReady + 8        # byte[32]
  RingSlotOffRecLen*  = RingSlotOffDigest + KeyDigestLen  # u32
  RingSlotOffPad*     = RingSlotOffRecLen + 4       # u32 pad
  RingSlotOffRec*     = RingSlotOffPad + 4          # byte[RingSlotRecCap]
  RingSlotStride*     = align8(RingSlotOffRec + RingSlotRecCap)

const
  CtlRegionSize* = align4k(RingSlotsBase + RingCap * RingSlotStride)
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
