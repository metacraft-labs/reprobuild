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
      applied*: uint64              ## records applied to the table (dedup-net).
      persisted*: uint64            ## records flushed to Tier-1.
      grown*: uint64                ## CAS-resize generations committed.
      dirty: Table[string, ContentDigest]
        ## weak digests applied since the last persist (dedup key → full digest).
      retiring: seq[RetiringSegment]  ## segments awaiting the RCU grace period.

    RetiringSegment = object
      seg: SegmentTable
      gen: uint32
      path: string

  # --- single-owner election (control-region pid/heartbeat) ---------------

  proc nowSeconds(): uint64 {.inline.} = uint64(epochTime())

  proc pidIsAlive(pid: uint64): bool =
    ## Whether a process with `pid` currently exists (POSIX `kill(pid, 0)`; ESRCH
    ## => dead). A daemon that was SIGKILLed leaves a RECENT heartbeat, so pid
    ## liveness — not just the TTL — is what makes takeover prompt after a hard
    ## crash (mirrors the runquotad stale-owner probe). A false positive (pid
    ## reused by an unrelated process) only DELAYS takeover to the TTL, never
    ## corrupts state, because the CAS still elects exactly one owner.
    if pid == 0: return false
    kill(Pid(pid), cint(0)) == 0

  proc heartbeatAgeSeconds(idx: ShmIndex): float =
    ## Seconds since the current owner last beat. A large value (or a never-set
    ## heartbeat) means the owner is presumed dead.
    let hb = loadU64Acquire(idx.ctl.base, CtlOffDaemonHeartbeat)
    if hb == 0: return 1e18
    let now = epochTime()
    max(0.0, now - float(hb))

  proc ownershipIsStale*(idx: ShmIndex): bool =
    ## True when no live owner holds the control region: pid is unclaimed, the
    ## owning process is DEAD (SIGKILL/crash — prompt takeover), OR the heartbeat
    ## TTL elapsed (owner wedged without clearing pid).
    if not idx.available: return false
    let pid = loadU64Acquire(idx.ctl.base, CtlOffDaemonPid)
    if pid == 0: return true
    if not pidIsAlive(pid): return true
    heartbeatAgeSeconds(idx) > HeartbeatTtlSeconds

  proc currentOwnerPid*(idx: ShmIndex): uint64 =
    if not idx.available: return 0
    loadU64Acquire(idx.ctl.base, CtlOffDaemonPid)

  proc beat(d: var CacheDaemon) =
    ## Publish a fresh heartbeat (release). Called on every drain loop turn.
    if d.owns:
      storeU64Release(d.idx.ctl.base, CtlOffDaemonHeartbeat, nowSeconds())

  proc tryClaimOwnership*(d: var CacheDaemon): bool =
    ## Attempt to become THE daemon for the cache root. Wins iff the slot is
    ## unclaimed (pid==0) OR the current owner's heartbeat is stale (crash).
    ## The `daemonPid` CAS is the election's linearization point: exactly one
    ## candidate transitions it from the observed value to our pid.
    if not d.idx.available: return false
    let base = d.idx.ctl.base
    let observed = loadU64Acquire(base, CtlOffDaemonPid)
    if observed != 0 and pidIsAlive(observed) and
        heartbeatAgeSeconds(d.idx) <= HeartbeatTtlSeconds:
      return false                       # a live owner holds it
    var expected = observed
    let me = uint64(getCurrentProcessId())
    if casU64(base, CtlOffDaemonPid, expected, me):
      # Publish an immediate heartbeat so a racing candidate sees us live.
      storeU64Release(base, CtlOffDaemonHeartbeat, nowSeconds())
      d.owns = true
      return true
    false

  proc releaseOwnership(d: var CacheDaemon) =
    ## Clean shutdown: clear pid (only if still ours) so the next daemon can
    ## claim immediately without waiting out the TTL.
    if d.owns and d.idx.available:
      var mine = uint64(getCurrentProcessId())
      discard casU64(d.idx.ctl.base, CtlOffDaemonPid, mine, 0'u64)
      d.owns = false

  # --- open / close -------------------------------------------------------

  proc openCacheDaemon*(cacheRoot: string;
      slotCap = DefaultSlotCap): CacheDaemon =
    ## Create-or-attach the shm region + open the Tier-1 store for `cacheRoot`.
    ## Does NOT claim ownership (call `tryClaimOwnership`) and does NOT scan the
    ## Tier-1 store (warm-start is lazy — §4.7).
    result.cacheRoot = cacheRoot
    result.idx = openShmIndex(cacheRoot, slotCap)
    # The daemon is the SOLE shm writer: it opens its Tier-1 store WITHOUT the
    # engine-side shm accelerator (`attachShm = false`) so it neither
    # auto-spawns itself nor submits its own persisted records back into the
    # ring it drains (AC-2c). It writes the shm table directly.
    result.store = openActionCache(cacheRoot, attachShm = false)
    result.dirty = initTable[string, ContentDigest]()

  proc close*(d: var CacheDaemon) =
    releaseOwnership(d)
    for r in d.retiring.mitems:
      if r.seg.isValid: r.seg.detach()
    d.retiring.setLen(0)
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

  proc growIfNeeded*(d: var CacheDaemon): bool  # fwd: interleaved into drain

  proc applyRecord(d: var CacheDaemon; digest: array[KeyDigestLen, byte];
      recBytes: seq[byte]): bool =
    ## Apply ONE drained record to the live segment. Dedup is trivial (single
    ## writer: `writeSlot` updates the same-key slot in place). On a full probe
    ## run it evicts the coldest slot in the window and retries once. Records
    ## whose metadata exceeds the inline cap are dropped (they fall through to
    ## Tier-1 on the engine side — §4.2). Returns true if the table changed.
    if not d.idx.liveSeg.isValid: return false
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

  proc drainOnce*(d: var CacheDaemon): int =
    ## Drain every currently-ready ring record into the table. Returns the count
    ## applied. Single consumer (§4.5) — only the daemon calls this.
    ##
    ## Growth is INTERLEAVED with the drain: the load-factor threshold is checked
    ## BEFORE each apply and a CAS-resize is committed the moment it is crossed,
    ## so a burst that would overflow the current generation grows the table
    ## first rather than thrashing it with LRU evictions. (Eviction is the
    ## bounded backstop for a genuinely-at-capacity generation, not the primary
    ## capacity mechanism.)
    if not d.idx.available: return 0
    var rr: RingRecord
    while d.idx.ringView.tryDrainOne(rr):
      discard d.growIfNeeded()
      if d.applyRecord(rr.digest, rr.rec):
        inc result

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

  proc reclaimRetired(d: var CacheDaemon) =
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

  proc loadFactorCrossed*(d: CacheDaemon): bool =
    ## True when the live segment's load factor has crossed the growth
    ## threshold (liveSlots * den >= slotCap * num).
    if not d.idx.liveSeg.isValid: return false
    let live = d.idx.liveSeg.liveSlotCount()
    live * GrowthLoadDen >= d.idx.liveSeg.slotCap * GrowthLoadNum

  proc growIfNeeded*(d: var CacheDaemon): bool =
    ## Single-writer CAS-resize. When the load factor is crossed: allocate a
    ## larger next-generation segment, REHASH every live record into it, then
    ## `casCurrentGeneration(old, new)` — the commit/linearization point. A
    ## crash BEFORE the CAS abandons the half-built new segment (the old one
    ## stays live+complete); a crash AFTER leaves the fully-migrated new one
    ## live. The old segment is queued for RCU reclamation. Returns true if a
    ## generation was committed.
    if not d.idx.available or not d.idx.liveSeg.isValid: return false
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
    reclaimRetired(d)
    true

  # --- persist + lazy warm-start ------------------------------------------

  proc persist*(d: var CacheDaemon): int =
    ## Flush every dirty edge's current record to the Tier-1 per-edge disk store
    ## (the durable backstop; shm is volatile). The table slot holds the newest
    ## metadata record for the edge; we read it back (seqlock) and merge it into
    ## the Tier-1 file via `writePerEdgeRecords`. Returns the count persisted.
    if not d.idx.available: return 0
    if d.dirty.len == 0: return 0
    var pending = d.dirty
    d.dirty = initTable[string, ContentDigest]()
    for _, weak in pending:
      var snap: SlotSnapshot
      let st = d.idx.liveSeg.lookupSlot(weak.bytes, snap)
      if st != srsHit:
        continue
      var rec: ActionResultRecord
      try:
        rec = decodeActionResultRecord(snap.rec)
      except CatchableError:
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
      inc d.persisted
      inc result

  proc warmFromDisk*(d: var CacheDaemon; weak: ContentDigest): bool =
    ## LAZY warm-start: on a miss for `weak`, read its Tier-1 per-edge file
    ## (`readHotRecord` — an O(1) single-file open, NEVER a whole-store scan)
    ## and, if present, apply the metadata record to the shm table so future
    ## engine lookups hit in shared memory. Returns true if a slot was warmed.
    if not d.idx.available or not d.idx.liveSeg.isValid: return false
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

  proc runDaemonLoop*(d: var CacheDaemon; stop: DaemonStopFn;
      pollMs = 5; persistEveryMs = 200) =
    ## The daemon's main loop: claim ownership, then drain → grow → beat, and
    ## persist at a cadence, until `stop()`. On a clean stop it persists once
    ## more and releases ownership. Single-writer throughout.
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
      d.beat()
      discard d.drainOnce()
      discard d.growIfNeeded()
      reclaimRetired(d)
      let now = epochTime()
      if (now - lastPersist) * 1000.0 >= float(persistEveryMs):
        discard d.persist()
        lastPersist = now
      sleep(pollMs)
    # Clean shutdown: final drain + persist + release.
    if d.owns:
      discard d.drainOnce()
      discard d.persist()
    releaseOwnership(d)

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
