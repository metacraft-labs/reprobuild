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

import std/[os, strutils, times]

when shmIndexSupported:
  import std/posix
  import ./repro_shm_index/[layout, mapping, atomics_shm, segment, ring]
  export layout, segment, ring
  export atomics_shm.ShmBase
  export mapping.MappedRegion, mapping.isValid, mapping.detach

when defined(macosx):
  {.emit: """
    #include <stdint.h>
    #include <libproc.h>
    static uint64_t repro_process_start_token(int pid) {
      struct proc_bsdinfo info;
      int got = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0,
                             &info, sizeof(info));
      if (got != (int)sizeof(info)) return 0;
      return (((uint64_t)info.pbi_start_tvsec) << 20) ^
             (uint64_t)info.pbi_start_tvusec;
    }
  """.}
  proc macProcessStartToken(pid: cint): uint64
    {.importc: "repro_process_start_token", nodecl.}

type
  ShmIndex* = object
    ## An attached view of the shared-memory hot index for one cache root.
    available*: bool             ## false on non-POSIX or on attach failure
    cacheRoot*: string
    when shmIndexSupported:
      ctl*: MappedRegion         ## the mapped control region
      liveSeg*: SegmentTable     ## currently-attached generation segment
      ringView*: SubmissionRing  ## MPSC submission ring view

  ProcessLiveness* = enum
    plAlive
    plDead
    plUnknown
      ## Permission denied or another indeterminate probe result. Unknown is
      ## deliberately treated as alive for every ownership/gate decision.

  OwnerIdentity* = object
    ## Exact process/capability identity. `startToken` distinguishes a reused
    ## PID, and the full-width nonce distinguishes same-process daemon/launcher
    ## objects. PID alone is retained only in the legacy control word.
    pid*: uint64
    startToken*: uint64
    nonce*: uint64

  ProcessLivenessProbe* = proc (identity: OwnerIdentity): ProcessLiveness
    {.closure, gcsafe.}

  WorkAssociation* = object
    sequence*: uint64
    previousSequence*: uint64
    ackAtStart*: uint64
    startedMs*: uint64

  WorkPublishHook* = proc (sequence: uint64) {.closure.}
    ## Deterministic seam immediately after a work-generation CAS. Production
    ## callers leave it nil.

  CoordReservation* = object
    ## Exact handle for one provisional slot generation. `claim` atomically
    ## carries the holder PID and a process-start fingerprint; `guardGeneration`
    ## distinguishes same-process objects without constraining the capability.
    slot*: int
    claim*: uint64
    guardGeneration*: uint64

  CoordReservationHook* = proc (reservation: CoordReservation) {.closure.}
    ## Deterministic seam immediately after the packed provisional claim CAS.
    ## Production callers leave it nil.

  CoordUpdateHook* = proc (token: uint64) {.closure.}
    ## Deterministic seam after one exact coordination generation has entered
    ## Updating and before its authorized field store. Production leaves it nil.

  CoordCleanupStage* = enum
    ccsTerminalPublished
      ## The exact generation entered Retiring/Reclaiming; no takeover ticket
      ## is necessarily present yet.
    ccsCleanupClaimed
      ## The exceptional cleanup claimant and per-slot ticket are stable.
    ccsBeforeWriterGateClear
      ## Every other external reference is gone; WriterGate is still resolvable.
    ccsAfterWriterGateClear
      ## WriterGate is gone, while identity/Reservation/Guard remain published.
    ccsAfterReservationClear
      ## Terminal Guard (and a takeover ticket, if any) still quarantine reuse.
    ccsAfterGuardClear
      ## A takeover ticket still quarantines reuse; an original-owner cleanup is
      ## physically free and performs no further slot stores.

  CoordCleanupHook* =
    proc (stage: CoordCleanupStage; slot: int; guard, token: uint64) {.closure.}
    ## Deterministic crash-boundary seam for terminal cleanup. Production leaves
    ## it nil; hook failure intentionally leaves the exact terminal state for a
    ## later call/process to resume.

  OwnerSnapshotHook* = proc (guard: uint64) {.closure.}
    ## Deterministic seam after the first owner-publication generation load.
    ## Production callers leave it nil.

  CoordClaimObservation* = object
    liveness*: ProcessLiveness
    startToken*: uint64

  CoordClaimLivenessProbe* =
    proc (pid: uint64): CoordClaimObservation {.closure, gcsafe.}
    ## Test seam for the earliest claim-only crash boundary. Production uses
    ## kill(2) plus the platform process-start token. The protocol itself still
    ## performs the fingerprint comparison, so tests cannot bypass it.

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

const
  WorkAckProbeGraceMs* = 100'u64
    ## Bounded grace for a fresh owner to acknowledge a work generation before
    ## the elected producer performs the exceptional hard-crash liveness probe.
  CapableHeartbeatBit* = 1'u64 shl 63
    ## Legacy code interprets the raw heartbeat as epoch seconds. Setting the
    ## high bit makes a capable owner's heartbeat look far in the future, so
    ## an origin/dev daemon never TTL-steals a live new owner. New code masks
    ## the bit and applies the real timestamp.
  DaemonLaunchLeaseTtlSeconds* = 5'u64
    ## Bounds a successful process launch which never reaches daemon
    ## ownership (exec/loader failure, wedged child, or a killed child).
  OwnerHeartbeatTtlSeconds* = 5.0

when shmIndexSupported:
  const DefaultSlotCap* = 4096
    ## Initial generation-0 slot capacity (AC-2b grows via new generations).

  type
    CoordCleanupAuthority = object
      claim: uint64
      start: uint64
      epoch: uint64
      ticket: uint32

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

  # --- engine read/submit front-end (AC-2c) -------------------------------
  #
  # The N build engines are lock-free READERS + MPSC-ring SUBMITTERS of the
  # shm tier (§4.3, §4.4). They NEVER write the shared table (only the daemon
  # does). The helpers below wrap the AC-2a primitives for the engine:
  #   * `readerSlotForPid` picks a reader-epoch slot without a layout change —
  #     a pid-derived index. A collision (two engines share a slot) only makes
  #     RCU reclamation MORE conservative (the daemon waits for the max of the
  #     colliding epochs), never incorrect: a reader that pins gen G keeps G
  #     mapped; and the reader's own per-process file-backed mmap stays valid
  #     regardless (POSIX inode refcount). Correctness never depends on the slot
  #     being exclusive.
  #   * `lookupMetadata` follows `currentGeneration`, (re)attaches the live
  #     segment if it advanced, publishes the reader epoch for the RCU grace
  #     window, and does a lock-free seqlock lookup — returning the inline
  #     metadata record bytes on a hit.
  #   * `submitRecord` appends a metadata record to the MPSC ring so the daemon
  #     publishes it to the table for other live builds (warm-on-record and
  #     warm-on-miss).

  proc readerSlotForPid*(): int {.inline.} =
    int(uint64(getCurrentProcessId()) mod uint64(MaxReaders))

  proc followLiveGeneration*(idx: var ShmIndex): bool =
    ## Ensure `idx.liveSeg` is attached to the control region's CURRENT
    ## generation (the daemon may have CAS-resized since we last looked). Best
    ## effort: returns true iff a valid live segment is attached afterwards.
    if not idx.available: return false
    let gen = idx.currentGeneration()
    if idx.liveSeg.isValid and idx.liveSeg.generation == gen:
      return true
    let cap = int(loadU64Relaxed(idx.ctl.base, CtlOffSegSlotCap))
    discard idx.attachGeneration(gen, cap)
    idx.liveSeg.isValid

  proc lookupMetadata*(idx: var ShmIndex; digest: openArray[byte];
      readerSlot: int; rec: var seq[byte]): bool =
    ## Lock-free shm-first read of the metadata record for `digest` (the weak
    ## fingerprint's 32 bytes). Publishes the reader epoch (RCU grace) for the
    ## generation it reads, follows a generation swap, and retries a raced slot
    ## a bounded number of times. Returns true + fills `rec` on a stable hit;
    ## false on a miss / torn-after-retries / unavailable (caller falls to
    ## Tier-1 disk — the decision is unchanged, shm is purely an accelerator).
    if not idx.available: return false
    if not idx.followLiveGeneration(): return false
    var snap: SlotSnapshot
    var tries = 0
    while tries < 64:
      # Re-follow in case the generation advanced between attempts; publish the
      # (possibly new) epoch before each read so the daemon's RCU grace pins the
      # generation we are actually reading.
      if not idx.followLiveGeneration():
        break
      idx.publishReaderEpoch(readerSlot, idx.liveSeg.generation)
      let st = idx.liveSeg.lookupSlot(digest, snap)
      case st
      of srsHit:
        rec = snap.rec
        idx.publishReaderEpoch(readerSlot, 0)     # done reading (idle)
        return true
      of srsMiss, srsProbeFull:
        idx.publishReaderEpoch(readerSlot, 0)
        return false
      of srsRetry:
        inc tries                                  # raced: retry the lookup
    idx.publishReaderEpoch(readerSlot, 0)
    false

  proc epochMillis(): uint64 {.inline.} =
    uint64(epochTime() * 1000.0)

  proc processStartToken*(pid: uint64): uint64 =
    ## Boot-local process incarnation. A PID-reused process is alive, but it is
    ## not the gate/owner incarnation that published the capability.
    if pid == 0: return 0
    when defined(linux):
      try:
        let raw = readFile("/proc/" & $pid & "/stat")
        let closeParen = raw.rfind(')')
        if closeParen >= 0 and closeParen + 2 < raw.len:
          # The suffix begins at stat field 3; starttime is field 22.
          let fields = raw[closeParen + 2 .. ^1].splitWhitespace()
          if fields.len > 19:
            return parseBiggestUInt(fields[19]).uint64
      except CatchableError:
        discard
    elif defined(macosx):
      return macProcessStartToken(cint(pid))
    0

  func coordSlotBase(slot: int): int {.inline.} =
    CtlExtCoordSlotsBase + slot * CoordSlotStride

  func coordGuardOffset(slot: int): int {.inline.} =
    CtlExtCoordGuardsBase + slot * 8

  func coordCleanupTicketOffset(slot: int): int {.inline.} =
    CtlExtCoordCleanupTicketsBase + slot * CoordCleanupTicketStride

  func coordGuardGeneration(guard: uint64): uint64 {.inline.} =
    guard and not CoordGuardStateMask

  func coordGuardState(guard: uint64): uint64 {.inline.} =
    guard and CoordGuardStateMask

  func coordGuardWithState(generation, state: uint64): uint64 {.inline.} =
    (generation and not CoordGuardStateMask) or state

  func coordTerminalState(state: uint64): bool {.inline.} =
    state == CoordGuardRetiring or state == CoordGuardReclaiming

  func coordStartFingerprint*(startToken: uint64): uint32 {.inline.} =
    ## A mismatch proves a different full process-start token. Equality is
    ## deliberately conservative: xor-fold collisions delay reclamation but
    ## can never authorize a false reclaim.
    if startToken == 0:
      return 0
    result = uint32(startToken xor (startToken shr 32))
    if result == 0:
      result = 1

  func coordClaimPid*(claim: uint64): uint64 {.inline.} =
    claim and uint64(high(uint32))

  func coordClaimStartFingerprint*(claim: uint64): uint32 {.inline.} =
    uint32(claim shr 32)

  func packCoordClaim(pid, startToken: uint64): uint64 {.inline.} =
    if pid == 0 or pid > uint64(high(uint32)):
      return 0
    (uint64(coordStartFingerprint(startToken)) shl 32) or pid

  proc nextCoordNonce*(idx: ShmIndex): uint64 =
    ## Mapping-wide full-width capability source. Zero is never published.
    if not idx.available: return 0
    result = fetchAddU64(idx.ctl.base, CtlExtOffNonceCounter, 1'u64)
    if result == 0:
      result = fetchAddU64(idx.ctl.base, CtlExtOffNonceCounter, 1'u64)

  proc coordTokenInUse(idx: ShmIndex; value: uint64): bool =
    ## Include prepared provisional tokens. A forced test nonce may therefore
    ## never alias an initializer which has not reached its commit CAS.
    if not idx.available or value == 0: return false
    let base = idx.ctl.base
    for slot in 0 ..< CoordSlotCount:
      let sb = coordSlotBase(slot)
      if loadU64Acquire(base, coordGuardOffset(slot)) != 0 and
          loadU64Acquire(base, sb + CoordSlotOffToken) == value:
        return true

  proc coordGuardGenerationInUse(idx: ShmIndex; generation: uint64): bool =
    if not idx.available or generation == 0: return false
    let base = idx.ctl.base
    for slot in 0 ..< CoordSlotCount:
      let guard = loadU64Acquire(base, coordGuardOffset(slot))
      if coordGuardGeneration(guard) == generation and guard != 0:
        return true

  proc freshCoordGuardGeneration(idx: ShmIndex): uint64 =
    ## The low bits belong exclusively to state. A live initializer is never
    ## freed until it acknowledges cancellation, and a dead initializer cannot
    ## resume, so an inactive generation cannot have a stale writer.
    var attempts = 0
    while attempts < CoordSlotCount * 3:
      inc attempts
      let nonce = idx.nextCoordNonce()
      let generation =
        (nonce shl CoordGuardStateBits) and not CoordGuardStateMask
      if generation != 0 and
          not idx.coordGuardGenerationInUse(generation):
        return generation

  func coordIdentityReadableState(state: uint64): bool {.inline.} =
    state == CoordGuardCommitted or state == CoordGuardUpdating or
      state == CoordGuardRetireRequested or coordTerminalState(state)

  proc coordResolvableGuard(base: ShmBase; slot: int;
      token: uint64): uint64 {.inline.} =
    ## Return the exact generation-tagged published guard, or zero. Updating and
    ## RetireRequested still expose immutable PID/start/token identity so a dead
    ## updater or referenced holder remains recoverable; neither state permits a
    ## new reference installation.
    if token == 0: return 0
    let guard = loadU64Acquire(base, coordGuardOffset(slot))
    if not coordIdentityReadableState(coordGuardState(guard)):
      return 0
    let sb = coordSlotBase(slot)
    if loadU64Acquire(base, sb + CoordSlotOffToken) != token:
      return 0
    # Terminal cleanup deliberately keeps immutable identity readable across
    # the Reservation->Guard free boundary. Non-terminal publication still
    # requires the exact nonzero Reservation claim.
    if not coordTerminalState(coordGuardState(guard)) and
        loadU64Acquire(base, sb + CoordSlotOffReservation) == 0:
      return 0
    guard

  proc claimLiveness(claim: uint64;
      probe: CoordClaimLivenessProbe): ProcessLiveness =
    let pid = coordClaimPid(claim)
    let fingerprint = coordClaimStartFingerprint(claim)
    var observation: CoordClaimObservation
    if probe != nil:
      observation = probe(pid)
    elif pid == 0:
      observation.liveness = plDead
    elif posix.kill(Pid(pid), cint(0)) != 0:
      observation.liveness =
        if errno == ESRCH: plDead else: plUnknown
    else:
      observation = CoordClaimObservation(liveness: plAlive,
        startToken: processStartToken(pid))
    if observation.liveness != plAlive:
      # EPERM and every other indeterminate result protect the reservation.
      return observation.liveness
    if fingerprint != 0:
      if observation.startToken == 0:
        return plUnknown
      if coordStartFingerprint(observation.startToken) != fingerprint:
        # Fingerprint mismatch proves reuse. Equality is conservative because
        # multiple full start tokens can fold to the same 32-bit value.
        return plDead
    plAlive

  proc exactCoordLiveness(identity: OwnerIdentity;
      probe: ProcessLivenessProbe): ProcessLiveness =
    if probe != nil:
      return probe(identity)
    if identity.pid == 0:
      return plDead
    if posix.kill(Pid(identity.pid), cint(0)) != 0:
      if errno == ESRCH: return plDead
      return plUnknown
    if identity.startToken != 0:
      let currentStart = processStartToken(identity.pid)
      if currentStart == 0:
        return plUnknown
      if currentStart != identity.startToken:
        return plDead
    plAlive

  proc originalCoordHolderIsCurrent(base: ShmBase; slot: int): bool =
    ## The common release path is authorized by the immutable exact process
    ## identity already stored in the slot. It needs no exceptional cleanup
    ## claim and performs no liveness probe.
    let sb = coordSlotBase(slot)
    let pid = loadU64Acquire(base, sb + CoordSlotOffPid)
    let start = loadU64Acquire(base, sb + CoordSlotOffStart)
    if pid != uint64(getCurrentProcessId()) or start == 0:
      return false
    processStartToken(pid) == start

  func cleanupTicketForEpoch(epoch: uint64): uint32 {.inline.} =
    uint32(epoch)

  proc freshCleanupEpoch(idx: ShmIndex; avoid: uint32): uint64 =
    var attempts = 0
    while attempts < CoordSlotCount * 3:
      inc attempts
      let epoch = idx.nextCoordNonce()
      let ticket = cleanupTicketForEpoch(epoch)
      if epoch != 0 and ticket != 0 and ticket != avoid:
        return epoch

  proc cleanupOwnerSnapshot(base: ShmBase): CoordCleanupAuthority =
    let claim0 = loadU64Acquire(base, CtlExtOffCleanupClaim)
    if claim0 == 0: return
    let start = loadU64Acquire(base, CtlExtOffCleanupStart)
    let startClaim = loadU64Acquire(base, CtlExtOffCleanupStartClaim)
    let epoch = loadU64Acquire(base, CtlExtOffCleanupEpoch)
    if loadU64Acquire(base, CtlExtOffCleanupClaim) != claim0:
      return
    result.claim = claim0
    result.start = if startClaim == claim0: start else: 0
    result.epoch = epoch
    result.ticket = cleanupTicketForEpoch(epoch)

  proc cleanupOwnerLiveness(owner: CoordCleanupAuthority;
      probe: CoordClaimLivenessProbe): ProcessLiveness =
    if owner.claim == 0: return plDead
    if probe != nil:
      let observation = probe(coordClaimPid(owner.claim))
      if observation.liveness != plAlive:
        return observation.liveness
      if owner.start != 0:
        if observation.startToken == 0:
          return plUnknown
        if observation.startToken != owner.start:
          return plDead
      return plAlive
    if owner.start != 0:
      return exactCoordLiveness(OwnerIdentity(
        pid: coordClaimPid(owner.claim), startToken: owner.start), nil)
    claimLiveness(owner.claim, nil)

  proc cleanupAuthorityMatches(base: ShmBase; slot: int;
      authority: CoordCleanupAuthority; requireTicket = true): bool =
    if authority.claim == 0 or authority.epoch == 0 or
        authority.ticket == 0:
      return false
    if loadU64Acquire(base, CtlExtOffCleanupClaim) != authority.claim or
        loadU64Acquire(base, CtlExtOffCleanupStart) != authority.start or
        loadU64Acquire(base, CtlExtOffCleanupStartClaim) != authority.claim or
        loadU64Acquire(base, CtlExtOffCleanupEpoch) != authority.epoch:
      return false
    not requireTicket or loadU32Acquire(base,
      coordCleanupTicketOffset(slot)) == authority.ticket

  proc anyCleanupTicket(base: ShmBase; exceptSlot = -1): bool =
    for slot in 0 ..< CoordSlotCount:
      if slot != exceptSlot and
          loadU32Acquire(base, coordCleanupTicketOffset(slot)) != 0:
        return true

  proc acquireCoordCleanup(idx: ShmIndex; slot: int;
      cleanupClaimProbe: CoordClaimLivenessProbe = nil):
      CoordCleanupAuthority =
    ## Serialize only exceptional takeover/resumption. CleanupClaim is a packed
    ## process-incarnation claim, so even a crash immediately after its CAS is
    ## recoverable. A different claimant may replace it only after definite
    ## death; equality remains collision-conservative and is never stolen.
    let base = idx.ctl.base
    let pid = uint64(getCurrentProcessId())
    let start = processStartToken(pid)
    let myClaim = packCoordClaim(pid, start)
    if myClaim == 0: return
    let ticketOffset = coordCleanupTicketOffset(slot)
    var attempts = 0
    while attempts < 16:
      inc attempts
      let existingTicket = loadU32Acquire(base, ticketOffset)
      var observed = loadU64Acquire(base, CtlExtOffCleanupClaim)
      var ownsClaim = false
      if observed == 0:
        if existingTicket != 0 or anyCleanupTicket(base, slot):
          return
        var empty = 0'u64
        ownsClaim = casU64(base, CtlExtOffCleanupClaim, empty, myClaim)
        if not ownsClaim:
          continue
      elif observed == myClaim:
        let current = cleanupOwnerSnapshot(base)
        if current.claim != myClaim:
          continue
        if current.start != 0 and current.start != start:
          # Same packed claim can be a folded-start collision. It protects the
          # earlier incarnation rather than authorizing an ambiguous takeover.
          return
        if existingTicket != 0 and current.epoch != 0 and
            current.ticket == existingTicket:
          result = current
          return
        if existingTicket != 0 or anyCleanupTicket(base, slot):
          return
        ownsClaim = true
      else:
        let previous = cleanupOwnerSnapshot(base)
        if previous.claim != observed:
          continue
        if cleanupOwnerLiveness(previous, cleanupClaimProbe) != plDead:
          return
        # Never reinterpret an equal folded claim as a new cleanup incarnation.
        if observed == myClaim:
          return
        var dead = observed
        if not casU64(base, CtlExtOffCleanupClaim, dead, myClaim):
          continue
        ownsClaim = true
      if not ownsClaim:
        continue

      let epoch = idx.freshCleanupEpoch(existingTicket)
      if epoch == 0:
        return
      let ticket = cleanupTicketForEpoch(epoch)
      storeU64Release(base, CtlExtOffCleanupStart, start)
      storeU64Release(base, CtlExtOffCleanupStartClaim, myClaim)
      storeU64Release(base, CtlExtOffCleanupEpoch, epoch)
      let authority = CoordCleanupAuthority(claim: myClaim, start: start,
        epoch: epoch, ticket: ticket)
      if not cleanupAuthorityMatches(base, slot, authority,
          requireTicket = false):
        continue
      var oldTicket = existingTicket
      if not casU32(base, ticketOffset, oldTicket, ticket):
        continue
      if cleanupAuthorityMatches(base, slot, authority):
        return authority

  proc clearCoordCleanupTicket(idx: ShmIndex; slot: int;
      authority: CoordCleanupAuthority): bool =
    let base = idx.ctl.base
    if not cleanupAuthorityMatches(base, slot, authority):
      return false
    var mine = authority.ticket
    result = casU32(base, coordCleanupTicketOffset(slot), mine, 0'u32)
    if not result or anyCleanupTicket(base):
      return
    if not cleanupAuthorityMatches(base, slot, authority,
        requireTicket = false):
      return
    # CleanupClaim is the release publication and is cleared with one exact CAS.
    # Start/association/epoch deliberately remain stale and unreachable after
    # Claim becomes zero; writing them after that CAS could erase a successor's
    # freshly-published authority. If interrupted before the CAS, the still-
    # associated process identity makes the orphan lock recoverable.
    var claim = authority.claim
    discard casU64(base, CtlExtOffCleanupClaim, claim, 0'u64)

  proc publishCoordSlotFree(idx: ShmIndex; slot: int; exactGuard,
      reservation: uint64; authority: CoordCleanupAuthority;
      afterCleanupStep: CoordCleanupHook): bool =
    ## Stale identity bytes need not be scrubbed: Guard is their publication
    ## generation, and a new initializer overwrites every field before its own
    ## commit CAS. Reservation clears first. Guard clears next. On takeover, the
    ## u32 ticket is the final physical-reuse publication.
    let base = idx.ctl.base
    if loadU64Acquire(base, coordGuardOffset(slot)) != exactGuard:
      return false
    if authority.ticket != 0 and
        not cleanupAuthorityMatches(base, slot, authority):
      return false
    let sb = coordSlotBase(slot)
    let currentReservation =
      loadU64Acquire(base, sb + CoordSlotOffReservation)
    if currentReservation != 0:
      if reservation == 0 or currentReservation != reservation:
        return false
      var mine = reservation
      if not casU64(base, sb + CoordSlotOffReservation, mine, 0'u64):
        return false
    if afterCleanupStep != nil:
      afterCleanupStep(ccsAfterReservationClear, slot, exactGuard,
        loadU64Acquire(base, sb + CoordSlotOffToken))
    var terminal = exactGuard
    if not casU64(base, coordGuardOffset(slot), terminal, 0'u64):
      return false
    if afterCleanupStep != nil:
      afterCleanupStep(ccsAfterGuardClear, slot, exactGuard,
        loadU64Acquire(base, sb + CoordSlotOffToken))
    if authority.ticket != 0:
      return idx.clearCoordCleanupTicket(slot, authority)
    true

  proc clearOwnerPublicationExact(base: ShmBase; token, pid: uint64): bool =
    ## Caller holds cleanup authority in WriterGate. Keep the exact owner
    ## publication generation nonzero until all capable and legacy fields have
    ## been retired, then publish zero last. Exact heartbeat/PID CAS operations
    ## preserve an origin/dev claimant which does not know WriterGate.
    if token == 0 or loadU64Acquire(base, CtlExtOffOwnerMagic) != token:
      return false
    let ownerHeartbeat = loadU64Acquire(base, CtlOffDaemonHeartbeat)
    storeU64Release(base, CtlExtOffOwnerPid, 0)
    storeU64Release(base, CtlExtOffOwnerNonce, 0)
    storeU64Release(base, CtlExtOffOwnerStart, 0)
    var rawPid = pid
    let clearedPid = casU64(base, CtlOffDaemonPid, rawPid, 0'u64)
    var heartbeat = ownerHeartbeat
    let clearedHeartbeat =
      casU64(base, CtlOffDaemonHeartbeat, heartbeat, 0'u64)
    if clearedPid and not clearedHeartbeat:
      var zeroPid = 0'u64
      discard casU64(base, CtlOffDaemonPid, zeroPid, pid)
    var ownerGeneration = token
    result = casU64(base, CtlExtOffOwnerMagic, ownerGeneration, 0'u64)

  proc finishCoordRetirement(idx: ShmIndex; slot: int; exactGuard,
      token, pid: uint64; suppliedAuthority = CoordCleanupAuthority();
      cleanupClaimProbe: CoordClaimLivenessProbe = nil;
      afterCleanupStep: CoordCleanupHook = nil): bool =
    ## `exactGuard` is Retiring/Reclaiming and therefore prevents every new-code
    ## reference-install path from using this token. Retire exact external
    ## references before publishing the physical slot Free. If this token is the
    ## capable owner, acquire/retain its WriterGate value as cleanup authority;
    ## a different live gate means a claimant is already transitioning ownership,
    ## so the caller must leave the slot quarantined and retry.
    let base = idx.ctl.base
    if loadU64Acquire(base, coordGuardOffset(slot)) != exactGuard:
      return false
    let sb = coordSlotBase(slot)
    let reservation =
      loadU64Acquire(base, sb + CoordSlotOffReservation)

    var authority = suppliedAuthority
    var originalFastPath = authority.ticket == 0 and
      loadU32Acquire(base, coordCleanupTicketOffset(slot)) == 0 and
      originalCoordHolderIsCurrent(base, slot)
    if authority.ticket != 0:
      if not cleanupAuthorityMatches(base, slot, authority):
        return false
    elif not originalFastPath:
      authority = idx.acquireCoordCleanup(slot, cleanupClaimProbe)
      if authority.ticket == 0:
        return false
      if afterCleanupStep != nil:
        afterCleanupStep(ccsCleanupClaimed, slot, exactGuard, token)
    template stillAuthorized(): bool =
      originalFastPath or cleanupAuthorityMatches(base, slot, authority)

    if not stillAuthorized():
      return false
    if token == 0:
      return idx.publishCoordSlotFree(slot, exactGuard, reservation, authority,
        afterCleanupStep)

    var ownsPublication =
      loadU64Acquire(base, CtlExtOffOwnerMagic) == token
    var gate = loadU64Acquire(base, CtlExtOffWriterGate)
    if ownsPublication and gate != token:
      if gate != 0:
        return false
      var empty = 0'u64
      if not casU64(base, CtlExtOffWriterGate, empty, token):
        return false
      gate = token
      # Owner publication may have changed only to zero while the gate was
      # acquired; a different owner generation is never ours to mutate.
      ownsPublication =
        loadU64Acquire(base, CtlExtOffOwnerMagic) == token

    # Once the exact generation is terminal, no conforming producer can publish
    # a new lease/gate/owner reference. Clear each existing reference by exact
    # CAS; the launch-start token is diagnostic only but is scrubbed exactly too.
    var lease = token
    discard casU64(base, CtlExtOffLaunchLease, lease, 0'u64)
    var launchMirror = token
    discard casU64(base, CtlExtOffLaunchStartedToken, launchMirror, 0'u64)

    if loadU64Acquire(base, CtlExtOffOwnerMagic) == token:
      if loadU64Acquire(base, CtlExtOffWriterGate) != token or
          not stillAuthorized():
        return false
      if not clearOwnerPublicationExact(base, token, pid):
        return false

    if loadU64Acquire(base, CtlExtOffLaunchLease) == token or
        loadU64Acquire(base, CtlExtOffOwnerMagic) == token:
      return false
    gate = loadU64Acquire(base, CtlExtOffWriterGate)
    if gate != 0 and gate != token and ownsPublication:
      return false

    # WriterGate is the last EXTERNAL reference. Identity, Reservation, terminal
    # Guard, and the exceptional cleanup ticket remain resolvable across this
    # CAS, so interruption can never create an ownerless nonzero gate.
    if gate == token:
      if afterCleanupStep != nil:
        afterCleanupStep(ccsBeforeWriterGateClear, slot, exactGuard, token)
      if not stillAuthorized():
        return false
      var mine = token
      if not casU64(base, CtlExtOffWriterGate, mine, 0'u64):
        return false
    if afterCleanupStep != nil:
      afterCleanupStep(ccsAfterWriterGateClear, slot, exactGuard, token)
    if loadU64Acquire(base, CtlExtOffWriterGate) == token:
      return false

    idx.publishCoordSlotFree(slot, exactGuard, reservation, authority,
      afterCleanupStep)

  proc finishTicketedCoordFree(idx: ShmIndex; slot: int; token: uint64;
      cleanupClaimProbe: CoordClaimLivenessProbe;
      afterCleanupStep: CoordCleanupHook): bool =
    ## Resume the final Guard->ticket boundary. Guard and Reservation are already
    ## zero, but the nonzero ticket still excludes every new allocator.
    let base = idx.ctl.base
    if loadU64Acquire(base, coordGuardOffset(slot)) != 0 or
        loadU64Acquire(base,
          coordSlotBase(slot) + CoordSlotOffReservation) != 0:
      return false
    let authority = idx.acquireCoordCleanup(slot, cleanupClaimProbe)
    if authority.ticket == 0:
      return false
    if afterCleanupStep != nil:
      afterCleanupStep(ccsCleanupClaimed, slot, 0, token)
    if token != 0 and (
        loadU64Acquire(base, CtlExtOffWriterGate) == token or
        loadU64Acquire(base, CtlExtOffLaunchLease) == token or
        loadU64Acquire(base, CtlExtOffOwnerMagic) == token):
      return false
    idx.clearCoordCleanupTicket(slot, authority)

  proc reclaimCoordSlot(idx: ShmIndex; slot: int;
      identityProbe: ProcessLivenessProbe;
      claimProbe: CoordClaimLivenessProbe;
      cleanupClaimProbe: CoordClaimLivenessProbe;
      afterCleanupStep: CoordCleanupHook): bool =
    ## Reclaim only after definite death. A live/EPERM/unknown provisional
    ## initializer remains quarantined, so no stale ordinary store can overlap
    ## a successor. Commit/reclaim race on the exact generation-tagged guard.
    let base = idx.ctl.base
    let sb = coordSlotBase(slot)
    let guard = loadU64Acquire(base, coordGuardOffset(slot))
    let state = coordGuardState(guard)
    let cleanupTicket =
      loadU32Acquire(base, coordCleanupTicketOffset(slot))
    let claim = loadU64Acquire(base, sb + CoordSlotOffReservation)
    let token0 = loadU64Acquire(base, sb + CoordSlotOffToken)

    # Guard was already invalidated, but a takeover ticket still publishes the
    # final reuse quarantine. The exact global claimant (or a definite-death
    # successor) is the only process allowed to clear it.
    if guard == 0 and claim == 0 and cleanupTicket != 0:
      return idx.finishTicketedCoordFree(slot, token0, cleanupClaimProbe,
        afterCleanupStep)

    # Retiring/Reclaiming is a durable resumable state, not a rejection. A
    # ticketed terminal follows cleanup-claim liveness. An unticketed terminal
    # may be resumed by its exact original process without probing; otherwise
    # only definite original-holder death authorizes takeover.
    if coordTerminalState(state):
      let pid = loadU64Acquire(base, sb + CoordSlotOffPid)
      let start = loadU64Acquire(base, sb + CoordSlotOffStart)
      if loadU64Acquire(base, coordGuardOffset(slot)) != guard or
          loadU64Acquire(base, sb + CoordSlotOffToken) != token0:
        return false
      if cleanupTicket != 0 or originalCoordHolderIsCurrent(base, slot):
        return idx.finishCoordRetirement(slot, guard, token0, pid,
          cleanupClaimProbe = cleanupClaimProbe,
          afterCleanupStep = afterCleanupStep)
      let liveness =
        if pid != 0 and start != 0:
          exactCoordLiveness(
            OwnerIdentity(pid: pid, startToken: start), identityProbe)
        elif claim != 0:
          claimLiveness(claim, claimProbe)
        else:
          plUnknown
      if liveness != plDead:
        return false
      return idx.finishCoordRetirement(slot, guard, token0, pid,
        cleanupClaimProbe = cleanupClaimProbe,
        afterCleanupStep = afterCleanupStep)

    if claim == 0:
      return false
    let pid0 = loadU64Acquire(base, sb + CoordSlotOffPid)
    let start0 = loadU64Acquire(base, sb + CoordSlotOffStart)
    let started0 = loadU64Acquire(base, sb + CoordSlotOffStarted)
    let flags0 = loadU64Acquire(base, sb + CoordSlotOffFlags)
    let gateStarted0 = loadU64Acquire(base, sb + CoordSlotOffGateStarted)
    let token1 = loadU64Acquire(base, sb + CoordSlotOffToken)
    if token1 != token0 or
        loadU64Acquire(base, coordGuardOffset(slot)) != guard or
        loadU64Acquire(base, sb + CoordSlotOffReservation) != claim:
      return false
    if loadU64Acquire(base, sb + CoordSlotOffPid) != pid0 or
        loadU64Acquire(base, sb + CoordSlotOffStart) != start0 or
        loadU64Acquire(base, sb + CoordSlotOffStarted) != started0 or
        loadU64Acquire(base, sb + CoordSlotOffFlags) != flags0 or
        loadU64Acquire(base, sb + CoordSlotOffGateStarted) != gateStarted0 or
        loadU64Acquire(base, sb + CoordSlotOffToken) != token0 or
        loadU64Acquire(base, coordGuardOffset(slot)) != guard or
        loadU64Acquire(base, sb + CoordSlotOffReservation) != claim:
      return false

    let liveness =
      if guard != 0 and pid0 != 0 and start0 != 0:
        exactCoordLiveness(
          OwnerIdentity(pid: pid0, startToken: start0), identityProbe)
      else:
        claimLiveness(claim, claimProbe)
    if liveness != plDead:
      return false

    let reclaiming =
      if guard == 0:
        let generation = idx.freshCoordGuardGeneration()
        if generation == 0: return false
        coordGuardWithState(generation, CoordGuardReclaiming)
      else:
        if state != CoordGuardReserved and state != CoordGuardCancelled and
            state != CoordGuardCommitted and state != CoordGuardUpdating and
            state != CoordGuardRetireRequested:
          return false
        coordGuardWithState(coordGuardGeneration(guard),
          CoordGuardReclaiming)
    var exact = guard
    if not casU64(base, coordGuardOffset(slot), exact, reclaiming):
      return false
    let cleanupToken =
      if state == CoordGuardCommitted or state == CoordGuardUpdating or
          state == CoordGuardRetireRequested:
        token0
      else:
        0'u64
    if afterCleanupStep != nil:
      afterCleanupStep(ccsTerminalPublished, slot, reclaiming, cleanupToken)
    # Terminal state is never rolled back. Every failure/interruption below is
    # resumed by a later saturation pass under the exact same generation.
    idx.finishCoordRetirement(slot, reclaiming, cleanupToken, pid0,
      cleanupClaimProbe = cleanupClaimProbe,
      afterCleanupStep = afterCleanupStep)

  proc reclaimAbandonedCoordReservations*(idx: ShmIndex;
      identityProbe: ProcessLivenessProbe = nil;
      claimProbe: CoordClaimLivenessProbe = nil;
      cleanupClaimProbe: CoordClaimLivenessProbe = nil;
      afterCleanupStep: CoordCleanupHook = nil): int =
    ## Bounded saturation repair. The normal free-slot allocation path does not
    ## enter this pass and therefore adds no per-follower process probes.
    if not idx.available: return 0
    for slot in 0 ..< CoordSlotCount:
      if idx.reclaimCoordSlot(slot, identityProbe, claimProbe,
          cleanupClaimProbe,
          afterCleanupStep):
        inc result

  proc coordIdentity*(idx: ShmIndex; token: uint64): OwnerIdentity =
    ## Resolve a full-width capability to its immutable identity record.
    if not idx.available or token == 0: return
    let base = idx.ctl.base
    for slot in 0 ..< CoordSlotCount:
      let sb = coordSlotBase(slot)
      let guard = coordResolvableGuard(base, slot, token)
      if guard == 0:
        continue
      let pid = loadU64Acquire(base, sb + CoordSlotOffPid)
      let start = loadU64Acquire(base, sb + CoordSlotOffStart)
      let tokenAgain = loadU64Acquire(base, sb + CoordSlotOffToken)
      let guardAgain = loadU64Acquire(base, coordGuardOffset(slot))
      if tokenAgain == token and guardAgain == guard and pid != 0:
        return OwnerIdentity(pid: pid, startToken: start, nonce: token)

  proc coordStarted*(idx: ShmIndex; token: uint64): uint64 =
    if not idx.available or token == 0: return 0
    let base = idx.ctl.base
    for slot in 0 ..< CoordSlotCount:
      let sb = coordSlotBase(slot)
      let guard = coordResolvableGuard(base, slot, token)
      if guard != 0:
        let started = loadU64Acquire(base, sb + CoordSlotOffStarted)
        if loadU64Acquire(base, coordGuardOffset(slot)) == guard and
            loadU64Acquire(base, sb + CoordSlotOffToken) == token:
          return started

  proc coordFlags*(idx: ShmIndex; token: uint64): uint64 =
    if not idx.available or token == 0: return 0
    let base = idx.ctl.base
    for slot in 0 ..< CoordSlotCount:
      let sb = coordSlotBase(slot)
      let guard = coordResolvableGuard(base, slot, token)
      if guard != 0:
        let flags = loadU64Acquire(base, sb + CoordSlotOffFlags)
        if loadU64Acquire(base, coordGuardOffset(slot)) == guard and
            loadU64Acquire(base, sb + CoordSlotOffToken) == token:
          return flags

  proc coordGateStarted*(idx: ShmIndex; token: uint64): uint64 =
    if not idx.available or token == 0: return 0
    let base = idx.ctl.base
    for slot in 0 ..< CoordSlotCount:
      let sb = coordSlotBase(slot)
      let guard = coordResolvableGuard(base, slot, token)
      if guard != 0:
        let started = loadU64Acquire(base, sb + CoordSlotOffGateStarted)
        if loadU64Acquire(base, coordGuardOffset(slot)) == guard and
            loadU64Acquire(base, sb + CoordSlotOffToken) == token:
          return started

  proc finishCoordFieldUpdate(idx: ShmIndex; slot: int; updating,
      token, pid: uint64): bool =
    ## Publish an authorized one-word update, or acknowledge an exact release
    ## request which raced it. RetireRequested never becomes reusable until this
    ## updater has stopped writing and exact-reference cleanup has completed.
    let base = idx.ctl.base
    let generation = coordGuardGeneration(updating)
    let committed = coordGuardWithState(generation, CoordGuardCommitted)
    var expected = updating
    if casU64(base, coordGuardOffset(slot), expected, committed):
      return true
    let requested =
      coordGuardWithState(generation, CoordGuardRetireRequested)
    if expected != requested:
      return false
    let retiring = coordGuardWithState(generation, CoordGuardRetiring)
    var exact = requested
    if not casU64(base, coordGuardOffset(slot), exact, retiring):
      return false
    idx.finishCoordRetirement(slot, retiring, token, pid)

  proc setCoordField(idx: ShmIndex; token: uint64; fieldOffset: int;
      value: uint64; afterUpdateLock: CoordUpdateHook = nil): bool =
    ## Serialize a mutable slot-field store with release/reclaim/reuse using the
    ## exact guard generation. Post-store validation alone is insufficient: a
    ## retired slot could already have been recycled before a stale store lands.
    if not idx.available or token == 0: return false
    let base = idx.ctl.base
    for slot in 0 ..< CoordSlotCount:
      let sb = coordSlotBase(slot)
      let guard = coordResolvableGuard(base, slot, token)
      if guard == 0 or coordGuardState(guard) != CoordGuardCommitted:
        continue
      let updating = coordGuardWithState(coordGuardGeneration(guard),
        CoordGuardUpdating)
      var exact = guard
      if not casU64(base, coordGuardOffset(slot), exact, updating):
        continue
      try:
        if afterUpdateLock != nil:
          afterUpdateLock(token)
        storeU64Release(base, sb + fieldOffset, value)
      except CatchableError:
        discard idx.finishCoordFieldUpdate(slot, updating, token,
          loadU64Acquire(base, sb + CoordSlotOffPid))
        raise
      return idx.finishCoordFieldUpdate(slot, updating, token,
        loadU64Acquire(base, sb + CoordSlotOffPid))

  proc setCoordFlags*(idx: ShmIndex; token, flags: uint64;
      afterUpdateLock: CoordUpdateHook = nil): bool =
    idx.setCoordField(token, CoordSlotOffFlags, flags, afterUpdateLock)

  proc setCoordGateStarted(idx: ShmIndex; token, started: uint64;
      afterUpdateLock: CoordUpdateHook = nil): bool =
    idx.setCoordField(token, CoordSlotOffGateStarted, started, afterUpdateLock)

  proc finishOwnCoordReservation(idx: ShmIndex;
      reservation: CoordReservation): bool =
    ## Called only by the initializer after it has observed its own exact guard
    ## cancelled or its packed claim revoked. It is the last possible ordinary
    ## writer, so after winning Reserved/Cancelled -> Reclaiming it can scrub
    ## and publish Free safely.
    let reserved = coordGuardWithState(reservation.guardGeneration,
      CoordGuardReserved)
    let cancelled = coordGuardWithState(reservation.guardGeneration,
      CoordGuardCancelled)
    let reclaiming = coordGuardWithState(reservation.guardGeneration,
      CoordGuardReclaiming)
    var expected = cancelled
    if not casU64(idx.ctl.base, coordGuardOffset(reservation.slot), expected,
        reclaiming):
      expected = reserved
      if not casU64(idx.ctl.base, coordGuardOffset(reservation.slot), expected,
          reclaiming):
        return false
    let sb = coordSlotBase(reservation.slot)
    idx.finishCoordRetirement(reservation.slot, reclaiming, 0,
      loadU64Acquire(idx.ctl.base, sb + CoordSlotOffPid))

  proc cancelCoordReservation*(idx: ShmIndex;
      reservation: CoordReservation): bool =
    ## Revoke one live provisional generation without reusing its slot. The
    ## initializer must observe this exact state and acknowledge it; if it dies,
    ## definite-death recovery performs the cleanup.
    if not idx.available or reservation.slot < 0 or
        reservation.slot >= CoordSlotCount or reservation.claim == 0 or
        reservation.guardGeneration == 0:
      return false
    let base = idx.ctl.base
    let sb = coordSlotBase(reservation.slot)
    if loadU64Acquire(base, sb + CoordSlotOffReservation) !=
        reservation.claim:
      return false
    let reserved = coordGuardWithState(reservation.guardGeneration,
      CoordGuardReserved)
    let cancelled = coordGuardWithState(reservation.guardGeneration,
      CoordGuardCancelled)
    var expected = reserved
    casU64(base, coordGuardOffset(reservation.slot), expected, cancelled)

  proc makeCoordToken*(idx: ShmIndex;
      pid = uint64(getCurrentProcessId()); startToken = 0'u64;
      forcedNonce = 0'u64; startedSeconds = 0'u64;
      afterReservation: CoordReservationHook = nil;
      afterIdentityWrite: CoordReservationHook = nil): uint64 =
    ## Allocate one exact capability record with an explicit provisional ->
    ## committed CAS. The capability itself is the full u64 nonce; no
    ## PID/nonce bit packing exists.
    if not idx.available or pid == 0: return 0
    let token = if forcedNonce == 0: idx.nextCoordNonce() else: forcedNonce
    if token == 0 or idx.coordTokenInUse(token):
      return 0
    let start =
      if startToken != 0: startToken
      elif pid == uint64(getCurrentProcessId()): processStartToken(pid)
      else: 0
    let claim = packCoordClaim(pid, start)
    if claim == 0: return 0
    let generation = idx.freshCoordGuardGeneration()
    if generation == 0: return 0
    let reserved = coordGuardWithState(generation, CoordGuardReserved)
    let committed = coordGuardWithState(generation, CoordGuardCommitted)
    let started =
      if startedSeconds == 0: uint64(epochTime()) else: startedSeconds
    let base = idx.ctl.base
    for allocationPass in 0 .. 1:
      for slot in 0 ..< CoordSlotCount:
        let sb = coordSlotBase(slot)
        if loadU32Acquire(base, coordCleanupTicketOffset(slot)) != 0 or
            loadU64Acquire(base, coordGuardOffset(slot)) != 0:
          continue
        var empty = 0'u64
        if not casU64(base, sb + CoordSlotOffReservation, empty, claim):
          continue
        if loadU32Acquire(base, coordCleanupTicketOffset(slot)) != 0 or
            loadU64Acquire(base, coordGuardOffset(slot)) != 0:
          var mine = claim
          discard casU64(base, sb + CoordSlotOffReservation, mine, 0'u64)
          continue
        let reservation = CoordReservation(slot: slot, claim: claim,
          guardGeneration: generation)
        try:
          if afterReservation != nil:
            afterReservation(reservation)
        except CatchableError:
          # The hook runs before Guard publication and before any identity
          # write. This initializer therefore still owns the exact packed
          # claim and can roll it back directly without exposing a reusable
          # slot to a stale writer.
          var mine = claim
          discard casU64(base, sb + CoordSlotOffReservation, mine, 0'u64)
          raise
        if loadU64Acquire(base, sb + CoordSlotOffReservation) != claim:
          return 0
        var guardEmpty = 0'u64
        if not casU64(base, coordGuardOffset(slot), guardEmpty, reserved):
          if guardEmpty == coordGuardWithState(generation,
              CoordGuardCancelled):
            discard idx.finishOwnCoordReservation(reservation)
          else:
            var mine = claim
            discard casU64(base, sb + CoordSlotOffReservation, mine, 0'u64)
          return 0
        template stillReserved(): bool =
          loadU64Acquire(base, coordGuardOffset(slot)) == reserved and
            loadU64Acquire(base, sb + CoordSlotOffReservation) == claim
        template abortCancelled(): untyped =
          discard idx.finishOwnCoordReservation(reservation)
          return 0
        if not stillReserved(): abortCancelled()
        storeU64Release(base, sb + CoordSlotOffPid, pid)
        if afterIdentityWrite != nil:
          afterIdentityWrite(reservation)
        if not stillReserved(): abortCancelled()
        storeU64Release(base, sb + CoordSlotOffStart, start)
        if not stillReserved(): abortCancelled()
        storeU64Release(base, sb + CoordSlotOffStarted, started)
        if not stillReserved(): abortCancelled()
        storeU64Release(base, sb + CoordSlotOffFlags, 0)
        if not stillReserved(): abortCancelled()
        storeU64Release(base, sb + CoordSlotOffGateStarted, 0)
        if not stillReserved(): abortCancelled()
        # Token remains invisible until the exact generation commit CAS.
        storeU64Release(base, sb + CoordSlotOffToken, token)
        if not stillReserved(): abortCancelled()
        var mine = reserved
        if casU64(base, coordGuardOffset(slot), mine, committed):
          return token
        if mine == coordGuardWithState(generation, CoordGuardCancelled):
          discard idx.finishOwnCoordReservation(reservation)
        return 0
      if allocationPass == 0:
        discard idx.reclaimAbandonedCoordReservations()
    0

  proc releaseCoordToken*(idx: ShmIndex; token: uint64;
      cleanupClaimProbe: CoordClaimLivenessProbe = nil;
      afterCleanupStep: CoordCleanupHook = nil): bool =
    ## Retire exactly one capability generation and all of its exact shared
    ## references. If a mutable field updater owns this generation, request
    ## retirement and return false: the updater must acknowledge before the slot
    ## is reusable, so release never reports a still-ambiguous record complete.
    if not idx.available or token == 0: return false
    let base = idx.ctl.base
    for slot in 0 ..< CoordSlotCount:
      let guard = coordResolvableGuard(base, slot, token)
      if guard == 0:
        continue
      let generation = coordGuardGeneration(guard)
      case coordGuardState(guard)
      of CoordGuardCommitted:
        let retiring = coordGuardWithState(generation, CoordGuardRetiring)
        var exact = guard
        if not casU64(base, coordGuardOffset(slot), exact, retiring):
          continue
        let sb = coordSlotBase(slot)
        if afterCleanupStep != nil:
          afterCleanupStep(ccsTerminalPublished, slot, retiring, token)
        return idx.finishCoordRetirement(slot, retiring, token,
          loadU64Acquire(base, sb + CoordSlotOffPid),
          cleanupClaimProbe = cleanupClaimProbe,
          afterCleanupStep = afterCleanupStep)
      of CoordGuardUpdating:
        let requested =
          coordGuardWithState(generation, CoordGuardRetireRequested)
        var exact = guard
        discard casU64(base, coordGuardOffset(slot), exact, requested)
        return false
      of CoordGuardRetireRequested:
        return false
      of CoordGuardRetiring, CoordGuardReclaiming:
        let sb = coordSlotBase(slot)
        return idx.finishCoordRetirement(slot, guard, token,
          loadU64Acquire(base, sb + CoordSlotOffPid),
          cleanupClaimProbe = cleanupClaimProbe,
          afterCleanupStep = afterCleanupStep)
      else:
        continue

  proc coordTokenPid*(idx: ShmIndex; token: uint64): uint64 {.inline.} =
    idx.coordIdentity(token).pid

  proc osProcessLiveness*(identity: OwnerIdentity): ProcessLiveness =
    ## Only ESRCH or an exact start-token mismatch is authoritative death.
    ## EPERM and every indeterminate result remain unknown/alive.
    if identity.pid == 0:
      return plDead
    if posix.kill(Pid(identity.pid), cint(0)) != 0:
      if errno == ESRCH: return plDead
      return plUnknown
    if identity.startToken != 0:
      let currentStart = processStartToken(identity.pid)
      if currentStart == 0:
        return plUnknown
      if currentStart != identity.startToken:
        return plDead
    plAlive

  proc osProcessLiveness*(pid: uint64): ProcessLiveness =
    osProcessLiveness(OwnerIdentity(pid: pid))

  proc probeProcess*(idx: ShmIndex; identity: OwnerIdentity;
      probe: ProcessLivenessProbe = nil): ProcessLiveness =
    if idx.available:
      discard fetchAddU64(idx.ctl.base, CtlExtOffOsProbeCount, 1'u64)
    if probe != nil:
      return probe(identity)
    osProcessLiveness(identity)

  proc probeProcess*(idx: ShmIndex; pid: uint64;
      probe: ProcessLivenessProbe = nil): ProcessLiveness =
    idx.probeProcess(OwnerIdentity(pid: pid), probe)

  proc rawOwnerPid*(idx: ShmIndex): uint64 =
    if not idx.available: return 0
    loadU64Acquire(idx.ctl.base, CtlOffDaemonPid)

  proc rawOwnerHeartbeat*(idx: ShmIndex): uint64 =
    if not idx.available: return 0
    loadU64Acquire(idx.ctl.base, CtlOffDaemonHeartbeat)

  proc heartbeatTimestamp*(raw: uint64): uint64 {.inline.} =
    raw and not CapableHeartbeatBit

  proc heartbeatIsCapable*(raw: uint64): bool {.inline.} =
    (raw and CapableHeartbeatBit) != 0

  proc heartbeatIsFresh*(idx: ShmIndex; nowSeconds = 0'u64): bool =
    let raw = idx.rawOwnerHeartbeat()
    let stamp = heartbeatTimestamp(raw)
    if stamp == 0: return false
    let now = if nowSeconds == 0: uint64(epochTime()) else: nowSeconds
    now <= stamp + uint64(OwnerHeartbeatTtlSeconds)

  proc currentOwnerIdentity*(idx: ShmIndex;
      afterGenerationRead: OwnerSnapshotHook = nil): OwnerIdentity =
    ## Acquire-published capable identity. OwnerMagic carries the exact full-width
    ## owner nonce, not a fixed sentinel, so clear/reassign cannot ABA a reader
    ## across a same-PID/same-start takeover.
    if not idx.available: return
    let base = idx.ctl.base
    let generation0 = loadU64Acquire(base, CtlExtOffOwnerMagic)
    if generation0 == 0: return
    if afterGenerationRead != nil:
      afterGenerationRead(generation0)
    let pid = loadU64Acquire(base, CtlExtOffOwnerPid)
    let nonce = loadU64Acquire(base, CtlExtOffOwnerNonce)
    let start = loadU64Acquire(base, CtlExtOffOwnerStart)
    let rawPid = loadU64Acquire(base, CtlOffDaemonPid)
    let hb = loadU64Acquire(base, CtlOffDaemonHeartbeat)
    let generation1 = loadU64Acquire(base, CtlExtOffOwnerMagic)
    if generation1 == generation0 and nonce == generation0 and pid != 0 and
        pid == rawPid and heartbeatIsCapable(hb):
      result = OwnerIdentity(pid: pid, startToken: start, nonce: nonce)

  proc isCapableOwner*(idx: ShmIndex): bool =
    idx.currentOwnerIdentity().nonce != 0

  proc publishOwnerIdentity*(idx: ShmIndex; owner: OwnerIdentity) =
    ## Caller holds the writer/takeover gate. The exact nonce is cleared while
    ## fields are replaced and release-published last as the snapshot generation.
    let base = idx.ctl.base
    storeU64Release(base, CtlExtOffOwnerMagic, 0)
    storeU64Release(base, CtlExtOffOwnerPid, owner.pid)
    storeU64Release(base, CtlExtOffOwnerNonce, owner.nonce)
    storeU64Release(base, CtlExtOffOwnerStart, owner.startToken)
    storeU64Release(base, CtlExtOffOwnerMagic, owner.nonce)

  proc clearOwnerIdentity*(idx: ShmIndex; owner: OwnerIdentity): bool =
    ## Caller holds this owner's exact writer gate. Keep its publication
    ## generation nonzero until capable fields and legacy PID/heartbeat are
    ## retired; zero is the final publication.
    if not idx.available or owner.nonce == 0: return false
    clearOwnerPublicationExact(idx.ctl.base, owner.nonce, owner.pid)

  proc publishCapableHeartbeat*(idx: ShmIndex; nowSeconds = 0'u64) =
    ## Caller holds the writer gate and has revalidated its exact owner token.
    let now = if nowSeconds == 0: uint64(epochTime()) else: nowSeconds
    storeU64Release(idx.ctl.base, CtlOffDaemonHeartbeat,
      CapableHeartbeatBit or now)

  proc ownerLooksStale*(idx: ShmIndex; nowSeconds = 0'u64;
      probe: ProcessLivenessProbe = nil): bool =
    ## New code never TTL-steals an alive legacy owner. A capable owner may be
    ## replaced after its decoded heartbeat expires, but only by a claimant that
    ## first acquires the same writer gate; a paused in-gate owner is therefore
    ## never stolen from. Healthy freshness is checked before any kill(2).
    if not idx.available: return false
    let pid = idx.rawOwnerPid()
    if pid == 0: return true
    if idx.heartbeatIsFresh(nowSeconds): return false
    if idx.isCapableOwner(): return true
    idx.probeProcess(OwnerIdentity(pid: pid), probe) == plDead

  proc freshLaunchGateAssociation(idx: ShmIndex; token,
      nowSeconds: uint64;
      afterAssociationRead: CoordUpdateHook = nil): bool =
    ## Recognize only one coherent, previously committed launch capability.
    ## Committed -> Updating -> Committed changes only mutable diagnostics;
    ## Reservation and immutable PID/start/token identity remain published for
    ## the same guard generation throughout. The writer-gate CAS caller
    ## supplies the exact token it observed, and this snapshot proves that
    ## token is still both the gate holder and the unexpired launch lease.
    ## Every association field, the acceptable guard generation/state, gate,
    ## and lease are revalidated so reassignment or retirement falls through to
    ## ordinary liveness/recovery instead of suppressing its probe.
    if not idx.available or token == 0: return false
    let base = idx.ctl.base
    if loadU64Acquire(base, CtlExtOffWriterGate) != token or
        loadU64Acquire(base, CtlExtOffLaunchLease) != token:
      return false
    for slot in 0 ..< CoordSlotCount:
      let sb = coordSlotBase(slot)
      let guard = loadU64Acquire(base, coordGuardOffset(slot))
      let state = coordGuardState(guard)
      if state != CoordGuardCommitted and state != CoordGuardUpdating:
        continue
      let reservation =
        loadU64Acquire(base, sb + CoordSlotOffReservation)
      let pid = loadU64Acquire(base, sb + CoordSlotOffPid)
      let start = loadU64Acquire(base, sb + CoordSlotOffStart)
      let started = loadU64Acquire(base, sb + CoordSlotOffStarted)
      if reservation == 0 or pid == 0 or started == 0 or
          loadU64Acquire(base, sb + CoordSlotOffToken) != token:
        continue
      if nowSeconds > started + DaemonLaunchLeaseTtlSeconds:
        return false
      if afterAssociationRead != nil:
        afterAssociationRead(token)
      let revalidatedGuard =
        loadU64Acquire(base, coordGuardOffset(slot))
      let revalidatedState = coordGuardState(revalidatedGuard)
      if coordGuardGeneration(revalidatedGuard) !=
          coordGuardGeneration(guard) or
          (revalidatedState != CoordGuardCommitted and
            revalidatedState != CoordGuardUpdating):
        return false
      if loadU64Acquire(base, sb + CoordSlotOffReservation) != reservation or
          loadU64Acquire(base, sb + CoordSlotOffPid) != pid or
          loadU64Acquire(base, sb + CoordSlotOffStart) != start or
          loadU64Acquire(base, sb + CoordSlotOffStarted) != started or
          loadU64Acquire(base, sb + CoordSlotOffToken) != token:
        return false
      return loadU64Acquire(base, CtlExtOffWriterGate) == token and
        loadU64Acquire(base, CtlExtOffLaunchLease) == token

  proc tryAcquireWriterGate*(idx: ShmIndex; token: uint64;
      probe: ProcessLivenessProbe = nil; atSeconds = 0'u64;
      recoveryDelaySeconds = 0'u64;
      afterGateUpdateLock: CoordUpdateHook = nil;
      afterLaunchAssociationRead: CoordUpdateHook = nil): bool =
    ## Exact cross-process mutation/takeover gate. A dead holder is reclaimed
    ## only after a definite ESRCH; EPERM/unknown and an alive paused process
    ## retain the gate.
    if not idx.available or token == 0: return false
    let base = idx.ctl.base
    let now = if atSeconds == 0: uint64(epochTime()) else: atSeconds
    if not idx.setCoordGateStarted(token, now, afterGateUpdateLock):
      return false
    var attempts = 0
    while attempts < 16:
      inc attempts
      var empty = 0'u64
      if casU64(base, CtlExtOffWriterGate, empty, token):
        # Release/reclaim may have raced after the field-update generation was
        # committed. Never leave a token installed unless its exact record is
        # still published; undo only our exact CAS if validation lost.
        if idx.coordIdentity(token).nonce == token:
          return true
        var mine = token
        discard casU64(base, CtlExtOffWriterGate, mine, 0'u64)
        return false
      let observed = empty
      if observed == token:
        return false
      var terminalSlot = -1
      for slot in 0 ..< CoordSlotCount:
        let holderGuard = coordResolvableGuard(base, slot, observed)
        if holderGuard != 0 and
            coordTerminalState(coordGuardState(holderGuard)):
          terminalSlot = slot
          break
      if terminalSlot >= 0:
        # A terminal holder may already have a live cleanup successor. Never
        # clear its gate merely because the ORIGINAL token owner is dead.
        # Terminal recovery arbitrates through the exact cleanup ticket/claim
        # and clears WriterGate while identity is still resolvable.
        discard idx.reclaimCoordSlot(terminalSlot, probe, nil, nil, nil)
        if loadU64Acquire(base, CtlExtOffWriterGate) == observed:
          return false
        continue
      let holder = idx.coordIdentity(observed)
      let holderStarted = idx.coordGateStarted(observed)
      if holder.nonce == 0:
        return false
      # `startProcess` may schedule the newly spawned daemon before its live
      # launcher returns and releases this exact authorization gate. The
      # launch lease is an immutable, full-width association with its own TTL:
      # while that association is still current and fresh, gate contention is
      # known launch progress rather than evidence of an abandoned holder.
      # Recheck the exact lease after resolving the holder so reassignment
      # cannot suppress recovery for an unrelated gate generation.
      if idx.freshLaunchGateAssociation(observed, now,
          afterLaunchAssociationRead):
        return false
      if recoveryDelaySeconds != 0 and holderStarted != 0 and
          now <= holderStarted + recoveryDelaySeconds:
        return false
      if idx.probeProcess(holder, probe) != plDead:
        return false
      # Retire under the still-resolvable exact gate. finishCoordRetirement
      # clears every owner/lease reference and WriterGate last.
      if not idx.releaseCoordToken(observed):
        return false
    false

  proc releaseWriterGate*(idx: ShmIndex; token: uint64): bool =
    if not idx.available or token == 0: return false
    var expected = token
    casU64(idx.ctl.base, CtlExtOffWriterGate, expected, 0'u64)

  proc writerGateToken*(idx: ShmIndex): uint64 =
    if not idx.available: return 0
    loadU64Acquire(idx.ctl.base, CtlExtOffWriterGate)

  proc workSequence*(idx: ShmIndex): uint64 =
    if not idx.available: return 0
    loadU64Acquire(idx.ctl.base, CtlExtOffWorkSequence)

  proc workAckSequence*(idx: ShmIndex): uint64 =
    if not idx.available: return 0
    loadU64Acquire(idx.ctl.base, CtlExtOffWorkAck)

  proc workOutstanding*(idx: ShmIndex): bool =
    idx.workAckSequence() != idx.workSequence()

  func workAssociationOffsets(sequence: uint64):
      tuple[target, started, previous, ack: int] =
    if ((sequence shr 1) and 1'u64) == 0:
      (CtlExtOffWorkStartSeq, CtlExtOffWorkStartedMs,
        CtlExtOffWorkPreviousSeq, CtlExtOffWorkAckAtStart)
    else:
      (CtlExtOffWorkStartSeq1, CtlExtOffWorkStartedMs1,
        CtlExtOffWorkPreviousSeq1, CtlExtOffWorkAckAtStart1)

  proc workAssociation*(idx: ShmIndex;
      sequence = high(uint64)): WorkAssociation =
    if not idx.available: return
    let wanted =
      if sequence == high(uint64): idx.workSequence() else: sequence
    if wanted == 0: return
    let offs = workAssociationOffsets(wanted)
    let base = idx.ctl.base
    if loadU64Acquire(base, offs.target) != wanted: return
    result.sequence = wanted
    result.startedMs = loadU64Acquire(base, offs.started)
    result.previousSequence = loadU64Acquire(base, offs.previous)
    result.ackAtStart = loadU64Acquire(base, offs.ack)
    if loadU64Acquire(base, offs.target) != wanted or
        (sequence == high(uint64) and idx.workSequence() != wanted):
      result = WorkAssociation()

  proc workStartSequence*(idx: ShmIndex): uint64 =
    idx.workAssociation().sequence

  proc workStartedMs*(idx: ShmIndex): uint64 =
    idx.workAssociation().startedMs

  proc workHadOutstandingAtStart*(idx: ShmIndex): bool =
    let assoc = idx.workAssociation()
    assoc.sequence != 0 and assoc.ackAtStart != assoc.previousSequence

  proc acknowledgeWorkThrough*(idx: ShmIndex; sequence: uint64) =
    ## Daemon-only shared mutation; caller holds the writer gate and revalidated
    ## the exact owner token.
    storeU64Release(idx.ctl.base, CtlExtOffWorkAck, sequence)

  proc notePublishedWork(idx: ShmIndex;
      afterSequencePublish: WorkPublishHook = nil) =
    ## Prepare the alternating association slot before publishing its sequence
    ## with one CAS. A crash before the CAS is follower-repairable; a crash
    ## after it always leaves an exact full-width age association visible.
    let base = idx.ctl.base
    var previous = idx.workSequence()
    while true:
      let target = previous + 2'u64
      if target == 0: return
      let offs = workAssociationOffsets(target)
      storeU64Release(base, offs.started, epochMillis())
      storeU64Release(base, offs.previous, previous)
      storeU64Release(base, offs.ack, idx.workAckSequence())
      storeU64Release(base, offs.target, target)
      var expected = previous
      if casU64(base, CtlExtOffWorkSequence, expected, target):
        if afterSequencePublish != nil:
          afterSequencePublish(target)
        return
      previous = expected

  proc workOutstandingSinceMs*(idx: ShmIndex): uint64 =
    if not idx.available: return 0
    let sequence = idx.workSequence()
    if idx.workAckSequence() == sequence: return 0
    idx.workStartedMs()

  proc submitRecord*(idx: ShmIndex; digest: openArray[byte];
      rec: openArray[byte];
      afterSequencePublish: WorkPublishHook = nil): bool =
    ## MPSC append followed by generation notification. A daemon never clears a
    ## boolean flag; it acknowledges an exact sequence only after a stable empty
    ## recheck, so a newer producer notification cannot be lost.
    if not idx.available: return false
    result = idx.ringView.append(digest, rec) == rasAppended
    if result:
      idx.notePublishedWork(afterSequencePublish)

  proc daemonLaunchLease*(idx: ShmIndex): uint64 =
    if not idx.available: return 0
    loadU64Acquire(idx.ctl.base, CtlExtOffLaunchLease)

  proc daemonLaunchStarted*(idx: ShmIndex; token: uint64): uint64 =
    idx.coordStarted(token)

  proc releaseDaemonLaunchLease*(idx: ShmIndex; token: uint64): bool =
    ## Exact CAS release: a stale/failed launcher cannot clear its successor.
    if not idx.available or token == 0: return false
    var expected = token
    result = casU64(idx.ctl.base, CtlExtOffLaunchLease, expected, 0'u64)
    if result and idx.writerGateToken() != token:
      discard idx.releaseCoordToken(token)

  proc tryAcquireDaemonLaunchLease*(idx: ShmIndex; nowSeconds = 0'u64;
      producerPid = uint64(getCurrentProcessId());
      probe: ProcessLivenessProbe = nil): uint64 =
    ## Elect one full-width launch/check responsibility capability. Its exact
    ## PID/start/nonce/age record is release-published before the lease CAS, so
    ## a follower can never mistake a live initializer for an unassociated
    ## stale lease. Reassignment and reservation share the writer gate.
    if not idx.available: return 0
    let now = if nowSeconds == 0: uint64(epochTime()) else: nowSeconds
    # The common follower path never enters (and therefore never probes) the
    # writer gate. The lease's exact capability record was published before
    # its CAS, so a fresh reservation is fully recognizable here.
    let preflightLease = idx.daemonLaunchLease()
    if preflightLease != 0:
      let preflightStarted = idx.daemonLaunchStarted(preflightLease)
      if preflightStarted != 0 and
          now <= preflightStarted + DaemonLaunchLeaseTtlSeconds:
        return 0
    let candidate = idx.makeCoordToken(producerPid, startedSeconds = now)
    if candidate == 0: return 0
    let base = idx.ctl.base
    if not idx.tryAcquireWriterGate(candidate, probe, now,
        DaemonLaunchLeaseTtlSeconds):
      discard idx.releaseCoordToken(candidate)
      return 0
    defer: discard idx.releaseWriterGate(candidate)
    var attempts = 0
    while attempts < 16:
      inc attempts
      let observed = loadU64Acquire(base, CtlExtOffLaunchLease)
      if observed != 0:
        let started = idx.daemonLaunchStarted(observed)
        if started == 0 or now <= started + DaemonLaunchLeaseTtlSeconds:
          discard idx.releaseWriterGate(candidate)
          discard idx.releaseCoordToken(candidate)
          return 0
        var stale = observed
        if not casU64(base, CtlExtOffLaunchLease, stale, 0'u64):
          continue
        discard idx.releaseCoordToken(observed)
        continue
      var empty = 0'u64
      if not casU64(base, CtlExtOffLaunchLease, empty, candidate):
        continue
      if idx.coordIdentity(candidate).nonce != candidate:
        var mine = candidate
        discard casU64(base, CtlExtOffLaunchLease, mine, 0'u64)
        discard idx.releaseCoordToken(candidate)
        return 0
      # Mirrors remain diagnostic only; the authoritative association was
      # already immutable in the capability record before this CAS.
      storeU64Release(base, CtlExtOffLaunchStarted, now)
      storeU64Release(base, CtlExtOffLaunchStartedToken, candidate)
      return candidate
    discard idx.releaseWriterGate(candidate)
    discard idx.releaseCoordToken(candidate)
    0

  proc acknowledgeDaemonLaunchLease*(idx: ShmIndex): bool =
    ## Stable-drain acknowledgement. Caller holds the writer gate and has
    ## observed both the notification sequence and ring empty; CAS the exact
    ## token observed under that gate rather than unconditionally clearing.
    let observed = idx.daemonLaunchLease()
    if observed == 0: return false
    idx.releaseDaemonLaunchLease(observed)

  proc osLivenessProbeCount*(idx: ShmIndex): uint64 =
    if not idx.available: return 0
    loadU64Acquire(idx.ctl.base, CtlExtOffOsProbeCount)

  proc noteDaemonSpawnAttempt*(idx: ShmIndex) =
    if idx.available:
      discard fetchAddU64(idx.ctl.base, CtlExtOffSpawnAttemptCount, 1'u64)

  proc daemonSpawnAttemptCount*(idx: ShmIndex): uint64 =
    if not idx.available: return 0
    loadU64Acquire(idx.ctl.base, CtlExtOffSpawnAttemptCount)

  proc noteOwnerClaim*(idx: ShmIndex) =
    if idx.available:
      discard fetchAddU64(idx.ctl.base, CtlExtOffOwnerClaimCount, 1'u64)

  proc ownerClaimCount*(idx: ShmIndex): uint64 =
    if not idx.available: return 0
    loadU64Acquire(idx.ctl.base, CtlExtOffOwnerClaimCount)

  proc noteShutdownDrainPass*(idx: ShmIndex; tickets: uint64) =
    if idx.available:
      discard fetchAddU64(idx.ctl.base, CtlExtOffShutdownPassCount, 1)
      discard fetchAddU64(idx.ctl.base, CtlExtOffShutdownTicketCount, tickets)

  proc shutdownDrainPassCount*(idx: ShmIndex): uint64 =
    if not idx.available: return 0
    loadU64Acquire(idx.ctl.base, CtlExtOffShutdownPassCount)

  proc shutdownDrainTicketCount*(idx: ShmIndex): uint64 =
    if not idx.available: return 0
    loadU64Acquire(idx.ctl.base, CtlExtOffShutdownTicketCount)

else:
  # Non-POSIX: the library compiles but reports unavailable so callers fall to
  # the Tier-1 disk-only path (AC-2c).
  proc openShmIndex*(cacheRoot: string; slotCap = 0; create = true): ShmIndex =
    ShmIndex(available: false, cacheRoot: cacheRoot)

  proc close*(idx: var ShmIndex) = discard

  # Engine front-end stubs: on a non-POSIX host the shm tier is unavailable, so
  # every call is a no-op and the engine runs pure Tier-1 disk-only (AC-2c
  # fallback). Signatures mirror the POSIX versions so `repro_local_store`
  # compiles unchanged.
  proc readerSlotForPid*(): int {.inline.} = 0
  proc followLiveGeneration*(idx: var ShmIndex): bool = false
  proc lookupMetadata*(idx: var ShmIndex; digest: openArray[byte];
      readerSlot: int; rec: var seq[byte]): bool = false
  proc submitRecord*(idx: ShmIndex; digest: openArray[byte];
      rec: openArray[byte];
      afterSequencePublish: WorkPublishHook = nil): bool = false
  proc publishReaderEpoch*(idx: ShmIndex; slot: int; gen: uint32) = discard

  # Lifecycle-coordination stubs deliberately preserve the full POSIX API.
  # They never elect or mutate anything because an unavailable index always
  # runs in Tier-1-only mode.
  proc nextCoordNonce*(idx: ShmIndex): uint64 = 0
  proc processStartToken*(pid: uint64): uint64 = 0
  proc makeCoordToken*(idx: ShmIndex;
      pid = uint64(getCurrentProcessId()); startToken = 0'u64;
      forcedNonce = 0'u64; startedSeconds = 0'u64;
      afterReservation: CoordReservationHook = nil;
      afterIdentityWrite: CoordReservationHook = nil): uint64 = 0
  proc coordIdentity*(idx: ShmIndex; token: uint64): OwnerIdentity =
    OwnerIdentity()
  proc reclaimAbandonedCoordReservations*(idx: ShmIndex;
      identityProbe: ProcessLivenessProbe = nil;
      claimProbe: CoordClaimLivenessProbe = nil;
      cleanupClaimProbe: CoordClaimLivenessProbe = nil;
      afterCleanupStep: CoordCleanupHook = nil): int = 0
  proc cancelCoordReservation*(idx: ShmIndex;
      reservation: CoordReservation): bool = false
  func coordStartFingerprint*(startToken: uint64): uint32 {.inline.} = 0
  func coordClaimPid*(claim: uint64): uint64 {.inline.} = 0
  func coordClaimStartFingerprint*(claim: uint64): uint32 {.inline.} = 0
  proc releaseCoordToken*(idx: ShmIndex; token: uint64;
      cleanupClaimProbe: CoordClaimLivenessProbe = nil;
      afterCleanupStep: CoordCleanupHook = nil): bool = false
  proc coordTokenPid*(idx: ShmIndex; token: uint64): uint64 {.inline.} = 0
  proc coordStarted*(idx: ShmIndex; token: uint64): uint64 = 0
  proc coordFlags*(idx: ShmIndex; token: uint64): uint64 = 0
  proc setCoordFlags*(idx: ShmIndex; token, flags: uint64;
      afterUpdateLock: CoordUpdateHook = nil): bool = false
  proc osProcessLiveness*(identity: OwnerIdentity): ProcessLiveness =
    if identity.pid == 0: plDead else: plUnknown
  proc osProcessLiveness*(pid: uint64): ProcessLiveness =
    if pid == 0: plDead else: plUnknown
  proc probeProcess*(idx: ShmIndex; identity: OwnerIdentity;
      probe: ProcessLivenessProbe = nil): ProcessLiveness =
    if probe != nil: probe(identity) else: osProcessLiveness(identity)
  proc probeProcess*(idx: ShmIndex; pid: uint64;
      probe: ProcessLivenessProbe = nil): ProcessLiveness =
    idx.probeProcess(OwnerIdentity(pid: pid), probe)

  proc rawOwnerPid*(idx: ShmIndex): uint64 = 0
  proc rawOwnerHeartbeat*(idx: ShmIndex): uint64 = 0
  proc heartbeatTimestamp*(raw: uint64): uint64 {.inline.} =
    raw and not CapableHeartbeatBit
  proc heartbeatIsCapable*(raw: uint64): bool {.inline.} =
    (raw and CapableHeartbeatBit) != 0
  proc heartbeatIsFresh*(idx: ShmIndex; nowSeconds = 0'u64): bool = false
  proc currentOwnerIdentity*(idx: ShmIndex;
      afterGenerationRead: OwnerSnapshotHook = nil): OwnerIdentity =
    OwnerIdentity()
  proc isCapableOwner*(idx: ShmIndex): bool = false
  proc publishOwnerIdentity*(idx: ShmIndex; owner: OwnerIdentity) = discard
  proc clearOwnerIdentity*(idx: ShmIndex; owner: OwnerIdentity): bool = false
  proc publishCapableHeartbeat*(idx: ShmIndex;
      nowSeconds = 0'u64) = discard
  proc ownerLooksStale*(idx: ShmIndex; nowSeconds = 0'u64;
      probe: ProcessLivenessProbe = nil): bool = false

  proc tryAcquireWriterGate*(idx: ShmIndex; token: uint64;
      probe: ProcessLivenessProbe = nil; atSeconds = 0'u64;
      recoveryDelaySeconds = 0'u64;
      afterGateUpdateLock: CoordUpdateHook = nil;
      afterLaunchAssociationRead: CoordUpdateHook = nil): bool = false
  proc releaseWriterGate*(idx: ShmIndex; token: uint64): bool = false
  proc writerGateToken*(idx: ShmIndex): uint64 = 0

  proc workSequence*(idx: ShmIndex): uint64 = 0
  proc workAckSequence*(idx: ShmIndex): uint64 = 0
  proc workOutstanding*(idx: ShmIndex): bool = false
  proc workStartSequence*(idx: ShmIndex): uint64 = 0
  proc workStartedMs*(idx: ShmIndex): uint64 = 0
  proc workAssociation*(idx: ShmIndex;
      sequence = high(uint64)): WorkAssociation = WorkAssociation()
  proc workHadOutstandingAtStart*(idx: ShmIndex): bool = false
  proc workOutstandingSinceMs*(idx: ShmIndex): uint64 = 0
  proc acknowledgeWorkThrough*(idx: ShmIndex; sequence: uint64) = discard

  proc daemonLaunchLease*(idx: ShmIndex): uint64 = 0
  proc daemonLaunchStarted*(idx: ShmIndex; token: uint64): uint64 = 0
  proc tryAcquireDaemonLaunchLease*(idx: ShmIndex; nowSeconds = 0'u64;
      producerPid = uint64(getCurrentProcessId());
      probe: ProcessLivenessProbe = nil): uint64 = 0
  proc releaseDaemonLaunchLease*(idx: ShmIndex; token: uint64): bool = false
  proc acknowledgeDaemonLaunchLease*(idx: ShmIndex): bool = false

  proc osLivenessProbeCount*(idx: ShmIndex): uint64 = 0
  proc noteDaemonSpawnAttempt*(idx: ShmIndex) = discard
  proc daemonSpawnAttemptCount*(idx: ShmIndex): uint64 = 0
  proc noteOwnerClaim*(idx: ShmIndex) = discard
  proc ownerClaimCount*(idx: ShmIndex): uint64 = 0
  proc noteShutdownDrainPass*(idx: ShmIndex; tickets: uint64) = discard
  proc shutdownDrainPassCount*(idx: ShmIndex): uint64 = 0
  proc shutdownDrainTicketCount*(idx: ShmIndex): uint64 = 0
