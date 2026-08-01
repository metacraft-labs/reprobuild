## repro_shm_index/daemon — the single-writer cache daemon
## (Action-Cache-Per-Edge-Store.md §4.5, §4.6, §4.7; milestone AC-2b).
##
## The daemon is the SOLE WRITER of the shared-memory action-index table AND the
## persistence writer of the Tier-1 per-edge disk store. The N build engines are
## lock-free readers + MPSC-ring submitters (AC-2c wires them; AC-2b builds and
## tests the daemon STANDALONE, records submitted to the ring by the test).
##
## Responsibilities, all from ONE thread (no process-shared mutex — atomics
## only, inherited from AC-2a):
##
##   * Lifecycle / single-owner election. Exactly one daemon per cache root:
##     a candidate CAS-claims `daemonPid` in the control region and publishes a
##     periodic `daemonHeartbeat`. A stale heartbeat (TTL elapsed → previous
##     owner crashed) lets a new candidate take over.
##   * Drain + dedup + apply. Drains the MPSC ring (single consumer,
##     `tryDrainOne`), dedups by keyDigest (trivial — single writer;
##     `writeSlot` updates in place), writes the table slot via the AC-2a
##     seqlock write. On a full probe run it evicts the least-recently-written
##     slot in the probe window (LRU-within-window; disk-backed → lossless).
##   * Growth (single-writer CAS-resize). When the live generation's load factor
##     crosses a threshold it allocates a larger `action-index.<gen+1>.seg`,
##     rehashes every live record into it, then `casCurrentGeneration(old,new)`
##     — the linearization/commit point. It RCU-reclaims the old segment:
##     unmap/unlink only after every `readerEpoch` has advanced past the old
##     generation (a grace period), so a slow reader is never faulted.
##   * Persist + lazy warm-start. Applied records are persisted to the Tier-1
##     per-edge disk store (`writePerEdgeRecords`) periodically / at idle / on
##     shutdown. A FRESH daemon starts with an EMPTY table and warms a slot from
##     Tier-1 (`readHotRecord`) ON DEMAND — never an eager whole-store scan (the
##     pathology that wedged).
##
## Crash safety: a crash before a `casCurrentGeneration` leaves the old
## generation live+complete; after it, the new one is fully migrated. Readers
## are never faulted (RCU grace before unmap). A respawned daemon resumes
## (warm-start from Tier-1 + drain the ring).

import std/[os, tables, times]

import ../repro_shm_index
import repro_hash/types
import repro_local_store

when shmIndexSupported:
  import std/posix
  import ./[layout, mapping, atomics_shm, segment, ring]

# The submitted / stored inline record is the encoded METADATA-ONLY
# `ActionResultRecord` (repro_local_store.encodeActionResultRecord); the slot
# keyDigest is the weak fingerprint's 32 bytes. This keeps the daemon's persist
# / warm-start bridge byte-compatible with the Tier-1 store and the peer cache.

const
  HeartbeatTtlSeconds* = 5.0
    ## A daemon whose heartbeat is older than this is presumed dead; a new
    ## candidate may take ownership (§4.5 single-owner election).
  GrowthLoadNum* = 3
  GrowthLoadDen* = 4
    ## Grow when liveSlots / slotCap >= 3/4 (load-factor threshold, §4.5).
  GrowthFactor* = 2
    ## New generation is `GrowthFactor`× the old slot capacity.

when shmIndexSupported:
  type
    CacheDaemon* = object
      ## The single-writer daemon's per-process state. NOT shared — only the
      ## `idx` (control region + live segment) and the retiring segments are in
      ## shared memory. Everything else is daemon-local bookkeeping.
      idx*: ShmIndex
      cacheRoot*: string
      store: ActionCache            ## Tier-1 per-edge disk store (persist/warm).
      owns*: bool                   ## true once this process won the election.
      owner*: OwnerIdentity         ## exact (pid, nonce) ownership generation.
      gateToken: uint64             ## exact writer/takeover gate token.
      applied*: uint64              ## records applied to the table (dedup-net).
      persisted*: uint64            ## records flushed to Tier-1.
      grown*: uint64                ## CAS-resize generations committed.
      lastDrainBudget*: uint64      ## captured tickets in the last drain pass.
      lastDrainTickets*: uint64     ## retired tickets in the last drain pass.
      dirty: Table[string, ContentDigest]
        ## weak digests applied since the last persist (dedup key → full digest).
      retiring: seq[RetiringSegment]  ## segments awaiting the RCU grace period.

    RetiringSegment = object
      seg: SegmentTable
      gen: uint32
      path: string

    DaemonMutationHook* = proc () {.closure.}
      ## Deterministic seam at a named mutation boundary. Production leaves it
      ## nil; tests use it to pause/transfer/terminate at the exact boundary.

  # --- single-owner election (control-region pid/heartbeat) ---------------

  proc ownershipIsStale*(idx: ShmIndex; now = 0'u64;
      probe: ProcessLivenessProbe = nil): bool =
    idx.ownerLooksStale(now, probe)

  proc currentOwnerPid*(idx: ShmIndex): uint64 =
    idx.rawOwnerPid()

  proc stillOwns*(d: var CacheDaemon): bool {.inline.} =
    ## Local preflight only. Every mutation additionally acquires the shared
    ## writer gate and revalidates this exact pair while holding it.
    if not d.owns or not d.idx.available:
      d.owns = false
      return false
    if d.idx.currentOwnerIdentity() != d.owner:
      d.owns = false
      return false
    true

  proc ownerMatchesLocked(d: CacheDaemon): bool {.inline.} =
    d.owns and d.owner.nonce != 0 and
      d.idx.currentOwnerIdentity() == d.owner

  proc acquireOwnedGate(d: var CacheDaemon): bool =
    if not d.stillOwns(): return false
    if not d.idx.tryAcquireWriterGate(d.gateToken): return false
    if not d.ownerMatchesLocked():
      discard d.idx.releaseWriterGate(d.gateToken)
      d.owns = false
      return false
    if not d.idx.followLiveGeneration():
      discard d.idx.releaseWriterGate(d.gateToken)
      return false
    true

  proc releaseOwnedGate(d: CacheDaemon) {.inline.} =
    discard d.idx.releaseWriterGate(d.gateToken)

  proc rebuildDirtyFromLiveTableLocked(d: var CacheDaemon)

  proc beat*(d: var CacheDaemon; atSeconds = 0'u64): bool =
    ## Heartbeat is a shared mutation and therefore uses the same exact gate as
    ## table writes/takeover. Origin/dev sees the high-bit tagged value as fresh.
    if not d.acquireOwnedGate(): return false
    d.idx.publishCapableHeartbeat(atSeconds)
    d.releaseOwnedGate()
    true

  proc tryClaimOwnership*(d: var CacheDaemon; atSeconds = 0'u64;
      probe: ProcessLivenessProbe = nil): bool =
    ## Claim/takeover is serialized by the exact writer gate. A capable stale
    ## owner may be replaced only while outside that gate; a legacy owner is
    ## replaceable only after definite ESRCH, never merely because its TTL
    ## elapsed. Freshness is published before the legacy PID CAS, eliminating
    ## the historical stale-heartbeat claim window.
    if not d.idx.available: return false
    if d.gateToken == 0:
      d.gateToken = d.idx.makeCoordToken()
    if not d.idx.tryAcquireWriterGate(d.gateToken, probe, atSeconds):
      return false
    defer: discard d.idx.releaseWriterGate(d.gateToken)

    let base = d.idx.ctl.base
    let observed = d.idx.rawOwnerPid()
    let current = d.idx.currentOwnerIdentity()
    if current.nonce != 0 and d.owns and current == d.owner:
      return true

    var eligible = observed == 0
    if observed != 0:
      if current.nonce != 0:
        # Freshness is always checked first. A daemon candidate normally is
        # spawned only after an outstanding-work probe has established death;
        # repeat the definitive ESRCH check here so a recent hard crash can be
        # claimed without waiting out the heartbeat TTL. Alive/EPERM stays put.
        eligible = not d.idx.heartbeatIsFresh(atSeconds) or
          d.idx.probeProcess(current, probe) == plDead
      else:
        let taggedTransition =
          heartbeatIsCapable(d.idx.rawOwnerHeartbeat())
        # A tagged heartbeat with no matching exact identity is a capable
        # claimant's narrow PID-CAS -> identity-publication transition. If it
        # dies in that window, definitive ESRCH recovers immediately even
        # though the heartbeat is fresh. A true legacy owner never emits the
        # tag and is never TTL-stolen: it must be both stale and definitely
        # dead.
        eligible =
          if taggedTransition:
            d.idx.probeProcess(OwnerIdentity(pid: observed), probe) == plDead
          else:
            not d.idx.heartbeatIsFresh(atSeconds) and
              d.idx.probeProcess(OwnerIdentity(pid: observed), probe) == plDead
    if not eligible:
      return false

    if not d.idx.followLiveGeneration():
      return false
    let me = uint64(getCurrentProcessId())
    let candidate = d.idx.coordIdentity(d.gateToken)
    if candidate.pid != me or candidate.nonce == 0:
      return false

    # Fence origin/dev before changing daemonPid. It sees this tagged heartbeat
    # as fresh if our CAS wins, and still races safely on the same legacy CAS if
    # it observed an unclaimed/dead owner first.
    d.idx.publishCapableHeartbeat(atSeconds)
    var expected = observed
    if not casU64(base, CtlOffDaemonPid, expected, me):
      return false
    if d.idx.writerGateToken() != d.gateToken or
        d.idx.coordIdentity(d.gateToken) != candidate:
      var mine = me
      discard casU64(base, CtlOffDaemonPid, mine, observed)
      return false
    let previousOwner = current
    d.owner = candidate
    d.idx.publishOwnerIdentity(d.owner)
    d.idx.publishCapableHeartbeat(atSeconds)
    if d.idx.writerGateToken() != d.gateToken or
        d.idx.coordIdentity(d.gateToken) != candidate or
        d.idx.currentOwnerIdentity() != candidate:
      if d.idx.writerGateToken() == d.gateToken:
        discard d.idx.clearOwnerIdentity(candidate)
      d.owner = OwnerIdentity()
      return false
    d.owns = true
    d.idx.noteOwnerClaim()
    d.rebuildDirtyFromLiveTableLocked()
    if previousOwner.nonce != 0 and previousOwner.nonce != d.owner.nonce:
      discard d.idx.releaseCoordToken(previousOwner.nonce)
    true

  proc releaseOwnership*(d: var CacheDaemon): bool =
    ## Exact clean release under the writer gate. Clearing capability before
    ## daemonPid=0 makes a racing origin/dev claimant unambiguously legacy.
    if not d.acquireOwnedGate(): return false
    result = d.idx.clearOwnerIdentity(d.owner)
    d.releaseOwnedGate()
    d.owns = false
    d.owner = OwnerIdentity()

  # --- open / close -------------------------------------------------------

  proc openCacheDaemon*(cacheRoot: string;
      slotCap = DefaultSlotCap): CacheDaemon =
    ## Create-or-attach the shm region + open the Tier-1 store for `cacheRoot`.
    ## Does NOT claim ownership (call `tryClaimOwnership`) and does NOT scan the
    ## Tier-1 store (warm-start is lazy — §4.7).
    result.cacheRoot = cacheRoot
    result.idx = openShmIndex(cacheRoot, slotCap)
    result.gateToken = result.idx.makeCoordToken()
    # The daemon is the SOLE shm writer: it opens its Tier-1 store WITHOUT the
    # engine-side shm accelerator (`attachShm = false`) so it neither
    # auto-spawns itself nor submits its own persisted records back into the
    # ring it drains (AC-2c). It writes the shm table directly.
    result.store = openActionCache(cacheRoot, attachShm = false)
    result.dirty = initTable[string, ContentDigest]()

  proc close*(d: var CacheDaemon) =
    discard releaseOwnership(d)
    for r in d.retiring.mitems:
      if r.seg.isValid: r.seg.detach()
    d.retiring.setLen(0)
    if d.gateToken != 0:
      discard d.idx.releaseCoordToken(d.gateToken)
      d.gateToken = 0
    d.idx.close()

  # --- dedup / apply / evict ----------------------------------------------

  proc dirtyKey(digest: openArray[byte]): string =
    result = newString(KeyDigestLen)
    for i in 0 ..< KeyDigestLen:
      result[i] = char(digest[i])

  proc weakFromRecord(recBytes: openArray[byte]): (bool, ContentDigest) =
    ## Recover the full weak `ContentDigest` (algorithm+domain+bytes) from an
    ## encoded metadata record so persist/warm-start can key the Tier-1 file.
    try:
      let rec = decodeActionResultRecord(recBytes)
      (true, rec.weakFingerprint)
    except CatchableError:
      (false, ContentDigest())

  proc rebuildDirtyFromLiveTableLocked(d: var CacheDaemon) =
    ## A predecessor may die after publishing a slot but before recording or
    ## flushing its process-local dirty table. Every exact ownership generation
    ## reconstructs that persistence obligation from the bounded live table.
    ## Rewrites are idempotent (Tier-1 merges by strong fingerprint).
    d.dirty = initTable[string, ContentDigest]()
    if not d.idx.liveSeg.isValid: return
    for snap in d.idx.liveSeg.liveSlots():
      let (ok, weak) = weakFromRecord(snap.rec)
      if ok:
        d.dirty[dirtyKey(snap.digest)] = weak

  proc evictLruInWindow(seg: var SegmentTable; digest: openArray[byte]) =
    ## LRU-within-window eviction POLICY over the AC-2a `evictSlot` MECHANISM:
    ## the probe window for `digest` is full; evict the slot in it with the
    ## SMALLEST seqlock value (the least-recently-written; every write bumps a
    ## slot's `seq`, so the smallest is the coldest). Disk-backed → lossless.
    if not seg.isValid: return
    var start = seg.probeIndexFor(digest)
    var victim = -1
    var victimSeq = high(uint64)
    for k in 0 ..< seg.slotCap:
      let idx = (start + k) mod seg.slotCap
      let sq = seg.slotSeqAt(idx)
      if sq != 0 and (sq and 1) == 0 and sq < victimSeq:
        victimSeq = sq
        victim = idx
    if victim >= 0:
      seg.evictSlot(victim)

  proc growIfNeededLocked(d: var CacheDaemon): bool

  proc applyRecordLocked(d: var CacheDaemon; digest: array[KeyDigestLen, byte];
      recBytes: seq[byte]): bool =
    ## Apply ONE drained record to the live segment. Dedup is trivial (single
    ## writer: `writeSlot` updates the same-key slot in place). On a full probe
    ## run it evicts the coldest slot in the window and retries once. Records
    ## whose metadata exceeds the inline cap are dropped (they fall through to
    ## Tier-1 on the engine side — §4.2). Returns true if the table changed.
    if not d.ownerMatchesLocked() or not d.idx.liveSeg.isValid: return false
    var st = d.idx.liveSeg.writeSlot(digest, recBytes)
    if st == swsProbeFull:
      evictLruInWindow(d.idx.liveSeg, digest)
      st = d.idx.liveSeg.writeSlot(digest, recBytes)
    if st != swsWritten:
      return false
    inc d.applied
    let (ok, weak) = weakFromRecord(recBytes)
    if ok:
      d.dirty[dirtyKey(digest)] = weak
    true

  proc drainOnce*(d: var CacheDaemon;
      afterFenceBeforeApply: DaemonMutationHook = nil;
      afterApplyBeforeAck: DaemonMutationHook = nil;
      beforeStableAck: DaemonMutationHook = nil;
      afterEveryAck: DaemonMutationHook = nil): int =
    ## Drain at most the tickets reserved at entry. Returns the count applied.
    ## The captured tail is a logical bound of at most `RingCap`; continuous
    ## producers therefore cannot make one service or shutdown pass unbounded.
    ##
    ## Growth is INTERLEAVED with the drain: the load-factor threshold is checked
    ## BEFORE each apply and a CAS-resize is committed the moment it is crossed,
    ## so a burst that would overflow the current generation grows the table
    ## first rather than thrashing it with LRU evictions. (Eviction is the
    ## bounded backstop for a genuinely-at-capacity generation, not the primary
    ## capacity mechanism.)
    var ranFenceHook = false
    var ranApplyHook = false
    var ranAckHook = false
    let startHead = d.idx.ringView.headTicket()
    let budgetTail = d.idx.ringView.tailTicket()
    d.lastDrainBudget = budgetTail - startHead
    d.lastDrainTickets = 0
    while d.idx.ringView.headTicket() < budgetTail:
      if not d.acquireOwnedGate():
        break
      if d.idx.ringView.headTicket() >= budgetTail:
        d.releaseOwnedGate()
        break
      var peeked: PeekedRingRecord
      let peekStatus = d.idx.ringView.peekOne(peeked)
      case peekStatus
      of rpsRecord:
        if afterFenceBeforeApply != nil and not ranFenceHook:
          ranFenceHook = true
          afterFenceBeforeApply()
        if not d.ownerMatchesLocked():
          d.releaseOwnedGate()
          d.owns = false
          break
        discard d.growIfNeededLocked()
        let applied = d.applyRecordLocked(peeked.record.digest,
          peeked.record.rec)
        if applied:
          inc result
        if afterApplyBeforeAck != nil and not ranApplyHook:
          ranApplyHook = true
          afterApplyBeforeAck()
        # Apply precedes the exact head CAS. A crash before this point replays
        # the same idempotent record; a stale owner cannot ack after takeover
        # because takeover needs this same gate.
        if d.idx.ringView.ackPeek(peeked.ticket):
          inc d.lastDrainTickets
        d.idx.publishCapableHeartbeat()
        d.releaseOwnedGate()
        if afterEveryAck != nil:
          afterEveryAck()
      of rpsMalformed:
        # A malformed published blob is not a usable cache record, but retaining
        # it forever would wedge all later Tier-1-backed work. Retire exactly
        # this ticket under the owner gate; no false cache hit is introduced.
        if d.idx.ringView.ackPeek(peeked.ticket):
          inc d.lastDrainTickets
        d.releaseOwnedGate()
        if afterEveryAck != nil:
          afterEveryAck()
      of rpsUnpublished:
        # A producer killed after tail reservation is not compatibly recoverable
        # from the unchanged embedded-ring layout. Leave head untouched and
        # return after one observation; Tier-1 remains authoritative.
        d.releaseOwnedGate()
        break
      of rpsEmpty:
        d.releaseOwnedGate()
        break

    # Acknowledge only a stable, truly empty ring. Work published beyond the
    # captured budget remains outstanding for the next bounded pass.
    if d.acquireOwnedGate():
      let observedSequence = d.idx.workSequence()
      if beforeStableAck != nil and not ranAckHook:
        ranAckHook = true
        beforeStableAck()
      if d.idx.ringView.pendingCount() == 0:
        d.idx.acknowledgeWorkThrough(observedSequence)
        let stable = d.idx.workSequence() == observedSequence and
          d.idx.ringView.pendingCount() == 0
        if stable:
          discard d.idx.acknowledgeDaemonLaunchLease()
      d.releaseOwnedGate()

  # --- growth: single-writer CAS-resize + RCU reclamation -----------------

  proc minReaderEpoch(idx: ShmIndex): uint64 =
    ## The smallest generation any reader is currently reading (0 == idle
    ## readers are ignored). Used to decide when a retired segment is safe to
    ## unmap: once every ACTIVE reader has advanced past the old generation.
    result = high(uint64)
    for slot in 0 ..< MaxReaders:
      let e = idx.readerEpoch(slot)
      if e != 0 and e < result:
        result = e

  proc reclaimRetiredLocked(d: var CacheDaemon) =
    ## RCU reclamation: unmap + unlink each retired segment whose generation no
    ## active reader can still be reading (its epoch has advanced past it). A
    ## reader that published `gen` for the OLD generation still pins it; only
    ## once no reader's epoch equals-or-precedes the retired gen do we unmap —
    ## so a slow reader is never pulled out from under (§4.5, §4.6).
    if d.retiring.len == 0: return
    let minEpoch = minReaderEpoch(d.idx)
    var keep: seq[RetiringSegment] = @[]
    for r in d.retiring.mitems:
      # Safe to reclaim once every active reader is on a strictly newer gen.
      if minEpoch == high(uint64) or minEpoch > uint64(r.gen):
        if r.seg.isValid: r.seg.detach()
        try:
          if fileExists(r.path): removeFile(r.path)
        except OSError:
          discard
      else:
        keep.add(r)
    d.retiring = keep

  proc reclaimRetired*(d: var CacheDaemon): bool =
    ## Segment unlink/reclaim is a shared mutation and is rejected for a fenced
    ## former owner just like slot/growth/persistence mutations.
    if not d.acquireOwnedGate(): return false
    d.reclaimRetiredLocked()
    d.releaseOwnedGate()
    true

  proc loadFactorCrossed*(d: CacheDaemon): bool =
    ## True when the live segment's load factor has crossed the growth
    ## threshold (liveSlots * den >= slotCap * num).
    if not d.idx.liveSeg.isValid: return false
    let live = d.idx.liveSeg.liveSlotCount()
    live * GrowthLoadDen >= d.idx.liveSeg.slotCap * GrowthLoadNum

  proc growIfNeededLocked(d: var CacheDaemon): bool =
    ## Single-writer CAS-resize. When the load factor is crossed: allocate a
    ## larger next-generation segment, REHASH every live record into it, then
    ## `casCurrentGeneration(old, new)` — the commit/linearization point. A
    ## crash BEFORE the CAS abandons the half-built new segment (the old one
    ## stays live+complete); a crash AFTER leaves the fully-migrated new one
    ## live. The old segment is queued for RCU reclamation. Returns true if a
    ## generation was committed.
    if not d.ownerMatchesLocked() or not d.idx.liveSeg.isValid: return false
    if not d.loadFactorCrossed(): return false
    let oldGen = d.idx.liveSeg.generation
    let newGen = oldGen + 1
    let newCap = d.idx.liveSeg.slotCap * GrowthFactor
    var newSeg = attachSegment(d.cacheRoot, newGen, newCap)
    if not newSeg.isValid:
      newSeg = createSegment(d.cacheRoot, newGen, newCap, bootId())
    if not newSeg.isValid:
      return false
    # Rehash all live records into the new generation (single-writer, so a
    # plain iterate + writeSlot is race-free).
    for snap in d.idx.liveSeg.liveSlots():
      discard newSeg.writeSlot(snap.digest, snap.rec)
    # Publish the new generation's slotCap/byteSize BEFORE the CAS commit. A
    # fresh attacher still follows the OLD generation (currentGen is unchanged
    # until the CAS), and it uses the ctl slotCap only to size the segment it
    # maps. Updating it first means a crash BETWEEN the CAS and this store
    # cannot leave currentGen pointing at newGen while the ctl slotCap still
    # says oldCap (which would make an attacher map the wrong size and fail).
    # The newGen segment already exists at full size on disk (created +
    # rehashed above), so an attacher that races ahead maps it correctly the
    # instant the CAS lands. Crash safety: the CAS is the SOLE commit point.
    storeU64Relaxed(d.idx.ctl.base, CtlOffSegSlotCap, uint64(newCap))
    storeU64Relaxed(d.idx.ctl.base, CtlOffSegByteSize,
      uint64(segRegionSize(newCap)))
    # COMMIT: publish the new generation atomically. Only after this do readers
    # follow the new segment; the CAS is the linearization point. A crash
    # BEFORE it leaves oldGen live+complete (newGen is an abandoned, GC-able
    # file); a crash AFTER it leaves newGen (fully migrated) live.
    if not d.idx.casCurrentGeneration(oldGen, newGen):
      # Lost the swap (should not happen — single writer). Drop the new seg and
      # restore the ctl slotCap to the old generation's.
      storeU64Relaxed(d.idx.ctl.base, CtlOffSegSlotCap,
        uint64(d.idx.liveSeg.slotCap))
      storeU64Relaxed(d.idx.ctl.base, CtlOffSegByteSize,
        uint64(segRegionSize(d.idx.liveSeg.slotCap)))
      newSeg.detach()
      return false
    # Queue the OLD segment for RCU reclamation and switch our live view.
    let oldSeg = d.idx.liveSeg
    d.retiring.add(RetiringSegment(seg: oldSeg, gen: oldGen,
      path: segPath(d.cacheRoot, oldGen)))
    d.idx.liveSeg = newSeg
    inc d.grown
    d.reclaimRetiredLocked()
    true

  proc growIfNeeded*(d: var CacheDaemon): bool =
    if not d.acquireOwnedGate(): return false
    result = d.growIfNeededLocked()
    d.releaseOwnedGate()

  # --- persist + lazy warm-start ------------------------------------------

  proc persist*(d: var CacheDaemon): int =
    ## Flush every dirty edge's current record to the Tier-1 per-edge disk store
    ## (the durable backstop; shm is volatile). The table slot holds the newest
    ## metadata record for the edge; we read it back (seqlock) and merge it into
    ## the Tier-1 file via `writePerEdgeRecords`. Returns the count persisted.
    if not d.acquireOwnedGate(): return 0
    defer: d.releaseOwnedGate()
    if d.dirty.len == 0: return 0
    var pending: seq[tuple[key: string, weak: ContentDigest]] = @[]
    for key, weak in d.dirty:
      pending.add((key: key, weak: weak))
    for item in pending:
      let key = item.key
      let weak = item.weak
      var snap: SlotSnapshot
      let st = d.idx.liveSeg.lookupSlot(weak.bytes, snap)
      if st != srsHit:
        d.dirty.del(key)
        continue
      var rec: ActionResultRecord
      try:
        rec = decodeActionResultRecord(snap.rec)
      except CatchableError:
        d.dirty.del(key)
        continue
      # Merge into the edge's bounded set (dedup by strong fingerprint), keyed
      # by the record's own weak fingerprint (the authoritative Tier-1 key).
      var existing = d.store.loadPerEdgeRecords(rec.weakFingerprint)
      var merged: seq[ActionResultRecord] = @[]
      for e in existing:
        if e.strongFingerprint != rec.strongFingerprint:
          merged.add(e)
      merged.add(rec)
      d.store.writePerEdgeRecords(rec.weakFingerprint, merged)
      d.dirty.del(key)
      inc d.persisted
      inc result

  proc warmFromDisk*(d: var CacheDaemon; weak: ContentDigest): bool =
    ## LAZY warm-start: on a miss for `weak`, read its Tier-1 per-edge file
    ## (`readHotRecord` — an O(1) single-file open, NEVER a whole-store scan)
    ## and, if present, apply the metadata record to the shm table so future
    ## engine lookups hit in shared memory. Returns true if a slot was warmed.
    if not d.acquireOwnedGate(): return false
    defer: d.releaseOwnedGate()
    if not d.idx.liveSeg.isValid: return false
    let hit = d.store.readHotRecord(weak)
    if not hit.found: return false
    let enc = encodeActionResultRecord(hit.record)
    if enc.len > SlotInlineCap: return false   # not shm-cacheable → disk only
    var digest = weak.bytes
    var st = d.idx.liveSeg.writeSlot(digest, enc)
    if st == swsProbeFull:
      evictLruInWindow(d.idx.liveSeg, digest)
      st = d.idx.liveSeg.writeSlot(digest, enc)
    st == swsWritten

  # --- the run loop -------------------------------------------------------

  type
    DaemonStopFn* = proc (): bool {.closure, gcsafe.}
      ## Returns true when the daemon should stop (test harness / signal).

    DaemonLifecycleHook* = proc () {.closure.}
      ## Optional deterministic lifecycle seam used by ownership-handoff
      ## regression tests. Production callers leave both hooks nil.

  proc runDaemonLoop*(d: var CacheDaemon; stop: DaemonStopFn;
      pollMs = 5; persistEveryMs = 200;
      afterFinalDrain: DaemonLifecycleHook = nil;
      afterRelinquish: DaemonLifecycleHook = nil;
      afterEveryShutdownAck: DaemonLifecycleHook = nil) =
    ## The daemon's main loop: claim ownership, then drain → grow → beat, and
    ## persist at a cadence, until `stop()`. A clean stop uses an ownership
    ## handoff: final-drain + persist while still owner, relinquish, then inspect
    ## the ring. If a producer published across that boundary, this daemon may
    ## drain again ONLY after winning ownership back. A different candidate may
    ## win instead; the old owner then exits without consuming. This closes the
    ## append-vs-release race while preserving the single-consumer invariant.
    if not d.owns:
      discard d.tryClaimOwnership()
    var lastPersist = epochTime()
    while not stop():
      if not d.owns:
        # Lost / never had ownership: try to (re)take a stale one, else idle.
        if ownershipIsStale(d.idx):
          discard d.tryClaimOwnership()
        if not d.owns:
          sleep(pollMs)
          continue
      discard d.beat()
      discard d.drainOnce()
      discard d.growIfNeeded()
      discard d.reclaimRetired()
      let now = epochTime()
      if (now - lastPersist) * 1000.0 >= float(persistEveryMs):
        discard d.persist()
        lastPersist = now
      sleep(pollMs)

    # Clean-shutdown ownership handoff. At most ONE release/reacquire pass is
    # attempted. If the reserved head is unpublished (producer died between
    # tail CAS and ready publication), the compatible ring has no information
    # with which to finish or skip that record; exit boundedly and retain the
    # Tier-1 backstop instead of release/reacquire spinning forever.
    if d.stillOwns():
      discard d.drainOnce(afterEveryAck = afterEveryShutdownAck)
      d.idx.noteShutdownDrainPass(d.lastDrainTickets)
      discard d.persist()
      if afterFinalDrain != nil:
        afterFinalDrain()
      discard d.releaseOwnership()
      if afterRelinquish != nil:
        afterRelinquish()

    if d.idx.ringView.pendingCount() != 0 and d.tryClaimOwnership():
      discard d.drainOnce(afterEveryAck = afterEveryShutdownAck)
      d.idx.noteShutdownDrainPass(d.lastDrainTickets)
      discard d.persist()
      discard d.releaseOwnership()

else:
  # Non-POSIX: the daemon is unavailable; callers use the Tier-1 disk-only path
  # (AC-2c). Provide a compiling stub surface.
  type
    CacheDaemon* = object
      cacheRoot*: string
      owns*: bool

  proc openCacheDaemon*(cacheRoot: string; slotCap = 0): CacheDaemon =
    CacheDaemon(cacheRoot: cacheRoot)

  proc close*(d: var CacheDaemon) = discard
  proc tryClaimOwnership*(d: var CacheDaemon): bool = false

  type
    DaemonStopFn* = proc (): bool {.closure, gcsafe.}
    DaemonLifecycleHook* = proc () {.closure.}

  proc runDaemonLoop*(d: var CacheDaemon; stop: DaemonStopFn;
      pollMs = 5; persistEveryMs = 200;
      afterFinalDrain: DaemonLifecycleHook = nil;
      afterRelinquish: DaemonLifecycleHook = nil;
      afterEveryShutdownAck: DaemonLifecycleHook = nil) = discard
