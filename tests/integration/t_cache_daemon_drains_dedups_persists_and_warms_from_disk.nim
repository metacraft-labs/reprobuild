import std/[os, osproc, strutils, tempfiles, times, unittest]

import repro_shm_index
import repro_shm_index/daemon
import repro_hash/types
import repro_local_store
import repro_test_support

# AC-2b (Action-Cache-Per-Edge-Store.md §4.5, §4.7): the single-writer cache
# daemon DRAINS the MPSC ring, DEDUPS by keyDigest (trivial — single writer),
# APPLIES to the shm table, and PERSISTS applied records to the Tier-1 per-edge
# disk store. A FRESH daemon starts with an EMPTY table and warms a slot from
# Tier-1 ON DEMAND (a single-file open — never a whole-store scan).
#
# Multi-process (the AC-2a/AC-1 pattern: REAL processes, one shared
# `--action-cache-root`):
#   * PRODUCER processes submit records to the ring, INCLUDING duplicates
#     (each key submitted twice).
#   * A DAEMON process claims ownership, drains → applies → dedups → persists,
#     then exits cleanly (a final persist flush on shutdown).
#   * The parent then asserts: the shm table has each key EXACTLY ONCE (dedup),
#     and the Tier-1 per-edge files match the applied records (persist).
#   * Finally a FRESH daemon (empty shm — a brand-new generation) warms a slot
#     from Tier-1 on a lookup and the record appears in shm.
#
# Falsifiable:
#   * skipping dedup would duplicate a key in the table (>1 live slot per key);
#   * skipping persist loses records across a daemon restart (warm-start finds
#     nothing on disk → the fresh table stays empty).

const
  ProducerFlag = "--daemon-producer"
  DaemonFlag = "--daemon-run"
  NumKeys = 40
  RecBytesLen = 24
  ExitOk = 0

proc weakFor(i: int): ContentDigest =
  ## A deterministic weak fingerprint for edge `i`, shared by producer + parent.
  result.algorithm = haBlake3_256
  result.domain = hdCasContent
  for b in 0 ..< 32:
    result.bytes[b] = byte((i * 191 + b * 7 + 3) and 0xFF)

proc recordFor(i: int): ActionResultRecord =
  ## A tiny metadata-only record whose weak fingerprint is `weakFor(i)`. Small
  ## enough to fit the inline slot cap. Self-describing: one input path encodes
  ## the key index so persist round-trips are checkable.
  result.weakFingerprint = weakFor(i)
  result.policy = ffpTimestamp
  result.outputPayloadKind = opkMetadataOnly
  result.inputs = @[FileFingerprint(
    path: "/edge/" & $i,
    policy: ffpTimestamp,
    metadata: FileMetadata(kind: ffkRegular, sizeBytes: uint64(i),
      mtimeNs: uint64(i) * 1000),
    hasLocalHash: false)]

proc runProducer(cacheRoot: string; startKey, endKey: int) =
  ## Submit each key in [startKey, endKey) to the ring TWICE (the duplicate the
  ## daemon must dedup). Retry a signalled transient full-ring drop.
  var idx = openShmIndex(cacheRoot, create = false)
  if not idx.available:
    quit(ExitOk)
  for i in startKey ..< endKey:
    let enc = encodeActionResultRecord(recordFor(i))
    var digest = weakFor(i).bytes
    for _ in 0 ..< 2:                       # submit the duplicate
      var st = idx.ringView.append(digest, enc)
      var spins = 0
      while st == rasDropped and spins < 5_000_000:
        st = idx.ringView.append(digest, enc)
        inc spins
      doAssert st != rasOversized
  idx.close()
  quit(ExitOk)

proc runDaemon(cacheRoot: string; durationMs: int) =
  ## Run a real daemon process for `durationMs`, then stop (a clean shutdown
  ## flushes a final persist). Claims ownership via the control region.
  var d = openCacheDaemon(cacheRoot)
  if not d.idx.available:
    quit(ExitOk)
  let deadline = epochTime() + durationMs.float / 1000.0
  let stop = proc (): bool {.closure, gcsafe.} = epochTime() >= deadline
  d.runDaemonLoop(stop, pollMs = 2, persistEveryMs = 50)
  d.close()
  quit(ExitOk)

when isMainModule:
  let params = commandLineParams()
  if params.len >= 3 and params[0] == ProducerFlag:
    runProducer(params[1], parseInt(params[2]), parseInt(params[3]))
  elif params.len >= 3 and params[0] == DaemonFlag:
    runDaemon(params[1], parseInt(params[2]))

proc liveKeyCount(seg: SegmentTable; i: int): int =
  ## How many live slots across the WHOLE table hold key `i` — must be exactly 1
  ## after dedup. A full scan (not a probe-terminating lookup) so a DUPLICATE
  ## (two slots with the same key — what skipping dedup produces) is detected.
  let want = weakFor(i).bytes
  for snap in seg.liveSlots():
    if snap.digest == want:
      inc result

suite "integration_cache_daemon_drains_dedups_persists_and_warms_from_disk":
  when isNixSupported:
    test "daemon drains+dedups+persists, fresh daemon warms from disk":
      let tempRoot = createTempDir("repro-daemon-drain", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"

      # Pre-create the shm region so every worker attaches to the same root.
      var idx = openShmIndex(cacheRoot)
      check idx.available
      idx.close()

      let self = getAppFilename()

      # Spawn the daemon FIRST (it claims ownership + drains continuously) then
      # the producers (which submit duplicates concurrently).
      var daemon = startProcess(self, args = @[DaemonFlag, cacheRoot, "2500"],
        options = {poStdErrToStdOut})
      var producers: seq[Process] = @[]
      let half = NumKeys div 2
      producers.add(startProcess(self,
        args = @[ProducerFlag, cacheRoot, "0", $half],
        options = {poStdErrToStdOut}))
      producers.add(startProcess(self,
        args = @[ProducerFlag, cacheRoot, $half, $NumKeys],
        options = {poStdErrToStdOut}))
      for p in producers:
        check p.waitForExit() == ExitOk
        p.close()
      # Let the daemon run to its deadline so it drains + persists everything.
      check daemon.waitForExit() == ExitOk
      daemon.close()

      # 1) DEDUP: the shm table has each key EXACTLY ONCE.
      var attach = openShmIndex(cacheRoot, create = false)
      check attach.available
      var tableHits = 0
      for i in 0 ..< NumKeys:
        let c = liveKeyCount(attach.liveSeg, i)
        check c == 1
        tableHits += c
      check tableHits == NumKeys
      attach.close()

      # 2) PERSIST: the Tier-1 per-edge files match the applied records.
      var store = openActionCache(cacheRoot)
      for i in 0 ..< NumKeys:
        let hit = store.readHotRecord(weakFor(i))
        check hit.found
        if hit.found:
          check hit.record.weakFingerprint == weakFor(i)
          check hit.record.inputs.len == 1
          check hit.record.inputs[0].path == "/edge/" & $i

      # 3) LAZY WARM-START: a FRESH table (new generation, empty) warms a slot
      # from Tier-1 on a lookup, WITHOUT any eager whole-store scan.
      var fresh = openCacheDaemon(cacheRoot)
      check fresh.idx.available
      # Move to a brand-new empty generation so the table starts cold. (Growth
      # would normally create it; here we make an empty gen directly to isolate
      # warm-start.)
      let coldGen = fresh.idx.currentGeneration() + 1
      var coldSeg = createSegment(cacheRoot, coldGen, fresh.idx.segSlotCap(),
        bootId())
      check coldSeg.isValid
      check fresh.idx.attachGeneration(coldGen, fresh.idx.segSlotCap())
      fresh.idx.setCurrentGeneration(coldGen)
      # Cold: the key is NOT in the fresh table yet.
      var snap0: SlotSnapshot
      check fresh.idx.liveSeg.lookupSlot(weakFor(7).bytes, snap0) != srsHit
      # Warm it from disk (single-file open, no scan) and confirm it now hits.
      check fresh.warmFromDisk(weakFor(7))
      var snap1: SlotSnapshot
      check fresh.idx.liveSeg.lookupSlot(weakFor(7).bytes, snap1) == srsHit
      let warmed = decodeActionResultRecord(snap1.rec)
      check warmed.weakFingerprint == weakFor(7)
      check warmed.inputs[0].path == "/edge/7"
      fresh.close()
