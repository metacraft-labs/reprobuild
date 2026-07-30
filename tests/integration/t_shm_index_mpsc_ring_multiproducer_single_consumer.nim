import std/[os, osproc, streams, strutils, tempfiles, unittest]

import repro_shm_index
import repro_test_support

# AC-2a (Action-Cache-Per-Edge-Store.md §4.4): the shared-memory MPSC
# submission ring. M producer PROCESSES each append K records; ONE consumer
# process drains. Below capacity EVERY record is drained exactly once (none
# lost, none duplicated). At capacity, drop-on-full is SIGNALLED via the atomic
# `dropped` counter — never silent. The ring's OTHER rejection, an over-cap
# record turned away before any ticket is reserved, is signalled the same way
# via the atomic `oversized` counter — otherwise a build whose records all
# exceed `RingSlotRecCap` would bypass the shm tier with no observable
# difference from a healthy idle one.
#
# Each record encodes (producerId, seqNo) in its digest + payload so the
# consumer can verify no record is lost or duplicated: it tallies a
# per-(producer,seq) seen-count and checks every count is exactly 1 and
# drained + dropped == produced.
#
# Multi-process: this binary re-execs itself as M producer worker PROCESSES and
# (in the below-capacity case) drains from the parent after they finish, or
# (in the drop-on-full case) checks the signalled counter.
#
# Falsifiable: replacing the CAS tail reservation in `ring.append` with a plain
# load+store tail bump lets two producers reserve the SAME slot under real
# multi-process concurrency → records are lost/duplicated → the exactly-once
# tally FAILS.

const
  ProducerFlag = "--shm-ring-producer"
  OversizeProducerFlag = "--shm-ring-oversize-producer"
  ExitOk = 0
  ExitOversizeNotRejected = 3

proc encodeDigest(producerId, seqNo: int): array[32, byte] =
  # First 4 bytes producerId, next 4 bytes seqNo (little-endian), rest derived.
  result[0] = byte(producerId and 0xFF)
  result[1] = byte((producerId shr 8) and 0xFF)
  result[2] = byte((producerId shr 16) and 0xFF)
  result[3] = byte((producerId shr 24) and 0xFF)
  result[4] = byte(seqNo and 0xFF)
  result[5] = byte((seqNo shr 8) and 0xFF)
  result[6] = byte((seqNo shr 16) and 0xFF)
  result[7] = byte((seqNo shr 24) and 0xFF)
  for i in 8 ..< 32:
    result[i] = byte((producerId * 7 + seqNo * 13 + i) and 0xFF)

proc decodeDigest(d: array[32, byte]): (int, int) =
  let p = int(d[0]) or (int(d[1]) shl 8) or (int(d[2]) shl 16) or (int(d[3]) shl 24)
  let s = int(d[4]) or (int(d[5]) shl 8) or (int(d[6]) shl 16) or (int(d[7]) shl 24)
  (p, s)

proc payloadFor(producerId, seqNo: int): seq[byte] =
  # A short self-describing payload echoing the ids (redundant integrity).
  result = newSeq[byte](16)
  let d = encodeDigest(producerId, seqNo)
  for i in 0 ..< 16:
    result[i] = d[i]

proc runProducer(cacheRoot: string; producerId, count: int) =
  ## Producer worker: append `count` records; retry a signalled drop briefly so
  ## the below-capacity case loses nothing (the consumer drains concurrently).
  var idx = openShmIndex(cacheRoot, create = false)
  if not idx.available:
    quit(ExitOk)
  for s in 0 ..< count:
    let dig = encodeDigest(producerId, s)
    let pay = payloadFor(producerId, s)
    var st = idx.ringView.append(dig, pay)
    var spins = 0
    while st == rasDropped and spins < 2_000_000:
      # The consumer will make room; brief spin keeps the below-capacity run
      # lossless. (The drop-on-full case uses a NON-draining ring instead.)
      st = idx.ringView.append(dig, pay)
      inc spins
    doAssert st != rasOversized
  idx.close()
  quit(ExitOk)

proc runOversizeProducer(cacheRoot: string; count: int) =
  ## Producer worker for the OVER-CAP path: every append carries a record one
  ## byte past `RingSlotRecCap`, so every one must be rejected without touching
  ## the ring. The parent reads the resulting signal back out of ITS OWN
  ## mapping, which is only possible if the counter lives in the shared control
  ## region rather than in producer-local state.
  var idx = openShmIndex(cacheRoot, create = false)
  if not idx.available:
    quit(ExitOk)
  let overCap = newSeq[byte](RingSlotRecCap + 1)
  for s in 0 ..< count:
    if idx.ringView.append(encodeDigest(0, s), overCap) != rasOversized:
      quit(ExitOversizeNotRejected)
  idx.close()
  quit(ExitOk)

when isMainModule:
  let params = commandLineParams()
  if params.len >= 4 and params[0] == ProducerFlag:
    runProducer(params[1], parseInt(params[2]), parseInt(params[3]))
  if params.len >= 3 and params[0] == OversizeProducerFlag:
    runOversizeProducer(params[1], parseInt(params[2]))

suite "integration_shm_index_mpsc_ring_multiproducer_single_consumer":
  when isNixSupported:
    test "M producers append; consumer drains each record exactly once":
      let tempRoot = createTempDir("repro-shm-ring", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"

      var idx = openShmIndex(cacheRoot)
      check idx.available

      let self = getAppFilename()
      let producerCount = 12
      let perProducer = 500
      let total = producerCount * perProducer

      # Spawn the producers; the CONSUMER is this parent process, draining
      # concurrently as they run (single consumer, many producers).
      var procs: seq[Process] = @[]
      for p in 0 ..< producerCount:
        procs.add(startProcess(self,
          args = @[ProducerFlag, cacheRoot, $p, $perProducer],
          options = {poStdErrToStdOut}))

      # Per-(producer,seq) seen tally. -1 sentinel = never seen.
      var seen = newSeq[int8](total)  # index = producerId * perProducer + seq
      var drained = 0
      var duplicate = false
      var outOfRange = false

      proc anyRunning(): bool =
        for pr in procs:
          if pr.running(): return true
        false

      proc drainAvailable() =
        var rr: RingRecord
        while idx.ringView.tryDrainOne(rr):
          let (pid, sno) = decodeDigest(rr.digest)
          if pid < 0 or pid >= producerCount or sno < 0 or sno >= perProducer:
            outOfRange = true
            continue
          let flat = pid * perProducer + sno
          if seen[flat] != 0:
            duplicate = true
          else:
            seen[flat] = 1
            inc drained

      # Drain while producers run, then drain the tail after they exit.
      while anyRunning():
        drainAvailable()
      for pr in procs:
        discard pr.waitForExit()
        pr.close()
      drainAvailable()

      # Every submitted record is drained EXACTLY ONCE: none lost, none
      # duplicated, none out of range. (Producers retry the SIGNALLED transient
      # full-ring drop, so a nonzero `dropped` counter is expected under a small
      # ring + bursty producers — the exactly-once tally is the correctness
      # invariant, and drops were never silent.)
      check not duplicate
      check not outOfRange
      check drained == total

      var missing = 0
      for v in seen:
        if v == 0: inc missing
      check missing == 0

      idx.close()

    test "drop-on-full is SIGNALLED (counted), not silent":
      # Fill the ring WITHOUT draining so it saturates, and confirm the excess
      # appends are counted in the atomic `dropped` signal (never silent).
      let tempRoot = createTempDir("repro-shm-ring-full", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var idx = openShmIndex(cacheRoot)
      check idx.available

      # RingCap slots accepted; every further append is a signalled drop.
      var accepted = 0
      var dropped = 0
      let attempts = RingCap + 200
      for i in 0 ..< attempts:
        let dig = encodeDigest(0, i)
        case idx.ringView.append(dig, payloadFor(0, i))
        of rasAppended: inc accepted
        of rasDropped: inc dropped
        of rasOversized: discard
      check accepted == RingCap
      check dropped == 200
      # The drop was SIGNALLED via the atomic counter, not silent.
      check idx.ringView.droppedCount() == 200'u64
      # A full ring is NOT an over-cap rejection: the two signals are distinct.
      check idx.ringView.oversizedCount() == 0'u64
      idx.close()

    test "over-cap rejection is SIGNALLED (counted), not silent":
      # An over-cap record is turned away BEFORE the ring (no ticket reserved),
      # so the `dropped` counter can never see it. Without its own signal an
      # engine whose records all exceed `RingSlotRecCap` — e.g. records whose
      # inlined input paths are long — bypasses the shm live-sharing tier 100%
      # of the time and is indistinguishable from a healthy idle one: the ring
      # stays empty, the daemon is never asked to publish, every lookup quietly
      # falls through to Tier-1 disk. Spec §4.4 / §8 AC-2c require the
      # oversized-Tier-1-only outcome to be SIGNALLED, not silent.
      let tempRoot = createTempDir("repro-shm-ring-oversize", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var idx = openShmIndex(cacheRoot)
      check idx.available
      # A freshly created region starts both signals at zero.
      check idx.ringView.oversizedCount() == 0'u64
      check idx.ringView.droppedCount() == 0'u64

      # NORMAL submits must NOT bump the oversize signal — including one
      # exactly AT the cap, which is still enqueueable.
      check idx.ringView.append(encodeDigest(0, 0), payloadFor(0, 0)) ==
        rasAppended
      check idx.ringView.append(encodeDigest(0, 1),
        newSeq[byte](RingSlotRecCap)) == rasAppended
      check idx.ringView.oversizedCount() == 0'u64

      # OVER-CAP submits from real producer PROCESSES: each is rejected and
      # each rejection is counted in the shared control region.
      let self = getAppFilename()
      let oversizeProducers = 4
      let perProducer = 5
      var procs: seq[Process] = @[]
      for p in 0 ..< oversizeProducers:
        procs.add(startProcess(self,
          args = @[OversizeProducerFlag, cacheRoot, $perProducer],
          options = {poStdErrToStdOut}))
      var workersOk = true
      for pr in procs:
        let code = pr.waitForExit()
        if code != ExitOk:
          workersOk = false
          checkpoint("oversize producer exited " & $code & ": " &
            pr.outputStream.readAll())
        pr.close()
      check workersOk

      # SIGNALLED: visible from this process's own mapping, so the counter is
      # shared state, not producer-local. The ring is untouched (no ticket
      # burned, no full-ring drop recorded) — only the two in-cap appends are
      # pending.
      check idx.ringView.oversizedCount() ==
        uint64(oversizeProducers * perProducer)
      check idx.ringView.droppedCount() == 0'u64
      check idx.ringView.pendingCount() == 2'u64
      idx.close()
