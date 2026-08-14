import std/[os, osproc, streams, strutils, tempfiles, times, unittest]

import repro_shm_index
import repro_shm_index/daemon
import repro_shm_index/atomics_shm
import repro_shm_index/mapping
import repro_hash/types
import repro_local_store
import repro_test_support

when defined(posix):
  import std/posix

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
  ClaimAndBlockFlag = "--daemon-claim-and-block"
  ApplyAndBlockFlag = "--daemon-apply-and-block"
  LaunchWorkerFlag = "--daemon-launch-worker"
  TwoPhaseLaunchWorkerFlag = "--daemon-two-phase-launch-worker"
  RecoveryLaunchWorkerFlag = "--daemon-recovery-launch-worker"
  PauseLaunchReservationFlag = "--daemon-pause-launch-reservation"
  PauseLaunchAuthorizationFlag = "--daemon-pause-launch-authorization"
  PublishSequenceAndBlockFlag = "--daemon-publish-sequence-and-block"
  CoordReserveAndBlockFlag = "--coord-reserve-and-block"
  CoordCommitAndBlockFlag = "--coord-commit-and-block"
  DaemonOpenUnclaimedAndBlockFlag = "--daemon-open-unclaimed-and-block"
  NumKeys = 40
  LaunchStormWorkers = 24
  AbandonedCoordInitializers = CoordSlotCount + 16
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
      var submitted = idx.submitRecord(digest, enc)
      var spins = 0
      while not submitted and spins < 5_000_000:
        submitted = idx.submitRecord(digest, enc)
        inc spins
      doAssert submitted
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

proc runClaimAndBlock(cacheRoot: string) =
  ## Deterministic hard-crash fixture: publish ownership, acknowledge it over
  ## stdout, then block on stdin until the parent terminates this process. No
  ## timer/sleep participates in the ownership or crash assertion.
  var d = openCacheDaemon(cacheRoot)
  doAssert d.idx.available
  doAssert d.tryClaimOwnership()
  stdout.writeLine("CLAIMED")
  stdout.flushFile()
  discard stdin.readLine()
  d.close()
  quit(ExitOk)

proc runApplyAndBlock(cacheRoot: string) =
  ## Claim, apply the published head under the writer gate, then stop at the
  ## exact apply-before-ack/persist boundary until the parent terminates us.
  var d = openCacheDaemon(cacheRoot)
  doAssert d.idx.available
  doAssert d.tryClaimOwnership()
  let blockAfterApply = proc () =
    stdout.writeLine("APPLIED")
    stdout.flushFile()
    discard stdin.readLine()
  discard d.drainOnce(afterApplyBeforeAck = blockAfterApply)
  d.close()
  quit(ExitOk)

proc runLaunchWorker(cacheRoot, startGate: string; key: int) =
  while not fileExists(startGate):
    sleep(1)
  var idx = openShmIndex(cacheRoot, create = false)
  doAssert idx.available
  let rec = recordFor(key)
  doAssert idx.submitRecord(rec.weakFingerprint.bytes,
    encodeActionResultRecord(rec))
  discard ensureCacheDaemon(cacheRoot, idx)
  idx.close()
  quit(ExitOk)

proc runTwoPhaseLaunchWorker(cacheRoot, readyGate, ensureGate: string;
    key: int) =
  ## Publish first, then wait until every real producer has published before
  ## entering launch arbitration. This makes the launch-storm assertion about
  ## one precise work cycle rather than OS scheduling across multiple cycles.
  var idx = openShmIndex(cacheRoot, create = false)
  doAssert idx.available
  let rec = recordFor(key)
  doAssert idx.submitRecord(rec.weakFingerprint.bytes,
    encodeActionResultRecord(rec))
  writeFile(readyGate, "published")
  while not fileExists(ensureGate):
    sleep(1)
  discard ensureCacheDaemon(cacheRoot, idx)
  idx.close()
  quit(ExitOk)

proc waitForGate(path: string) =
  while not fileExists(path):
    sleep(1)

proc runRecoveryLaunchWorker(cacheRoot, readyGate, ensureGate: string;
    key: int; atSeconds: uint64) =
  var idx = openShmIndex(cacheRoot, create = false)
  doAssert idx.available
  let rec = recordFor(key)
  doAssert idx.submitRecord(rec.weakFingerprint.bytes,
    encodeActionResultRecord(rec))
  writeFile(readyGate, "published")
  waitForGate(ensureGate)
  discard ensureCacheDaemon(cacheRoot, idx, atSeconds = atSeconds)
  idx.close()
  quit(ExitOk)

proc runPausedLaunchWorker(cacheRoot, readyGate, continueGate: string;
    key: int; pauseAuthorization: bool) =
  var idx = openShmIndex(cacheRoot, create = false)
  doAssert idx.available
  let rec = recordFor(key)
  doAssert idx.submitRecord(rec.weakFingerprint.bytes,
    encodeActionResultRecord(rec))
  let pause = proc () =
    writeFile(readyGate, "ready")
    waitForGate(continueGate)
  if pauseAuthorization:
    discard ensureCacheDaemon(cacheRoot, idx,
      afterAuthorizationBeforeSpawn = pause)
  else:
    discard ensureCacheDaemon(cacheRoot, idx, afterLeaseReserved = pause)
  idx.close()
  quit(ExitOk)

proc runPublishSequenceAndBlock(cacheRoot: string; key: int) =
  var idx = openShmIndex(cacheRoot, create = false)
  doAssert idx.available
  let rec = recordFor(key)
  let blockAfterSequence = proc (sequence: uint64) =
    stdout.writeLine("SEQUENCED " & $sequence)
    stdout.flushFile()
    discard stdin.readLine()
  doAssert idx.submitRecord(rec.weakFingerprint.bytes,
    encodeActionResultRecord(rec), blockAfterSequence)
  idx.close()
  quit(ExitOk)

proc runCoordReserveAndBlock(cacheRoot: string) =
  ## Pause at the exact claim-only boundary: Reservation already atomically
  ## carries PID + start fingerprint, while Guard and every identity field are
  ## still unpublished. The parent terminates this real initializer process.
  var idx = openShmIndex(cacheRoot, create = false)
  doAssert idx.available
  let pause = proc (reservation: CoordReservation) =
    stdout.writeLine("RESERVED " & $reservation.slot & " " &
      $reservation.claim & " " & $reservation.guardGeneration)
    stdout.flushFile()
    discard stdin.readLine()
  discard idx.makeCoordToken(afterReservation = pause)
  idx.close()
  quit(ExitOk)

proc runCoordCommitAndBlock(cacheRoot: string) =
  ## Pause immediately after `makeCoordToken` has returned its committed
  ## generation, before the caller can publish it in any shared reference.
  var idx = openShmIndex(cacheRoot, create = false)
  doAssert idx.available
  let token = idx.makeCoordToken()
  doAssert token != 0
  stdout.writeLine("COMMITTED " & $token)
  stdout.flushFile()
  discard stdin.readLine()
  idx.close()
  quit(ExitOk)

proc runDaemonOpenUnclaimedAndBlock(cacheRoot: string) =
  ## Exercise the production-sized window: openCacheDaemon owns a committed
  ## process-local gate token before tryClaimOwnership publishes any reference.
  var daemon = openCacheDaemon(cacheRoot)
  doAssert daemon.idx.available
  var token = 0'u64
  let me = uint64(getCurrentProcessId())
  for slot in 0 ..< CoordSlotCount:
    let sb = CtlExtCoordSlotsBase + slot * CoordSlotStride
    let guard = loadU64Acquire(daemon.idx.ctl.base,
      CtlExtCoordGuardsBase + slot * 8)
    if (guard and CoordGuardStateMask) == CoordGuardCommitted and
        loadU64Acquire(daemon.idx.ctl.base, sb + CoordSlotOffPid) == me:
      token = loadU64Acquire(daemon.idx.ctl.base, sb + CoordSlotOffToken)
      break
  doAssert token != 0
  stdout.writeLine("OPENED " & $token)
  stdout.flushFile()
  discard stdin.readLine()
  daemon.close()
  quit(ExitOk)

proc spawnedDaemonRoot(params: seq[string]): string =
  for param in params:
    if param.startsWith("--action-cache-root="):
      return param.split("=", 1)[1]

proc runSpawnedDaemon(cacheRoot: string) =
  ## The real launch-storm/exec-recovery fixtures point the production launcher
  ## at this test executable. This mode runs the actual CacheDaemon state machine
  ## in a distinct child process (not a spawn hook).
  var d = openCacheDaemon(cacheRoot)
  doAssert d.idx.available
  let deadline = epochTime() + 1.5
  let stop = proc (): bool {.closure, gcsafe.} = epochTime() >= deadline
  d.runDaemonLoop(stop, pollMs = 1, persistEveryMs = 10)
  d.close()
  quit(ExitOk)

when isMainModule:
  let params = commandLineParams()
  if params.len >= 3 and params[0] == ProducerFlag:
    runProducer(params[1], parseInt(params[2]), parseInt(params[3]))
  elif params.len >= 3 and params[0] == DaemonFlag:
    runDaemon(params[1], parseInt(params[2]))
  elif params.len >= 2 and params[0] == ClaimAndBlockFlag:
    runClaimAndBlock(params[1])
  elif params.len >= 2 and params[0] == ApplyAndBlockFlag:
    runApplyAndBlock(params[1])
  elif params.len >= 4 and params[0] == LaunchWorkerFlag:
    runLaunchWorker(params[1], params[2], parseInt(params[3]))
  elif params.len >= 5 and params[0] == TwoPhaseLaunchWorkerFlag:
    runTwoPhaseLaunchWorker(params[1], params[2], params[3],
      parseInt(params[4]))
  elif params.len >= 6 and params[0] == RecoveryLaunchWorkerFlag:
    runRecoveryLaunchWorker(params[1], params[2], params[3],
      parseInt(params[4]), parseBiggestUInt(params[5]).uint64)
  elif params.len >= 5 and params[0] == PauseLaunchReservationFlag:
    runPausedLaunchWorker(params[1], params[2], params[3],
      parseInt(params[4]), false)
  elif params.len >= 5 and params[0] == PauseLaunchAuthorizationFlag:
    runPausedLaunchWorker(params[1], params[2], params[3],
      parseInt(params[4]), true)
  elif params.len >= 3 and params[0] == PublishSequenceAndBlockFlag:
    runPublishSequenceAndBlock(params[1], parseInt(params[2]))
  elif params.len >= 2 and params[0] == CoordReserveAndBlockFlag:
    runCoordReserveAndBlock(params[1])
  elif params.len >= 2 and params[0] == CoordCommitAndBlockFlag:
    runCoordCommitAndBlock(params[1])
  elif params.len >= 2 and params[0] == DaemonOpenUnclaimedAndBlockFlag:
    runDaemonOpenUnclaimedAndBlock(params[1])
  else:
    let daemonRoot = spawnedDaemonRoot(params)
    if daemonRoot.len > 0:
      runSpawnedDaemon(daemonRoot)

proc liveKeyCount(seg: SegmentTable; i: int): int =
  ## How many live slots across the WHOLE table hold key `i` — must be exactly 1
  ## after dedup. A full scan (not a probe-terminating lookup) so a DUPLICATE
  ## (two slots with the same key — what skipping dedup produces) is detected.
  let want = weakFor(i).bytes
  for snap in seg.liveSlots():
    if snap.digest == want:
      inc result

proc waitUntil(predicate: proc (): bool {.closure.};
    timeoutSeconds = 5.0): bool =
  let deadline = epochTime() + timeoutSeconds
  while epochTime() < deadline:
    if predicate(): return true
    sleep(2)
  predicate()

proc bytesHex(raw: openArray[byte]): string =
  result = newStringOfCap(raw.len * 2)
  for value in raw:
    result.add(toHex(value, 2))

proc legacyTryClaim(idx: ShmIndex; candidatePid, atSeconds: uint64): bool =
  ## Byte-for-byte behavioral shape of origin/dev's owner election: raw PID,
  ## kill(pid,0), and an untagged epoch heartbeat. Keeping it in this binary
  ## avoids runtime compilation while exercising both coexistence directions.
  let observed = idx.rawOwnerPid()
  if observed != 0 and osProcessLiveness(observed) == plAlive:
    let age = max(0.0, float(atSeconds) - float(idx.rawOwnerHeartbeat()))
    if age <= HeartbeatTtlSeconds:
      return false
  var expected = observed
  if casU64(idx.ctl.base, CtlOffDaemonPid, expected, candidatePid):
    storeU64Release(idx.ctl.base, CtlOffDaemonHeartbeat, atSeconds)
    return true
  false

proc peerCommand(peer: var Process; command: string): string =
  peer.inputStream.writeLine(command)
  peer.inputStream.flush()
  peer.outputStream.readLine()

template exerciseBidirectionalPeer(peerBinaryStem, peerActionId,
    tempPrefix: string) =
  block:
    let tempRoot = createTempDir(tempPrefix, "")
    defer: removeDir(tempRoot)
    let cacheRoot = tempRoot / "action-cache"
    let legacyPeer = requireBinary(
      getCurrentDir() / "build" / "test-bin" /
        addFileExt(peerBinaryStem, ExeExt), peerActionId)
    var idx = openShmIndex(cacheRoot)
    require idx.available

    # The owner is a separately compiled old-algorithm daemon. Force its
    # untagged heartbeat logically stale while leaving its real process alive:
    # capable code must not TTL-steal a live legacy owner.
    var legacyOwner = startProcess(legacyPeer,
      args = @["claim-block", cacheRoot],
      options = {poStdErrToStdOut})
    defer:
      if legacyOwner.running:
        legacyOwner.terminate()
        discard legacyOwner.waitForExit()
      legacyOwner.close()
    require legacyOwner.outputStream.readLine() == "CLAIMED"
    let legacyPid = idx.rawOwnerPid()
    check legacyPid != 0
    check legacyPid != uint64(getCurrentProcessId())
    check not heartbeatIsCapable(idx.rawOwnerHeartbeat())
    storeU64Release(idx.ctl.base, CtlOffDaemonHeartbeat, 1)

    var capable = openCacheDaemon(cacheRoot)
    check not capable.tryClaimOwnership(atSeconds = 100)
    check idx.rawOwnerPid() == legacyPid
    check idx.currentOwnerIdentity().nonce == 0

    # Hard-stop the old daemon, then prove prompt capable-code recovery.
    legacyOwner.terminate()
    discard legacyOwner.waitForExit()
    check capable.tryClaimOwnership(atSeconds = 200)
    let capableOwner = idx.currentOwnerIdentity()
    check capableOwner.nonce != 0
    check capableOwner == capable.owner

    # Old election sees the tagged heartbeat as fresh and rejects its claim.
    var legacyContender = startProcess(legacyPeer,
      args = @["try-claim", cacheRoot],
      options = {poStdErrToStdOut})
    let contenderCode = legacyContender.waitForExit()
    let contenderOutput = legacyContender.outputStream.readAll().strip()
    legacyContender.close()
    check contenderCode == 0
    check contenderOutput == "REJECTED"
    check idx.currentOwnerIdentity() == capableOwner

    # Old producer -> new consumer, with an exact metadata payload check.
    let oldProducedRecord = recordFor(NumKeys + 425)
    let oldProducedPayload = encodeActionResultRecord(oldProducedRecord)
    var oldProducer = startProcess(legacyPeer, args = @[
      "produce", cacheRoot,
      bytesHex(oldProducedRecord.weakFingerprint.bytes),
      bytesHex(oldProducedPayload),
    ], options = {poStdErrToStdOut})
    let producerCode = oldProducer.waitForExit()
    let producerOutput = oldProducer.outputStream.readAll().strip()
    oldProducer.close()
    check producerCode == 0
    check producerOutput == "PRODUCED"
    check idx.ringView.pendingCount() == 1
    check capable.drainOnce() == 1
    var oldProducedSnap: SlotSnapshot
    check capable.idx.liveSeg.lookupSlot(
      oldProducedRecord.weakFingerprint.bytes, oldProducedSnap) == srsHit
    check oldProducedSnap.rec == oldProducedPayload

    # New producer -> old consumer through the complete old daemon module.
    capable.close()
    let newProducedRecord = recordFor(NumKeys + 426)
    let newProducedPayload = encodeActionResultRecord(newProducedRecord)
    check idx.submitRecord(newProducedRecord.weakFingerprint.bytes,
      newProducedPayload)
    var legacyConsumer = startProcess(legacyPeer,
      args = @["consume", cacheRoot],
      options = {poStdErrToStdOut})
    let consumerCode = legacyConsumer.waitForExit()
    let consumerOutput = legacyConsumer.outputStream.readAll().strip()
    legacyConsumer.close()
    check consumerCode == 0
    check consumerOutput == "CONSUMED " &
      bytesHex(newProducedRecord.weakFingerprint.bytes) & " " &
      bytesHex(newProducedPayload)
    check idx.ringView.pendingCount() == 0
    check idx.followLiveGeneration()
    var newProducedSnap: SlotSnapshot
    check idx.liveSeg.lookupSlot(newProducedRecord.weakFingerprint.bytes,
      newProducedSnap) == srsHit
    check newProducedSnap.rec == newProducedPayload

    # A capable successor reclaims and acknowledges the old consumer's notice.
    var successor = openCacheDaemon(cacheRoot)
    check successor.tryClaimOwnership()
    check successor.drainOnce() == 0
    check not idx.workOutstanding()
    successor.close()
    idx.close()

suite "integration_cache_daemon_drains_dedups_persists_and_warms_from_disk":
  when isNixSupported:
    test "writer gate blocks takeover until apply completes":
      let tempRoot = createTempDir("repro-daemon-fence", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var owner = openCacheDaemon(cacheRoot)
      var contender = openCacheDaemon(cacheRoot)
      var producer = openShmIndex(cacheRoot, create = false)
      check owner.tryClaimOwnership()
      check owner.beat(1)
      let rec = recordFor(NumKeys + 1)
      let payload = encodeActionResultRecord(rec)
      check producer.submitRecord(rec.weakFingerprint.bytes, payload)
      var attemptedInsideFence = false
      var claimInsideFence = true
      let tryTakeover = proc () =
        attemptedInsideFence = true
        claimInsideFence = contender.tryClaimOwnership(atSeconds = 100)
      check owner.drainOnce(afterFenceBeforeApply = tryTakeover) == 1
      check attemptedInsideFence
      check not claimInsideFence
      check owner.stillOwns()
      var snap: SlotSnapshot
      check producer.liveSeg.lookupSlot(rec.weakFingerprint.bytes, snap) == srsHit
      if producer.liveSeg.lookupSlot(rec.weakFingerprint.bytes, snap) == srsHit:
        check snap.rec == payload
      producer.close()
      contender.close()
      owner.close()

    test "new generation fences every resumed old-owner mutation":
      let tempRoot = createTempDir("repro-daemon-owner-token", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var oldOwner = openCacheDaemon(cacheRoot)
      var newOwner = openCacheDaemon(cacheRoot)
      var producer = openShmIndex(cacheRoot, create = false)
      check oldOwner.tryClaimOwnership()

      let first = recordFor(NumKeys + 10)
      check producer.submitRecord(first.weakFingerprint.bytes,
        encodeActionResultRecord(first))
      check oldOwner.drainOnce() == 1
      check oldOwner.beat(1)
      check newOwner.tryClaimOwnership(atSeconds = 100)
      check newOwner.owner.pid == oldOwner.owner.pid
      check newOwner.owner.nonce != oldOwner.owner.nonce
      check not oldOwner.stillOwns()

      var store = openActionCache(cacheRoot, attachShm = false)
      check oldOwner.persist() == 0
      check not store.readHotRecord(first.weakFingerprint).found

      let queued = recordFor(NumKeys + 11)
      check producer.submitRecord(queued.weakFingerprint.bytes,
        encodeActionResultRecord(queued))
      let genBefore = producer.currentGeneration()
      let heartbeatBefore = producer.rawOwnerHeartbeat()
      check oldOwner.drainOnce() == 0
      check not oldOwner.growIfNeeded()
      check oldOwner.persist() == 0
      check not oldOwner.beat(200)
      check not oldOwner.reclaimRetired()
      check not oldOwner.releaseOwnership()
      check producer.currentGeneration() == genBefore
      check producer.rawOwnerHeartbeat() == heartbeatBefore
      check producer.ringView.pendingCount() == 1

      let warmOnly = recordFor(NumKeys + 12)
      store.writePerEdgeRecords(warmOnly.weakFingerprint, @[warmOnly])
      check not oldOwner.warmFromDisk(warmOnly.weakFingerprint)
      check newOwner.warmFromDisk(warmOnly.weakFingerprint)
      check newOwner.drainOnce() == 1
      check newOwner.persist() >= 2
      check store.readHotRecord(first.weakFingerprint).found
      check store.readHotRecord(queued.weakFingerprint).found
      producer.close()
      newOwner.close()
      oldOwner.close()

    test "same-PID daemon objects have one exact owner generation":
      let tempRoot = createTempDir("repro-daemon-same-pid", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var first = openCacheDaemon(cacheRoot)
      var second = openCacheDaemon(cacheRoot)
      check first.tryClaimOwnership()
      let firstToken = first.owner
      check first.beat(1)
      check second.tryClaimOwnership(atSeconds = 100)
      check second.owner.pid == firstToken.pid
      check second.owner.nonce != firstToken.nonce
      check not first.stillOwns()
      check second.stillOwns()
      check second.idx.currentOwnerIdentity() == second.owner
      second.close()
      first.close()

    test "standby follows grown generation before takeover and reconstruction":
      let tempRoot = createTempDir("repro-daemon-standby-generation", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var owner = openCacheDaemon(cacheRoot, slotCap = 8)
      var standby = openCacheDaemon(cacheRoot, slotCap = 8)
      var producer = openShmIndex(cacheRoot, slotCap = 8, create = false)
      var gen0 = attachSegment(cacheRoot, 0, 8)
      check gen0.isValid
      check owner.tryClaimOwnership()
      check standby.idx.liveSeg.generation == 0

      for i in 0 ..< 8:
        let rec = recordFor(NumKeys + 100 + i)
        check producer.submitRecord(rec.weakFingerprint.bytes,
          encodeActionResultRecord(rec))
      check owner.drainOnce() == 8
      check owner.idx.currentGeneration() > 0
      let grownGeneration = owner.idx.currentGeneration()
      check owner.releaseOwnership()

      let afterGrow = recordFor(NumKeys + 109)
      let afterGrowPayload = encodeActionResultRecord(afterGrow)
      check producer.submitRecord(afterGrow.weakFingerprint.bytes,
        afterGrowPayload)
      check standby.tryClaimOwnership()
      check standby.idx.liveSeg.generation == grownGeneration
      check standby.drainOnce() == 1
      check standby.persist() >= 1

      var staleSnap: SlotSnapshot
      check gen0.lookupSlot(afterGrow.weakFingerprint.bytes, staleSnap) !=
        srsHit
      var liveSnap: SlotSnapshot
      check standby.idx.liveSeg.lookupSlot(afterGrow.weakFingerprint.bytes,
        liveSnap) == srsHit
      if standby.idx.liveSeg.lookupSlot(afterGrow.weakFingerprint.bytes,
          liveSnap) == srsHit:
        check liveSnap.rec == afterGrowPayload
      var store = openActionCache(cacheRoot, attachShm = false)
      let disk = store.readHotRecord(afterGrow.weakFingerprint)
      check disk.found
      if disk.found:
        check encodeActionResultRecord(disk.record) == afterGrowPayload
      gen0.detach()
      producer.close()
      standby.close()
      owner.close()

    test "fresh tagged PID-CAS transition recovers only after definite death":
      let tempRoot = createTempDir("repro-daemon-claim-transition", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var idx = openShmIndex(cacheRoot)
      let transitionalPid = 424_242'u64
      storeU64Release(idx.ctl.base, CtlOffDaemonHeartbeat,
        CapableHeartbeatBit or 500'u64)
      storeU64Release(idx.ctl.base, CtlOffDaemonPid, transitionalPid)
      check idx.currentOwnerIdentity().nonce == 0
      var candidate = openCacheDaemon(cacheRoot)
      let unknown = proc (identity: OwnerIdentity): ProcessLiveness {.gcsafe.} =
        plUnknown
      check not candidate.tryClaimOwnership(atSeconds = 500, probe = unknown)
      let dead = proc (identity: OwnerIdentity): ProcessLiveness {.gcsafe.} =
        if identity.pid == transitionalPid: plDead else: plUnknown
      check candidate.tryClaimOwnership(atSeconds = 500, probe = dead)
      check candidate.idx.currentOwnerIdentity() == candidate.owner
      candidate.close()
      idx.close()

    test "empty-to-nonempty acknowledgement gap drains the newer generation":
      let tempRoot = createTempDir("repro-daemon-ack-gap", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var owner = openCacheDaemon(cacheRoot)
      var producer = openShmIndex(cacheRoot, create = false)
      check owner.tryClaimOwnership()
      let rec = recordFor(NumKeys + 20)
      let payload = encodeActionResultRecord(rec)
      var injected = false
      let publishInGap = proc () =
        if not injected:
          injected = producer.submitRecord(rec.weakFingerprint.bytes, payload)
      check owner.drainOnce(beforeStableAck = publishInGap) == 0
      check injected
      check producer.ringView.pendingCount() == 1
      check producer.workAckSequence() != producer.workSequence()
      check owner.drainOnce() == 1
      check producer.ringView.pendingCount() == 0
      check producer.workAckSequence() == producer.workSequence()
      check owner.persist() == 1
      var snap: SlotSnapshot
      check producer.liveSeg.lookupSlot(rec.weakFingerprint.bytes, snap) == srsHit
      var store = openActionCache(cacheRoot, attachShm = false)
      let disk = store.readHotRecord(rec.weakFingerprint)
      check disk.found
      if disk.found:
        check encodeActionResultRecord(disk.record) == payload
      producer.close()
      owner.close()

    test "healthy sequential generations need no OS liveness probes":
      let tempRoot = createTempDir("repro-daemon-no-probes", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var owner = openCacheDaemon(cacheRoot)
      var producer = openShmIndex(cacheRoot, create = false)
      check owner.tryClaimOwnership()
      let initialProbes = producer.osLivenessProbeCount()
      for i in 0 ..< 32:
        let rec = recordFor(NumKeys + 30 + i)
        check producer.submitRecord(rec.weakFingerprint.bytes,
          encodeActionResultRecord(rec))
        check owner.drainOnce() == 1
        check not ensureCacheDaemon(cacheRoot, producer)
      check producer.osLivenessProbeCount() == initialProbes
      check producer.workAckSequence() == producer.workSequence()
      producer.close()
      owner.close()

    test "late multi-cycle burst has one bounded liveness check and no spawn":
      let tempRoot = createTempDir("repro-daemon-late-cycle-probe", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var owner = openCacheDaemon(cacheRoot)
      var producer = openShmIndex(cacheRoot, create = false)
      check owner.tryClaimOwnership(atSeconds = 100)

      # A fully acknowledged first cycle establishes the sequential baseline:
      # submit/drain generations never need a process-liveness check.
      let first = recordFor(NumKeys + 70)
      let firstPayload = encodeActionResultRecord(first)
      check producer.submitRecord(first.weakFingerprint.bytes, firstPayload)
      check owner.drainOnce() == 1
      let acknowledged = producer.workAckSequence()
      check acknowledged == producer.workSequence()
      check producer.osLivenessProbeCount() == 0

      # Two late publications before the next drain are intentionally a new
      # already-outstanding cycle. A freshly dead owner and a healthy owner in
      # this exact state are indistinguishable from shared memory alone, so
      # immediate crash recovery permits ONE elected liveness check. The live
      # answer retains the responsibility lease; every follower is syscall-free
      # and no duplicate daemon is launched.
      let second = recordFor(NumKeys + 71)
      let third = recordFor(NumKeys + 72)
      let secondPayload = encodeActionResultRecord(second)
      let thirdPayload = encodeActionResultRecord(third)
      check producer.submitRecord(second.weakFingerprint.bytes, secondPayload)
      check producer.submitRecord(third.weakFingerprint.bytes, thirdPayload)
      check producer.workAckSequence() == acknowledged
      check producer.workHadOutstandingAtStart()
      var livenessCalls = 0
      let expectedOwner = owner.owner
      let liveOwner = proc (
          identity: OwnerIdentity): ProcessLiveness {.gcsafe.} =
        inc livenessCalls
        if identity == expectedOwner: plAlive else: plUnknown
      var spawnCalls = 0
      let countedSpawn = proc (root: string;
          args: seq[string]): bool {.gcsafe.} =
        inc spawnCalls
        true
      check not ensureCacheDaemon(cacheRoot, producer,
        livenessProbe = liveOwner, spawnHook = countedSpawn, atSeconds = 100)
      check livenessCalls == 1
      check producer.osLivenessProbeCount() == 1
      check producer.daemonLaunchLease() != 0
      for _ in 0 ..< LaunchStormWorkers:
        check not ensureCacheDaemon(cacheRoot, producer,
          livenessProbe = liveOwner, spawnHook = countedSpawn, atSeconds = 100)
      check livenessCalls == 1
      check producer.osLivenessProbeCount() == 1
      check spawnCalls == 0
      check producer.daemonSpawnAttemptCount() == 0
      check producer.ownerClaimCount() == 1

      check owner.drainOnce() == 2
      check producer.daemonLaunchLease() == 0
      check producer.workAckSequence() == producer.workSequence()
      check owner.persist() == 3
      for expected in [first, second, third]:
        let expectedPayload = encodeActionResultRecord(expected)
        var snap: SlotSnapshot
        check producer.liveSeg.lookupSlot(
          expected.weakFingerprint.bytes, snap) == srsHit
        if producer.liveSeg.lookupSlot(
            expected.weakFingerprint.bytes, snap) == srsHit:
          check snap.rec == expectedPayload
        var store = openActionCache(cacheRoot, attachShm = false)
        let disk = store.readHotRecord(expected.weakFingerprint)
        check disk.found
        if disk.found:
          check encodeActionResultRecord(disk.record) == expectedPayload
      producer.close()
      owner.close()

    test "coord slots commit, revoke, reclaim, and retire exact generations":
      let tempRoot = createTempDir("repro-daemon-coord-slot-states", "")
      defer: removeDir(tempRoot)
      var idx = openShmIndex(tempRoot / "action-cache")

      # Earliest-gap PID reuse: the packed claim has no full identity fields
      # yet, but a start-fingerprint mismatch is sufficient proof that the
      # original initializer incarnation ended. Equality remains conservative.
      let fakePid = 424_260'u64
      let originalStart = 0x0123_4567_89AB_CDEF'u64
      let reusedStart = originalStart xor 0x0000_0000_0000_0001'u64
      check coordStartFingerprint(originalStart) !=
        coordStartFingerprint(reusedStart)
      var sawReuseClaim = false
      let reusedPidProbe = proc (
          pid: uint64): CoordClaimObservation {.gcsafe.} =
        sawReuseClaim = pid == fakePid
        CoordClaimObservation(liveness: plAlive, startToken: reusedStart)
      let recoverEarliest = proc (reservation: CoordReservation) =
        check coordClaimPid(reservation.claim) == fakePid
        check coordClaimStartFingerprint(reservation.claim) ==
          coordStartFingerprint(originalStart)
        check idx.coordIdentity(0xD001_0000_0000_0001'u64).nonce == 0
        check idx.reclaimAbandonedCoordReservations(
          claimProbe = reusedPidProbe) == 1
      check idx.makeCoordToken(fakePid, startToken = originalStart,
        forcedNonce = 0xD001_0000_0000_0001'u64,
        afterReservation = recoverEarliest) == 0
      check sawReuseClaim

      # A folded equality can be a collision and therefore cannot authorize
      # reclaim. Simulated EPERM/unknown similarly protects the live holder.
      let collidingStart =
        originalStart xor (1'u64 shl 32) xor 1'u64
      check collidingStart != originalStart
      check coordStartFingerprint(collidingStart) ==
        coordStartFingerprint(originalStart)
      var protectedReservation: CoordReservation
      var equalFoldCalls = 0
      let equalFoldClaim = proc (
          pid: uint64): CoordClaimObservation {.gcsafe.} =
        inc equalFoldCalls
        check pid == fakePid
        CoordClaimObservation(liveness: plAlive,
          startToken: collidingStart)
      var unknownCalls = 0
      let unknownClaim = proc (
          pid: uint64): CoordClaimObservation {.gcsafe.} =
        inc unknownCalls
        check pid == fakePid
        CoordClaimObservation(liveness: plUnknown,
          startToken: reusedStart)
      let protectBeforeCommit = proc (reservation: CoordReservation) =
        protectedReservation = reservation
        check idx.reclaimAbandonedCoordReservations(
          claimProbe = equalFoldClaim) == 0
        check idx.reclaimAbandonedCoordReservations(
          claimProbe = unknownClaim) == 0
      let protectedToken = idx.makeCoordToken(fakePid,
        startToken = collidingStart,
        forcedNonce = 0xD001_0000_0000_0002'u64,
        afterReservation = protectBeforeCommit)
      check protectedToken == 0xD001_0000_0000_0002'u64
      check equalFoldCalls == 1
      check unknownCalls == 1
      check not idx.cancelCoordReservation(protectedReservation)
      check idx.releaseCoordToken(protectedToken)

      # The packed claim intentionally repeats for same-PID/same-incarnation
      # objects. A stale pre-guard cancellation handle must still be rejected
      # because only the successor's exact generation may change its guard.
      let rejectStaleCancellation = proc (
          successorReservation: CoordReservation) =
        check successorReservation.claim == protectedReservation.claim
        check successorReservation.guardGeneration !=
          protectedReservation.guardGeneration
        check not idx.cancelCoordReservation(protectedReservation)
      let sameProcessSuccessor = idx.makeCoordToken(fakePid,
        startToken = collidingStart,
        forcedNonce = 0xD001_0000_0000_0013'u64,
        afterReservation = rejectStaleCancellation)
      check sameProcessSuccessor == 0xD001_0000_0000_0013'u64
      check idx.releaseCoordToken(sameProcessSuccessor)

      # Cancellation can also win after an ordinary identity store. The slot
      # stays quarantined until the resumed initializer observes the exact lost
      # guard, scrubs its own possible stale write, and publishes Free.
      var writeReservation: CoordReservation
      let captureWriteReservation = proc (reservation: CoordReservation) =
        writeReservation = reservation
      let cancelAfterWrite = proc (reservation: CoordReservation) =
        check reservation == writeReservation
        check idx.cancelCoordReservation(reservation)
      check idx.makeCoordToken(
        forcedNonce = 0xD001_0000_0000_0012'u64,
        afterReservation = captureWriteReservation,
        afterIdentityWrite = cancelAfterWrite) == 0
      let cancelledSlotBase =
        CtlExtCoordSlotsBase + writeReservation.slot * CoordSlotStride
      check loadU64Acquire(idx.ctl.base,
        cancelledSlotBase + CoordSlotOffReservation) == 0
      check loadU64Acquire(idx.ctl.base,
        CtlExtCoordGuardsBase + writeReservation.slot * 8) == 0

      # A reclaimer observing a live provisional generation cannot clear it;
      # initialization commits after that observation. A live or indeterminate
      # committed holder remains protected, while a definitely dead committed
      # holder is covered by the process-level saturation test below.
      var committedReservation: CoordReservation
      var liveCalls = 0
      let liveClaim = proc (
          pid: uint64): CoordClaimObservation {.gcsafe.} =
        inc liveCalls
        CoordClaimObservation(liveness: plAlive,
          startToken: processStartToken(pid))
      let observeBeforeCommit = proc (reservation: CoordReservation) =
        committedReservation = reservation
        check idx.reclaimAbandonedCoordReservations(
          claimProbe = liveClaim) == 0
      let committedToken = idx.makeCoordToken(
        forcedNonce = 0xD001_0000_0000_0003'u64,
        afterReservation = observeBeforeCommit)
      check committedToken == 0xD001_0000_0000_0003'u64
      check liveCalls == 1
      check not idx.cancelCoordReservation(committedReservation)
      var committedProbeCalls = 0
      let liveCommitted = proc (
          identity: OwnerIdentity): ProcessLiveness {.gcsafe.} =
        inc committedProbeCalls
        plAlive
      check idx.reclaimAbandonedCoordReservations(
        identityProbe = liveCommitted) == 0
      check committedProbeCalls == 1
      let unknownCommitted = proc (
          identity: OwnerIdentity): ProcessLiveness {.gcsafe.} =
        inc committedProbeCalls
        plUnknown
      check idx.reclaimAbandonedCoordReservations(
        identityProbe = unknownCommitted) == 0
      check committedProbeCalls == 2
      check idx.coordIdentity(committedToken).nonce == committedToken

      # An old exact guard generation cannot retire a successor even after the
      # old release has completed and the physical slot is recycled.
      let oldGuardOffset =
        CtlExtCoordGuardsBase + committedReservation.slot * 8
      let oldCommittedGuard =
        loadU64Acquire(idx.ctl.base, oldGuardOffset)
      check oldCommittedGuard ==
        (committedReservation.guardGeneration or CoordGuardCommitted)
      check idx.releaseCoordToken(committedToken)
      var successorReservation: CoordReservation
      let captureSuccessor = proc (reservation: CoordReservation) =
        successorReservation = reservation
      let successorToken = idx.makeCoordToken(
        forcedNonce = 0xD001_0000_0000_0004'u64,
        afterReservation = captureSuccessor)
      check successorToken == 0xD001_0000_0000_0004'u64
      check successorReservation.slot == committedReservation.slot
      check successorReservation.guardGeneration !=
        committedReservation.guardGeneration
      let guardOffset =
        CtlExtCoordGuardsBase + successorReservation.slot * 8
      var staleGuard = oldCommittedGuard
      check not casU64(idx.ctl.base, guardOffset, staleGuard,
        committedReservation.guardGeneration or CoordGuardRetiring)
      check idx.coordIdentity(successorToken).nonce == successorToken
      check idx.releaseCoordToken(successorToken)

      let finalToken = idx.makeCoordToken(
        forcedNonce = 0xD001_0000_0000_0005'u64)
      check finalToken == 0xD001_0000_0000_0005'u64
      check idx.releaseCoordToken(finalToken)
      idx.close()

    test "definite-dead committed records retire every exact shared reference":
      let tempRoot = createTempDir("repro-daemon-committed-references", "")
      defer: removeDir(tempRoot)
      var idx = openShmIndex(tempRoot / "action-cache")
      var nextPid = 424_300'u64
      var nextNonce = 0xD002_0000_0000_0000'u64
      let definitelyDead = proc (
          identity: OwnerIdentity): ProcessLiveness {.gcsafe.} =
        plDead
      proc deadToken(): uint64 =
        inc nextPid
        inc nextNonce
        idx.makeCoordToken(nextPid, startToken = nextPid + 1,
          forcedNonce = nextNonce)

      let unreferenced = deadToken()
      check unreferenced != 0
      check idx.reclaimAbandonedCoordReservations(
        identityProbe = definitelyDead) == 1
      check idx.coordIdentity(unreferenced).nonce == 0

      let gateHolder = deadToken()
      check idx.tryAcquireWriterGate(gateHolder)
      check idx.writerGateToken() == gateHolder
      check idx.reclaimAbandonedCoordReservations(
        identityProbe = definitelyDead) == 1
      check idx.writerGateToken() == 0
      check idx.coordIdentity(gateHolder).nonce == 0

      let leaseHolder = deadToken()
      var noLease = 0'u64
      check casU64(idx.ctl.base, CtlExtOffLaunchLease, noLease, leaseHolder)
      storeU64Release(idx.ctl.base, CtlExtOffLaunchStartedToken, leaseHolder)
      storeU64Release(idx.ctl.base, CtlExtOffLaunchStarted, 700)
      check idx.reclaimAbandonedCoordReservations(
        identityProbe = definitelyDead) == 1
      check idx.daemonLaunchLease() == 0
      check loadU64Acquire(idx.ctl.base,
        CtlExtOffLaunchStartedToken) == 0
      check idx.coordIdentity(leaseHolder).nonce == 0

      let ownerToken = deadToken()
      let owner = idx.coordIdentity(ownerToken)
      storeU64Release(idx.ctl.base, CtlOffDaemonPid, owner.pid)
      idx.publishOwnerIdentity(owner)
      idx.publishCapableHeartbeat(700)
      check idx.currentOwnerIdentity() == owner
      check idx.reclaimAbandonedCoordReservations(
        identityProbe = definitelyDead) == 1
      check idx.currentOwnerIdentity().nonce == 0
      check idx.rawOwnerPid() == 0
      check idx.rawOwnerHeartbeat() == 0
      check idx.writerGateToken() == 0
      check idx.coordIdentity(ownerToken).nonce == 0
      idx.close()

    test "terminal cleanup resumes Retiring and Reclaiming past slot capacity":
      let tempRoot = createTempDir("repro-daemon-terminal-resume", "")
      defer: removeDir(tempRoot)
      var idx = openShmIndex(tempRoot / "action-cache")

      # The original exact holder takes the zero-probe fast path. Interrupt each
      # free boundary more than 48 times so Retiring can never become a
      # capacity-consuming terminal sink.
      let retiringStages = [
        ccsTerminalPublished,
        ccsAfterWriterGateClear,
        ccsAfterReservationClear,
        ccsAfterGuardClear]
      for i in 0 ..< AbandonedCoordInitializers:
        var reservation: CoordReservation
        let token = idx.makeCoordToken(
          forcedNonce = 0xD002_1000_0000_0000'u64 + uint64(i + 1),
          afterReservation = proc (value: CoordReservation) =
            reservation = value)
        check token != 0
        let stopAt = retiringStages[i mod retiringStages.len]
        var interrupted = false
        let interrupt = proc (stage: CoordCleanupStage; slot: int;
            guard, observedToken: uint64) =
          if stage == stopAt:
            check slot == reservation.slot
            check guard == 0 or
              (guard and CoordGuardStateMask) == CoordGuardRetiring
            check observedToken == token
            interrupted = true
            raise newException(IOError, "retiring cleanup interruption")
        try:
          discard idx.releaseCoordToken(token,
            afterCleanupStep = interrupt)
        except IOError:
          discard
        check interrupted
        if stopAt != ccsAfterGuardClear:
          check idx.releaseCoordToken(token)
        check loadU64Acquire(idx.ctl.base,
          CtlExtCoordGuardsBase + reservation.slot * 8) == 0
        check loadU64Acquire(idx.ctl.base,
          CtlExtCoordSlotsBase + reservation.slot * CoordSlotStride +
            CoordSlotOffReservation) == 0
        check loadU32Acquire(idx.ctl.base,
          CtlExtCoordCleanupTicketsBase +
            reservation.slot * CoordCleanupTicketStride) == 0
        check loadU64Acquire(idx.ctl.base, CtlExtOffCleanupClaim) == 0

      # A dead committed holder enters Reclaiming. Exercise the unclaimed
      # terminal, claimed terminal, Reservation-cleared, and Guard-cleared
      # boundaries. The final case proves Guard=0 + ticket!=0 remains
      # quarantined and is completed by the next bounded recovery pass.
      let reclaimingStages = [
        ccsTerminalPublished,
        ccsCleanupClaimed,
        ccsAfterWriterGateClear,
        ccsAfterReservationClear,
        ccsAfterGuardClear]
      let definitelyDead = proc (
          identity: OwnerIdentity): ProcessLiveness {.gcsafe.} =
        plDead
      for i in 0 ..< AbandonedCoordInitializers:
        var reservation: CoordReservation
        let token = idx.makeCoordToken(
          pid = 425_000'u64 + uint64(i),
          startToken = 0xA500_0000'u64 + uint64(i),
          forcedNonce = 0xD002_2000_0000_0000'u64 + uint64(i + 1),
          afterReservation = proc (value: CoordReservation) =
            reservation = value)
        check token != 0
        let stopAt = reclaimingStages[i mod reclaimingStages.len]
        var interrupted = false
        let interrupt = proc (stage: CoordCleanupStage; slot: int;
            guard, observedToken: uint64) =
          if stage == stopAt:
            check slot == reservation.slot
            check guard == 0 or
              (guard and CoordGuardStateMask) == CoordGuardReclaiming
            check observedToken == token
            interrupted = true
            raise newException(IOError, "reclaiming cleanup interruption")
        try:
          discard idx.reclaimAbandonedCoordReservations(
            identityProbe = definitelyDead,
            afterCleanupStep = interrupt)
        except IOError:
          discard
        check interrupted
        check idx.reclaimAbandonedCoordReservations(
          identityProbe = definitelyDead) == 1
        check loadU64Acquire(idx.ctl.base,
          CtlExtCoordGuardsBase + reservation.slot * 8) == 0
        check loadU64Acquire(idx.ctl.base,
          CtlExtCoordSlotsBase + reservation.slot * CoordSlotStride +
            CoordSlotOffReservation) == 0
        check loadU32Acquire(idx.ctl.base,
          CtlExtCoordCleanupTicketsBase +
            reservation.slot * CoordCleanupTicketStride) == 0
        check loadU64Acquire(idx.ctl.base, CtlExtOffCleanupClaim) == 0

      # Both 64-cycle campaigns left the physical table genuinely reusable.
      let proof = idx.makeCoordToken(
        forcedNonce = 0xD002_3000_0000_0001'u64)
      check proof != 0
      check idx.releaseCoordToken(proof)
      idx.close()

    test "terminal cleanup claimant protects live unknown and same claims":
      let tempRoot = createTempDir("repro-daemon-cleanup-claim", "")
      defer: removeDir(tempRoot)
      var idx = openShmIndex(tempRoot / "action-cache")
      let originalDead = proc (
          identity: OwnerIdentity): ProcessLiveness {.gcsafe.} =
        plDead

      proc forceReclaiming(token: uint64;
          reservation: CoordReservation): uint64 =
        let guardOffset =
          CtlExtCoordGuardsBase + reservation.slot * 8
        let committed =
          reservation.guardGeneration or CoordGuardCommitted
        result = reservation.guardGeneration or CoordGuardReclaiming
        var exact = committed
        check casU64(idx.ctl.base, guardOffset, exact, result)

      proc installCleanupClaim(reservation: CoordReservation; pid,
          start, epoch: uint64) =
        let claim =
          (uint64(coordStartFingerprint(start)) shl 32) or pid
        check claim != 0
        check uint32(epoch) != 0
        storeU64Release(idx.ctl.base, CtlExtOffCleanupClaim, claim)
        storeU64Release(idx.ctl.base, CtlExtOffCleanupStart, start)
        storeU64Release(idx.ctl.base, CtlExtOffCleanupStartClaim, claim)
        storeU64Release(idx.ctl.base, CtlExtOffCleanupEpoch, epoch)
        storeU32Release(idx.ctl.base,
          CtlExtCoordCleanupTicketsBase +
            reservation.slot * CoordCleanupTicketStride,
          uint32(epoch))

      var protectedReservation: CoordReservation
      let protected = idx.makeCoordToken(pid = 426_000'u64,
        startToken = 0xB600_0001'u64,
        forcedNonce = 0xD002_3500_0000_0001'u64,
        afterReservation = proc (value: CoordReservation) =
          protectedReservation = value)
      check protected != 0
      discard forceReclaiming(protected, protectedReservation)
      let cleanupPid = 426_100'u64
      let cleanupStart = 0xB610_0001'u64
      installCleanupClaim(protectedReservation, cleanupPid, cleanupStart,
        0xC100_0001'u64)
      let aliveCleanup = proc (
          pid: uint64): CoordClaimObservation {.gcsafe.} =
        check pid == cleanupPid
        CoordClaimObservation(liveness: plAlive,
          startToken: cleanupStart)
      let unknownCleanup = proc (
          pid: uint64): CoordClaimObservation {.gcsafe.} =
        check pid == cleanupPid
        CoordClaimObservation(liveness: plUnknown,
          startToken: cleanupStart)
      check idx.reclaimAbandonedCoordReservations(
        identityProbe = originalDead,
        cleanupClaimProbe = aliveCleanup) == 0
      check idx.reclaimAbandonedCoordReservations(
        identityProbe = originalDead,
        cleanupClaimProbe = unknownCleanup) == 0
      let deadCleanup = proc (
          pid: uint64): CoordClaimObservation {.gcsafe.} =
        CoordClaimObservation(liveness: plDead)
      check idx.reclaimAbandonedCoordReservations(
        identityProbe = originalDead,
        cleanupClaimProbe = deadCleanup) == 1
      check idx.coordIdentity(protected).nonce == 0

      # A folded-start collision produces the same packed claim. Even a hostile
      # "dead" seam cannot turn equality into takeover authority; exact start
      # association protects it conservatively.
      var sameClaimReservation: CoordReservation
      let sameClaimToken = idx.makeCoordToken(pid = 426_200'u64,
        startToken = 0xB620_0001'u64,
        forcedNonce = 0xD002_3500_0000_0002'u64,
        afterReservation = proc (value: CoordReservation) =
          sameClaimReservation = value)
      check sameClaimToken != 0
      discard forceReclaiming(sameClaimToken, sameClaimReservation)
      let currentPid = uint64(getCurrentProcessId())
      let currentStart = processStartToken(currentPid)
      let collidingStart =
        currentStart xor (1'u64 shl 32) xor 1'u64
      check coordStartFingerprint(collidingStart) ==
        coordStartFingerprint(currentStart)
      installCleanupClaim(sameClaimReservation, currentPid, collidingStart,
        0xC100_0002'u64)
      check idx.reclaimAbandonedCoordReservations(
        identityProbe = originalDead,
        cleanupClaimProbe = deadCleanup) == 0
      storeU64Release(idx.ctl.base, CtlExtOffCleanupStart, currentStart)
      check idx.reclaimAbandonedCoordReservations(
        identityProbe = originalDead) == 1
      check idx.coordIdentity(sameClaimToken).nonce == 0
      idx.close()

    test "interruption before final WriterGate clear keeps identity recoverable":
      let tempRoot = createTempDir("repro-daemon-gate-final-clear", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var idx = openShmIndex(cacheRoot)
      var reservation: CoordReservation
      let token = idx.makeCoordToken(
        forcedNonce = 0xD002_4000_0000_0001'u64,
        afterReservation = proc (value: CoordReservation) =
          reservation = value)
      check token != 0
      check idx.tryAcquireWriterGate(token)
      let owner = idx.coordIdentity(token)
      storeU64Release(idx.ctl.base, CtlOffDaemonPid, owner.pid)
      idx.publishOwnerIdentity(owner)
      idx.publishCapableHeartbeat(700)

      var interrupted = false
      let interrupt = proc (stage: CoordCleanupStage; slot: int;
          guard, observedToken: uint64) =
        if stage == ccsBeforeWriterGateClear:
          check slot == reservation.slot
          check (guard and CoordGuardStateMask) == CoordGuardRetiring
          check observedToken == token
          # All owner fields are gone, but the final gate still resolves through
          # the unchanged terminal slot identity.
          check idx.writerGateToken() == token
          check idx.currentOwnerIdentity().nonce == 0
          check idx.rawOwnerPid() == 0
          check idx.rawOwnerHeartbeat() == 0
          check idx.coordIdentity(token) == owner
          interrupted = true
          raise newException(IOError, "before final writer-gate clear")
      try:
        discard idx.releaseCoordToken(token, afterCleanupStep = interrupt)
      except IOError:
        discard
      check interrupted
      check idx.writerGateToken() == token
      check idx.coordIdentity(token) == owner
      check idx.releaseCoordToken(token)
      check idx.writerGateToken() == 0
      check idx.coordIdentity(token).nonce == 0

      # Prove that the recovered mapping still supports a fresh app handle,
      # shared-memory publication, and durable Tier-1 persistence.
      let rec = recordFor(NumKeys + 777)
      let payload = encodeActionResultRecord(rec)
      check idx.submitRecord(rec.weakFingerprint.bytes, payload)
      var daemon = openCacheDaemon(cacheRoot)
      check daemon.tryClaimOwnership()
      check daemon.drainOnce() == 1
      check daemon.persist() == 1
      var follower = openShmIndex(cacheRoot, create = false)
      var snapshot: SlotSnapshot
      check follower.liveSeg.lookupSlot(
        rec.weakFingerprint.bytes, snapshot) == srsHit
      if follower.liveSeg.lookupSlot(
          rec.weakFingerprint.bytes, snapshot) == srsHit:
        check snapshot.rec == payload
      var disk = openActionCache(cacheRoot, attachShm = false)
      let persisted = disk.readHotRecord(rec.weakFingerprint)
      check persisted.found
      if persisted.found:
        check encodeActionResultRecord(persisted.record) == payload
      follower.close()
      daemon.close()
      idx.close()

    test "coord field updater quarantines release until its exact store ends":
      let tempRoot = createTempDir("repro-daemon-coord-update-release", "")
      defer: removeDir(tempRoot)
      var idx = openShmIndex(tempRoot / "action-cache")
      var originalReservation: CoordReservation
      let original = idx.makeCoordToken(
        forcedNonce = 0xD003_0000_0000_0001'u64,
        afterReservation = proc (reservation: CoordReservation) =
          originalReservation = reservation)
      check original != 0
      var successorReservation: CoordReservation
      var successor = 0'u64
      let releaseWhileUpdating = proc (token: uint64) =
        check token == original
        let guard = loadU64Acquire(idx.ctl.base,
          CtlExtCoordGuardsBase + originalReservation.slot * 8)
        check (guard and CoordGuardStateMask) == CoordGuardUpdating
        check not idx.releaseCoordToken(original)
        let requested = loadU64Acquire(idx.ctl.base,
          CtlExtCoordGuardsBase + originalReservation.slot * 8)
        check (requested and CoordGuardStateMask) ==
          CoordGuardRetireRequested
        successor = idx.makeCoordToken(
          forcedNonce = 0xD003_0000_0000_0002'u64,
          afterReservation = proc (reservation: CoordReservation) =
            successorReservation = reservation)
        check successor != 0
        check successorReservation.slot != originalReservation.slot
      check not idx.tryAcquireWriterGate(original,
        afterGateUpdateLock = releaseWhileUpdating)
      check idx.coordIdentity(original).nonce == 0
      check idx.writerGateToken() == 0
      check idx.coordIdentity(successor).nonce == successor
      check idx.releaseCoordToken(successor)

      var recycledReservation: CoordReservation
      let recycled = idx.makeCoordToken(
        forcedNonce = 0xD003_0000_0000_0003'u64,
        afterReservation = proc (reservation: CoordReservation) =
          recycledReservation = reservation)
      check recycled != 0
      check recycledReservation.slot == originalReservation.slot
      let recycledBase =
        CtlExtCoordSlotsBase + recycledReservation.slot * CoordSlotStride
      check loadU64Acquire(idx.ctl.base,
        recycledBase + CoordSlotOffGateStarted) == 0
      check idx.releaseCoordToken(recycled)
      idx.close()

    test "owner snapshot generation rejects same-PID nonce reassignment ABA":
      let tempRoot = createTempDir("repro-daemon-owner-snapshot-generation", "")
      defer: removeDir(tempRoot)
      var idx = openShmIndex(tempRoot / "action-cache")
      let me = uint64(getCurrentProcessId())
      let start = processStartToken(me)
      let firstToken = idx.makeCoordToken(me, startToken = start,
        forcedNonce = 0xD004_0000_0000_0001'u64)
      let secondToken = idx.makeCoordToken(me, startToken = start,
        forcedNonce = 0xD004_0000_0000_0002'u64)
      let first = idx.coordIdentity(firstToken)
      let second = idx.coordIdentity(secondToken)
      storeU64Release(idx.ctl.base, CtlOffDaemonPid, me)
      idx.publishOwnerIdentity(first)
      idx.publishCapableHeartbeat(700)
      var reassigned = false
      let reassignMidSnapshot = proc (generation: uint64) =
        check generation == firstToken
        idx.publishOwnerIdentity(second)
        idx.publishCapableHeartbeat(701)
        reassigned = true
      check idx.currentOwnerIdentity(reassignMidSnapshot).nonce == 0
      check reassigned
      check idx.currentOwnerIdentity() == second
      check loadU64Acquire(idx.ctl.base,
        CtlExtOffOwnerMagic) == secondToken
      check idx.releaseCoordToken(firstToken)
      check idx.releaseCoordToken(secondToken)
      check idx.rawOwnerPid() == 0
      check idx.currentOwnerIdentity().nonce == 0
      idx.close()

    test "launch lease has full age and exact-token release semantics":
      let tempRoot = createTempDir("repro-daemon-lease-age", "")
      defer: removeDir(tempRoot)
      var idx = openShmIndex(tempRoot / "action-cache")
      let oldToken = idx.tryAcquireDaemonLaunchLease(nowSeconds = 100)
      check oldToken != 0
      check idx.daemonLaunchStarted(oldToken) == 100
      check idx.tryAcquireDaemonLaunchLease(
        nowSeconds = 100 + DaemonLaunchLeaseTtlSeconds) == 0
      let farFuture = 100'u64 + 256_000'u64
      let successor = idx.tryAcquireDaemonLaunchLease(nowSeconds = farFuture)
      check successor != 0
      check successor != oldToken
      check idx.daemonLaunchStarted(successor) == farFuture
      check not idx.releaseDaemonLaunchLease(oldToken)
      check idx.daemonLaunchLease() == successor
      check idx.releaseDaemonLaunchLease(successor)
      idx.close()

    test "a launcher fenced during liveness cannot act for a successor lease":
      let tempRoot = createTempDir("repro-daemon-lease-revalidate", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var owner = openCacheDaemon(cacheRoot)
      var idx = openShmIndex(cacheRoot, create = false)
      check owner.tryClaimOwnership()
      let first = recordFor(NumKeys + 70)
      let second = recordFor(NumKeys + 71)
      check idx.submitRecord(first.weakFingerprint.bytes,
        encodeActionResultRecord(first))
      check idx.submitRecord(second.weakFingerprint.bytes,
        encodeActionResultRecord(second))

      var successorToken = 0'u64
      let successorCandidate = idx.makeCoordToken()
      let base = idx.ctl.base
      let replaceLease = proc (
          identity: OwnerIdentity): ProcessLiveness {.gcsafe.} =
        let predecessor = loadU64Acquire(base, CtlExtOffLaunchLease)
        if predecessor != 0:
          var expected = predecessor
          if casU64(base, CtlExtOffLaunchLease, expected,
              successorCandidate):
            storeU64Release(base, CtlExtOffLaunchStarted, 700)
            storeU64Release(base, CtlExtOffLaunchStartedToken,
              successorCandidate)
            successorToken = successorCandidate
        plDead
      var spawns = 0
      let countedSpawn = proc (root: string;
          args: seq[string]): bool {.gcsafe.} =
        inc spawns
        true
      check not ensureCacheDaemon(cacheRoot, idx,
        livenessProbe = replaceLease, spawnHook = countedSpawn)
      check successorToken != 0
      check idx.daemonLaunchLease() == successorToken
      check spawns == 0
      check idx.releaseDaemonLaunchLease(successorToken)
      idx.close()
      owner.close()

    test "pre-spawn authorization gate excludes an expired successor":
      let tempRoot = createTempDir("repro-daemon-spawn-authorization", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var idx = openShmIndex(cacheRoot)
      let rec = recordFor(NumKeys + 72)
      check idx.submitRecord(rec.weakFingerprint.bytes,
        encodeActionResultRecord(rec))
      var spawns = 0
      var successorResult = true
      let countedSpawn = proc (root: string;
          args: seq[string]): bool {.gcsafe.} =
        inc spawns
        true
      let tryExpiredSuccessor = proc () =
        successorResult = ensureCacheDaemon(cacheRoot, idx,
          spawnHook = countedSpawn,
          atSeconds = 100 + DaemonLaunchLeaseTtlSeconds + 1)
      check ensureCacheDaemon(cacheRoot, idx, spawnHook = countedSpawn,
        atSeconds = 100,
        afterAuthorizationBeforeSpawn = tryExpiredSuccessor)
      check not successorResult
      check spawns == 1
      check idx.daemonSpawnAttemptCount() == 1
      let lease = idx.daemonLaunchLease()
      check lease != 0
      check idx.coordFlags(lease) == 2
      check idx.releaseDaemonLaunchLease(lease)
      idx.close()

    test "fresh launch gate is probe-free for the spawned daemon contender":
      let tempRoot = createTempDir("repro-daemon-launch-gate-contender", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var idx = openShmIndex(cacheRoot)
      var candidate = openCacheDaemon(cacheRoot)
      let transitionContender = idx.makeCoordToken(startedSeconds = 100)
      check transitionContender != 0
      let rec = recordFor(NumKeys + 73)
      check idx.submitRecord(rec.weakFingerprint.bytes,
        encodeActionResultRecord(rec))

      var livenessCalls = 0
      let liveLauncher = proc (
          identity: OwnerIdentity): ProcessLiveness {.gcsafe.} =
        inc livenessCalls
        plAlive
      var contended = false
      let contendBeforeLauncherUnlock = proc () =
        let lease = idx.daemonLaunchLease()
        check lease != 0
        check idx.writerGateToken() == lease
        contended = true
        check not candidate.tryClaimOwnership(
          atSeconds = 100, probe = liveLauncher)
        # The launcher publishes its post-spawn diagnostic phase before
        # releasing WriterGate. Its immutable, previously committed identity
        # remains coherent while the exact guard is update-locked.
        var updateContended = false
        let contendDuringPhaseUpdate = proc (token: uint64) =
          check token == lease
          check idx.writerGateToken() == lease
          updateContended = true
          check not candidate.tryClaimOwnership(
            atSeconds = 100, probe = liveLauncher)
        check idx.setCoordFlags(lease, 1,
          afterUpdateLock = contendDuringPhaseUpdate)
        check updateContended

        # A committed -> Updating transition between association snapshot and
        # revalidation is the same safe launch generation, not reassignment.
        # Force that exact interleaving without a scheduler race.
        var transitionedSlot = -1
        var committedGuard = 0'u64
        let transitionAfterAssociationRead = proc (token: uint64) =
          check token == lease
          for slot in 0 ..< CoordSlotCount:
            let sb = CtlExtCoordSlotsBase + slot * CoordSlotStride
            if loadU64Acquire(idx.ctl.base,
                sb + CoordSlotOffToken) == lease:
              let guardOffset = CtlExtCoordGuardsBase + slot * 8
              committedGuard = loadU64Acquire(idx.ctl.base, guardOffset)
              check (committedGuard and CoordGuardStateMask) ==
                CoordGuardCommitted
              var exact = committedGuard
              check casU64(idx.ctl.base, guardOffset, exact,
                (committedGuard and not CoordGuardStateMask) or
                  CoordGuardUpdating)
              transitionedSlot = slot
              break
        check not idx.tryAcquireWriterGate(transitionContender,
          probe = liveLauncher,
          atSeconds = 100,
          afterLaunchAssociationRead = transitionAfterAssociationRead)
        check transitionedSlot >= 0
        if transitionedSlot >= 0:
          let guardOffset =
            CtlExtCoordGuardsBase + transitionedSlot * 8
          var updating =
            (committedGuard and not CoordGuardStateMask) or
              CoordGuardUpdating
          check casU64(idx.ctl.base, guardOffset, updating, committedGuard)
      let successfulSpawn = proc (root: string;
          args: seq[string]): bool {.gcsafe.} =
        true

      check ensureCacheDaemon(cacheRoot, idx,
        livenessProbe = liveLauncher,
        spawnHook = successfulSpawn,
        atSeconds = 100,
        afterAuthorizationBeforeSpawn = contendBeforeLauncherUnlock)
      check contended
      check livenessCalls == 0
      check idx.osLivenessProbeCount() == 0

      # Once the launcher releases the gate, the same daemon candidate claims,
      # drains the published payload, and acknowledges the exact launch lease.
      let lease = idx.daemonLaunchLease()
      check lease != 0
      check candidate.tryClaimOwnership(atSeconds = 100,
        probe = liveLauncher)
      check candidate.drainOnce() == 1
      check candidate.persist() == 1
      check idx.daemonLaunchLease() == 0
      check livenessCalls == 0
      var snap: SlotSnapshot
      check idx.liveSeg.lookupSlot(
        rec.weakFingerprint.bytes, snap) == srsHit
      if idx.liveSeg.lookupSlot(
          rec.weakFingerprint.bytes, snap) == srsHit:
        check snap.rec == encodeActionResultRecord(rec)
      var store = openActionCache(cacheRoot, attachShm = false)
      let disk = store.readHotRecord(rec.weakFingerprint)
      check disk.found
      if disk.found:
        check encodeActionResultRecord(disk.record) ==
          encodeActionResultRecord(rec)
      candidate.close()
      check idx.releaseCoordToken(transitionContender)

      # Expiry preserves the existing liveness policy: unknown/EPERM protects
      # the exact holder, while definite death performs bounded cleanup and
      # lets the contender acquire without waiting beyond the launch TTL.
      let expiredLease =
        idx.tryAcquireDaemonLaunchLease(nowSeconds = 200)
      check expiredLease != 0
      check idx.tryAcquireWriterGate(expiredLease, atSeconds = 200)
      let expiryContender = idx.makeCoordToken(startedSeconds = 200)
      check expiryContender != 0
      var expiryProbeCalls = 0
      let unknownExpired = proc (
          identity: OwnerIdentity): ProcessLiveness {.gcsafe.} =
        inc expiryProbeCalls
        check identity.nonce == expiredLease
        plUnknown
      check not idx.tryAcquireWriterGate(expiryContender,
        probe = unknownExpired,
        atSeconds = 200 + DaemonLaunchLeaseTtlSeconds + 1)
      check expiryProbeCalls == 1
      check idx.writerGateToken() == expiredLease
      let deadExpired = proc (
          identity: OwnerIdentity): ProcessLiveness {.gcsafe.} =
        inc expiryProbeCalls
        check identity.nonce == expiredLease
        plDead
      check idx.tryAcquireWriterGate(expiryContender,
        probe = deadExpired,
        atSeconds = 200 + DaemonLaunchLeaseTtlSeconds + 1)
      check expiryProbeCalls == 2
      check idx.daemonLaunchLease() == 0
      check idx.writerGateToken() == expiryContender
      check idx.releaseWriterGate(expiryContender)
      check idx.releaseCoordToken(expiryContender)

      # A different live launch lease never suppresses recovery for the exact
      # token actually observed in WriterGate.
      let unrelatedLease =
        idx.tryAcquireDaemonLaunchLease(nowSeconds = 300)
      let mismatchedHolder = idx.makeCoordToken(startedSeconds = 300)
      let mismatchContender = idx.makeCoordToken(startedSeconds = 300)
      check unrelatedLease != 0
      check mismatchedHolder != 0
      check mismatchContender != 0
      check idx.tryAcquireWriterGate(mismatchedHolder, atSeconds = 300)
      var mismatchProbeCalls = 0
      let unknownMismatch = proc (
          identity: OwnerIdentity): ProcessLiveness {.gcsafe.} =
        inc mismatchProbeCalls
        check identity.nonce == mismatchedHolder
        plUnknown
      check not idx.tryAcquireWriterGate(mismatchContender,
        probe = unknownMismatch, atSeconds = 300)
      check mismatchProbeCalls == 1
      check idx.writerGateToken() == mismatchedHolder
      check idx.releaseWriterGate(mismatchedHolder)
      check idx.releaseCoordToken(mismatchedHolder)
      check idx.releaseDaemonLaunchLease(unrelatedLease)
      check idx.releaseCoordToken(mismatchContender)
      idx.close()

    test "writer gate treats EPERM as alive and only ESRCH as death":
      let tempRoot = createTempDir("repro-daemon-gate-liveness", "")
      defer: removeDir(tempRoot)
      var idx = openShmIndex(tempRoot / "action-cache")
      let holder = idx.makeCoordToken(424_240)
      let contender = idx.makeCoordToken(424_241)
      check idx.tryAcquireWriterGate(holder, atSeconds = 100)
      let unknown = proc (
          identity: OwnerIdentity): ProcessLiveness {.gcsafe.} = plUnknown
      check not idx.tryAcquireWriterGate(contender, unknown, atSeconds = 100)
      check idx.writerGateToken() == holder
      let dead = proc (
          identity: OwnerIdentity): ProcessLiveness {.gcsafe.} = plDead
      check idx.tryAcquireWriterGate(contender, dead, atSeconds = 100)
      check idx.writerGateToken() == contender
      check not idx.releaseWriterGate(holder)
      check idx.releaseWriterGate(contender)
      idx.close()

    test "full-width capabilities do not alias at identical low 32 bits":
      let tempRoot = createTempDir("repro-daemon-full-capability", "")
      defer: removeDir(tempRoot)
      var idx = openShmIndex(tempRoot / "action-cache")
      let me = uint64(getCurrentProcessId())
      let start = processStartToken(me)
      let nonceA = 0x0000_0000_A5A5_0042'u64
      let nonceB = 0x0000_0001_A5A5_0042'u64
      check uint32(nonceA) == uint32(nonceB)
      let first = idx.makeCoordToken(me, startToken = start,
        forcedNonce = nonceA)
      let second = idx.makeCoordToken(me, startToken = start,
        forcedNonce = nonceB)
      check first == nonceA
      check second == nonceB
      check idx.coordIdentity(first).pid == me
      check idx.coordIdentity(second).pid == me
      check idx.coordIdentity(first).startToken == start
      check idx.coordIdentity(second).startToken == start
      check idx.tryAcquireWriterGate(first)
      check not idx.tryAcquireWriterGate(second)
      check idx.writerGateToken() == first
      check not idx.releaseWriterGate(second)
      check idx.writerGateToken() == first
      check idx.releaseWriterGate(first)
      check idx.tryAcquireWriterGate(second)
      check not idx.releaseWriterGate(first)
      check idx.writerGateToken() == second
      check idx.releaseWriterGate(second)
      check idx.releaseCoordToken(first)
      check idx.releaseCoordToken(second)
      idx.close()

    test "reused PID incarnation reclaims exact gate without false clearing":
      let tempRoot = createTempDir("repro-daemon-pid-incarnation", "")
      defer: removeDir(tempRoot)
      var idx = openShmIndex(tempRoot / "action-cache")
      let me = uint64(getCurrentProcessId())
      let actualStart = processStartToken(me)
      check actualStart != 0
      check osProcessLiveness(OwnerIdentity(
        pid: me, startToken: actualStart)) == plAlive
      let wrongStart =
        if actualStart == high(uint64): actualStart - 1 else: actualStart + 1
      check osProcessLiveness(OwnerIdentity(
        pid: me, startToken: wrongStart)) == plDead

      let reusedPid = 424_250'u64
      let holder = idx.makeCoordToken(reusedPid, startToken = 111,
        forcedNonce = 0x1111_0000_0000_0001'u64)
      let contender = idx.makeCoordToken(
        forcedNonce = 0x2222_0000_0000_0001'u64)
      check idx.tryAcquireWriterGate(holder)
      var sawExactOldIncarnation = false
      let reused = proc (
          identity: OwnerIdentity): ProcessLiveness {.gcsafe.} =
        if identity.pid == reusedPid and identity.startToken == 111:
          sawExactOldIncarnation = true
          plDead
        else:
          plUnknown
      check idx.tryAcquireWriterGate(contender, reused)
      check sawExactOldIncarnation
      check idx.writerGateToken() == contender
      check not idx.releaseWriterGate(holder)
      check idx.releaseWriterGate(contender)
      check idx.coordIdentity(holder).nonce == 0
      check not idx.releaseCoordToken(holder)
      check idx.releaseCoordToken(contender)
      idx.close()

    test "a long-lived handle recovers a hard-terminated owner on its next work":
      let tempRoot = createTempDir("repro-daemon-hard-crash-recover", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var producer = openShmIndex(cacheRoot)
      check producer.available

      # The producer mapping predates the daemon and remains attached across a
      # real owner-process termination (the regression's long-lived handle).
      let child = startProcess(getAppFilename(),
        args = @[ClaimAndBlockFlag, cacheRoot], options = {poStdErrToStdOut})
      check child.outputStream.readLine() == "CLAIMED"
      let crashedPid = currentOwnerPid(producer)
      check crashedPid != 0

      # Leave one generation outstanding while the owner is still alive. Its
      # heartbeat can therefore remain fresh after SIGTERM. A second
      # generation from this same long-lived producer must be enough to elect
      # exactly one liveness probe without synchronously waiting on the normal
      # first-notification path.
      let precursor = recordFor(NumKeys + 299)
      let precursorPayload = encodeActionResultRecord(precursor)
      check producer.submitRecord(precursor.weakFingerprint.bytes,
        precursorPayload)
      child.terminate()
      discard child.waitForExit()
      child.close()

      let rec = recordFor(NumKeys + 300)
      let payload = encodeActionResultRecord(rec)
      check producer.submitRecord(rec.weakFingerprint.bytes, payload)
      var spawns = 0
      let countedSpawn = proc (root: string;
          args: seq[string]): bool {.gcsafe.} =
        inc spawns
        true
      let probesBefore = producer.osLivenessProbeCount()
      check ensureCacheDaemon(cacheRoot, producer, spawnHook = countedSpawn)
      check producer.osLivenessProbeCount() == probesBefore + 1
      check spawns == 1
      check producer.daemonLaunchLease() != 0

      # Followers in the same unacknowledged cycle neither probe nor spawn.
      for _ in 0 ..< LaunchStormWorkers:
        discard ensureCacheDaemon(cacheRoot, producer, spawnHook = countedSpawn)
      check producer.osLivenessProbeCount() == probesBefore + 1
      check spawns == 1

      var replacement = openCacheDaemon(cacheRoot)
      check replacement.tryClaimOwnership()
      let stopNow = proc (): bool {.closure, gcsafe.} = true
      replacement.runDaemonLoop(stopNow, pollMs = 1, persistEveryMs = 50)
      check replacement.applied == 2
      check replacement.persisted == 2
      check producer.ringView.pendingCount() == 0
      check currentOwnerPid(producer) == 0
      check producer.daemonLaunchLease() == 0
      var snap: SlotSnapshot
      check producer.liveSeg.lookupSlot(
        precursor.weakFingerprint.bytes, snap) == srsHit
      if producer.liveSeg.lookupSlot(
          precursor.weakFingerprint.bytes, snap) == srsHit:
        check snap.rec == precursorPayload
      check producer.liveSeg.lookupSlot(rec.weakFingerprint.bytes, snap) ==
        srsHit
      if producer.liveSeg.lookupSlot(rec.weakFingerprint.bytes, snap) == srsHit:
        check snap.rec == payload
      var diskStore = openActionCache(cacheRoot, attachShm = false)
      let disk = diskStore.readHotRecord(rec.weakFingerprint)
      check disk.found
      if disk.found:
        check encodeActionResultRecord(disk.record) == payload
      replacement.close()
      producer.close()

    test "producer death after work sequence publication is follower-repairable":
      let tempRoot = createTempDir("repro-daemon-work-sequence-death", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var producer = openShmIndex(cacheRoot)
      check producer.available

      var owner = startProcess(getAppFilename(),
        args = @[ClaimAndBlockFlag, cacheRoot], options = {poStdErrToStdOut})
      check owner.outputStream.readLine() == "CLAIMED"
      let ownerPid = producer.rawOwnerPid()
      let ownerHeartbeat = producer.rawOwnerHeartbeat()
      check ownerPid != 0
      check producer.heartbeatIsFresh()

      let firstKey = NumKeys + 350
      var publisher = startProcess(getAppFilename(),
        args = @[PublishSequenceAndBlockFlag, cacheRoot, $firstKey],
        options = {poStdErrToStdOut})
      let sequenceLine = publisher.outputStream.readLine()
      check sequenceLine.startsWith("SEQUENCED ")
      let firstSequence = producer.workSequence()
      let association = producer.workAssociation(firstSequence)
      check firstSequence != 0
      check association.sequence == firstSequence
      check association.startedMs != 0

      publisher.terminate()
      discard publisher.waitForExit()
      publisher.close()
      owner.terminate()
      discard owner.waitForExit()
      owner.close()

      # Submit through the mapping that predates both terminated processes.
      # The predecessor sequence remains outstanding, so this next generation
      # authorizes one immediate exact-owner probe without waiting for heartbeat
      # TTL expiry.
      let second = recordFor(firstKey + 1)
      check producer.submitRecord(second.weakFingerprint.bytes,
        encodeActionResultRecord(second))
      let probesBefore = producer.osLivenessProbeCount()
      var spawns = 0
      let countedSpawn = proc (root: string;
          args: seq[string]): bool {.gcsafe.} =
        inc spawns
        true
      check ensureCacheDaemon(cacheRoot, producer, spawnHook = countedSpawn)
      check producer.osLivenessProbeCount() == probesBefore + 1
      check spawns == 1
      check producer.rawOwnerHeartbeat() == ownerHeartbeat
      check producer.heartbeatIsFresh()

      var replacement = openCacheDaemon(cacheRoot)
      check replacement.tryClaimOwnership()
      check replacement.drainOnce() == 2
      check replacement.persist() == 2
      for i in 0 .. 1:
        let rec = recordFor(firstKey + i)
        var snap: SlotSnapshot
        check producer.liveSeg.lookupSlot(rec.weakFingerprint.bytes, snap) ==
          srsHit
        if producer.liveSeg.lookupSlot(rec.weakFingerprint.bytes, snap) ==
            srsHit:
          check snap.rec == encodeActionResultRecord(rec)
        var store = openActionCache(cacheRoot, attachShm = false)
        let disk = store.readHotRecord(rec.weakFingerprint)
        check disk.found
        if disk.found:
          check encodeActionResultRecord(disk.record) ==
            encodeActionResultRecord(rec)
      replacement.close()
      producer.close()

    test "apply-before-persist termination replays and persists exact payload":
      let tempRoot = createTempDir("repro-daemon-apply-crash", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var producer = openShmIndex(cacheRoot)
      let rec = recordFor(NumKeys + 400)
      let payload = encodeActionResultRecord(rec)
      check producer.submitRecord(rec.weakFingerprint.bytes, payload)
      let child = startProcess(getAppFilename(),
        args = @[ApplyAndBlockFlag, cacheRoot], options = {poStdErrToStdOut})
      check child.outputStream.readLine() == "APPLIED"
      check producer.ringView.pendingCount() == 1
      child.terminate()
      discard child.waitForExit()
      child.close()

      var successor = openCacheDaemon(cacheRoot)
      check successor.tryClaimOwnership()
      check successor.drainOnce() == 1
      check successor.persist() == 1
      check producer.ringView.pendingCount() == 0
      check liveKeyCount(producer.liveSeg, NumKeys + 400) == 1
      var store = openActionCache(cacheRoot, attachShm = false)
      let disk = store.readHotRecord(rec.weakFingerprint)
      check disk.found
      if disk.found:
        check encodeActionResultRecord(disk.record) == payload
      successor.close()
      producer.close()

    test "unpublished reserved head exits after one bounded handoff":
      let tempRoot = createTempDir("repro-daemon-unpublished-head", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var owner = openCacheDaemon(cacheRoot)
      check owner.tryClaimOwnership()
      check owner.idx.ringView.reserveUnpublishedForTesting() != high(uint64)
      let claimsBefore = owner.idx.ownerClaimCount()
      let stopNow = proc (): bool {.closure, gcsafe.} = true
      owner.runDaemonLoop(stopNow, pollMs = 1, persistEveryMs = 1)
      check owner.idx.ringView.pendingCount() == 1
      check owner.idx.ownerClaimCount() == claimsBefore + 1
      check owner.idx.rawOwnerPid() == 0
      owner.close()

    test "captured-tail shutdown is logically bounded under continuous publish":
      let tempRoot = createTempDir("repro-daemon-bounded-shutdown", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var owner = openCacheDaemon(cacheRoot)
      var producer = openShmIndex(cacheRoot, create = false)
      var store = openActionCache(cacheRoot, attachShm = false)
      check owner.tryClaimOwnership()
      let firstKey = NumKeys + 430
      var published = 0

      proc publishOne(i: int) =
        let rec = recordFor(firstKey + i)
        store.writePerEdgeRecords(rec.weakFingerprint, @[rec])
        check producer.submitRecord(rec.weakFingerprint.bytes,
          encodeActionResultRecord(rec))
        inc published

      publishOne(0)
      let keepPublishing = proc () =
        if published < 4:
          publishOne(published)

      # Each acknowledgement adds one successor. A non-budgeted drain would
      # never return; the captured-tail pass retires exactly its entry ticket.
      check owner.drainOnce(afterEveryAck = keepPublishing) == 1
      check owner.lastDrainBudget == 1
      check owner.lastDrainTickets == 1
      check published == 2
      check producer.ringView.pendingCount() == 1

      let passesBefore = producer.shutdownDrainPassCount()
      let ticketsBefore = producer.shutdownDrainTicketCount()
      let stopNow = proc (): bool {.closure, gcsafe.} = true
      owner.runDaemonLoop(stopNow, pollMs = 1, persistEveryMs = 1,
        afterEveryShutdownAck = keepPublishing)
      check producer.shutdownDrainPassCount() == passesBefore + 2
      check producer.shutdownDrainTicketCount() == ticketsBefore + 2
      check published == 4
      check producer.ringView.pendingCount() == 1
      check producer.rawOwnerPid() == 0

      # Tier 1 remains authoritative for every publication, including the one
      # deliberately left queued after the bounded two-pass handoff.
      for i in 0 ..< 4:
        let rec = recordFor(firstKey + i)
        let disk = store.readHotRecord(rec.weakFingerprint)
        check disk.found
        if disk.found:
          check encodeActionResultRecord(disk.record) ==
            encodeActionResultRecord(rec)

      var successor = openCacheDaemon(cacheRoot)
      check successor.tryClaimOwnership()
      check successor.drainOnce() == 1
      check producer.ringView.pendingCount() == 0
      for i in 0 ..< 4:
        let rec = recordFor(firstKey + i)
        var snap: SlotSnapshot
        check successor.idx.liveSeg.lookupSlot(rec.weakFingerprint.bytes,
          snap) == srsHit
        if successor.idx.liveSeg.lookupSlot(rec.weakFingerprint.bytes,
            snap) == srsHit:
          check snap.rec == encodeActionResultRecord(rec)
      successor.close()
      producer.close()
      owner.close()

    test "legacy and capable owners coexist without live stealing":
      let tempRoot = createTempDir("repro-daemon-legacy-coexist", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var idx = openShmIndex(cacheRoot)
      let me = uint64(getCurrentProcessId())

      # New code must not TTL-steal a live legacy owner.
      storeU64Release(idx.ctl.base, CtlOffDaemonPid, me)
      storeU64Release(idx.ctl.base, CtlOffDaemonHeartbeat, 1)
      var capable = openCacheDaemon(cacheRoot)
      check not capable.tryClaimOwnership(atSeconds = 100)
      check idx.currentOwnerIdentity().nonce == 0
      storeU64Release(idx.ctl.base, CtlOffDaemonPid, 0)

      # Legacy code must treat a capable owner's tagged heartbeat as fresh even
      # at a far-future logical timestamp.
      check capable.tryClaimOwnership(atSeconds = 200)
      check heartbeatIsCapable(idx.rawOwnerHeartbeat())
      check not legacyTryClaim(idx, me, 200 + 10_000)
      check idx.currentOwnerIdentity() == capable.owner
      capable.close()
      idx.close()

    when defined(linux):
      test "pinned origin dev peer interoperates in both directions":
        const pathRoot = "linux-lifecycle-root"
        check LifecycleNamespaceVersion == 1
        check ctlPath(pathRoot) == pathRoot / "action-index.ctl"
        check segPath(pathRoot, 7) == pathRoot / "action-index.7.seg"
        exerciseBidirectionalPeer(
          "legacy_cache_peer_origin_dev",
          "reprobuild.test_helpers.legacy_cache_peer_origin_dev",
          "repro-daemon-origin-dev-peer")

    test "legacy-wire peer interoperates in both directions":
      exerciseBidirectionalPeer(
        "legacy_cache_peer_legacy_wire",
        "reprobuild.test_helpers.legacy_cache_peer_legacy_wire",
        "repro-daemon-legacy-wire-peer")

    when defined(macosx):
      test "Darwin v1 and v2 peers isolate volatile state and share Tier-1":
        let tempRoot = createTempDir("repro-daemon-darwin-namespaces", "")
        defer: removeDir(tempRoot)
        let cacheRoot = tempRoot / "action-cache"
        let exactPeer = requireBinary(
          getCurrentDir() / "build" / "test-bin" /
            addFileExt("legacy_cache_peer_origin_dev", ExeExt),
          "reprobuild.test_helpers.legacy_cache_peer_origin_dev")

        # Keep the exact-old v1 mapping open. Reopening it later would invoke
        # its historical time-varying boot identity and obscure the namespace
        # isolation property under test.
        var oldPeer = startProcess(exactPeer,
          args = @["isolation-server", cacheRoot],
          options = {poStdErrToStdOut})
        defer:
          if oldPeer.running:
            oldPeer.terminate()
            discard oldPeer.waitForExit()
          oldPeer.close()
        require oldPeer.outputStream.readLine() == "CLAIMED"

        let oldCtlPath = cacheRoot / "action-index.ctl"
        let oldSegPath = cacheRoot / "action-index.0.seg"
        require fileExists(oldCtlPath)
        require fileExists(oldSegPath)
        var oldCtl = attachRegion(oldCtlPath, CtlRegionSize)
        require oldCtl.isValid
        defer: oldCtl.detach()
        let oldPid = uint64(processID(oldPeer))
        check loadU64Acquire(oldCtl.base, CtlOffDaemonPid) == oldPid
        check peerCommand(oldPeer, "state") == "STATE 1 0 0"

        var capable = openCacheDaemon(cacheRoot)
        require capable.idx.available
        require LifecycleNamespaceVersion == 2
        require FormatVersion == 1
        let newCtlPath = ctlPath(cacheRoot)
        let newSegPath = segPath(cacheRoot, 0)
        check newCtlPath == cacheRoot / "action-index-v2.ctl"
        check newSegPath == cacheRoot / "action-index-v2.0.seg"
        check newCtlPath != oldCtlPath
        check newSegPath != oldSegPath
        require fileExists(newCtlPath)
        require fileExists(newSegPath)
        require capable.tryClaimOwnership()
        check capable.idx.rawOwnerPid() == uint64(getCurrentProcessId())
        check capable.idx.rawOwnerPid() != oldPid
        check loadU64Acquire(oldCtl.base, CtlOffDaemonPid) == oldPid
        check peerCommand(oldPeer, "state") == "STATE 1 0 0"

        let oldRecord = recordFor(NumKeys + 427)
        let oldPayload = encodeActionResultRecord(oldRecord)
        check peerCommand(oldPeer, "produce " &
          bytesHex(oldRecord.weakFingerprint.bytes) & " " &
          bytesHex(oldPayload)) == "PRODUCED"
        check peerCommand(oldPeer, "state") == "STATE 1 1 0"
        check capable.idx.ringView.pendingCount() == 0
        var snapshot: SlotSnapshot
        check capable.idx.liveSeg.lookupSlot(
          oldRecord.weakFingerprint.bytes, snapshot) == srsMiss

        let newRecord = recordFor(NumKeys + 428)
        let newPayload = encodeActionResultRecord(newRecord)
        check capable.idx.submitRecord(newRecord.weakFingerprint.bytes,
          newPayload)
        check capable.idx.ringView.pendingCount() == 1
        check peerCommand(oldPeer, "state") == "STATE 1 1 0"
        check peerCommand(oldPeer, "lookup " &
          bytesHex(newRecord.weakFingerprint.bytes)) == "MISS"

        # Each daemon drains only its own ring and writes only its own segment.
        check peerCommand(oldPeer, "drain-persist") ==
          "DRAINED 1 PERSISTED 1"
        check capable.idx.ringView.pendingCount() == 1
        check capable.idx.liveSeg.lookupSlot(
          oldRecord.weakFingerprint.bytes, snapshot) == srsMiss
        check peerCommand(oldPeer, "lookup " &
          bytesHex(oldRecord.weakFingerprint.bytes)) ==
            "HIT " & bytesHex(oldPayload)

        check capable.drainOnce() == 1
        check capable.idx.ringView.pendingCount() == 0
        check capable.idx.liveSeg.lookupSlot(
          newRecord.weakFingerprint.bytes, snapshot) == srsHit
        check snapshot.rec == newPayload
        check peerCommand(oldPeer, "lookup " &
          bytesHex(newRecord.weakFingerprint.bytes)) == "MISS"

        # Volatile namespaces are isolated, but the durable Tier-1 store is the
        # intended compatibility bridge. Recover the old record lazily into v2.
        check capable.warmFromDisk(oldRecord.weakFingerprint)
        check capable.idx.liveSeg.lookupSlot(
          oldRecord.weakFingerprint.bytes, snapshot) == srsHit
        check snapshot.rec == oldPayload
        check peerCommand(oldPeer, "state") == "STATE 1 0 0"
        check loadU64Acquire(oldCtl.base, CtlOffDaemonPid) == oldPid
        check peerCommand(oldPeer, "quit") == "BYE"
        check oldPeer.waitForExit() == 0
        capable.close()

    test "paused lease initializer is recognizable to 24 real followers":
      let tempRoot = createTempDir("repro-daemon-paused-reservation", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      let readyGate = tempRoot / "reserved"
      let continueGate = tempRoot / "continue"
      let startGate = tempRoot / "followers-go"
      var idx = openShmIndex(cacheRoot)
      let oldBin = getEnv("REPRO_CACHE_DAEMON_BIN", "")
      putEnv("REPRO_CACHE_DAEMON_BIN", getAppFilename())
      defer:
        if oldBin.len > 0: putEnv("REPRO_CACHE_DAEMON_BIN", oldBin)
        else: delEnv("REPRO_CACHE_DAEMON_BIN")

      let firstKey = NumKeys + 450
      var initializer = startProcess(getAppFilename(), args = @[
        PauseLaunchReservationFlag, cacheRoot, readyGate, continueGate,
        $firstKey], options = {poStdErrToStdOut})
      check waitUntil(proc (): bool = fileExists(readyGate))
      check idx.daemonLaunchLease() != 0

      var followers: seq[Process] = @[]
      for i in 0 ..< LaunchStormWorkers:
        followers.add(startProcess(getAppFilename(), args = @[
          LaunchWorkerFlag, cacheRoot, startGate, $(firstKey + 1 + i)],
          options = {poStdErrToStdOut}))
      writeFile(startGate, "go")
      for follower in followers:
        let code = follower.waitForExit()
        if code != 0: checkpoint(follower.outputStream.readAll())
        check code == 0
        follower.close()
      check idx.osLivenessProbeCount() == 0
      check idx.daemonSpawnAttemptCount() == 0

      writeFile(continueGate, "continue")
      let initCode = initializer.waitForExit()
      if initCode != 0: checkpoint(initializer.outputStream.readAll())
      check initCode == 0
      initializer.close()
      check waitUntil(proc (): bool =
        idx.ringView.pendingCount() == 0 and
          idx.workAckSequence() == idx.workSequence())
      check idx.osLivenessProbeCount() == 0
      check idx.daemonSpawnAttemptCount() == 1
      check idx.ownerClaimCount() == 1
      for i in 0 .. LaunchStormWorkers:
        let rec = recordFor(firstKey + i)
        var snap: SlotSnapshot
        check idx.liveSeg.lookupSlot(rec.weakFingerprint.bytes, snap) == srsHit
        if idx.liveSeg.lookupSlot(rec.weakFingerprint.bytes, snap) == srsHit:
          check snap.rec == encodeActionResultRecord(rec)
      check waitUntil(proc (): bool = idx.rawOwnerPid() == 0, 3.0)
      idx.close()

    test "terminated paused initializer has one bounded real-process recovery":
      let tempRoot = createTempDir("repro-daemon-dead-reservation", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      let readyGate = tempRoot / "reserved"
      let neverContinue = tempRoot / "never"
      let recoveryGate = tempRoot / "recover"
      var idx = openShmIndex(cacheRoot)
      let oldBin = getEnv("REPRO_CACHE_DAEMON_BIN", "")
      putEnv("REPRO_CACHE_DAEMON_BIN", getAppFilename())
      defer:
        if oldBin.len > 0: putEnv("REPRO_CACHE_DAEMON_BIN", oldBin)
        else: delEnv("REPRO_CACHE_DAEMON_BIN")

      let firstKey = NumKeys + 700
      var initializer = startProcess(getAppFilename(), args = @[
        PauseLaunchReservationFlag, cacheRoot, readyGate, neverContinue,
        $firstKey], options = {poStdErrToStdOut})
      check waitUntil(proc (): bool = fileExists(readyGate))
      let abandonedLease = idx.daemonLaunchLease()
      let abandonedStarted = idx.daemonLaunchStarted(abandonedLease)
      check abandonedLease != 0
      check abandonedStarted != 0
      initializer.terminate()
      discard initializer.waitForExit()
      initializer.close()

      let recoveryAt =
        abandonedStarted + DaemonLaunchLeaseTtlSeconds + 1
      var recoverers: seq[Process] = @[]
      for i in 0 ..< LaunchStormWorkers:
        recoverers.add(startProcess(getAppFilename(), args = @[
          RecoveryLaunchWorkerFlag, cacheRoot,
          tempRoot / ("recover-ready-" & $i), recoveryGate,
          $(firstKey + 1 + i), $recoveryAt],
          options = {poStdErrToStdOut}))
      check waitUntil(proc (): bool =
        for i in 0 ..< LaunchStormWorkers:
          if not fileExists(tempRoot / ("recover-ready-" & $i)):
            return false
        true)
      writeFile(recoveryGate, "go")
      for recoverer in recoverers:
        let code = recoverer.waitForExit()
        if code != 0: checkpoint(recoverer.outputStream.readAll())
        check code == 0
        recoverer.close()
      check waitUntil(proc (): bool =
        idx.ringView.pendingCount() == 0 and
          idx.workAckSequence() == idx.workSequence())
      check idx.daemonSpawnAttemptCount() == 1
      check idx.ownerClaimCount() == 1
      for i in 0 .. LaunchStormWorkers:
        let rec = recordFor(firstKey + i)
        var snap: SlotSnapshot
        check idx.liveSeg.lookupSlot(rec.weakFingerprint.bytes, snap) == srsHit
        if idx.liveSeg.lookupSlot(rec.weakFingerprint.bytes, snap) == srsHit:
          check snap.rec == encodeActionResultRecord(rec)
      check waitUntil(proc (): bool = idx.rawOwnerPid() == 0, 3.0)
      idx.close()

    test "dead pre-spawn authorization holder recovers without duplicate spawn":
      let tempRoot = createTempDir("repro-daemon-dead-authorization", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      let readyGate = tempRoot / "authorized"
      let neverContinue = tempRoot / "never"
      var idx = openShmIndex(cacheRoot)
      let oldBin = getEnv("REPRO_CACHE_DAEMON_BIN", "")
      putEnv("REPRO_CACHE_DAEMON_BIN", getAppFilename())
      defer:
        if oldBin.len > 0: putEnv("REPRO_CACHE_DAEMON_BIN", oldBin)
        else: delEnv("REPRO_CACHE_DAEMON_BIN")

      let firstKey = NumKeys + 760
      var launcher = startProcess(getAppFilename(), args = @[
        PauseLaunchAuthorizationFlag, cacheRoot, readyGate, neverContinue,
        $firstKey], options = {poStdErrToStdOut})
      check waitUntil(proc (): bool = fileExists(readyGate))
      let lease = idx.daemonLaunchLease()
      let started = idx.daemonLaunchStarted(lease)
      check idx.writerGateToken() == lease
      check idx.daemonSpawnAttemptCount() == 0
      launcher.terminate()
      discard launcher.waitForExit()
      launcher.close()

      let second = recordFor(firstKey + 1)
      check idx.submitRecord(second.weakFingerprint.bytes,
        encodeActionResultRecord(second))
      check ensureCacheDaemon(cacheRoot, idx,
        atSeconds = started + DaemonLaunchLeaseTtlSeconds + 1)
      check waitUntil(proc (): bool =
        idx.ringView.pendingCount() == 0 and
          idx.workAckSequence() == idx.workSequence())
      check idx.daemonSpawnAttemptCount() == 1
      check idx.ownerClaimCount() == 1
      for i in 0 .. 1:
        let rec = recordFor(firstKey + i)
        var snap: SlotSnapshot
        check idx.liveSeg.lookupSlot(rec.weakFingerprint.bytes, snap) == srsHit
        if idx.liveSeg.lookupSlot(rec.weakFingerprint.bytes, snap) == srsHit:
          check snap.rec == encodeActionResultRecord(rec)
      check waitUntil(proc (): bool = idx.rawOwnerPid() == 0, 3.0)
      idx.close()

    test "killed claim and committed initializers recover before one launch storm":
      let tempRoot = createTempDir("repro-daemon-coord-claim-recovery", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      let ensureGate = tempRoot / "ensure"
      var idx = openShmIndex(cacheRoot)
      let oldBin = getEnv("REPRO_CACHE_DAEMON_BIN", "")
      putEnv("REPRO_CACHE_DAEMON_BIN", getAppFilename())
      defer:
        if oldBin.len > 0: putEnv("REPRO_CACHE_DAEMON_BIN", oldBin)
        else: delEnv("REPRO_CACHE_DAEMON_BIN")

      # More than the entire 48-slot table dies at the exact post-Reservation
      # hook. Every child is terminated and reaped before recovery, making
      # definite ESRCH (rather than a timeout) the reclamation barrier.
      var recovered = 0
      for _ in 0 ..< AbandonedCoordInitializers:
        var initializer = startProcess(getAppFilename(),
          args = @[CoordReserveAndBlockFlag, cacheRoot],
          options = {poStdErrToStdOut})
        let barrier = initializer.outputStream.readLine().splitWhitespace()
        check barrier.len == 4
        if barrier.len == 4:
          check barrier[0] == "RESERVED"
          let slot = parseInt(barrier[1])
          let claim = parseBiggestUInt(barrier[2]).uint64
          let generation = parseBiggestUInt(barrier[3]).uint64
          check slot >= 0 and slot < CoordSlotCount
          check claim != 0
          check generation != 0
          check loadU64Acquire(idx.ctl.base,
            CtlExtCoordSlotsBase + slot * CoordSlotStride +
              CoordSlotOffReservation) == claim
          check loadU64Acquire(idx.ctl.base,
            CtlExtCoordGuardsBase + slot * 8) == 0
        initializer.terminate()
        discard initializer.waitForExit()
        initializer.close()
        let repaired = idx.reclaimAbandonedCoordReservations()
        check repaired == 1
        recovered += repaired
      check recovered == AbandonedCoordInitializers

      # Fill the entire coordination table with real children paused immediately
      # after `makeCoordToken` returned Committed, while the capability is still
      # process-local. Reap all holders before one bounded saturation repair, then
      # repeat past the table capacity to prove recovery is not a one-shot reset.
      var recoveredCommitted = 0
      for batchSize in [CoordSlotCount, AbandonedCoordInitializers - CoordSlotCount]:
        var committedChildren: seq[Process] = @[]
        var committedTokens: seq[uint64] = @[]
        for _ in 0 ..< batchSize:
          var child = startProcess(getAppFilename(),
            args = @[CoordCommitAndBlockFlag, cacheRoot],
            options = {poStdErrToStdOut})
          let barrier = child.outputStream.readLine().splitWhitespace()
          check barrier.len == 2
          if barrier.len == 2:
            check barrier[0] == "COMMITTED"
            let token = parseBiggestUInt(barrier[1]).uint64
            check token != 0
            check idx.coordIdentity(token).nonce == token
            committedTokens.add(token)
          committedChildren.add(child)
        check committedTokens.len == batchSize
        for child in committedChildren.mitems:
          child.terminate()
          discard child.waitForExit()
          child.close()
        let repaired = idx.reclaimAbandonedCoordReservations()
        check repaired == batchSize
        recoveredCommitted += repaired
        for token in committedTokens:
          check idx.coordIdentity(token).nonce == 0
      check recoveredCommitted == AbandonedCoordInitializers

      # `openCacheDaemon` creates the same process-local committed token before
      # it attempts ownership, so cover that production call site explicitly.
      var unopened = startProcess(getAppFilename(),
        args = @[DaemonOpenUnclaimedAndBlockFlag, cacheRoot],
        options = {poStdErrToStdOut})
      let openedBarrier = unopened.outputStream.readLine().splitWhitespace()
      check openedBarrier.len == 2
      var unopenedToken = 0'u64
      if openedBarrier.len == 2:
        check openedBarrier[0] == "OPENED"
        unopenedToken = parseBiggestUInt(openedBarrier[1]).uint64
        check idx.coordIdentity(unopenedToken).nonce == unopenedToken
      unopened.terminate()
      discard unopened.waitForExit()
      unopened.close()
      check idx.reclaimAbandonedCoordReservations() == 1
      check idx.coordIdentity(unopenedToken).nonce == 0

      # The repaired mapping remains usable for an ordinary exact capability
      # before entering real multiprocess daemon launch arbitration.
      let proofToken = idx.makeCoordToken(
        forcedNonce = 0xD064_0000_0000_0001'u64)
      check proofToken == 0xD064_0000_0000_0001'u64
      check idx.releaseCoordToken(proofToken)

      let firstKey = NumKeys + 900
      var workers: seq[Process] = @[]
      for i in 0 ..< LaunchStormWorkers:
        workers.add(startProcess(getAppFilename(), args = @[
          TwoPhaseLaunchWorkerFlag, cacheRoot,
          tempRoot / ("coord-ready-" & $i), ensureGate, $(firstKey + i)],
          options = {poStdErrToStdOut}))
      check waitUntil(proc (): bool =
        for i in 0 ..< LaunchStormWorkers:
          if not fileExists(tempRoot / ("coord-ready-" & $i)):
            return false
        true)
      writeFile(ensureGate, "go")
      for worker in workers:
        let code = worker.waitForExit()
        if code != 0:
          checkpoint(worker.outputStream.readAll())
        check code == 0
        worker.close()
      check waitUntil(proc (): bool =
        idx.ringView.pendingCount() == 0 and
          idx.workAckSequence() == idx.workSequence(), 5.0)
      check idx.daemonSpawnAttemptCount() == 1
      check idx.ownerClaimCount() == 1
      check idx.osLivenessProbeCount() == 0
      check waitUntil(proc (): bool = idx.rawOwnerPid() == 0, 3.0)
      check idx.daemonLaunchLease() == 0
      check idx.workAckSequence() == idx.workSequence()
      check idx.writerGateToken() == 0
      for i in 0 ..< LaunchStormWorkers:
        let rec = recordFor(firstKey + i)
        let payload = encodeActionResultRecord(rec)
        var snap: SlotSnapshot
        check idx.liveSeg.lookupSlot(rec.weakFingerprint.bytes, snap) == srsHit
        if idx.liveSeg.lookupSlot(rec.weakFingerprint.bytes, snap) == srsHit:
          check snap.rec == payload
        var store = openActionCache(cacheRoot, attachShm = false)
        let disk = store.readHotRecord(rec.weakFingerprint)
        check disk.found
        if disk.found:
          check encodeActionResultRecord(disk.record) == payload
      idx.close()

    test "real 24-process launch storm starts one child and preserves payloads":
      let tempRoot = createTempDir("repro-daemon-real-launch-storm", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      let ensureGate = tempRoot / "ensure"
      var idx = openShmIndex(cacheRoot)
      let oldBin = getEnv("REPRO_CACHE_DAEMON_BIN", "")
      putEnv("REPRO_CACHE_DAEMON_BIN", getAppFilename())
      defer:
        if oldBin.len > 0: putEnv("REPRO_CACHE_DAEMON_BIN", oldBin)
        else: delEnv("REPRO_CACHE_DAEMON_BIN")
      var workers: seq[Process] = @[]
      for i in 0 ..< LaunchStormWorkers:
        workers.add(startProcess(getAppFilename(), args = @[
          TwoPhaseLaunchWorkerFlag, cacheRoot, tempRoot / ("ready-" & $i),
          ensureGate, $(NumKeys + 500 + i)],
          options = {poStdErrToStdOut}))
      check waitUntil(proc (): bool =
        for i in 0 ..< LaunchStormWorkers:
          if not fileExists(tempRoot / ("ready-" & $i)):
            return false
        true)
      writeFile(ensureGate, "go")
      for worker in workers:
        let code = worker.waitForExit()
        if code != 0:
          checkpoint(worker.outputStream.readAll())
        check code == 0
        worker.close()
      check waitUntil(proc (): bool =
        idx.ringView.pendingCount() == 0 and
          idx.workAckSequence() == idx.workSequence(), 5.0)
      check idx.daemonSpawnAttemptCount() == 1
      check idx.ownerClaimCount() == 1
      check idx.osLivenessProbeCount() == 0
      check waitUntil(proc (): bool = idx.rawOwnerPid() == 0, 3.0)
      for i in 0 ..< LaunchStormWorkers:
        let rec = recordFor(NumKeys + 500 + i)
        var snap: SlotSnapshot
        check idx.liveSeg.lookupSlot(rec.weakFingerprint.bytes, snap) == srsHit
        if idx.liveSeg.lookupSlot(rec.weakFingerprint.bytes, snap) == srsHit:
          check snap.rec == encodeActionResultRecord(rec)
        var store = openActionCache(cacheRoot, attachShm = false)
        check store.readHotRecord(rec.weakFingerprint).found
      idx.close()

    test "spawn-hook exceptions release the exact launch lease":
      let tempRoot = createTempDir("repro-daemon-spawn-hook-exception", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var idx = openShmIndex(cacheRoot)
      let rec = recordFor(NumKeys + 599)
      check idx.submitRecord(rec.weakFingerprint.bytes,
        encodeActionResultRecord(rec))
      let raisingSpawn = proc (root: string;
          args: seq[string]): bool {.gcsafe.} =
        raise newException(ValueError, "deterministic spawn failure")
      check not ensureCacheDaemon(cacheRoot, idx, spawnHook = raisingSpawn,
        ackWaitMs = 0)
      check idx.daemonSpawnAttemptCount() == 1
      check idx.daemonLaunchLease() == 0
      let successor = idx.tryAcquireDaemonLaunchLease()
      check successor != 0
      check idx.releaseDaemonLaunchLease(successor)
      idx.close()

    test "real exec failure releases or expires and the next launch recovers":
      let tempRoot = createTempDir("repro-daemon-real-exec-failure", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      let invalidBin = tempRoot / "invalid-daemon"
      writeFile(invalidBin, "not an executable image\n")
      setFilePermissions(invalidBin, {fpUserRead, fpUserWrite, fpUserExec})
      let oldBin = getEnv("REPRO_CACHE_DAEMON_BIN", "")
      defer:
        if oldBin.len > 0: putEnv("REPRO_CACHE_DAEMON_BIN", oldBin)
        else: delEnv("REPRO_CACHE_DAEMON_BIN")
      putEnv("REPRO_CACHE_DAEMON_BIN", invalidBin)
      var idx = openShmIndex(cacheRoot)
      let rec = recordFor(NumKeys + 600)
      check idx.submitRecord(rec.weakFingerprint.bytes,
        encodeActionResultRecord(rec))
      discard ensureCacheDaemon(cacheRoot, idx, ackWaitMs = 0)
      let failedLease = idx.daemonLaunchLease()
      let failedStarted = idx.daemonLaunchStarted(failedLease)

      putEnv("REPRO_CACHE_DAEMON_BIN", getAppFilename())
      if failedLease == 0:
        check ensureCacheDaemon(cacheRoot, idx, ackWaitMs = 0)
      else:
        check failedStarted != 0
        check ensureCacheDaemon(cacheRoot, idx,
          atSeconds = failedStarted + DaemonLaunchLeaseTtlSeconds + 1,
          ackWaitMs = 0)
      check waitUntil(proc (): bool =
        idx.ringView.pendingCount() == 0 and
          idx.workAckSequence() == idx.workSequence(), 5.0)
      var snap: SlotSnapshot
      check idx.liveSeg.lookupSlot(rec.weakFingerprint.bytes, snap) == srsHit
      if idx.liveSeg.lookupSlot(rec.weakFingerprint.bytes, snap) == srsHit:
        check snap.rec == encodeActionResultRecord(rec)
      check idx.daemonSpawnAttemptCount() == 2
      check waitUntil(proc (): bool = idx.rawOwnerPid() == 0, 3.0)
      idx.close()

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
      var store = openActionCache(cacheRoot, attachShm = false)
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
      check fresh.tryClaimOwnership()
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
