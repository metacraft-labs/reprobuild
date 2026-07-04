import std/[os, osproc, streams, strutils, tempfiles, times, unittest]

import repro_shm_index
import repro_test_support

# AC-2a (Action-Cache-Per-Edge-Store.md §4.2, §4.3): the generation segment's
# per-slot SEQLOCK gives lock-free readers a STABLE snapshot even while a
# single-writer stand-in rewrites slots and swaps `currentGeneration` (a
# stand-in "resize"). Every read that reports a HIT must be a COMPLETE, valid
# record — never a torn / half-written one.
#
# The records are self-describing so a torn read is detectable: each record is
# `payload = [tag; tag; tag; ...]` (all `recLen` bytes equal to a single
# generation-derived tag byte). A writer that flips a slot between two tag
# values while readers copy it would, WITHOUT the seqlock re-check, let a reader
# observe a mix of old and new tag bytes — an INCONSISTENT record. The reader
# rejects any snapshot whose bytes are not all-equal (torn) and reports it.
#
# Multi-process: this binary re-execs itself as N reader worker PROCESSES and
# one writer worker PROCESS, all mapping the same `--action-cache-root` shm
# region (the AC-1 concurrent-test pattern: real processes, one shared root).
#
# Falsifiable: removing the seqlock re-check in `segment.readSlotAt` (accepting
# the copy without confirming `seq` unchanged + even) lets readers observe torn
# records → a worker exits with the TORN code → this test FAILS.

const
  ReaderFlag = "--shm-seqlock-reader"
  WriterFlag = "--shm-seqlock-writer"
  NumSlots = 32          # distinct keys the writer cycles through
  DurationMs = 1500      # how long workers run
  ExitTorn = 7           # a reader observed a torn record
  ExitOk = 0

proc keyFor(i: int): array[32, byte] =
  # Deterministic per-slot key digest shared by writer + readers.
  for b in 0 ..< 32:
    result[b] = byte((i * 131 + b * 17 + 1) and 0xFF)

proc recordFor(tag: byte; length: int): seq[byte] =
  # A self-describing record: `length` bytes all equal to `tag`.
  result = newSeq[byte](length)
  for i in 0 ..< length:
    result[i] = tag

proc recIsConsistent(rec: seq[byte]): bool =
  # Valid iff non-empty and all bytes are equal (a complete single-tag record).
  if rec.len == 0:
    return false
  let first = rec[0]
  for b in rec:
    if b != first:
      return false
  true

proc runWriter(cacheRoot: string) =
  ## Single-writer stand-in: continuously rewrite every slot with a fresh tag
  ## (seqlock even->odd->even) and periodically swap `currentGeneration` between
  ## two live segments, mimicking the daemon's resize commit point.
  var idx = openShmIndex(cacheRoot)
  if not idx.available:
    quit(ExitOk)  # unsupported platform: nothing to falsify
  # Pre-create a second generation so we can swap between 0 and 1.
  let cap = idx.segSlotCap()
  var seg1 = createSegment(cacheRoot, 1'u32, cap, bootId())
  doAssert seg1.isValid
  let deadline = epochTime() + DurationMs.float / 1000.0
  var tag: byte = 1
  var flip = 0
  while epochTime() < deadline:
    let curGen = idx.currentGeneration()
    var seg = if curGen == 0'u32: idx.liveSeg else: seg1
    for i in 0 ..< NumSlots:
      let k = keyFor(i)
      # Vary the record LENGTH too so a torn read mixing old/new is more likely
      # to be caught (length 8..200, always a valid single-tag record).
      let length = 8 + (int(tag) * 3 + i * 5) mod 192
      discard seg.writeSlot(k, recordFor(tag, length))
      inc tag
      if tag == 0: tag = 1
    inc flip
    if (flip and 3) == 0:
      # Swap the live generation (the resize commit). Mirror the same records
      # into the target gen first so lookups still hit after the swap.
      let target = 1'u32 - curGen
      var tgt = if target == 0'u32: idx.liveSeg else: seg1
      for i in 0 ..< NumSlots:
        discard tgt.writeSlot(keyFor(i), recordFor(tag, 16))
      idx.setCurrentGeneration(target)
  seg1.detach()
  idx.close()
  quit(ExitOk)

proc runReader(cacheRoot: string; readerSlot: int) =
  ## Reader worker: continuously seqlock-read random slots across whichever
  ## generation is currently live. Any HIT that is not a consistent record is a
  ## torn read → exit ExitTorn (the falsification signal).
  var idx = openShmIndex(cacheRoot, create = false)
  if not idx.available:
    quit(ExitOk)
  # ATTACH the writer's gen-1 segment (never create it — a re-create would swap
  # the inode out from under the writer). Retry briefly until the writer has
  # created it.
  var attached1 = attachSegment(cacheRoot, 1'u32, idx.segSlotCap())
  var tries = 0
  while not attached1.isValid and tries < 2000:
    attached1 = attachSegment(cacheRoot, 1'u32, idx.segSlotCap())
    inc tries
  let deadline = epochTime() + DurationMs.float / 1000.0
  var seed = uint64(readerSlot) * 2654435761'u64 + 1'u64
  while epochTime() < deadline:
    let gen = idx.currentGeneration()
    idx.publishReaderEpoch(readerSlot mod 64, gen)
    var seg = if gen == 0'u32: idx.liveSeg else: attached1
    if not seg.isValid:
      continue
    # xorshift for a cheap per-reader slot choice.
    seed = seed xor (seed shl 13); seed = seed xor (seed shr 7)
    seed = seed xor (seed shl 17)
    let i = int(seed mod uint64(NumSlots))
    var snap: SlotSnapshot
    let st = seg.lookupSlot(keyFor(i), snap)
    if st == srsHit:
      if not recIsConsistent(snap.rec):
        # TORN: a hit whose bytes are not all-equal — a half-written record.
        quit(ExitTorn)
  attached1.detach()
  idx.close()
  quit(ExitOk)

when isMainModule:
  let params = commandLineParams()
  if params.len >= 2 and params[0] == WriterFlag:
    runWriter(params[1])
  elif params.len >= 3 and params[0] == ReaderFlag:
    runReader(params[1], parseInt(params[2]))

suite "integration_shm_index_seqlock_reads_consistent_across_resize":
  when isNixSupported:
    test "M readers see only complete records while a writer rewrites + resizes":
      let tempRoot = createTempDir("repro-shm-seqlock", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"

      # Pre-create the shm region so every worker attaches to the same root.
      var idx = openShmIndex(cacheRoot)
      check idx.available
      idx.close()

      let self = getAppFilename()
      let readerCount = 8

      var procs: seq[Process] = @[]
      # Start the writer first so readers have live data immediately.
      procs.add(startProcess(self, args = @[WriterFlag, cacheRoot],
        options = {poStdErrToStdOut}))
      for r in 0 ..< readerCount:
        procs.add(startProcess(self,
          args = @[ReaderFlag, cacheRoot, $r],
          options = {poStdErrToStdOut}))

      var anyTorn = false
      var allExitedOk = true
      for i, p in procs:
        let code = p.waitForExit()
        if code == ExitTorn:
          anyTorn = true
          checkpoint("worker " & $i & " observed a TORN record")
        elif code != ExitOk:
          allExitedOk = false
          checkpoint("worker " & $i & " exited with code " & $code & ": " &
            p.outputStream.readAll())
        p.close()

      # No reader ever observed a torn record, and all workers exited cleanly.
      check not anyTorn
      check allExitedOk
