## Action-Cache-Per-Edge-Store.md §6.2, §11.1 — the premise of the whole
## change, stated as a red case rather than as prose.
##
## The tier this replaces was an MPSC ring with a fixed 256-byte inline
## submission slot. §3 measured a live developer cache at a p50 record of 8,914
## bytes and a mean of 232,330, so only 7.0% of records fit; the other 93% were
## refused. The refusal was not merely lossy, it could not converge: the submit
## always failed, so the shared read could never hit, so the warm-on-miss path
## re-encoded the same doomed record on the next build, every build, forever.
## Worse, the encoded size is dominated by absolute path strings, so the SAME
## graph was admitted or excluded depending on how deep the checkout happened to
## be — roughly one byte per character of cache root, with the cliff near 102
## characters.
##
## §6.2's element is 84 bytes and is a pure function of `(kind, weak, strong,
## generation, tombstone)`. Nothing about the record it denotes can change that.
## This file records a record that is orders of magnitude past every historical
## cap — 12,000 inputs, ~600 KB encoded even after the §5.5 C4 path interning,
## i.e. 2,400x the inline slot and 9x the ceiling a 16-bit length field imposes
## on any inline scheme — and requires a SECOND ENGINE PROCESS to find it in the
## index and hit on it.
##
## Falsifiable: reinstate any size test on the write path and the element is
## absent, so the second process's enumeration comes back empty and its lookup
## misses. Nothing else in the suite would notice, because Tier 1 would still
## serve the record correctly — which is precisely how the old cliff stayed
## invisible for as long as it did.
##
## NO MOCKS. A real record with real input files on a real filesystem, a real
## chain, and a real second process reading it.

import std/[os, osproc, streams, strutils, tempfiles, unittest]

import repro_hash
import repro_local_store

import repro_test_support

proc asBytes(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i, ch in text:
    result[i] = byte(ord(ch))

proc weakFor(name: string): ContentDigest =
  blake3DomainDigest(asBytes("reprobuild.ac4c.oversized." & name),
    hdActionFingerprint)

const
  ReaderFlag = "--ac4c-oversized-reader"
  WideInputs = 12_000
    ## Far past the ~102-character root cliff, past the 256 B slot by three
    ## orders of magnitude, and past the 65,535 B ceiling a 16-bit length field
    ## imposed on any inline scheme (§12.A).

proc buildWideFixture(work: string): seq[string] =
  ## `WideInputs` real files, in nested directories so the record's interned
  ## path table has real prefixes to intern and the encoding is representative
  ## rather than degenerate.
  for i in 0 ..< WideInputs:
    let dir = work / "inputs" / ("d" & $(i div 100))
    createDir(dir)
    let path = dir / ("input-" & $i & ".txt")
    writeFile(path, "wide-input-" & $i & "\n")
    result.add(path)

proc runReaderProcess(cacheRoot, casRoot, work: string) =
  ## A SECOND ENGINE PROCESS. It attaches the chain it did not create,
  ## enumerates the edge, and requires the element to be there — then takes the
  ## ordinary lookup and requires a hit.
  ##
  ## Exit codes:
  ##   30  the chain would not attach
  ##   31  no live record element for the edge — the size cliff is back
  ##   32  the lookup did not hit
  ##   33  the edge did not become complete once this process had read it
  ##   34  a §11 counter is nonzero on what should be a healthy root
  let cas = openLocalCas(casRoot)
  var cache = openActionCache(cacheRoot)
  if cache.shm == nil or not cache.shm.enabled: quit(30)
  let weak = weakFor("wide-edge")
  # The write path inserts the RECORD element (§9 step 3); the `edge-complete`
  # element is published by whoever takes the union read (§8 step 5). So the
  # thing that proves the record entered the index at all is the live key, and
  # it is checked before anything has had a chance to warm this process's view.
  let view = cache.shm.idx.enumerateEdge(weak)
  if view.liveStrong.len != 1: quit(31)
  let hit = cache.lookupActionResult(cas, weak, ffpChecksum, outputRoot = work)
  if hit.status != aclHit: quit(32)
  if hit.record.strongFingerprint != view.liveStrong[0]: quit(32)
  if not cache.shm.idx.enumerateEdge(weak).complete: quit(33)
  let counters = cache.actionIndexCounters()
  if counters.growthFailed != 0 or counters.unresolvedReferences != 0 or
      counters.bypassWrites != 0:
    stderr.writeLine("growthFailed=" & $counters.growthFailed &
      " unresolved=" & $counters.unresolvedReferences &
      " bypass=" & $counters.bypassWrites)
    quit(34)
  cache.closeShmTier()
  quit(0)

when isMainModule:
  let params = commandLineParams()
  if params.len >= 3 and params[0] == ReaderFlag:
    runReaderProcess(params[1], params[2], params[3])
    quit(0)

suite "integration_action_cache_oversized_record_is_indexed":
  when isNixSupported and actionIndexSupported:

    test "a record far past every historical cap is indexed and hits from another process":
      let tempRoot = createTempDir("repro-ac4c-oversized", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / ".repro" / "action-cache"
      let casRoot = tempRoot / ".repro" / "cas"
      let work = tempRoot / "work"
      createDir(work)
      let cas = openLocalCas(casRoot)
      var cache = openActionCache(cacheRoot)
      check cache.shm.enabled

      let inputs = buildWideFixture(work)
      writeFile(work / "wide-out.txt", "wide-output\n")
      let weak = weakFor("wide-edge")
      let recorded = cache.recordActionResult(cas, weak, ffpChecksum,
        inputs, ["wide-out.txt"], work)

      # State the size, so the fixture cannot silently shrink under a later
      # edit and leave the case passing for the wrong reason.
      let encodedBytes = encodeActionResultRecord(recorded).len
      checkpoint("record encodes to " & $encodedBytes & " bytes over " &
        $recorded.inputs.len & " inputs")
      check recorded.inputs.len >= 10_000
      check encodedBytes > 500_000       # 2,000x the retired 256 B inline slot
      check encodedBytes > 65_535        # past any 16-bit length field

      # The element is 84 bytes regardless of all that, and it is present.
      let view = cache.shm.idx.enumerateEdge(weak)
      check view.liveStrong.len == 1
      check view.liveStrong[0] == recorded.strongFingerprint

      # A second, independent engine process finds it and hits on it.
      let self = getAppFilename()
      let reader = startProcess(self,
        args = @[ReaderFlag, cacheRoot, casRoot, work],
        options = {poStdErrToStdOut})
      let code = reader.waitForExit()
      if code != 0:
        checkpoint("reader exited " & $code & ": " &
          reader.outputStream.readAll())
      reader.close()
      check code == 0

      let counters = cache.actionIndexCounters()
      check counters.growthFailed == 0
      check counters.unresolvedReferences == 0
      cache.closeShmTier()

    test "the index cost of an edge is bounded by its keys, not by its bytes":
      # §12.C's arithmetic, measured rather than inherited. One edge whose
      # record is over a megabyte contributes the same 84-byte element as one
      # whose record is a hundred bytes, so the chain's size tracks the KEY
      # count. This is the trade the design makes explicit: the index gives up
      # caching record content and in exchange is bounded by distinct keys.
      let tempRoot = createTempDir("repro-ac4c-size", "")
      defer: removeDir(tempRoot)
      let cacheRoot = tempRoot / ".repro" / "action-cache"
      let casRoot = tempRoot / ".repro" / "cas"
      let work = tempRoot / "work"
      createDir(work)
      let cas = openLocalCas(casRoot)
      var cache = openActionCache(cacheRoot)
      defer: cache.closeShmTier()

      writeFile(work / "small-in.txt", "small\n")
      writeFile(work / "small-out.txt", "small-out\n")
      discard cache.recordActionResult(cas, weakFor("small"), ffpChecksum,
        [work / "small-in.txt"], ["small-out.txt"], work)
      let elementsAfterSmall = cache.actionIndexCounters().liveElements

      let inputs = buildWideFixture(work)
      writeFile(work / "big-out.txt", "big-out\n")
      let big = cache.recordActionResult(cas, weakFor("big"), ffpChecksum,
        inputs, ["big-out.txt"], work)
      let elementsAfterBig = cache.actionIndexCounters().liveElements

      let bigBytes = encodeActionResultRecord(big).len
      checkpoint("small record indexed with " & $elementsAfterSmall &
        " elements; a " & $bigBytes & "-byte record added " &
        $(elementsAfterBig - elementsAfterSmall))
      # Exactly one more element for a record four orders of magnitude larger.
      check elementsAfterBig - elementsAfterSmall == 1'u64
      check bigBytes > 500_000
