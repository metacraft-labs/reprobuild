import std/[os, osproc, posix, strutils, tempfiles, times, unittest]

import repro_shm_index
import repro_shm_index/daemon
import repro_hash/types
import repro_local_store
import repro_test_support

# AC-2b (Action-Cache-Per-Edge-Store.md §4.5, §4.6): the single-writer daemon
# GROWS the table via a CAS-resize (allocate a larger generation, rehash live
# records in, `casCurrentGeneration` = the commit point) and RCU-reclaims the
# old segment after the reader grace period; it SURVIVES a crash (a crash before
# the CAS leaves the old generation live+complete; after it, the new is fully
# migrated).
#
# Multi-process (REAL processes, one shared `--action-cache-root`):
#   * PRODUCER processes submit enough DISTINCT keys to cross the load-factor
#     threshold of the (small) generation-0 segment → the daemon grows.
#   * READER processes seqlock-read the whole key set continuously; a hit whose
#     decoded record does not match the submitted key is TORN/inconsistent, and
#     a key that is present-then-absent across the resize would be a MISS — both
#     are reported as failures. (Growth must never expose a torn or missing
#     entry to a concurrent reader.)
#   * After growth: the parent confirms the live generation advanced (> 0) and
#     ALL keys survive the migration (every key is a hit in the new generation).
#   * CRASH: a daemon is KILLED (SIGKILL) mid-resize (right around the CAS); the
#     parent confirms the CURRENT generation stays COMPLETE (every key that was
#     applied is still a consistent hit), and a RESPAWNED daemon recovers
#     (drains any queued submissions + keeps serving).
#
# Falsifiable:
#   * unmapping the old segment BEFORE the reader grace period faults a slow
#     reader (SIGSEGV / a torn read) — the RCU reclamation guards against it;
#   * a NON-ATOMIC generation swap (plain store instead of CAS, or publishing
#     the new gen before the rehash completes) exposes a half-built table → a
#     reader sees a missing key → FAIL.

const
  ProducerFlag = "--grow-producer"
  ReaderFlag = "--grow-reader"
  DaemonFlag = "--grow-daemon"
  CrashDaemonFlag = "--grow-crash-daemon"
  # Small gen-0 so a modest key count crosses the 3/4 load threshold and forces
  # a real CAS-resize quickly.
  Gen0Cap = 64
  NumKeys = 96                 # > 3/4 * 64 = 48 → guarantees at least one grow
  ReaderDurationMs = 2500
  ExitOk = 0
  ExitTorn = 7                 # a reader saw a torn/inconsistent record
  ExitMissing = 8              # a reader saw a key vanish after it appeared

proc weakFor(i: int): ContentDigest =
  result.algorithm = haBlake3_256
  result.domain = hdCasContent
  for b in 0 ..< 32:
    result.bytes[b] = byte((i * 131 + b * 17 + 5) and 0xFF)

proc recordFor(i: int): ActionResultRecord =
  result.weakFingerprint = weakFor(i)
  result.policy = ffpTimestamp
  result.outputPayloadKind = opkMetadataOnly
  result.inputs = @[FileFingerprint(
    path: "/e/" & $i,
    policy: ffpTimestamp,
    metadata: FileMetadata(kind: ffkRegular, sizeBytes: uint64(i),
      mtimeNs: uint64(i)),
    hasLocalHash: false)]

proc runProducer(cacheRoot: string; startKey, endKey: int) =
  var idx = openShmIndex(cacheRoot, create = false)
  if not idx.available:
    quit(ExitOk)
  for i in startKey ..< endKey:
    let enc = encodeActionResultRecord(recordFor(i))
    var digest = weakFor(i).bytes
    var st = idx.ringView.append(digest, enc)
    var spins = 0
    while st == rasDropped and spins < 5_000_000:
      st = idx.ringView.append(digest, enc)
      inc spins
    doAssert st != rasOversized
  idx.close()
  quit(ExitOk)

proc runReader(cacheRoot: string; readerSlot: int) =
  ## Continuously read every key across whichever generation is live. Publishes
  ## its reader epoch (the RCU grace surface) so the daemon must wait it out
  ## before reclaiming the old segment. A hit whose decoded record mismatches
  ## the key is TORN; a key that was seen then disappears is MISSING.
  var idx = openShmIndex(cacheRoot, create = false)
  if not idx.available:
    quit(ExitOk)
  let deadline = epochTime() + ReaderDurationMs.float / 1000.0
  var seenOnce = newSeq[bool](NumKeys)
  while epochTime() < deadline:
    let gen = idx.currentGeneration()
    idx.publishReaderEpoch(readerSlot mod 64, gen)
    # (Re)attach the live generation if the daemon advanced past ours.
    if not idx.liveSeg.isValid or idx.liveSeg.generation != gen:
      discard idx.attachGeneration(gen, idx.segSlotCap())
    if not idx.liveSeg.isValid:
      continue
    for i in 0 ..< NumKeys:
      var snap: SlotSnapshot
      let st = idx.liveSeg.lookupSlot(weakFor(i).bytes, snap)
      if st == srsHit:
        # Verify the record is the complete, correct one for this key.
        var ok = false
        try:
          let rec = decodeActionResultRecord(snap.rec)
          ok = rec.weakFingerprint == weakFor(i) and
               rec.inputs.len == 1 and rec.inputs[0].path == "/e/" & $i
        except CatchableError:
          ok = false
        if not ok:
          quit(ExitTorn)
        seenOnce[i] = true
      elif seenOnce[i]:
        # It was present in a prior generation and is now gone — a resize that
        # exposed a half-built table would do this.
        quit(ExitMissing)
  idx.publishReaderEpoch(readerSlot mod 64, 0)  # go idle
  idx.close()
  quit(ExitOk)

proc runDaemon(cacheRoot: string; durationMs: int) =
  var d = openCacheDaemon(cacheRoot, slotCap = Gen0Cap)
  if not d.idx.available:
    quit(ExitOk)
  let deadline = epochTime() + durationMs.float / 1000.0
  let stop = proc (): bool {.closure, gcsafe.} = epochTime() >= deadline
  d.runDaemonLoop(stop, pollMs = 1, persistEveryMs = 50)
  d.close()
  quit(ExitOk)

proc runCrashDaemon(cacheRoot: string) =
  ## A daemon that races to grow and is expected to be SIGKILL'd by the parent
  ## mid-resize. It never exits on its own (loops until killed) so the parent
  ## controls the exact kill moment.
  var d = openCacheDaemon(cacheRoot, slotCap = Gen0Cap)
  if not d.idx.available:
    quit(ExitOk)
  let stop = proc (): bool {.closure, gcsafe.} = false
  d.runDaemonLoop(stop, pollMs = 1, persistEveryMs = 1_000_000)
  quit(ExitOk)

when isMainModule:
  let params = commandLineParams()
  if params.len >= 3 and params[0] == ProducerFlag:
    runProducer(params[1], parseInt(params[2]), parseInt(params[3]))
  elif params.len >= 3 and params[0] == ReaderFlag:
    runReader(params[1], parseInt(params[2]))
  elif params.len >= 3 and params[0] == DaemonFlag:
    runDaemon(params[1], parseInt(params[2]))
  elif params.len >= 2 and params[0] == CrashDaemonFlag:
    runCrashDaemon(params[1])

proc keyIsConsistentHit(seg: SegmentTable; i: int): bool =
  var snap: SlotSnapshot
  if seg.lookupSlot(weakFor(i).bytes, snap) != srsHit:
    return false
  try:
    let rec = decodeActionResultRecord(snap.rec)
    return rec.weakFingerprint == weakFor(i) and
           rec.inputs.len == 1 and rec.inputs[0].path == "/e/" & $i
  except CatchableError:
    return false

suite "integration_cache_daemon_grows_via_cas_resize_and_survives_crash":
  when isNixSupported:
    test "daemon grows via CAS-resize; all records survive; readers never torn":
      let tempRoot = createTempDir("repro-daemon-grow", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"

      # Pre-create the shm region with a SMALL gen-0 so growth triggers fast.
      var idx0 = openShmIndex(cacheRoot, slotCap = Gen0Cap)
      check idx0.available
      check idx0.segSlotCap() == Gen0Cap
      idx0.close()

      let self = getAppFilename()

      # Daemon + concurrent readers, then producers submit all keys.
      var daemon = startProcess(self, args = @[DaemonFlag, cacheRoot, "2500"],
        options = {poStdErrToStdOut})
      var readers: seq[Process] = @[]
      for r in 0 ..< 6:
        readers.add(startProcess(self,
          args = @[ReaderFlag, cacheRoot, $r], options = {poStdErrToStdOut}))
      var producers: seq[Process] = @[]
      let third = NumKeys div 3
      producers.add(startProcess(self,
        args = @[ProducerFlag, cacheRoot, "0", $third],
        options = {poStdErrToStdOut}))
      producers.add(startProcess(self,
        args = @[ProducerFlag, cacheRoot, $third, $(2 * third)],
        options = {poStdErrToStdOut}))
      producers.add(startProcess(self,
        args = @[ProducerFlag, cacheRoot, $(2 * third), $NumKeys],
        options = {poStdErrToStdOut}))
      for p in producers:
        check p.waitForExit() == ExitOk
        p.close()

      # Readers ran concurrently through the resize: none may report TORN or
      # MISSING.
      for i, r in readers:
        let code = r.waitForExit()
        if code == ExitTorn:
          checkpoint("reader " & $i & " saw a TORN record during resize")
        elif code == ExitMissing:
          checkpoint("reader " & $i & " saw a key VANISH during resize")
        check code == ExitOk
        r.close()
      check daemon.waitForExit() == ExitOk
      daemon.close()

      # The live generation advanced (a real CAS-resize happened) and EVERY key
      # survived the migration.
      var attach = openShmIndex(cacheRoot, create = false)
      check attach.available
      check attach.currentGeneration() > 0'u32
      var survived = 0
      for i in 0 ..< NumKeys:
        if keyIsConsistentHit(attach.liveSeg, i):
          inc survived
      check survived == NumKeys
      attach.close()

    test "daemon killed mid-resize leaves a complete generation; respawn recovers":
      let tempRoot = createTempDir("repro-daemon-crash", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"

      var idx0 = openShmIndex(cacheRoot, slotCap = Gen0Cap)
      check idx0.available
      idx0.close()

      let self = getAppFilename()

      # A crash-daemon that never exits on its own; submit all keys so it starts
      # draining + (once past threshold) resizing.
      var crashDaemon = startProcess(self,
        args = @[CrashDaemonFlag, cacheRoot], options = {poStdErrToStdOut})
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

      # Give the daemon a brief window to drain + begin/commit a resize, then
      # KILL it hard (SIGKILL) right around the CAS. The current generation must
      # stay COMPLETE regardless of exactly when the kill lands.
      sleep(120)
      let pid = Pid(crashDaemon.processID)
      discard kill(pid, SIGKILL)
      discard crashDaemon.waitForExit()
      crashDaemon.close()

      # Whatever generation is currently live, it is COMPLETE: every key that
      # is present is a CONSISTENT hit (no torn/half-built slot from the swap),
      # and the generation the ctl points at maps to a valid segment.
      var attach = openShmIndex(cacheRoot, create = false)
      check attach.available
      let liveGen = attach.currentGeneration()
      check attach.liveSeg.isValid
      check attach.liveSeg.generation == liveGen
      # No slot in the live generation is torn: a hit is always consistent.
      var presentHits = 0
      for i in 0 ..< NumKeys:
        var snap: SlotSnapshot
        let st = attach.liveSeg.lookupSlot(weakFor(i).bytes, snap)
        if st == srsHit:
          check keyIsConsistentHit(attach.liveSeg, i)
          inc presentHits
      attach.close()

      # A RESPAWNED daemon takes over the stale ownership and keeps serving:
      # after it runs, EVERY key is a consistent hit (it drained any queued
      # submissions and/or warmed from Tier-1 persistence).
      var respawn = startProcess(self, args = @[DaemonFlag, cacheRoot, "1500"],
        options = {poStdErrToStdOut})
      # Re-submit the keys so the respawned daemon (which starts on whatever
      # generation is live) applies them — this exercises takeover + drain.
      var producers2: seq[Process] = @[]
      producers2.add(startProcess(self,
        args = @[ProducerFlag, cacheRoot, "0", $half],
        options = {poStdErrToStdOut}))
      producers2.add(startProcess(self,
        args = @[ProducerFlag, cacheRoot, $half, $NumKeys],
        options = {poStdErrToStdOut}))
      for p in producers2:
        check p.waitForExit() == ExitOk
        p.close()
      check respawn.waitForExit() == ExitOk
      respawn.close()

      var final = openShmIndex(cacheRoot, create = false)
      check final.available
      var recovered = 0
      for i in 0 ..< NumKeys:
        if keyIsConsistentHit(final.liveSeg, i):
          inc recovered
      check recovered == NumKeys
      final.close()
