import std/[os, osproc, strutils, tempfiles, unittest]

import repro_shm_index
import repro_test_support

# AC-2a (Action-Cache-Per-Edge-Store.md §4.4): the shared-memory MPSC
# submission ring. M producer PROCESSES each append K records; ONE consumer
# process drains. Below capacity EVERY record is drained exactly once (none
# lost, none duplicated). At capacity, drop-on-full is SIGNALLED via the atomic
# `dropped` counter — never silent.
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
  ExitOk = 0

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

when isMainModule:
  let params = commandLineParams()
  if params.len >= 4 and params[0] == ProducerFlag:
    runProducer(params[1], parseInt(params[2]), parseInt(params[3]))

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
      idx.close()
