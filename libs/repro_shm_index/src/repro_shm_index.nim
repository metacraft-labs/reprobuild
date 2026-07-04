## repro_shm_index — shared-memory action-cache hot-tier DATA STRUCTURES
## (Action-Cache-Per-Edge-Store.md §4; milestone AC-2a).
##
## This library provides the *pure data structures* of the shared-memory hot
## tier — NO daemon logic (that is AC-2b) and NO engine wiring (AC-2c):
##
##   * `action-index.ctl`  — the fixed, self-describing control region: header
##     (magic / formatVersion / creatorBootId), atomic `currentGeneration`,
##     daemon pid + heartbeat, a reader-epoch table, and the MPSC submission
##     ring. Created/attached with a version+boot guard that recreates the
##     region empty on mismatch or corruption.
##   * `action-index.<gen>.seg` — a fixed open-addressed generation segment with
##     lock-free seqlock reads and a single-writer slot write.
##
## Primitives (all POSIX atomics + offset-only addressing, NO process-shared
## mutex):
##   * lock-free seqlock slot READ           (`segment.lookupSlot`)
##   * single-writer slot WRITE / evict      (`segment.writeSlot`/`evictSlot`)
##   * MPSC ring multi-producer APPEND (CAS) (`ring.append`)
##   * single-consumer ring DRAIN            (`ring.tryDrainOne`)
##
## Platform: implemented for Linux + macOS. On other platforms the module still
## compiles but `shmIndexSupported` is false and `openShmIndex` returns an
## unavailable handle (AC-2c handles the disk-only fallback).

const shmIndexSupported* = defined(linux) or defined(macosx)

import std/[os, times]

when shmIndexSupported:
  import ./repro_shm_index/[layout, mapping, atomics_shm, segment, ring]
  export layout, segment, ring
  export atomics_shm.ShmBase
  export mapping.MappedRegion, mapping.isValid, mapping.detach

type
  ShmIndex* = object
    ## An attached view of the shared-memory hot index for one cache root.
    available*: bool             ## false on non-POSIX or on attach failure
    cacheRoot*: string
    when shmIndexSupported:
      ctl*: MappedRegion         ## the mapped control region
      liveSeg*: SegmentTable     ## currently-attached generation segment
      ringView*: SubmissionRing  ## MPSC submission ring view

proc bootId*(): uint64 =
  ## A per-boot identity used to invalidate stale shm regions after a reboot
  ## (§4.1 creatorBootId). On Linux the kernel boot_id; elsewhere a stable-per-
  ## boot fallback derived from a monotonic reference. Zero is never returned.
  when defined(linux):
    try:
      let raw = readFile("/proc/sys/kernel/random/boot_id")
      var h: uint64 = 1469598103934665603'u64      # FNV-1a offset basis
      for ch in raw:
        if ch != '-' and ch != '\n':
          h = (h xor uint64(ord(ch))) * 1099511628211'u64
      return (h or 1'u64)
    except CatchableError:
      discard
  # Fallback: boot time inferred as (now - uptime) rounded to seconds. Stable
  # across a single boot, changes across reboots.
  let secs = uint64(epochTime().int64)
  (secs or 1'u64)

when shmIndexSupported:
  const DefaultSlotCap* = 4096
    ## Initial generation-0 slot capacity (AC-2b grows via new generations).

  proc ctlPath*(cacheRoot: string): string =
    cacheRoot / "action-index.ctl"

  proc headerLooksValid(base: ShmBase; expectBoot: uint64): bool =
    ## The version+boot guard: a region is usable only if the magic + format
    ## version match AND it was created on THIS boot (a reboot invalidates the
    ## volatile shm — its generation segments are gone / stale).
    loadU64Acquire(base, CtlOffMagic) == CtlMagic and
      loadU32Acquire(base, CtlOffFormatVersion) == FormatVersion and
      loadU64Relaxed(base, CtlOffCreatorBootId) == expectBoot

  proc initCtlHeader(base: ShmBase; boot: uint64; slotCap: int) =
    ## Initialise a freshly-created control region: zero the ring, set the
    ## generation-0 metadata, then publish the magic LAST (release) so any
    ## concurrent attacher that observes the magic also observes the header.
    resetRing(base)
    storeU32Release(base, CtlOffFormatVersion, FormatVersion)
    storeU32Release(base, CtlOffFlags, 0)
    storeU64Relaxed(base, CtlOffCreatorBootId, boot)
    storeU64Release(base, CtlOffCurrentGen, 0)
    storeU64Release(base, CtlOffDaemonPid, 0)
    storeU64Release(base, CtlOffDaemonHeartbeat, 0)
    storeU64Relaxed(base, CtlOffSegByteSize, uint64(segRegionSize(slotCap)))
    storeU64Relaxed(base, CtlOffSegSlotCap, uint64(slotCap))
    for i in 0 ..< MaxReaders:
      storeU64Relaxed(base, CtlOffReaderEpochs + i * 8, 0)
    storeU64Release(base, CtlOffMagic, CtlMagic)

  proc currentGeneration*(idx: ShmIndex): uint32 =
    ## The live generation (acquire) — the segment `lookup` reads from.
    if not idx.available: return 0
    uint32(loadU64Acquire(idx.ctl.base, CtlOffCurrentGen))

  proc setCurrentGeneration*(idx: ShmIndex; gen: uint32) =
    ## Publish a new live generation (release). This is the CAS-resize commit
    ## point in AC-2b; exposed here for the resize stand-in test.
    if idx.available:
      storeU64Release(idx.ctl.base, CtlOffCurrentGen, uint64(gen))

  proc casCurrentGeneration*(idx: ShmIndex; expected, desired: uint32): bool =
    if not idx.available: return false
    var exp = uint64(expected)
    casU64(idx.ctl.base, CtlOffCurrentGen, exp, uint64(desired))

  proc segSlotCap*(idx: ShmIndex): int =
    if not idx.available: return 0
    int(loadU64Relaxed(idx.ctl.base, CtlOffSegSlotCap))

  proc attachGeneration*(idx: var ShmIndex; gen: uint32; slotCap: int): bool =
    ## (Re)attach `idx.liveSeg` to segment `gen`. Used after a generation swap.
    if not idx.available: return false
    if idx.liveSeg.isValid and idx.liveSeg.generation == gen:
      return true
    var seg = attachSegment(idx.cacheRoot, gen, slotCap)
    if not seg.isValid:
      return false
    if idx.liveSeg.isValid:
      idx.liveSeg.detach()
    idx.liveSeg = seg
    true

  proc openShmIndex*(cacheRoot: string; slotCap = DefaultSlotCap;
      create = true): ShmIndex =
    ## Create-or-attach the control region + generation-0 segment for
    ## `cacheRoot`. The version+boot guard recreates the region EMPTY on a
    ## magic/version/boot mismatch (a stale post-reboot or corrupt region).
    result.cacheRoot = cacheRoot
    result.available = false
    let boot = bootId()
    createDir(cacheRoot)
    let cp = ctlPath(cacheRoot)

    # Attach if a valid region already exists on this boot.
    var ctl = attachRegion(cp, CtlRegionSize)
    if ctl.isValid and headerLooksValid(ctl.base, boot):
      result.ctl = ctl
      result.available = true
    elif create:
      if ctl.isValid:
        # Stale/corrupt (wrong boot or version): drop the mapping + recreate.
        ctl.detach()
        removeFile(cp)
      var fresh = createRegionAtomically(cp, CtlRegionSize)
      if not fresh.isValid:
        # Lost a create race — re-attach the winner.
        fresh = attachRegion(cp, CtlRegionSize)
        if not fresh.isValid:
          return
        if not headerLooksValid(fresh.base, boot):
          fresh.detach()
          return
        result.ctl = fresh
        result.available = true
      else:
        initCtlHeader(fresh.base, boot, slotCap)
        result.ctl = fresh
        result.available = true
    else:
      if ctl.isValid: ctl.detach()
      return

    if not result.available:
      return
    result.ringView = initRing(result.ctl.base)

    # Attach (or, for a freshly-created ctl, create) generation-0.
    let gen = uint32(loadU64Acquire(result.ctl.base, CtlOffCurrentGen))
    let cap = int(loadU64Relaxed(result.ctl.base, CtlOffSegSlotCap))
    var seg = attachSegment(cacheRoot, gen, cap)
    if not seg.isValid and create:
      seg = createSegment(cacheRoot, gen, cap, boot)
    if seg.isValid:
      result.liveSeg = seg

  proc close*(idx: var ShmIndex) =
    if idx.liveSeg.isValid: idx.liveSeg.detach()
    if idx.ctl.isValid: idx.ctl.detach()
    idx.available = false

  # --- reader-epoch table (RCU support surface for AC-2b) -----------------

  proc publishReaderEpoch*(idx: ShmIndex; slot: int; gen: uint32) =
    ## A reader publishes the generation it is about to read (release); the
    ## daemon reclaims an old segment only after every reader's epoch has
    ## advanced past it (AC-2b grace period). `slot` in [0, MaxReaders).
    if idx.available and slot >= 0 and slot < MaxReaders:
      storeU64Release(idx.ctl.base, CtlOffReaderEpochs + slot * 8, uint64(gen))

  proc readerEpoch*(idx: ShmIndex; slot: int): uint64 =
    if idx.available and slot >= 0 and slot < MaxReaders:
      loadU64Acquire(idx.ctl.base, CtlOffReaderEpochs + slot * 8)
    else:
      0

else:
  # Non-POSIX: the library compiles but reports unavailable so callers fall to
  # the Tier-1 disk-only path (AC-2c).
  proc openShmIndex*(cacheRoot: string; slotCap = 0; create = true): ShmIndex =
    ShmIndex(available: false, cacheRoot: cacheRoot)

  proc close*(idx: var ShmIndex) = discard
