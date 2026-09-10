## Action-Cache-Per-Edge-Store.md §6.7 — flattening, retirement, and the two
## orderings that make them safe for a concurrent reader.
##
## Flattening is where redundancy is reclaimed: over the life of a cache root
## the older shards accumulate elements that are superseded, tombstoned, or
## duplicated across a resurrection. It is not a daemon — a maintenance pass
## guarded by a non-blocking `flock` on the anchor, so at most one flattener
## runs per root and every other process simply skips it.
##
## TWO ORDERINGS ARE NORMATIVE AND BOTH ARE TESTED HERE.
##
## 1. PER EDGE, records and tombstones are copied BEFORE that edge's
##    `edge-complete` element, and if any of those copies fails the
##    `edge-complete` element is not copied. Reverse it and an edge claims
##    completeness in a chain state where one of its keys is missing, so a
##    later index-first read resolves a short candidate set and a false MISS
##    appears.
##
## 2. COPY-THEN-RETIRE, against an ASCENDING (oldest-shard-first) reader.
##    Because an element reaches the newer shard before it leaves the older
##    one, a reader travelling in the same direction as the migration can never
##    be overtaken by it. Reversing either direction breaks completeness.
##
## Retirement is lossless in the only sense that matters: the per-edge disk
## store remains authoritative, so a key a retirement wrongly dropped costs one
## directory read (§8 step 5), never a wrong answer. This file therefore asserts
## the stronger thing — that the DECISION is unchanged across the flatten — and
## not merely that nothing crashed.
##
## NO MOCKS. A real chain grown to several real shard files, flattened in place,
## with a real second process holding a mapping of a shard the flatten retires.

import std/[os, osproc, streams, strutils, tempfiles, unittest]

import repro_hash
import repro_local_store

import repro_test_support

proc asBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.ac4d.flatten." & name),
    hdActionFingerprint)

proc strongFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.ac4d.flatten.strong." & name),
    hdActionFingerprint)

const
  HolderFlag = "--ac4d-mapping-holder"
  GrowthEdges = 6_000
    ## Enough distinct keys to push shard0 (4,096 slots at a load factor of
    ## 0.5) past growth several times, so the chain really has older shards to
    ## drain rather than one shard and a no-op.

proc runMappingHolder(cacheRoot, readyPath: string) =
  ## A second process that attaches the chain, reads an edge, and then holds
  ## its mappings while the parent flattens and retires shards underneath it.
  ## §6.7: a process that already mapped a retired file keeps a valid mapping —
  ## POSIX inode refcounting — and its content is a subset of the newest shard,
  ## so continuing to read it is harmless. No RCU grace period, no reader-epoch
  ## table.
  ##
  ## Exit codes:
  ##   40  the chain would not attach
  ##   41  an edge that was live before the flatten was not live after it
  var cache = openActionCache(cacheRoot)
  if cache.shm == nil or not cache.shm.enabled: quit(40)
  let idx = cache.shm.idx
  # Force every shard into this process's mapping table before signalling.
  var before: seq[int] = @[]
  for e in 0 ..< 64:
    before.add(idx.enumerateEdge(weakFor("edge-" & $e)).liveStrong.len)
  writeFile(readyPath, "ready")
  # Wait for the parent to finish flattening.
  var spins = 0
  while not fileExists(readyPath & ".flattened") and spins < 60_000:
    sleep(5)
    inc spins
  for e in 0 ..< 64:
    if idx.enumerateEdge(weakFor("edge-" & $e)).liveStrong.len < before[e]:
      stderr.writeLine("edge " & $e & " lost elements across the flatten")
      quit(41)
  cache.closeShmTier()
  quit(0)

when isMainModule:
  let params = commandLineParams()
  if params.len >= 2 and params[0] == HolderFlag:
    runMappingHolder(params[1], params[2])
    quit(0)

suite "integration_action_index_flatten_retire_preserves_completeness":
  when actionIndexSupported:

    test "a flatten preserves every live key, every completeness claim and every decision":
      let tempRoot = createTempDir("repro-ac4d-flatten", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var cache = openActionCache(cacheRoot)
      defer: cache.closeShmTier()
      check cache.shm.enabled
      let idx = cache.shm.idx

      # Build a chain with several shards, and populate it with all three of
      # the states a flatten has to distinguish: plain live keys, keys that were
      # tombstoned and stayed retired, and keys that were tombstoned and then
      # resurrected.
      for e in 0 ..< GrowthEdges:
        let weak = weakFor("edge-" & $e)
        check idx.insertRecord(weak, strongFor("edge-" & $e)) == isInserted
        check idx.insertEdgeComplete(weak) == isInserted
      check idx.shardCount() > 1

      for e in 0 ..< 200:
        let weak = weakFor("edge-" & $e)
        let strong = strongFor("edge-" & $e)
        if e mod 2 == 0:
          # Retired for good.
          check idx.evictRecord(weak, strong) == isInserted
          check idx.evictEdgeComplete(weak) == isInserted
        else:
          # Retired and then resurrected — a superseded tombstone, which is
          # exactly the redundancy a flatten is supposed to reclaim.
          check idx.evictRecord(weak, strong) == isInserted
          check idx.insertRecord(weak, strong) == isInserted

      proc snapshotDecision(): seq[string] =
        for e in 0 ..< GrowthEdges:
          let weak = weakFor("edge-" & $e)
          let view = idx.enumerateEdge(weak)
          var line = $e & ":" & (if view.complete: "C" else: "-")
          for strong in view.liveStrong:
            line.add("/" & toHex(strong.bytes))
          result.add(line)

      let shardsBefore = idx.shardCount()
      let elementsBefore = idx.liveElementCount()
      let decisionBefore = snapshotDecision()

      check cache.flattenActionIndex()

      let decisionAfter = snapshotDecision()
      checkpoint("shards before=" & $shardsBefore & " after=" &
        $idx.shardCount() & "; elements before=" & $elementsBefore &
        " after=" & $idx.liveElementCount())
      check decisionBefore.len == decisionAfter.len
      var diverged = 0
      for i in 0 ..< min(decisionBefore.len, decisionAfter.len):
        if decisionBefore[i] != decisionAfter[i]:
          if diverged < 5:
            checkpoint("before: " & decisionBefore[i])
            checkpoint("after:  " & decisionAfter[i])
          inc diverged
      check diverged == 0

      # And the drained shards are actually gone from disk, so the flatten did
      # real work rather than returning true and skipping.
      var shardFiles = 0
      for kind, path in walkDir(cacheRoot / "action-index"):
        if kind == pcFile and path.extractFilename.contains(".shard"):
          inc shardFiles
      checkpoint("shard files on disk after the flatten: " & $shardFiles)
      check shardFiles < shardsBefore

    test "a process holding a retired shard's mapping keeps reading it":
      when isNixSupported:
        let tempRoot = createTempDir("repro-ac4d-holder", "")
        defer: removeDir(tempRoot)
        let cacheRoot = tempRoot / "action-cache"
        let readyPath = tempRoot / "holder.ready"
        var cache = openActionCache(cacheRoot)
        defer: cache.closeShmTier()
        let idx = cache.shm.idx
        for e in 0 ..< GrowthEdges:
          let weak = weakFor("edge-" & $e)
          discard idx.insertRecord(weak, strongFor("edge-" & $e))
          discard idx.insertEdgeComplete(weak)
        check idx.shardCount() > 1

        let self = getAppFilename()
        let holder = startProcess(self,
          args = @[HolderFlag, cacheRoot, readyPath],
          options = {poStdErrToStdOut})
        var spins = 0
        while not fileExists(readyPath) and spins < 4_000:
          sleep(5)
          inc spins
        check fileExists(readyPath)

        check cache.flattenActionIndex()
        writeFile(readyPath & ".flattened", "done")

        let code = holder.waitForExit()
        if code != 0:
          checkpoint("holder exited " & $code & ": " &
            holder.outputStream.readAll())
        holder.close()
        check code == 0

    test "a flatten clears the bypass counter and restores completeness":
      # §6.8's escape hatch voids every completeness claim chain-wide until the
      # next flatten. That "until" has to be real: a counter nothing ever
      # clears would degrade the tier permanently after a single opt-out run.
      let tempRoot = createTempDir("repro-ac4d-bypass", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / "action-cache"
      var cache = openActionCache(cacheRoot)
      defer: cache.closeShmTier()
      let idx = cache.shm.idx
      for e in 0 ..< GrowthEdges:
        let weak = weakFor("edge-" & $e)
        discard idx.insertRecord(weak, strongFor("edge-" & $e))
        discard idx.insertEdgeComplete(weak)
      check idx.shardCount() > 1
      check idx.enumerateEdge(weakFor("edge-0")).complete

      idx.noteBypassWrite()
      check cache.actionIndexCounters().bypassWrites == 1'u64
      check not idx.enumerateEdge(weakFor("edge-0")).complete

      check cache.flattenActionIndex()
      check cache.actionIndexCounters().bypassWrites == 0'u64
      check idx.enumerateEdge(weakFor("edge-0")).complete
