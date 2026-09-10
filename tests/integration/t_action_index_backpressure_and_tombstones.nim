## Action-Cache-Per-Edge-Store.md §6.1, §6.4, §6.5 — the two properties the
## grow-only index is CHOSEN for, proved rather than asserted.
##
## WHY THESE TWO, AND WHY TOGETHER. §12.F rejects the MPSC ring this tier
## replaces on one argument above all others: a bounded ring's only answers when
## full are dropping a correctly-produced record or blocking a producer,
## *"neither is acceptable, and no third answer exists for a fixed-capacity"*
## structure. §6.1's counter-claim is that the grow-only set has no full state —
## *"No producer ever blocks and no consumer ever drains, so backpressure does
## not arise."* That is a claim about behaviour under a load a fixed capacity
## cannot absorb, so the only honest test is to APPLY such a load, concurrently,
## and count what survives.
##
## The second property is the one that makes eviction work at all. §6.5 spends a
## paragraph on a single word: a tombstone's generation must be FRESH, not
## merely current, because liveness is a STRICT comparison and a tombstone that
## ties the generation of the record it retires leaves the key live and loses
## the eviction silently. A rule whose failure is silent needs a test that is
## not.
##
## NO MOCKS. Every case drives the real `nim-shm-gset` chain through the real
## `action_index` element layer over real `mmap(MAP_SHARED)` shard files under a
## real temp cache root. The multi-producer case uses real PROCESSES, because
## the property under test is cross-process and a thread pool would not
## reproduce it.

import std/[os, osproc, sets, streams, strutils, tempfiles, times, unittest]

import repro_hash
import repro_local_store

import repro_test_support

proc asBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.ac4.index." & name),
    hdActionFingerprint)

proc strongFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.ac4.index.strong." & name),
    hdActionFingerprint)

const
  WorkerFlag = "--ac4-index-storm-worker"
  StormProducers = 6
    ## Concurrent PRODUCER PROCESSES. §12.F's measured comparison used six.
  StormElementsPerProducer = 5_000
    ## Distinct elements each producer inserts. Six of these is 30,000 distinct
    ## keys — two orders of magnitude past the 256-slot inline geometry the ring
    ## tier shipped with, and past shard0's own slot array, so the chain MUST
    ## grow rather than refuse.
  StormReobservations = 8
    ## Re-inserts of every element. This is the duplication the structure
    ## absorbs at the liveness probe without writing anything: it is what makes
    ## the set bounded by DISTINCT ELEMENTS rather than by events.
  StormBlockedThresholdSeconds = 0.050
    ## No single insert may take this long. A ring with blocking backpressure
    ## parks a producer for as long as the consumer takes to drain; a grow-only
    ## insert is a probe run plus at most one arena bump and one CAS, and a
    ## GROWTH is one file creation. 50 ms is two orders of magnitude above the
    ## latter and well below the former under a full ring.

proc runStormWorker(cacheRoot, tag: string) =
  ## One producer process. Inserts `StormElementsPerProducer` distinct record
  ## elements, each `StormReobservations + 1` times, into ONE shared chain, and
  ## reports the longest single insert it observed.
  ##
  ## Exit codes are the assertion surface, because a worker cannot `check`:
  ##   20  the chain would not attach at all
  ##   21  an insert returned `isSaturated` — growth itself failed, which is the
  ##       ONLY failure a grow-only insert has, and it must not happen here
  ##   22  an insert blocked longer than the threshold
  var cache = openActionCache(cacheRoot)
  if cache.shm == nil or not cache.shm.enabled:
    quit(20)
  let idx = cache.shm.idx
  var worstSeconds = 0.0
  for i in 0 ..< StormElementsPerProducer:
    let weak = weakFor("storm-" & tag & "-" & $i)
    let strong = strongFor("storm-" & tag & "-" & $i)
    for r in 0 .. StormReobservations:
      let started = epochTime()
      let status = idx.insertRecord(weak, strong)
      let took = epochTime() - started
      if took > worstSeconds: worstSeconds = took
      if status == isSaturated:
        quit(21)
  if worstSeconds > StormBlockedThresholdSeconds:
    stderr.writeLine("worst insert " & $worstSeconds & " s")
    quit(22)
  cache.closeShmTier()
  quit(0)

when isMainModule:
  let params = commandLineParams()
  if params.len >= 2 and params[0] == WorkerFlag:
    runStormWorker(params[1], params[2])
    quit(0)

suite "integration_action_index_backpressure_and_tombstones":
  when actionIndexSupported:

    test "concurrent producers far past any fixed capacity: none blocks, none is dropped":
      # THE BACK-PRESSURE PROOF (§6.1 against §12.F).
      #
      # Six processes insert 30,000 distinct elements with a 9x duplication
      # ratio — 270,000 insert calls — into one chain whose shard0 holds 4,096
      # slots. A fixed-capacity structure of that geometry has exactly two
      # answers here and both are failures: refuse the 26,000th element, or park
      # the producer that submitted it. The grow-only set has a third: shard.
      #
      # The assertions are the two halves of the claim, and neither is a
      # restatement of the other. NOTHING BLOCKS is enforced inside each worker
      # (exit 22 if any single insert exceeded the threshold) and again here by
      # the wall-clock bound. NOTHING IS DROPPED is enforced by reading every
      # key back afterwards, from a SEPARATE handle, and requiring all 30,000.
      let tempRoot = createTempDir("repro-ac4-storm", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / ".repro" / "action-cache"
      var seed = openActionCache(cacheRoot)
      check seed.shm != nil
      check seed.shm.enabled
      seed.closeShmTier()

      let self = getAppFilename()
      let started = epochTime()
      var procs: seq[Process] = @[]
      for w in 0 ..< StormProducers:
        procs.add(startProcess(self,
          args = @[WorkerFlag, cacheRoot, "w" & $w],
          options = {poStdErrToStdOut}))
      var allOk = true
      for p in procs:
        let code = p.waitForExit()
        if code != 0:
          allOk = false
          checkpoint("producer exited " & $code & ": " &
            p.outputStream.readAll())
        p.close()
      let elapsed = epochTime() - started
      check allOk

      # A blocked producer is the failure mode; the bound is generous enough
      # that it can only be tripped by blocking, never by a slow machine.
      check elapsed < 120.0

      # NOTHING WAS DROPPED. Every one of the 30,000 distinct keys is readable
      # from a handle that did none of the inserting.
      var reader = openActionCache(cacheRoot)
      defer: reader.closeShmTier()
      check reader.shm.enabled
      var missing = 0
      var found = 0
      for w in 0 ..< StormProducers:
        for i in 0 ..< StormElementsPerProducer:
          let tag = "storm-w" & $w & "-" & $i
          let weak = weakFor(tag)
          let want = strongFor(tag)
          var hit = false
          for strong in reader.shm.idx.enumerateEdge(weak).liveStrong:
            if strong == want: hit = true
          if hit: inc found else: inc missing
      checkpoint("distinct elements recovered: " & $found & ", missing: " &
        $missing)
      check missing == 0
      check found == StormProducers * StormElementsPerProducer

      # The structure absorbed the duplication WITHOUT growing with it: the
      # element count tracks distinct keys, not the 270,000 insert calls. This
      # is the property §12.E and §6.1 both turn on, and it is what makes the
      # absence of backpressure possible at all — the ring had to carry every
      # event.
      let counters = reader.actionIndexCounters()
      checkpoint("shards=" & $counters.shards & " liveElements=" &
        $counters.liveElements)
      check counters.growthFailed == 0
      check counters.shards > 1        # it GREW rather than refusing
      check counters.liveElements >=
        uint64(StormProducers * StormElementsPerProducer)
      check counters.liveElements <
        uint64(StormProducers * StormElementsPerProducer * 2)

    test "a tombstone retires the record it names, and a resurrection survives it":
      # THE TOMBSTONE-GENERATION PROOF (§6.5).
      #
      # The rule is that a key is live iff no tombstone for it bears a
      # generation NEWER than the newest record element for that key, with
      # "newer" strict. Three states are exercised in order — live, retired,
      # resurrected — and each is read back from the real chain.
      let tempRoot = createTempDir("repro-ac4-tomb", "")
      defer: removeDir(tempRoot)
      var cache = openActionCache(tempRoot / ".repro" / "action-cache")
      defer: cache.closeShmTier()
      check cache.shm.enabled
      let idx = cache.shm.idx
      let weak = weakFor("tombstoned-edge")
      let strong = strongFor("tombstoned-edge")

      proc liveStrongs(): seq[ContentDigest] =
        idx.enumerateEdge(weak).liveStrong

      check idx.insertRecord(weak, strong) == isInserted
      check liveStrongs() == @[strong]

      # A re-insert of a LIVE identity writes nothing at all (§6.4 step 1) —
      # which is what keeps a re-record of an unchanged path-set free of any
      # shared-memory mutation.
      let beforeReinsert = idx.liveElementCount()
      check idx.insertRecord(weak, strong) == isExists
      check idx.liveElementCount() == beforeReinsert

      # THE MUTATION THIS CASE EXISTS FOR. `evictRecord` allocates a FRESH
      # generation with a fetch-add. Change that to "read the current value"
      # and the tombstone TIES the record's generation instead of exceeding it;
      # the strict comparison in the liveness rule then leaves the key live and
      # the eviction is silently lost. This assertion is the only thing that
      # notices.
      let generationBefore = idx.currentGenerationValue()
      check idx.evictRecord(weak, strong) == isInserted
      check idx.currentGenerationValue() > generationBefore
      check liveStrongs().len == 0

      # A resurrection needs a generation newer than the tombstone and no
      # coordination with whoever wrote it.
      check idx.insertRecord(weak, strong) == isInserted
      check liveStrongs() == @[strong]

      # Both the record and its tombstone are still PRESENT — nothing is ever
      # removed from the set. Liveness is a computed property of the run, not a
      # deletion.
      check idx.liveElementCount() >= 3'u64

    test "an edge's probe run enumerates exactly its own keys, past foreign collisions":
      # §6.3: the primary hash is over the WEAK fingerprint alone, so every
      # element of one edge shares a home slot and occupies one contiguous
      # probe run — and a run may legitimately interleave foreign keys, which
      # the stored-weak-fingerprint filter handles at one comparison each.
      #
      # Falsifiable: revert `primaryKeySpan` to the whole element and the
      # elements of one edge scatter across the table, so this enumeration
      # returns a strict subset.
      let tempRoot = createTempDir("repro-ac4-runs", "")
      defer: removeDir(tempRoot)
      var cache = openActionCache(tempRoot / ".repro" / "action-cache")
      defer: cache.closeShmTier()
      let idx = cache.shm.idx

      const Edges = 64
      const PathSetsPerEdge = 5
      for e in 0 ..< Edges:
        let weak = weakFor("run-" & $e)
        for p in 0 ..< PathSetsPerEdge:
          check idx.insertRecord(weak, strongFor("run-" & $e & "-" & $p)) ==
            isInserted
        check idx.insertEdgeComplete(weak) == isInserted

      var sawForeign = 0
      for e in 0 ..< Edges:
        let weak = weakFor("run-" & $e)
        let view = idx.enumerateEdge(weak)
        sawForeign += view.foreign
        check view.complete
        var got = initHashSet[string]()
        for strong in view.liveStrong:
          got.incl(toHex(strong.bytes))
        check got.len == PathSetsPerEdge
        for p in 0 ..< PathSetsPerEdge:
          check toHex(strongFor("run-" & $e & "-" & $p).bytes) in got
      # The run walks to the first EMPTY slot, so it is bounded by the cluster
      # rather than by the edge and foreign members are expected. Reporting the
      # count keeps the "one comparison each" claim observable rather than
      # merely asserted.
      checkpoint("foreign elements filtered across " & $Edges & " runs: " &
        $sawForeign)
